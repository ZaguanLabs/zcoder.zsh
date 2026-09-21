#!/usr/bin/env zsh
# zcoder.zsh - a Zsh-first Ollama coding agent.

0="${ZERO:-${${0:#$ZSH_ARGZERO}:-${(%):-%N}}}"
0="${${(M)0:#/*}:-$PWD/$0}"
source "${0:A:h}/lib/runtime.zsh"
# Sourced entrypoints retain their caller's shell state and test/tool hooks.
if [[ $ZSH_EVAL_CONTEXT == toplevel ]]; then
  zcoder_runtime_select "$0" "$@" || exit $?
fi

setopt EXTENDED_GLOB NO_NOMATCH NO_MONITOR NO_NOTIFY NO_CHECK_JOBS NO_HUP 2>/dev/null
zmodload zsh/datetime zsh/files zsh/mapfile zsh/net/tcp zsh/system zsh/zselect || {
  print -u2 -- "Error: required Zsh loadable modules are unavailable."
  exit 1
}

typeset -gr ZCODER_NAME="zcoder.zsh"
typeset -gr ZCODER_VERSION="0.18.3"

typeset -gr ZCODER_DIR="${0:A:h}"

# Load each library once, on demand. Mode-gated libraries — ACP, the remote
# transport, and the external-delegate harnesses — stay unloaded until their
# feature is actually used, trimming launch time and the resident footprint.
typeset -gA ZCODER_LOADED_LIBS=()
zcoder_require() {
  local lib=""
  for lib in "$@"; do
    (( ${+ZCODER_LOADED_LIBS[$lib]} )) && continue
    source "${ZCODER_DIR}/lib/${lib}.zsh" || return $?
    ZCODER_LOADED_LIBS[$lib]=1
  done
}

# The mcp maintenance CLI needs only the configuration and protocol
# libraries; scripts running `zcoder.zsh mcp list` should not pay for the
# full agent runtime.
if [[ "${1:-}" == mcp ]]; then
  shift
  zcoder_require util json instructions mcp || exit $?
  mcp_cli "$@"
  typeset -i mcp_status=$?
  mcp_shutdown_all
  zcoder_runtime_cleanup
  exit "$mcp_status"
fi

zcoder_require util json mcp http instructions skills transcript command_safety tools compact goal agent agent_prompts agent_lfm state input_queue agent_loop || exit $?

# The remote-mode default participates in option parsing before lib/remote.zsh
# loads; that library preserves any value already set here.
typeset -g REMOTE_MODE="${REMOTE_MODE:-local}"

typeset -g ONE_SHOT_PROMPT=""
typeset -g RESUME_SESSION_ID=""
typeset -gi TUI_SESSION_STARTED=0
typeset -gi ACP_MODE=0
typeset -gi RUNNING=1
typeset -gi PRINT_INSTRUCTIONS=0
typeset -gi PRINT_SKILLS=0
typeset -gi ZCODER_MODEL_OVERRIDE=0

usage() {
  print -r -- "Usage: ${ZCODER_NAME} [options]"
  print -r -- "       ${ZCODER_NAME} mcp list|add|get|remove|enable|disable|test ..."
  print -r -- ""
  print -r -- "Options:"
  print -r -- "  -m, --model NAME       Ollama model (default: ${ZCODER_MODEL})"
  print -r -- "  -h, --host HOST        Ollama host (default: ${OLLAMA_HOST})"
  print -r -- "  -w, --workspace PATH   Directory the agent may access (default: current)"
  print -r -- "      --server NAME      Run a headless remote-agent server"
  print -r -- "      --acp              Run as an ACP v1 agent over stdio"
  print -r -- "      --port PORT        Remote-agent server port (default: 7337)"
  print -r -- "      --connect HOST     Connect this UI to a remote-agent server"
  print -r -- "      --token-file PATH  Shared remote authentication token file"
  print -r -- "      --profile NAME     System prompt profile: coding or sysadmin (default: ${ZCODER_PROFILE})"
  print -r -- "      --tool-exposure MODE  Tool schemas: full or staged (default: ${ZCODER_TOOL_EXPOSURE})"
  print -r -- "  -p, --prompt TEXT      Run one prompt without the full-screen UI"
  print -r -- "      --resume ID        Continue a saved session (default: start a new chat)"
  print -r -- "      --context-window N Context tokens to request, or auto (default: ${ZCODER_CONTEXT_WINDOW})"
  print -r -- "      --compact-at PCT   Compact at this context percentage (default: ${ZCODER_COMPACT_PERCENT})"
  print -r -- "      --yes              Allow shell commands (coding profile only)"
  print -r -- "      --deny-commands    Deny shell commands without prompting"
  print -r -- "      --no-think         Ask Ollama not to return model reasoning"
  print -r -- "      --no-warmup        Do not warm the model at interactive startup"
  print -r -- "      --debug            Append diagnostics to /tmp/zcoder-debug-${UID}.log"
  print -r -- "      --debug-log PATH   Append diagnostics to a specific file"
  print -r -- "      --print-instructions  Show the resolved AGENTS.md chain and exit"
  print -r -- "      --print-skills     Show discovered Agent Skills and exit"
  print -r -- "  -V, --version          Show version"
  print -r -- "      --help             Show this help"
}

