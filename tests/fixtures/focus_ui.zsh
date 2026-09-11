#!/usr/bin/env zsh
emulate -R zsh
zmodload zsh/mapfile
typeset -g fixture_root=$1 fixture_base=$2
export ZCODER_HOME="$fixture_base.home" ZCODER_RELAY=off ZCODER_SYNC_OUTPUT=false
export ZCODER_CURSES=$3
command stty rows 24 cols 120 < /dev/tty
# Keep the actual entrypoint and input loop; replace only model warm-up and
# record the state immediately before the next terminal read.
source() {
  builtin source "$@" || return $?
  case $1 in
    */lib/agent.zsh)
      agent_warmup_start() { return 0; }
      agent_warmup_poll() { return 0; }
      ;;
    */lib/terminal.zsh)
      functions[_fixture_read]=$functions[terminal_read_event]
      terminal_read_event() {
        mapfile[$fixture_base.state]="$UI_FOCUS:$SIDE_W:$INPUT_POS:$INPUT_BUF"
        mapfile[$fixture_base.tty]=$TTY
        _fixture_read "$@"
      }
      ;;
  esac
  return 0
}
builtin source "$fixture_root/zcoder.zsh" --model fixture --workspace "$fixture_base.workspace" \
  --context-window 32768 --no-warmup --deny-commands
