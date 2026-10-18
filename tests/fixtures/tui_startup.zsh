#!/usr/bin/env zsh
# Real entrypoint and terminal; only model work is replaced. Optional barriers
# let the parent type while workspace preparation is still pending.
emulate -R zsh
zmodload zsh/datetime zsh/mapfile zsh/zselect
typeset -g startup_root=$1 startup_base=$2 startup_backend=$3
typeset -gF startup_started=$EPOCHREALTIME
typeset -gi startup_frame=0 startup_idle=0 startup_picker_sources=0 startup_document_sources=0
export ZCODER_HOME="$startup_base.home" ZCODER_RELAY=on ZCODER_SYNC_OUTPUT=false
export ZCODER_RELAY_DIR="$startup_base.relay"
export ZCODER_CURSES=$startup_backend
export ZCODER_USER_SKILLS_DIR="$startup_base.workspace/.agents/skills"
export ZCODER_CONFIG_SKILLS_DIR="$ZCODER_USER_SKILLS_DIR"
command stty rows 24 cols 120 < /dev/tty

startup_ready() {
  [[ $INSTRUCTIONS_TEXT == *STARTUP_INSTRUCTION* &&
     ${SKILL_DESCRIPTIONS[startup]:-} == 'Startup skill.' &&
     ${MCP_COMMAND[startup]:-} == startup-command &&
     ${TUI_STARTUP_PENDING:-1} == 0 && $STATE_ENABLED == 1 && $RELAY_ACTIVE == 1 ]]
}

source() {
  local startup_file=$1
  builtin source "$@" || return $?
  case $startup_file in
    */lib/instructions.zsh)
      functions[_startup_instructions]=$functions[instructions_load]
      instructions_load() {
        (( startup_frame )) || exit 20
        # A pending listener must stay unpublished until session preparation.
        [[ $RELAY_LISTENER_PID == <1-> && ! -e $RELAY_MANIFEST_PATH ]] || exit 26
        (( ! RELAY_ACTIVE && ! RELAY_AVAILABLE )) || exit 27
        print -r -- "$RELAY_LISTENER_PID" > "$startup_base.listener"
        print -r -- 1 > "$startup_base.preparing"
        while [[ -f $startup_base.block && ! -f $startup_base.release ]]; do zselect -t 1; done
        _startup_instructions "$@"
      }
      ;;
    */lib/agent_loop.zsh)
      agent_user_turn() {
        startup_ready || exit 21
        # Exercise the real approval boundary, even on the first queued turn.
        tool_approve_command 'print must-not-run' && exit 22
        case $1 in
          document) ui_document_view Startup heading heading 'Startup document.' ;;
          picker) ui_modal_choose Startup alpha alpha beta ;;
          *) print -rn -- "$1" > "$startup_base.turn" ;;
        esac
        print -r -- "$startup_picker_sources:$startup_document_sources" > "$startup_base.helpers"
      }
      ;;
    */lib/ui.zsh)
      functions[_startup_flush]=$functions[ui_flush]
      ui_flush() {
        _startup_flush "$@" || return $?
        if (( ! startup_frame )); then
          (( ! STATE_ENABLED && ! ${+ZCODER_LOADED_LIBS[mcp]} &&
             ! ${+ZCODER_LOADED_LIBS[acp]} && ! ${+ZCODER_LOADED_LIBS[relay]} &&
             UI_PICKER_HELPERS == -1 && UI_DOCUMENT_HELPERS == -1 )) || exit 23
          startup_frame=1
          printf '%.0f\n' "$(( (EPOCHREALTIME-startup_started)*1000000 ))" > "$startup_base.frame"
        fi
      }
      ;;
    */lib/terminal.zsh)
      functions[_startup_read]=$functions[terminal_read_event]
      terminal_read_event() {
        if (( ! startup_idle )); then
          startup_ready || exit 24
          (( startup_frame && ! startup_picker_sources && ! startup_document_sources )) || exit 25
          startup_idle=1
          printf '%.0f\n' "$(( (EPOCHREALTIME-startup_started)*1000000 ))" > "$startup_base.idle"
        fi
        if (( ${UI_MODAL_ACTIVE:-0} )); then
          print -r -- "$modal_title" > "$startup_base.modal"
        else
          print -rn -- "$INPUT_BUF" > "$startup_base.draft"
        fi
        _startup_read "$@"
      }
      ;;
    */zdraw-list.zsh) (( startup_picker_sources++ )) ;;
    */zdraw-document.zsh) (( startup_document_sources++ )) ;;
  esac
  return 0
}

builtin source "$startup_root/zcoder.zsh" --workspace "$startup_base.workspace" \
  --context-window 32768 --no-warmup --deny-commands
print -r -- "$?" > "$startup_base.exit"
