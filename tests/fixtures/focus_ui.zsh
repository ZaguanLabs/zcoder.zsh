#!/usr/bin/env zsh
emulate -R zsh
zmodload zsh/mapfile
typeset -g fixture_root=$1 fixture_base=$2
export ZCODER_HOME="$fixture_base.home" ZCODER_RELAY=off ZCODER_SYNC_OUTPUT=false
export ZCODER_CURSES=$3
command stty rows 24 cols 120 < /dev/tty
# Keep the actual entrypoint, session storage and input loop. Model warm-up
# exercises the real activity transition without contacting Ollama.
source() {
  builtin source "$@" || return $?
  case $1 in
    */lib/agent.zsh)
      agent_warmup_start() { ui_wait_for_context; }
      agent_context_discovery_ready() { return 0; }
      agent_warmup_poll() { return 0; }
      ;;
    */lib/tui.zsh)
      functions[_fixture_state_init]=$functions[state_init]
      state_init() {
        _fixture_state_init "$@" || return $?
        local -i fixture_index
        for fixture_index in 1 2 3; do
          state_new_session || return $?
          CURRENT_SESSION_ID="170000000${fixture_index}_1"
          agent_add_message user "Fixture conversation $fixture_index"
          ui_append_message user "Fixture conversation $fixture_index"
          state_save_session || return $?
        done
        state_refresh_sessions_list
        state_load_session "$SESSION_IDS[1]"
      }
      ;;
    */lib/terminal.zsh)
      functions[_fixture_read]=$functions[terminal_read_event]
      terminal_read_event() {
        mapfile[$fixture_base.state]="$UI_FOCUS:$SIDE_W:$INPUT_POS:$INPUT_BUF"
        mapfile[$fixture_base.selection]="${SESSION_IDS[(Ie)$CURRENT_SESSION_ID]}"
        mapfile[$fixture_base.tty]=$TTY
        _fixture_read "$@"
      }
      ;;
  esac
  return 0
}
builtin source "$fixture_root/zcoder.zsh" --model fixture --workspace "$fixture_base.workspace" \
  --context-window 32768 --no-warmup --deny-commands
