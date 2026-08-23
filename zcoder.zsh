#!/usr/bin/env zsh
# zcoder.zsh - a Zsh-first Ollama coding agent.

setopt EXTENDED_GLOB NO_NOMATCH NO_MONITOR NO_NOTIFY NO_CHECK_JOBS NO_HUP 2>/dev/null
zmodload zsh/curses zsh/datetime zsh/files zsh/mapfile zsh/net/tcp \
  zsh/system zsh/terminfo zsh/zselect || {
  print -u2 -- "Error: required Zsh loadable modules are unavailable."
  exit 1
}

typeset -gr ZCODER_NAME="zcoder.zsh"
typeset -gr ZCODER_VERSION="0.4.6"

0="${ZERO:-${${0:#$ZSH_ARGZERO}:-${(%):-%N}}}"
0="${${(M)0:#/*}:-$PWD/$0}"
typeset -gr ZCODER_DIR="${0:A:h}"

source "${ZCODER_DIR}/lib/util.zsh"
source "${ZCODER_DIR}/lib/json.zsh"
source "${ZCODER_DIR}/lib/mcp.zsh"
source "${ZCODER_DIR}/lib/http.zsh"
source "${ZCODER_DIR}/lib/instructions.zsh"
source "${ZCODER_DIR}/lib/skills.zsh"
source "${ZCODER_DIR}/lib/input.zsh"
source "${ZCODER_DIR}/lib/ui.zsh"
source "${ZCODER_DIR}/lib/tools.zsh"
source "${ZCODER_DIR}/lib/compact.zsh"
source "${ZCODER_DIR}/lib/agent.zsh"
source "${ZCODER_DIR}/lib/state.zsh"
source "${ZCODER_DIR}/lib/delegate.zsh"

typeset -g ONE_SHOT_PROMPT=""
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
  print -r -- "      --profile NAME     System prompt profile: coding or sysadmin (default: ${ZCODER_PROFILE})"
  print -r -- "  -p, --prompt TEXT      Run one prompt without the full-screen UI"
  print -r -- "      --context-window N Context tokens to request, or auto (default: ${ZCODER_CONTEXT_WINDOW})"
  print -r -- "      --compact-at PCT   Compact at this context percentage (default: ${ZCODER_COMPACT_PERCENT})"
  print -r -- "      --yes              Allow shell commands (coding profile only)"
  print -r -- "      --deny-commands    Deny shell commands without prompting"
  print -r -- "      --no-think         Ask Ollama not to return model reasoning"
  print -r -- "      --debug            Append diagnostics to /tmp/zcoder-debug-${UID}.log"
  print -r -- "      --debug-log PATH   Append diagnostics to a specific file"
  print -r -- "      --print-instructions  Show the resolved AGENTS.md chain and exit"
  print -r -- "      --print-skills     Show discovered Agent Skills and exit"
  print -r -- "  -V, --version          Show version"
  print -r -- "      --help             Show this help"
}

if [[ "${1:-}" == mcp ]]; then
  shift
  mcp_cli "$@"
  exit $?
fi

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
    --profile)
      require_option_value "$1" "${2:-}"
      if ! agent_select_profile "$2"; then print -u2 -- "Error: $REPLY"; exit 2; fi
      shift
      ;;
    -p|--prompt) require_option_value "$1" "${2:-}"; ONE_SHOT_PROMPT="$2"; shift ;;
    --context-window)
      require_option_value "$1" "${2:-}"
      [[ "$2" == auto || "$2" == <4096-> ]] || { print -u2 -- "Error: --context-window expects auto or an integer of at least 4096"; exit 2; }
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

if ! agent_select_profile "$ZCODER_PROFILE"; then
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
    zcoder_debug session "version=$ZCODER_VERSION profile=$ZCODER_PROFILE model=${(qqq)ZCODER_MODEL} host=${(qqq)OLLAMA_HOST} workspace=${(qqq)ZCODER_WORKSPACE}"
  fi
fi
instructions_load "$ZCODER_WORKSPACE"
skills_load "$ZCODER_WORKSPACE"
if ! mcp_load; then
  print -u2 -- "Warning: $MCP_ERROR"
fi

