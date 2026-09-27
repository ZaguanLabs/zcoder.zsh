#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
zmodload zsh/zpty zsh/zselect zsh/datetime zsh/mapfile zsh/files || exit 1
typeset root=${0:A:h:h} base output='' chunk='' action tail
base=$(mktemp -d "${TMPDIR:-/tmp}/zcoder-keyboard-exit.XXXXXXXX") || exit 1
trap 'zpty -d keyboard-exit 2>/dev/null; zf_rm -rf -- "$base"' EXIT
fail() { print -ru2 -- "FAIL: $*" "${(V)output[-1200,-1]}"; exit 1; }
drain() { while zpty -r keyboard-exit chunk 2>/dev/null; do output+=$chunk; done; }
wait_phase() {
  local wanted=$1
  local -F deadline=$(( EPOCHREALTIME+8 ))
  while (( EPOCHREALTIME < deadline )); do
    drain
    [[ ${mapfile[$base/phase]:-} == "$wanted" ]] && return 0
    [[ ${mapfile[$base/phase]:-} == unsupported ]] && return 2
    zselect -t 1
  done
  fail "timed out waiting for $wanted"
}
run_fixture() {
  trap - EXIT INT TERM
  export TERM=xterm-256color
  exec zsh -df "$root/tests/fixtures/keyboard_exit_ui.zsh" "$root" "$base" "$action"
}
for action in initial resume; do
  output=''; mapfile[$base/phase]=''
  zpty -b keyboard-exit run_fixture || fail startup
  typeset -F deadline=$(( EPOCHREALTIME+8 ))
  while [[ $output != *$'\e[?u'* ]] && (( EPOCHREALTIME < deadline )); do
    drain
    [[ ${mapfile[$base/phase]:-} == unsupported ]] && break
    zselect -t 1
  done
  # A nonzero pre-existing flag value must survive our push/configure/pop.
  zpty -w -n keyboard-exit $'\e[?5u'
  if ! wait_phase ready; then
    print -r -- 'SKIP: keyboard exit requires native keyboard events'
    exit 0
  fi
  # Model the mode active when Enter was pressed. With event reporting the
  # release can already be queued by the time /quit restores the shell.
  tail=${output##*$'\e[>27u'}
  zpty -w -n keyboard-exit $'/quit\e[13;129u'
  if [[ $tail != *$'\e[=25u'* ]]; then
    zpty -w -n keyboard-exit $'\e[13;129:3u'
  fi
  wait_phase done || fail completion
  [[ -z ${mapfile[$base/leaked]} ]] || fail "$action /quit leaked ${(V)mapfile[$base/leaked]} to the shell"
  [[ $tail == *$'\e[=25u'* ]] || fail "$action requested unused release events"
  [[ $output == *$'\e[<u'* ]] || fail "$action did not restore the previous keyboard flags"
  zpty -d keyboard-exit
  print -r -- "PASS: $action /quit leaves no key-release bytes for the shell"
done
