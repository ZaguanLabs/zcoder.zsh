#!/usr/bin/env zsh
# Standalone PTY checks; optional zdraw captures need no Python at test time.
emulate -R zsh
setopt extendedglob
zmodload zsh/zpty zsh/zselect zsh/datetime zsh/mapfile zsh/files || exit 1
typeset -g picker_root=${0:A:h:h} picker_output='' picker_chunk='' picker_base
typeset -g picker_actual="$picker_root/.build/picker-visuals"
typeset -g picker_expected="$picker_root/tests/fixtures/picker"
zf_mkdir -p "$picker_actual" || exit 1
trap 'zpty -d picker-ui 2>/dev/null' EXIT
picker_fail() {
  print -ru2 -- "FAIL: $*"
  print -ru2 -- "${(V)picker_output[-1500,-1]}"
  exit 1
}
picker_wait() {
  local suffix=$1 expected=$2
  local -F deadline=$(( EPOCHREALTIME + 15 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r picker-ui picker_chunk 2>/dev/null; do picker_output+=$picker_chunk; done
    [[ ${mapfile[$picker_base.$suffix]:-} == "$expected" ]] && return 0
    zselect -t 1
  done
  picker_fail "timed out waiting for $suffix=$expected"
}
picker_run() {
  trap - EXIT INT TERM
  export TERM=xterm-256color ZCODER_COLOR=$picker_profile
  exec zsh -df "$picker_root/tests/fixtures/picker_ui.zsh" "$picker_root" "$picker_base" "$picker_backend"
}
typeset picker_backend picker_profile picker_tty actual baseline stem
typeset -a picker_stale
typeset -i snapshots=0
for picker_backend picker_profile in stock auto auto auto auto mono auto basic; do
  picker_base="$picker_actual/$picker_backend-$picker_profile"
  picker_stale=("$picker_base".*(N) "$picker_base"-*.json(N))
  (( ${#picker_stale} )) && zf_rm -f -- "${picker_stale[@]}"
  picker_output=''
  zpty -b picker-ui picker_run || picker_fail 'could not start PTY'
  picker_wait frame choose:1:44
  if [[ ${mapfile[$picker_base.backend]} == zdraw ]]; then
    [[ ${mapfile[$picker_base.widgets]} == 1 ]] || picker_fail 'native picker did not use widgets'
  else
    [[ ${mapfile[$picker_base.widgets]} == 0 ]] || picker_fail 'stock picker enabled native widgets'
  fi
  zpty -w -n picker-ui $'\eOF'
  picker_wait frame choose:30:44
  picker_tty=${mapfile[$picker_base.tty]}
  command stty rows 10 cols 28 < "$picker_tty" || picker_fail resize
  picker_wait frame choose:30:28
  zpty -w -n picker-ui $'\eOH\eOB\r'
  picker_wait frame empty:0:28
  # Enter cannot accept an empty list; q must still be consumed by that modal.
  zpty -w -n picker-ui $'\r'q
  picker_wait frame fallback:1:28
  [[ ${mapfile[$picker_base.widgets]} == 0 ]] || picker_fail 'draw failure did not select fallback'
  zpty -w -n picker-ui $'\r'
  picker_wait frame unusual:1:28
  zpty -w -n picker-ui $'\eOB\r'
  picker_wait done 1
  zpty -d picker-ui
  for stem in choose-1-44 choose-30-44 choose-30-28 empty-0-28 fallback-1-28; do
    actual="$picker_base-$stem.json"
    [[ ${mapfile[$picker_base.backend]} == zdraw ]] || continue
    [[ -s $actual ]] || picker_fail "missing capture: $actual"
    baseline="$picker_expected/${actual:t}"
    if [[ ${ZCODER_UPDATE_VISUALS:-0} == 1 ]]; then
      zf_mkdir -p "$picker_expected" || exit 1
      print -r -- "$(<"$actual")" > "$baseline" || exit 1
    elif [[ ! -r $baseline || "$(<"$actual")" != "$(<"$baseline")" ]]; then
      print -ru2 -- "Visual mismatch: $baseline"
      print -ru2 -- "Actual: $actual"
      print -ru2 -- "Compare with: python3 vendor/zdraw/scripts/visual_diff.py ${(q)baseline} ${(q)actual} --html ${(q)actual}.html"
      exit 1
    fi
    (( snapshots++ ))
  done
  print -r -- "PASS: picker $picker_backend/$picker_profile input, resize, empty list and fallback"
done
if (( snapshots )); then
  print -r -- "PASS: $snapshots picker visual baselines"
else
  [[ ${ZCODER_REQUIRE_VISUALS:-0} == 1 ]] && picker_fail 'visual tests require a matching zdraw build with window snapshots'
  print -r -- 'SKIP: visual baselines require a matching zdraw build with window snapshots'
fi
