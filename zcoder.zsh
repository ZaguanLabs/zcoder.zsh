#!/usr/bin/env zsh
# zcoder.zsh - a Zsh-first Ollama coding agent.

setopt EXTENDED_GLOB NO_NOMATCH NO_MONITOR NO_NOTIFY NO_CHECK_JOBS NO_HUP 2>/dev/null
zmodload zsh/datetime zsh/files zsh/mapfile zsh/net/tcp zsh/system zsh/zselect || {
  print -u2 -- "Error: required Zsh loadable modules are unavailable."
  exit 1
}

typeset -gr ZCODER_NAME="zcoder.zsh"
typeset -gr ZCODER_VERSION="0.11.3"

0="${ZERO:-${${0:#$ZSH_ARGZERO}:-${(%):-%N}}}"
0="${${(M)0:#/*}:-$PWD/$0}"
typeset -gr ZCODER_DIR="${0:A:h}"

# Load each library once, on demand. Mode-gated libraries — ACP, the remote
# transport, and the external-delegate harnesses — stay unloaded until their
# feature is actually used, trimming launch time and the resident footprint.
typeset -gA ZCODER_LOADED_LIBS=()
zcoder_require() {
  local lib=""
  for lib in "$@"; do
    (( ${+ZCODER_LOADED_LIBS[$lib]} )) && continue
    ZCODER_LOADED_LIBS[$lib]=1
    source "${ZCODER_DIR}/lib/${lib}.zsh"
  done
}

# The mcp maintenance CLI needs only the configuration and protocol
# libraries; scripts running `zcoder.zsh mcp list` should not pay for the
# full agent runtime.
if [[ "${1:-}" == mcp ]]; then
  shift
  zcoder_require util json instructions mcp
  mcp_cli "$@"
  typeset -i mcp_status=$?
  mcp_shutdown_all
  zcoder_runtime_cleanup
  exit "$mcp_status"
fi

zcoder_require util json mcp http instructions skills transcript tools compact goal agent state

# The remote-mode default participates in option parsing before lib/remote.zsh
# loads; that library preserves any value already set here.
typeset -g REMOTE_MODE="${REMOTE_MODE:-local}"

typeset -g ONE_SHOT_PROMPT=""
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

[[ "$REMOTE_MODE" == local ]] || zcoder_require remote
(( ACP_MODE )) && zcoder_require acp
if (( ACP_MODE )) && [[ "$REMOTE_MODE" == server ]]; then
  print -u2 -- "Error: --acp cannot be combined with --server"
  exit 2
fi