require_option_value() {
  [[ -n "${2:-}" ]] || { print -u2 -- "Error: $1 requires a value"; exit 2; }
}

while (( $# > 0 )); do
  case "$1" in
    -m|--model) require_option_value "$1" "${2:-}"; ZCODER_MODEL="$2"; ZCODER_MODEL_OVERRIDE=1; shift ;;
    -h|--host)
      require_option_value "$1" "${2:-}"
      if ! ollama_normalize_host "$2"; then print -u2 -- "Error: $HTTP_ERROR"; exit 2; fi
      OLLAMA_HOST="$REPLY"; shift
      ;;
    -w|--workspace)
      require_option_value "$1" "${2:-}"
      [[ -d "$2" ]] || { print -u2 -- "Error: workspace is not a directory: $2"; exit 2; }
      ZCODER_WORKSPACE="${2:A}"; shift
      ;;
    --server)
      require_option_value "$1" "${2:-}"
      [[ "$REMOTE_MODE" == local || "$REMOTE_MODE" == server ]] || { print -u2 -- "Error: --server and --connect cannot be combined"; exit 2; }
      REMOTE_MODE="server"; REMOTE_SERVER_NAME="$2"; shift
      ;;
    --acp)
      ACP_MODE=1
      ;;
    --port) require_option_value "$1" "${2:-}"; REMOTE_SERVER_PORT="$2"; shift ;;
    --connect)
      require_option_value "$1" "${2:-}"
      [[ "$REMOTE_MODE" == local || "$REMOTE_MODE" == client ]] || { print -u2 -- "Error: --server and --connect cannot be combined"; exit 2; }
      REMOTE_MODE="client"; REMOTE_ENDPOINT="$2"; shift
      ;;
    --token-file) require_option_value "$1" "${2:-}"; REMOTE_TOKEN_FILE="$2"; shift ;;
    --profile)
      require_option_value "$1" "${2:-}"
      if ! agent_select_profile "$2"; then print -u2 -- "Error: $REPLY"; exit 2; fi
      shift
      ;;
    --tool-exposure)
      require_option_value "$1" "${2:-}"
      if ! agent_select_tool_exposure "$2"; then print -u2 -- "Error: $REPLY"; exit 2; fi
      shift
      ;;
    -p|--prompt) require_option_value "$1" "${2:-}"; ONE_SHOT_PROMPT="$2"; shift ;;
    --resume)
      require_option_value "$1" "${2:-}"
      _state_valid_id "$2" || { print -u2 -- 'Error: --resume expects a session ID'; exit 2; }
      RESUME_SESSION_ID="$2"; shift
      ;;
    --context-window)
      require_option_value "$1" "${2:-}"
      [[ "$2" == auto || "$2" == <32768-> ]] || { print -u2 -- "Error: --context-window expects auto or an integer of at least 32768"; exit 2; }
      ZCODER_CONTEXT_WINDOW="$2"; shift
      ;;
    --compact-at)
      require_option_value "$1" "${2:-}"
      [[ "$2" == <25-90> ]] || { print -u2 -- "Error: --compact-at expects an integer from 25 through 90"; exit 2; }
      ZCODER_COMPACT_PERCENT="$2"; shift
      ;;
    --yes) ZCODER_COMMAND_POLICY="allow" ;;
    --deny-commands) ZCODER_COMMAND_POLICY="deny" ;;
    --no-think) ZCODER_THINK="false" ;;
    --no-warmup) ZCODER_WARMUP="false" ;;
    --debug) ZCODER_DEBUG_LOG="${TMPDIR:-/tmp}/zcoder-debug-${UID}.log" ;;
    --debug-log)
      require_option_value "$1" "${2:-}"
      ZCODER_DEBUG_LOG="$2"; shift
      ;;
    --print-instructions) PRINT_INSTRUCTIONS=1 ;;
    --print-skills) PRINT_SKILLS=1 ;;
    -V|--version) print -r -- "${ZCODER_NAME} v${ZCODER_VERSION}"; exit 0 ;;
    --help) usage; exit 0 ;;
    --) shift; break ;;
    *) print -u2 -- "Error: unknown option: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ -n "$RESUME_SESSION_ID" ]] && { [[ "$REMOTE_MODE" == server ]] || (( ACP_MODE || PRINT_INSTRUCTIONS || PRINT_SKILLS )); }; then
  print -u2 -- 'Error: --resume cannot be combined with --server, --acp, --print-instructions, or --print-skills'
  exit 2
