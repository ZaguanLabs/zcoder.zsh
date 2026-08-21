#!/usr/bin/env zsh
# zcoder.zsh - a Zsh-first Ollama coding agent.

setopt EXTENDED_GLOB NO_NOMATCH NO_MONITOR NO_NOTIFY NO_CHECK_JOBS NO_HUP 2>/dev/null
zmodload zsh/curses zsh/datetime zsh/files zsh/mapfile zsh/net/tcp \
  zsh/system zsh/terminfo zsh/zselect || {
  print -u2 -- "Error: required Zsh loadable modules are unavailable."
  exit 1
}

typeset -gr ZCODER_NAME="zcoder.zsh"
typeset -gr ZCODER_VERSION="0.3.1"

0="${ZERO:-${${0:#$ZSH_ARGZERO}:-${(%):-%N}}}"
0="${${(M)0:#/*}:-$PWD/$0}"
typeset -gr ZCODER_DIR="${0:A:h}"

source "${ZCODER_DIR}/lib/util.zsh"
source "${ZCODER_DIR}/lib/json.zsh"
source "${ZCODER_DIR}/lib/http.zsh"
source "${ZCODER_DIR}/lib/instructions.zsh"
source "${ZCODER_DIR}/lib/input.zsh"
source "${ZCODER_DIR}/lib/ui.zsh"
source "${ZCODER_DIR}/lib/tools.zsh"
source "${ZCODER_DIR}/lib/compact.zsh"
source "${ZCODER_DIR}/lib/agent.zsh"

typeset -g ONE_SHOT_PROMPT=""
typeset -gi RUNNING=1
typeset -gi PRINT_INSTRUCTIONS=0

usage() {
  print -r -- "Usage: ${ZCODER_NAME} [options]"
  print -r -- ""
  print -r -- "Options:"
  print -r -- "  -m, --model NAME       Ollama model (default: ${ZCODER_MODEL})"
  print -r -- "  -h, --host HOST        Ollama host (default: ${OLLAMA_HOST})"
  print -r -- "  -w, --workspace PATH   Directory the agent may access (default: current)"
  print -r -- "  -p, --prompt TEXT      Run one prompt without the full-screen UI"
  print -r -- "      --max-turns COUNT  Emergency model-turn limit (default: ${AGENT_MAX_STEPS})"
  print -r -- "      --context-window N Context tokens to request, or auto (default: ${ZCODER_CONTEXT_WINDOW})"
  print -r -- "      --compact-at PCT   Compact at this context percentage (default: ${ZCODER_COMPACT_PERCENT})"
  print -r -- "      --yes              Allow shell commands for this process"
  print -r -- "      --deny-commands    Deny shell commands without prompting"
  print -r -- "      --no-think         Ask Ollama not to return model reasoning"
  print -r -- "      --debug            Append diagnostics to /tmp/zcoder-debug-${UID}.log"
  print -r -- "      --debug-log PATH   Append diagnostics to a specific file"
  print -r -- "      --print-instructions  Show the resolved AGENTS.md chain and exit"
  print -r -- "  -V, --version          Show version"
  print -r -- "      --help             Show this help"
}

require_option_value() {
  [[ -n "${2:-}" ]] || { print -u2 -- "Error: $1 requires a value"; exit 2; }
}

while (( $# > 0 )); do
  case "$1" in
    -m|--model) require_option_value "$1" "${2:-}"; ZCODER_MODEL="$2"; shift ;;
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
    -p|--prompt) require_option_value "$1" "${2:-}"; ONE_SHOT_PROMPT="$2"; shift ;;
    --max-turns)
      require_option_value "$1" "${2:-}"
      [[ "$2" == <1-> ]] || { print -u2 -- "Error: --max-turns expects a positive integer"; exit 2; }
      AGENT_MAX_STEPS="$2"; shift
      ;;
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
    -V|--version) print -r -- "${ZCODER_NAME} v${ZCODER_VERSION}"; exit 0 ;;
    --help) usage; exit 0 ;;
    --) shift; break ;;
    *) print -u2 -- "Error: unknown option: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

ZCODER_WORKSPACE="${ZCODER_WORKSPACE:A}"
if [[ -n "$ZCODER_DEBUG_LOG" ]]; then
  if ! zcoder_debug_init; then
    print -u2 -- "Warning: could not open debug log: $ZCODER_DEBUG_LOG"
  else
    zcoder_debug session "version=$ZCODER_VERSION model=${(qqq)ZCODER_MODEL} host=${(qqq)OLLAMA_HOST} workspace=${(qqq)ZCODER_WORKSPACE}"
  fi
fi
instructions_load "$ZCODER_WORKSPACE"

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

if ! ollama_normalize_host "$OLLAMA_HOST"; then
  print -u2 -- "Error: $HTTP_ERROR"
  exit 2
fi
OLLAMA_HOST="$REPLY"

cleanup() {
  local exit_status=$?
  zcoder_debug session_end "status=$exit_status running=$RUNNING async_pid=${HTTP_ASYNC_PID:-none}"
  RUNNING=0
  http_async_cancel
  ui_end
}
trap cleanup EXIT INT TERM HUP

handle_slash_command() {
  local text="$1" value=""
  case "$text" in
    /new|/clear)
      agent_reset
      UI_ROLES=(); UI_CONTENTS=(); UI_THINKINGS=(); UI_TIMES=(); UI_REASONING_OPEN=()
      UI_SCROLL=0; UI_AUTO_SCROLL=1
      ui_set_status "Ready"
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
    /help|/\?)
      ui_append_message system $'Enter sends a prompt. Shift+Enter inserts a newline; Alt+Enter is the fallback for terminals that do not report Shift+Enter separately. Pasted multiline text keeps its formatting. Escape stops the running Ollama response.\nCtrl+O selects an Ollama model. Ctrl+R toggles reasoning. Ctrl+N clears the conversation. PgUp/PgDn scroll. Ctrl+U clears input. Ctrl+W deletes a word. Ctrl+Q exits.\n/model opens the picker; /model NAME changes directly; /host HOST changes Ollama; /instructions lists active AGENTS.md files; /compact creates a context checkpoint; /context shows the token budget; /new starts over.'
      ;;
    /quit|/exit|/q) RUNNING=0 ;;
    *) return 1 ;;
  esac
  ui_refresh_all
}

main_tui() {
  local ch="" key="" mouse="" text=""
  input_reset
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
    elif [[ "$ch" == $'\x0f' ]]; then
      ui_select_model
    elif [[ "$ch" == $'\x12' ]]; then
      ui_toggle_reasoning
    elif [[ "$key" == PPAGE ]]; then
      UI_AUTO_SCROLL=0; (( UI_SCROLL -= 6 )); (( UI_SCROLL < 0 )) && UI_SCROLL=0; ui_draw_chat
    elif [[ "$key" == NPAGE ]]; then
      (( UI_SCROLL += 6 )); ui_draw_chat
    elif [[ "$ch" == $'\n' || "$ch" == $'\r' || "$key" == ENTER || "$key" == PADENTER ]]; then
      input_submit; text="$INPUT_SUBMITTED"
      ui_input_changed
      if [[ -n "$text" ]]; then
        if [[ "$text" == /* ]]; then
          handle_slash_command "$text" || agent_user_turn "$text"
        else
          agent_user_turn "$text"
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
