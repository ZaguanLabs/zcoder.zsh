#!/usr/bin/env zsh
emulate -R zsh
zmodload zsh/mapfile zsh/zselect zsh/system
[[ "$#:$1" == 1:models ]] || exit 9
case "${mapfile[$fixture_base.phase]}" in
  opencode_cancel|opencode_timeout)
    print -r -- provider/partial
    print -r -- PRIVATE_MODEL_WORKER > /dev/tty
    mapfile[$fixture_base.command_started]="${mapfile[$fixture_base.phase]}:$sysparams[pid]"
    while true; do zselect -t 10; done
    ;;
  opencode_failure) print -r -- 'catalog unavailable'; exit 7 ;;
  opencode_large) print -r -- provider/partial; print -r -- ${(pl:1100000::x:)} ;;
  *) print -rl -- provider/alpha provider/beta ;;
esac