fi

[[ "$REMOTE_MODE" == local ]] || zcoder_require remote
(( ACP_MODE )) && zcoder_require acp
if (( ACP_MODE )) && [[ "$REMOTE_MODE" == server ]]; then
  print -u2 -- "Error: --acp cannot be combined with --server"
  exit 2
fi

if [[ "$REMOTE_MODE" != server ]] && (( ! ACP_MODE )); then
  zcoder_require curses input terminal process ui overlays commands command_dispatch stream tui
  zcoder_curses_load && zmodload zsh/terminfo || {
    print -u2 -- "Error: required Zsh curses modules are unavailable."
    exit 1
  }
fi

if ! agent_select_profile "$ZCODER_PROFILE"; then
  print -u2 -- "Error: $REPLY"
  exit 2
fi
if ! agent_select_tool_exposure "$ZCODER_TOOL_EXPOSURE"; then
  print -u2 -- "Error: $REPLY"
  exit 2
fi
if [[ "$ZCODER_PROFILE" == sysadmin && "$ZCODER_COMMAND_POLICY" == allow ]]; then
  print -u2 -- "Error: --yes and ZCODER_COMMAND_POLICY=allow are disabled by the sysadmin profile"
  exit 2
fi

ZCODER_WORKSPACE="${ZCODER_WORKSPACE:A}"
if [[ -n "$ZCODER_DEBUG_LOG" ]]; then
  if ! zcoder_debug_init; then
    print -u2 -- "Warning: could not open debug log: $ZCODER_DEBUG_LOG"
  else
    zcoder_debug session "version=$ZCODER_VERSION profile=$ZCODER_PROFILE tool_exposure=$ZCODER_TOOL_EXPOSURE model=${(qqq)ZCODER_MODEL} host=${(qqq)OLLAMA_HOST} workspace=${(qqq)ZCODER_WORKSPACE}"
  fi
fi
typeset -gi REMOTE_HANDSHAKE_PENDING=0
if [[ "$REMOTE_MODE" == client ]]; then
  if ! remote_normalize_endpoint "$REMOTE_ENDPOINT"; then
    print -u2 -- "Error: $REMOTE_ERROR"
    exit 2
  fi
  REMOTE_ENDPOINT="$REPLY"
  if [[ -z "$ONE_SHOT_PROMPT" ]] && (( ! ACP_MODE && ! PRINT_INSTRUCTIONS && ! PRINT_SKILLS )); then
    REMOTE_HANDSHAKE_PENDING=1
  elif ! remote_client_handshake; then
    print -u2 -- "Error: $REMOTE_ERROR"
    exit 1
  fi
else
  instructions_load "$ZCODER_WORKSPACE"
  skills_load "$ZCODER_WORKSPACE"
  if ! mcp_load; then
    print -u2 -- "Warning: $MCP_ERROR"
  fi
fi

