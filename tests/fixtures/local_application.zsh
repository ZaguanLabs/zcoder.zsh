#!/usr/bin/env zsh
emulate -R zsh
zmodload zsh/mapfile
typeset -g fixture_root="$1" fixture_base="$2"
command stty rows 24 cols 80 < /dev/tty
typeset -g terminal_before="$(command stty -g < /dev/tty)"
ZCODER_HOME="$fixture_base.home" ZCODER_RELAY=off ZCODER_DEBUG_LOG='' \
  ZCODER_USER_SKILLS_DIR="$fixture_base.workspace" ZCODER_CONFIG_SKILLS_DIR="$fixture_base.workspace" \
  ZCODER_SYNC_OUTPUT=false ZCODER_STREAM=true TMPDIR="$fixture_base.tmp" \
  command zsh -f "$fixture_root/zcoder.zsh" --host "${mapfile[$fixture_base.endpoint]}" \
    --model fixture --workspace "$fixture_base.workspace" --context-window auto --deny-commands
mapfile[$fixture_base.application_exit]="$?"
typeset -g terminal_after="$(command stty -g < /dev/tty)"
mapfile[$fixture_base.terminal_restored]="$([[ "$terminal_before" == "$terminal_after" ]] && print 1 || print 0)"