if (( PRINT_INSTRUCTIONS )); then
  instructions_summary
  print -r -- "$REPLY"
  if (( ${#INSTRUCTION_SOURCES} > 0 )); then
    print -r -- ""
    instructions_prompt_block
    print -r -- "$REPLY"
  fi
  exit 0
fi

if (( PRINT_SKILLS )); then
  skills_summary
  print -r -- "$REPLY"
  exit 0
fi

if ! ollama_normalize_host "$OLLAMA_HOST"; then
  print -u2 -- "Error: $HTTP_ERROR"
  exit 2
fi
OLLAMA_HOST="$REPLY"

cleanup() {
  local exit_status=$?
  zcoder_debug session_end "status=$exit_status running=$RUNNING async_pid=${HTTP_ASYNC_PID:-none} delegate_pid=${DELEGATE_PID:-none}"
  RUNNING=0
  (( $+functions[state_save_session] )) && state_save_session
  delegate_async_cancel
  http_async_cancel
  mcp_shutdown_all
  ui_end
}
trap cleanup EXIT INT TERM HUP

handle_slash_command() {
  local text="$1" value="" provider=""
  local -i delegate_status=0
  case "$text" in
    /new|/clear)
      state_new_session
      UI_FOCUS="input"
      ui_set_status "Ready"
      ;;
    /sessions)
      if (( SIDE_W > 0 )); then
        UI_FOCUS="sidebar"
      else
        ui_append_message error "The terminal is too narrow to show the session sidebar."
      fi
      ;;
    /copy)
      ui_copy_view
      ;;
    /model)
      ui_select_model; ;;
    /model\ *)
      value="${text#/model }"; value="${value##[[:space:]]#}"
      [[ -n "$value" ]] && ZCODER_MODEL="$value"
      ui_append_message system "Model changed to $ZCODER_MODEL"; ;;
    /host)
      ui_append_message system "Current Ollama host: $OLLAMA_HOST"; ;;
    /host\ *)
      value="${text#/host }"; value="${value##[[:space:]]#}"
      if ollama_normalize_host "$value"; then
        OLLAMA_HOST="$REPLY"; ui_append_message system "Ollama host changed to $OLLAMA_HOST"
      else
        ui_append_message error "$HTTP_ERROR"
      fi
      ;;
    /instructions)
      instructions_summary
      ui_append_message system "$REPLY"
      ;;
    /skills)
      skills_summary
      ui_append_message system "$REPLY"
      ;;
    /skills\ reload)
      skills_load "$ZCODER_WORKSPACE"
      skills_summary
      ui_append_message system "Skills reloaded."$'\n'"$REPLY"
      ;;
    /mcp)
      ui_mcp_servers
      ;;
    /mcp\ reload)
      if mcp_load; then
        ui_append_message system "MCP configuration reloaded."
      else
        ui_append_message error "$MCP_ERROR"
      fi
      ;;
    /skill)
      ui_append_message error "/skill requires an installed Skill name"
      ;;
    /skill\ *)
      value="${text#/skill }"; value="${value%%[[:space:]]*}"
      if skills_activate "$value"; then
        ui_append_message system "$TOOL_RESULT"
      else
        ui_append_message error "$TOOL_RESULT"
      fi
      ;;
    /compact)
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
    /context)
      agent_context_summary
      ui_append_message system "$REPLY"
      ;;
    /claude|/codex|/agy)
      provider="${text#/}"
      ui_append_message error "/${provider} requires a request"
      ;;
    /claude\ *|/codex\ *|/agy\ *)
      provider="${text%% *}"; provider="${provider#/}"
      value="${text#/${provider} }"
      delegate_run "$provider" "$value" || delegate_status=$?
      if (( delegate_status != 0 && delegate_status != 130 && ! DELEGATE_ERROR_REPORTED )); then
        ui_append_message error "${DELEGATE_ERROR:-${provider} consultation failed}"
      fi
      ;;
    /opencode)
      ui_select_opencode_model
      ;;
    /opencode\ *)
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
      ui_select_opencode_model
      ;;
    /opencode-model\ *)
      value="${text#/opencode-model }"; value="${value##[[:space:]]#}"
      if [[ "$value" == */* ]]; then
        ZCODER_OPENCODE_MODEL="$value"
        ui_append_message system "OpenCode model changed to $ZCODER_OPENCODE_MODEL"
      else
        ui_append_message error "OpenCode models use provider/model form"
      fi
      ;;
    /help|/\?)
      ui_append_message system $'Enter sends a prompt. Shift+Enter inserts a newline; Alt+Enter is the fallback for terminals that do not report Shift+Enter separately. Pasted multiline text keeps its formatting. Escape stops a running Ollama response or external consultation.\nTab moves focus between the prompt, session sidebar, and transcript. Use Up/Down in the sidebar to resume another job. Ctrl+Y or /copy opens a stable plain-text view for native terminal selection and copying.\nCtrl+O selects an Ollama model. Ctrl+R toggles reasoning. Ctrl+N starts a new saved session. PgUp/PgDn scroll. Ctrl+U clears input. Ctrl+W deletes a word. Ctrl+Q exits.\n/claude REQUEST, /codex REQUEST, /agy REQUEST, and /opencode REQUEST run read-only external consultations. /opencode with no request selects its provider/model. /mcp shows configured servers and live status; /mcp reload reloads configuration. /skills lists installed Agent Skills; /skill NAME activates one. Prefix a request with $skill-name for explicit activation. /model opens the Ollama picker; /host HOST changes Ollama; /instructions lists active AGENTS.md files; /compact creates a context checkpoint; /context shows the token budget; /sessions focuses saved jobs; /new starts a saved job.'
      ;;
    /quit|/exit|/q) RUNNING=0 ;;
    *) return 1 ;;
  esac
  (( $+functions[state_save_and_refresh] )) && state_save_and_refresh
  ui_refresh_all
}

main_tui() {
  local ch="" key="" mouse="" text=""
  local -i current_index=1 i=1
  input_reset
  if ! state_init; then
    print -u2 -- "Warning: could not initialize session storage at $ZCODER_SESSIONS_DIR"
  fi
  ui_init || { print -u2 -- "Error: could not initialize curses UI"; return 1; }
  while (( RUNNING )); do
    ui_poll_resize
    ch=""; key=""; mouse=""
    zcurses timeout input_win 100
    zcurses input input_win ch key mouse
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
    elif [[ "$ch" == $'\x0f' ]]; then
      ui_select_model
      state_save_and_refresh
    elif [[ "$ch" == $'\x12' ]]; then
      ui_toggle_reasoning
    elif [[ "$ch" == $'\t' || "$key" == TAB ]]; then
      case "$UI_FOCUS" in
        input) (( SIDE_W > 0 )) && UI_FOCUS="sidebar" || UI_FOCUS="chat" ;;
        sidebar) UI_FOCUS="chat" ;;
        *) UI_FOCUS="input" ;;
      esac
      ui_refresh_all
    elif [[ "$key" == PPAGE ]]; then
      UI_AUTO_SCROLL=0; (( UI_SCROLL -= 6 )); (( UI_SCROLL < 0 )) && UI_SCROLL=0; ui_draw_chat
    elif [[ "$key" == NPAGE ]]; then
      (( UI_SCROLL += 6 )); ui_draw_chat
    elif [[ "$UI_FOCUS" == sidebar ]]; then
      current_index=1
      for (( i=1; i<=${#SESSION_IDS}; i++ )); do
        [[ "${SESSION_IDS[i]}" == "$CURRENT_SESSION_ID" ]] && { current_index=$i; break; }
      done
      if [[ "$key" == UP || "$ch" == k ]]; then
        if (( current_index > 1 )); then
          state_load_session "${SESSION_IDS[current_index-1]}"
          ui_set_status "Ready"
          ui_refresh_all
        fi
      elif [[ "$key" == DOWN || "$ch" == j ]]; then
        if (( current_index < ${#SESSION_IDS} )); then
          state_load_session "${SESSION_IDS[current_index+1]}"
          ui_set_status "Ready"
          ui_refresh_all
        fi
      elif [[ "$ch" == $'\n' || "$ch" == $'\r' || "$key" == ENTER || "$key" == PADENTER ]]; then
        UI_FOCUS="input"
        ui_refresh_all
      fi
    elif [[ "$UI_FOCUS" == chat ]]; then
      :
    elif [[ "$ch" == $'\n' || "$ch" == $'\r' || "$key" == ENTER || "$key" == PADENTER ]]; then
      input_submit; text="$INPUT_SUBMITTED"
      ui_input_changed
      if [[ -n "$text" ]]; then
        if [[ "$text" == /* ]]; then
          handle_slash_command "$text" || { agent_user_turn "$text"; state_save_and_refresh; }
        else
          agent_user_turn "$text"
          state_save_and_refresh
        fi
      fi
    elif [[ "$key" == BACKSPACE || "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then
      input_backspace; ui_input_changed
    elif [[ "$key" == DC || "$key" == DELETE ]]; then
      input_delete; ui_input_changed
    elif [[ "$key" == LEFT ]]; then input_left; ui_input_changed
    elif [[ "$key" == RIGHT ]]; then input_right; ui_input_changed
    elif [[ "$key" == HOME || "$ch" == $'\x01' ]]; then input_home; ui_input_changed
    elif [[ "$key" == END || "$ch" == $'\x05' ]]; then input_end; ui_input_changed
    elif [[ "$ch" == $'\x15' ]]; then input_clear; ui_input_changed
    elif [[ "$ch" == $'\x17' ]]; then input_kill_word; ui_input_changed
    elif [[ "$key" == UP ]]; then
      ui_input_width
      input_move_vertical -1 "$REPLY" $(( INPUT_H - 2 )) || input_history_previous
      ui_input_changed
    elif [[ "$key" == DOWN ]]; then
      ui_input_width
      input_move_vertical 1 "$REPLY" $(( INPUT_H - 2 )) || input_history_next
      ui_input_changed
    elif [[ -n "$ch" && "$ch" != $'\x1b' ]]; then input_insert "$ch"; ui_input_changed
    fi
  done
}

if [[ -n "$ONE_SHOT_PROMPT" ]]; then
  agent_user_turn "$ONE_SHOT_PROMPT"
else
  [[ -t 0 && -t 1 ]] || { print -u2 -- "Error: interactive mode requires a terminal; use --prompt for one-shot mode"; exit 2; }
  main_tui
fi