if (( PRINT_INSTRUCTIONS )); then
  instructions_summary
  zcoder_fd_safe 1 "$REPLY"; print -r -- "$REPLY"
  if (( ${#INSTRUCTION_SOURCES} > 0 )); then
    print -r -- ""
    instructions_prompt_block
    zcoder_fd_safe 1 "$REPLY"; print -r -- "$REPLY"
  fi
  exit 0
fi

if (( PRINT_SKILLS )); then
  skills_summary
  zcoder_fd_safe 1 "$REPLY"; print -r -- "$REPLY"
  exit 0
fi

if [[ "$REMOTE_MODE" != client ]]; then
  if ! ollama_normalize_host "$OLLAMA_HOST"; then
    print -u2 -- "Error: $HTTP_ERROR"
    exit 2
  fi
  OLLAMA_HOST="$REPLY"
fi

zcoder_resume_notice() {
  (( TUI_SESSION_STARTED )) || return 0
  _state_valid_id "$CURRENT_SESSION_ID" || return 0
  local -a resume_command=("$ZCODER_DIR/zcoder.zsh" --resume "$CURRENT_SESSION_ID")
  local prefix='' resume_home="${ZCODER_HOME:A}" resume_store="${ZCODER_SESSIONS_DIR:A}"
  if [[ "$REMOTE_MODE" == client ]]; then
    (( REMOTE_SESSIONS_SUPPORTED )) || return 0
    resume_command+=(--connect "$REMOTE_ENDPOINT" --token-file "${REMOTE_TOKEN_FILE:A}")
  else
    (( STATE_ENABLED )) || return 0
    resume_command+=(--workspace "$ZCODER_WORKSPACE" --profile "$ZCODER_PROFILE" --host "$OLLAMA_HOST")
    [[ "$ZCODER_HOME" == "${XDG_CONFIG_HOME:-$HOME/.config}/zcoder" ]] || prefix="ZCODER_HOME=${(q)resume_home} "
    [[ "$ZCODER_SESSIONS_DIR" == "$ZCODER_HOME/sessions" ]] || prefix+="ZCODER_SESSIONS_DIR=${(q)resume_store} "
  fi
  print -rl -- '' 'To continue this session, run:' "  $prefix${(j: :)${(@q)resume_command}}"
}

cleanup() {
  local exit_status=$?
  local -i session_saved=1
  trap - INT TERM HUP
  zcoder_debug session_end "status=$exit_status running=$RUNNING async_pid=${HTTP_ASYNC_PID:-none} delegate_pid=${DELEGATE_PID:-none}"
  RUNNING=0
  (( $+functions[tool_process_cleanup] )) && tool_process_cleanup
  (( $+functions[acp_shutdown] )) && acp_shutdown
  if [[ "$REMOTE_MODE" != server ]] && (( $+functions[state_save_session] )); then
    state_save_session || session_saved=0
  fi
  (( $+functions[delegate_async_cancel] )) && delegate_async_cancel
  (( $+functions[remote_client_idle_cancel] )) && remote_client_idle_cancel
  agent_context_discovery_cancel
  http_async_cancel
  (( $+functions[relay_stop] )) && relay_stop
  (( $+functions[remote_server_stop] )) && remote_server_stop
  mcp_shutdown_all
  (( $+functions[ui_end] )) && ui_end
  zcoder_debug_close
  zcoder_runtime_cleanup
  (( session_saved )) && zcoder_resume_notice
  return "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Headless modes do not need the terminal command handlers or event loop.
if (( ACP_MODE )); then
  [[ -z "$ONE_SHOT_PROMPT" ]] || { print -u2 -- "Error: --acp and --prompt cannot be combined"; exit 2; }
  acp_main
  exit $?
elif [[ "$REMOTE_MODE" == server ]]; then
  [[ -z "$ONE_SHOT_PROMPT" ]] || { print -u2 -- "Error: --server and --prompt cannot be combined"; exit 2; }
  remote_server_main
  exit $?
fi


if [[ -n "$ONE_SHOT_PROMPT" ]]; then
  if [[ -n "$RESUME_SESSION_ID" && "$REMOTE_MODE" != client ]] && ! state_init resume "$RESUME_SESSION_ID"; then
    print -u2 -r -- "Error: could not resume $RESUME_SESSION_ID: $STATE_ERROR"
    exit 1
  fi
  if [[ "$ONE_SHOT_PROMPT" == /goal || "$ONE_SHOT_PROMPT" == /goal\ * ]]; then
    goal_handle_command "$ONE_SHOT_PROMPT"
  else
    agent_user_turn "$ONE_SHOT_PROMPT"
  fi
else
  [[ -t 0 && -t 1 ]] || { print -u2 -- "Error: interactive mode requires a terminal; use --prompt for one-shot mode"; exit 2; }
  main_tui
fi