if [[ "$REMOTE_MODE" != server ]] && (( ! ACP_MODE )); then
  zcoder_require input terminal process ui overlays commands stream
  zmodload zsh/curses zsh/terminfo || {
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
if [[ "$REMOTE_MODE" == client ]]; then
  if ! remote_normalize_endpoint "$REMOTE_ENDPOINT"; then
    print -u2 -- "Error: $REMOTE_ERROR"
    exit 2
  fi
  REMOTE_ENDPOINT="$REPLY"
  if ! remote_client_handshake; then
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

cleanup() {
  local exit_status=$?
  trap - INT TERM HUP
  zcoder_debug session_end "status=$exit_status running=$RUNNING async_pid=${HTTP_ASYNC_PID:-none} delegate_pid=${DELEGATE_PID:-none}"
  RUNNING=0
  (( $+functions[tool_process_cleanup] )) && tool_process_cleanup
  (( $+functions[acp_shutdown] )) && acp_shutdown
  [[ "$REMOTE_MODE" != server ]] && (( $+functions[state_save_session] )) && state_save_session
  (( $+functions[delegate_async_cancel] )) && delegate_async_cancel
  http_async_cancel
  (( $+functions[relay_stop] )) && relay_stop
  (( $+functions[remote_server_stop] )) && remote_server_stop
  mcp_shutdown_all
  (( $+functions[ui_end] )) && ui_end
  zcoder_debug_close
  zcoder_runtime_cleanup
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

zcoder_refresh_sessions() {
  if [[ "$REMOTE_MODE" == client && ${REMOTE_SESSIONS_SUPPORTED:-0} -eq 1 ]]; then
    remote_client_refresh_sessions
  else
    state_save_and_refresh
  fi
  (( $+functions[relay_refresh_manifest] )) && relay_refresh_manifest || true
}

zcoder_delegate_host_label() {
  if [[ "$REMOTE_MODE" == client ]]; then
    REPLY="remote server '${REMOTE_SERVER_NAME:-unknown}'"
  else
    REPLY="this zcoder host"
  fi
}

zcoder_delegate_require_available() {
  local provider="$1" host_label=""
  if [[ "$REMOTE_MODE" == client ]]; then
    (( ${REMOTE_HARNESS_DISCOVERY_SUPPORTED:-0} )) || return 0
  else
    delegate_refresh_availability
  fi
  zcoder_delegate_host_label; host_label="$REPLY"
  delegate_require_available "$provider" "$host_label"
}

zcoder_delegate_availability_summary() {
  local host_label=""
  if [[ "$REMOTE_MODE" == client && ${REMOTE_HARNESS_DISCOVERY_SUPPORTED:-0} -ne 1 ]]; then
    REPLY="External harness availability is not reported by this remote server."
    return 0
  fi
  [[ "$REMOTE_MODE" == client ]] || delegate_refresh_availability
  zcoder_delegate_host_label; host_label="$REPLY"
  delegate_availability_summary "$host_label"
}

handle_slash_command() {
  local text="$1" value="" provider="" command_name="" previous_value=""
  local -i delegate_status=0
  case "$text" in
    /claude|/claude\ *|/claude!|/claude!\ *|/codex|/codex\ *|/codex!|/codex!\ *|/agy|/agy\ *|/agy!|/agy!\ *|/opencode*|/help|/\?)
      zcoder_require harnesses delegate
      ;;
  esac
  provider=""
  case "$text" in
    /claude|/claude\ *|/claude!|/claude!\ *) provider="claude" ;;
    /codex|/codex\ *|/codex!|/codex!\ *) provider="codex" ;;
    /agy|/agy\ *|/agy!|/agy!\ *) provider="agy" ;;
    /opencode|/opencode\ *|/opencode!|/opencode!\ *|/opencode-model|/opencode-model\ *) provider="opencode" ;;
  esac
  if [[ -n "$provider" ]] && ! zcoder_delegate_require_available "$provider"; then
    ui_append_message error "$DELEGATE_ERROR"
    ui_refresh_all
    return 0
  fi
  case "$text" in
    /commands)
      ui_command_palette
      return 0
      ;;
    /goal|/goal\ *)
      if [[ "$REMOTE_MODE" == client ]]; then
        if (( ${REMOTE_GOALS_SUPPORTED:-0} )); then
          remote_client_user_turn "$text"
        else
          ui_append_message error "Persistent goals are not supported by this remote server."
        fi
      else
        goal_handle_command "$text"
      fi
      (( $+functions[zcoder_refresh_sessions] )) && zcoder_refresh_sessions
      ui_refresh_all
      return 0
      ;;
    /new|/clear)
      if [[ "$REMOTE_MODE" == client ]]; then
        if ! remote_client_new_session; then
          ui_append_message error "Could not create a remote session: $REMOTE_ERROR"
          return 0
        fi
      else
        state_new_session
        agent_warmup_start || true
      fi
      UI_FOCUS="input"
      ui_set_status "Ready"
      ;;
    /sessions)
      if [[ "$REMOTE_MODE" == client && ${REMOTE_SESSIONS_SUPPORTED:-0} -ne 1 ]]; then
        ui_append_message error "Remote session browsing is not supported by this server."
        return 0
      fi
      if (( SIDE_W > 0 )); then
        UI_FOCUS="sidebar"
      else
        ui_append_message error "The terminal is too narrow to show the session sidebar."
      fi
      ;;
    /list-agents)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Agent discovery is local to the machine running the agent and is not bridged through a remote client."
      elif (( ! $+functions[relay_discover] || ! ${RELAY_ACTIVE:-0} )); then
        ui_append_message error "Inter-agent relay is unavailable: ${RELAY_ERROR:-not started}."
      elif relay_discover; then
        relay_agents_text
        zcoder_terminal_safe "$REPLY"
        ui_append_message system "$REPLY"
      else
        ui_append_message error "Could not list local agents: ${RELAY_ERROR:-unknown error}"
      fi
      ;;
    /agents)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Agent relay controls are local to the machine running the agent."
      elif (( $+functions[relay_status_text] )); then
        relay_status_text
        ui_append_message system "$REPLY"
      else
        ui_append_message error "Inter-agent relay is unavailable."
      fi
      ;;
    /agents\ pause)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Agent relay controls are local to the machine running the agent."
      elif (( $+functions[relay_pause] )) && relay_pause; then
        ui_append_message system "Inter-agent relay paused. New messages will be rejected; accepted messages remain queued."
      else
        ui_append_message error "Could not pause inter-agent relay: ${RELAY_ERROR:-not started}."
      fi
      ;;
    /agents\ resume)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Agent relay controls are local to the machine running the agent."
      elif (( $+functions[relay_resume] )) && relay_resume; then
        ui_append_message system "Inter-agent relay resumed."
      else
        ui_append_message error "Could not resume inter-agent relay: ${RELAY_ERROR:-not started}."
      fi
      ;;
    /agents\ *)
      ui_append_message error "Usage: /agents, /agents pause, or /agents resume"
      ;;
    /copy)
      ui_copy_view
      ;;
    /model)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message system "Remote model: $ZCODER_MODEL (selected by $REMOTE_SERVER_NAME)"
      else
        previous_value="$ZCODER_MODEL"
        ui_select_model
        [[ "$ZCODER_MODEL" != "$previous_value" ]] && agent_warmup_start || true
      fi
      ;;
    /model\ *)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "The remote model is fixed by the server process."
        return 0
      fi
      value="${text#/model }"; value="${value##[[:space:]]#}"
      if [[ -n "$value" ]]; then
        ZCODER_MODEL="$value"
        ui_append_message system "Model changed to $ZCODER_MODEL"
        agent_warmup_start || true
      fi
      ;;
    /host)
      [[ "$REMOTE_MODE" == client ]] && ui_append_message system "Connected to $REMOTE_SERVER_NAME at $REMOTE_ENDPOINT" || ui_append_message system "Current Ollama host: $OLLAMA_HOST"
      ;;
    /host\ *)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "The Ollama host is controlled by the remote server."
        return 0
      fi
      value="${text#/host }"; value="${value##[[:space:]]#}"
      if ollama_normalize_host "$value"; then
        OLLAMA_HOST="$REPLY"
        AGENT_CONTEXT_MODEL=""
        ui_append_message system "Ollama host changed to $OLLAMA_HOST"
        agent_warmup_start || true
      else
        ui_append_message error "$HTTP_ERROR"
      fi
      ;;
    /instructions)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Remote instruction inspection is not available in this first server release."
        return 0
      fi
      instructions_summary
      ui_append_message system "$REPLY"
      ;;
    /skills)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Remote Skill inspection is not available in this first server release."
        return 0
      fi
      skills_summary
      ui_append_message system "$REPLY"
      ;;
    /skills\ reload)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Skills are loaded and controlled by the remote server."
        return 0
      fi
      skills_load "$ZCODER_WORKSPACE"
      skills_summary
      ui_append_message system "Skills reloaded."$'\n'"$REPLY"
      agent_warmup_start || true
      ;;
    /mcp)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Remote MCP inspection is not available in this first server release."
        return 0
      fi
      ui_mcp_servers
      ;;
    /mcp\ reload)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "MCP servers are loaded and controlled by the remote server."
        return 0
      fi
      if mcp_load; then
        ui_append_message system "MCP configuration reloaded."
        agent_warmup_start || true
      else
        ui_append_message error "$MCP_ERROR"
      fi
      ;;
    /skill)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Skills are activated by prompts handled on the remote server."
        return 0
      fi
      ui_append_message error "/skill requires an installed Skill name"
      ;;
    /skill\ *)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Skills are activated by prompts handled on the remote server."
        return 0
      fi
      value="${text#/skill }"; value="${value%%[[:space:]]*}"
      if skills_activate "$value"; then
        ui_append_message system "$TOOL_RESULT"
        agent_warmup_start || true
      else
        ui_append_message error "$TOOL_RESULT"
      fi
      ;;
    /compact)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Remote manual compaction is not available in this first server release."
        return 0
      fi
      (( AGENT_WARMUP_ACTIVE )) && agent_warmup_cancel "manual compaction started"
      if ! agent_compact_history manual; then
        if (( AGENT_CANCELLED )); then
          ui_append_message system "⏹ Compaction stopped."
          ui_set_status "Stopped"
        elif [[ "$HTTP_ERROR" == "" ]]; then
          ui_append_message system "Nothing to compact yet."
        else
          ui_append_message error "Compaction failed: $HTTP_ERROR"
          ui_set_status "Compaction error"
        fi
      else
        ui_set_status "Ready"
      fi
      ;;
    /terminal)
      ui_show_terminal
      return 0
      ;;
    /context)
      if (( UI_ACTIVE )); then
        ui_show_context
        return 0
      fi
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message system "Remote model: $ZCODER_MODEL; context accounting is maintained by the server."
        return 0
      fi
      agent_context_summary
      ui_append_message system "$REPLY"
      ;;
    /claude|/codex|/agy)
      provider="${text#/}"
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "External consultations are not exposed by the remote server."
        return 0
      fi
      ui_append_message error "/${provider} requires a request"
      ;;
    /claude\ *|/codex\ *|/agy\ *)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "External consultations are not exposed by the remote server."
        return 0
      fi
      provider="${text%% *}"; provider="${provider#/}"
      value="${text#/${provider} }"
      delegate_run "$provider" "$value" || delegate_status=$?
      if (( delegate_status != 0 && delegate_status != 130 && ! DELEGATE_ERROR_REPORTED )); then
        ui_append_message error "${DELEGATE_ERROR:-${provider} consultation failed}"
      fi
      ;;
    /claude!|/codex!|/agy!|/opencode!)
      provider="${text#/}"; provider="${provider%!}"
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "External workers are not exposed by the remote server."
        return 0
      fi
      ui_append_message error "/${provider}! requires a request"
      ;;
    /claude!\ *|/codex!\ *|/agy!\ *|/opencode!\ *)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "External workers are not exposed by the remote server."
        return 0
      fi
      command_name="${text%% *}"
      provider="${command_name#/}"; provider="${provider%!}"
      value="${text#${command_name} }"
      if [[ "$provider" == opencode && -z "$ZCODER_OPENCODE_MODEL" ]]; then
        ui_select_opencode_model || { ui_refresh_all; return 0; }
      fi
      delegate_run "$provider" "$value" execute || delegate_status=$?
      if (( delegate_status != 0 && delegate_status != 130 && ! DELEGATE_ERROR_REPORTED )); then
        ui_append_message error "${DELEGATE_ERROR:-${provider} worker failed}"
      fi
      ;;
    /opencode)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "External consultations are not exposed by the remote server."
        return 0
      fi
      ui_select_opencode_model
      ;;
    /opencode\ *)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "External consultations are not exposed by the remote server."
        return 0
      fi
      value="${text#/opencode }"
      if [[ -z "$ZCODER_OPENCODE_MODEL" ]]; then
        ui_select_opencode_model || { ui_refresh_all; return 0; }
      fi
      delegate_run opencode "$value" || delegate_status=$?
      if (( delegate_status != 0 && delegate_status != 130 && ! DELEGATE_ERROR_REPORTED )); then
        ui_append_message error "${DELEGATE_ERROR:-OpenCode consultation failed}"
      fi
      ;;
    /opencode-model)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "External consultations are not exposed by the remote server."
        return 0
      fi
      ui_select_opencode_model
      ;;
    /opencode-model\ *)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "External consultations are not exposed by the remote server."
        return 0
      fi
      value="${text#/opencode-model }"; value="${value##[[:space:]]#}"
      if [[ "$value" == */* ]]; then
        ZCODER_OPENCODE_MODEL="$value"
        ui_append_message system "OpenCode model changed to $ZCODER_OPENCODE_MODEL"
      else
        ui_append_message error "OpenCode models use provider/model form"
      fi
      ;;
    /help|/\?)
      ui_append_message system $'Enter sends a prompt. Shift+Enter inserts a newline; Alt+Enter is the fallback for terminals that do not report Shift+Enter separately. Pasted multiline text keeps its formatting. Escape stops a running Ollama response, local command/search, or external delegate.\nTab moves focus between the prompt, session sidebar, and transcript. Use Up/Down in the sidebar to resume another job. Ctrl+Y or /copy opens a stable plain-text view for native terminal selection and copying.\nCtrl+P or /commands opens the searchable command palette. Ctrl+O selects an Ollama model. With transcript focus, Up/Down or k/j selects an entry, Home/End selects the first/last entry, and Enter/Space folds its body. Ctrl+R toggles the selected reasoning, or the latest reasoning when editing the prompt. Ctrl+N starts a new saved session. PgUp/PgDn scroll. Ctrl+U clears input. Ctrl+W deletes a word. Ctrl+Q exits.\n/goal OBJECTIVE runs a persistent, independently verified goal; /goal shows status, and /goal pause, /goal resume, or /goal clear control it. Add --tokens N before the objective for a token limit. /claude REQUEST, /codex REQUEST, /agy REQUEST, and /opencode REQUEST run read-only consultations. Add ! to run an explicitly workspace-editing worker, for example /codex! REQUEST. /opencode with no request selects its provider/model. /list-agents lists other local zcoder instances; /agents pause or /agents resume controls incoming work. /mcp shows configured servers and live status; /mcp reload reloads configuration. /skills lists installed Agent Skills; /skill NAME activates one. Prefix a request with $skill-name for explicit activation. /model opens the Ollama picker; /host HOST changes Ollama; /instructions lists active AGENTS.md files; /compact creates a context checkpoint; /context opens the context usage inspector; /terminal shows terminal capabilities; /sessions focuses saved jobs; /new starts a saved job.'
      zcoder_delegate_availability_summary
      ui_append_message system "$REPLY"
      ;;
    /quit|/exit|/q) RUNNING=0 ;;
    *) return 1 ;;
  esac
  (( $+functions[zcoder_refresh_sessions] )) && zcoder_refresh_sessions
  ui_refresh_all
}

main_tui() {
  local ch="" key="" mouse="" text="" previous_model="" relay_context="" relay_display=""
  local -i current_index=1 i=1 relay_claim_status=1
  input_reset
  if [[ "$REMOTE_MODE" != client ]] && ! state_init; then
    print -u2 -- "Warning: could not initialize session storage at $ZCODER_SESSIONS_DIR"
  fi
  if [[ "$REMOTE_MODE" == local ]]; then
    zcoder_require relay
    if ! relay_start && [[ "$ZCODER_RELAY" != off ]]; then
      ui_append_message system "Inter-agent relay unavailable: ${RELAY_ERROR:-startup failed}."
    fi
  fi
  if [[ "$REMOTE_MODE" == local && "$ZCODER_WARMUP" == true ]]; then
    ui_set_status "Warming Up"
  elif [[ "$REMOTE_MODE" == client ]]; then
    case "$REMOTE_MODEL_STATUS" in
      warming) ui_set_status "Warming Up" ;;
      error) ui_set_status "Warm-up Failed" ;;
      *) ui_set_status "Ready" ;;
    esac
  fi
  ui_init || { print -u2 -- "Error: could not initialize curses UI"; return 1; }
  agent_warmup_start || true
  while (( RUNNING )); do
    ui_poll_resize
    if [[ "$REMOTE_MODE" == client ]]; then
      remote_client_model_poll || true
    else
      agent_warmup_poll
    fi
    if [[ "$REMOTE_MODE" == local ]] && (( $+functions[relay_claim_one] && ${RELAY_ACTIVE:-0} )); then
      relay_refresh_manifest || true
      relay_claim_one
      relay_claim_status=$?
      if (( relay_claim_status == 0 )); then
        relay_relay_context; relay_context="$REPLY"
        relay_relay_display; relay_display="$REPLY"
        agent_relay_turn "$relay_context" "$relay_display" "$RELAY_CLAIM_SENDER_ID"
        relay_complete_claim || ui_append_message error "Could not finalize relayed message ${RELAY_CLAIM_MESSAGE_ID}."
        zcoder_refresh_sessions
        continue
      elif (( relay_claim_status == 2 )); then
        ui_append_message error "$RELAY_ERROR"
        ui_refresh_all
        continue
      fi
    fi
    ch=""; key=""; mouse=""
    zcurses timeout input_win 100
    terminal_read_event input_win ch key mouse
    if [[ "$key" == RESIZE ]]; then
      UI_RESIZE_PENDING=1
      ui_poll_resize
      continue
    fi
    [[ -z "$ch" && -z "$key" ]] && continue
    if input_decode_terminal_event "$ch" "$key"; then
      if [[ "$INPUT_EVENT_ACTION" == newline ]]; then
        input_insert $'\n'
        ui_input_changed
      elif [[ "$INPUT_EVENT_ACTION" == paste && -n "$INPUT_EVENT_TEXT" ]]; then
        input_insert "$INPUT_EVENT_TEXT"
        ui_input_changed
      fi
      continue
    elif [[ "$ch" == $'\x11' || "$ch" == $'\x04' ]]; then
      break
    elif [[ "$ch" == $'\x03' ]]; then
      input_clear; ui_input_changed
    elif [[ "$ch" == $'\x0e' ]]; then
      handle_slash_command /new
    elif [[ "$ch" == $'\x19' ]]; then
      ui_copy_view
    elif [[ "$ch" == $'\x10' ]]; then
      ui_command_palette
    elif [[ "$ch" == $'\x0f' ]]; then
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message system "Remote model: $ZCODER_MODEL (selected by $REMOTE_SERVER_NAME)"
        ui_refresh_all
      else
        previous_model="$ZCODER_MODEL"
        ui_select_model
        [[ "$ZCODER_MODEL" != "$previous_model" ]] && agent_warmup_start || true
        zcoder_refresh_sessions
      fi
    elif [[ "$ch" == $'\x12' ]]; then
      ui_toggle_reasoning
    elif [[ "$ch" == $'\t' || "$key" == TAB ]]; then
      case "$UI_FOCUS" in
        input) (( SIDE_W > 0 )) && UI_FOCUS="sidebar" || UI_FOCUS="chat" ;;
        sidebar) UI_FOCUS="chat" ;;
        *) UI_FOCUS="input" ;;
      esac
      [[ "$UI_FOCUS" == chat ]] && { UI_AUTO_SCROLL=0; UI_REVEAL_SELECTED=1; }
      ui_refresh_all
    elif [[ "$key" == PPAGE ]]; then
      UI_AUTO_SCROLL=0; (( UI_SCROLL -= 6 )); (( UI_SCROLL < 0 )) && UI_SCROLL=0; ui_draw_chat
    elif [[ "$key" == NPAGE ]]; then
      (( UI_SCROLL += 6 )); ui_draw_chat
    elif [[ "$UI_FOCUS" == sidebar ]]; then
      current_index=${SESSION_IDS[(Ie)$CURRENT_SESSION_ID]}
      (( current_index > 0 )) || current_index=1
      if [[ "$key" == UP || "$ch" == k ]]; then
        if (( current_index > 1 )); then
          if [[ "$REMOTE_MODE" == client ]]; then
            remote_client_select_session "${SESSION_IDS[current_index-1]}" || ui_append_message error "Could not load remote session: $REMOTE_ERROR"
          else
            state_load_session "${SESSION_IDS[current_index-1]}"
            agent_warmup_start || true
          fi
          ui_set_status "Ready"
          ui_refresh_all
        fi
      elif [[ "$key" == DOWN || "$ch" == j ]]; then
        if (( current_index < ${#SESSION_IDS} )); then
          if [[ "$REMOTE_MODE" == client ]]; then
            remote_client_select_session "${SESSION_IDS[current_index+1]}" || ui_append_message error "Could not load remote session: $REMOTE_ERROR"
          else
            state_load_session "${SESSION_IDS[current_index+1]}"
            agent_warmup_start || true
          fi
          ui_set_status "Ready"
          ui_refresh_all
        fi
      elif [[ "$ch" == $'\n' || "$ch" == $'\r' || "$key" == ENTER || "$key" == PADENTER ]]; then
        UI_FOCUS="input"
        ui_refresh_all
      fi
    elif [[ "$UI_FOCUS" == chat ]]; then
      ui_chat_input "$ch" "$key"
    elif [[ "$ch" == $'\n' || "$ch" == $'\r' || "$key" == ENTER || "$key" == PADENTER ]]; then
      input_submit; text="$INPUT_SUBMITTED"
      ui_input_changed
      if [[ -n "$text" ]]; then
        if [[ "$text" == /* ]]; then
          handle_slash_command "$text" || { agent_user_turn "$text"; zcoder_refresh_sessions; }
        else
          agent_user_turn "$text"
          zcoder_refresh_sessions
        fi
      fi
    else
      ui_editor_input "$ch" "$key" || true
    fi
  done
}

if [[ -n "$ONE_SHOT_PROMPT" ]]; then
  if [[ "$ONE_SHOT_PROMPT" == /goal || "$ONE_SHOT_PROMPT" == /goal\ * ]]; then
    goal_handle_command "$ONE_SHOT_PROMPT"
  else
    agent_user_turn "$ONE_SHOT_PROMPT"
  fi
else
  [[ -t 0 && -t 1 ]] || { print -u2 -- "Error: interactive mode requires a terminal; use --prompt for one-shot mode"; exit 2; }
  main_tui
fi
