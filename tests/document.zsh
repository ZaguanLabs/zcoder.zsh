#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
zmodload zsh/zpty zsh/zselect zsh/datetime zsh/mapfile zsh/files || exit 1
typeset -g doc_root=${0:A:h:h} doc_output='' doc_chunk='' doc_base
typeset -g doc_actual="$doc_root/.build/document-visuals"
typeset -g doc_expected="$doc_root/tests/fixtures/document"
zf_mkdir -p "$doc_actual" || exit 1
trap 'zpty -d document-ui 2>/dev/null' EXIT
doc_fail() { print -ru2 -- "FAIL: $*" "${(V)doc_output[-1200,-1]}"; exit 1; }
doc_wait() {
  local suffix=$1 expected=$2
  local -F deadline=$(( EPOCHREALTIME+15 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r document-ui doc_chunk 2>/dev/null; do doc_output+=$doc_chunk; done
    [[ ${mapfile[$doc_base.$suffix]:-} == "$expected" ]] && return 0
    zselect -t 1
  done
  doc_fail "timed out waiting for $suffix=$expected"
}
doc_run() {
  trap - EXIT INT TERM
  unset ESCDELAY
  export TERM=xterm-256color ZCODER_COLOR=$doc_profile
  exec zsh -df "$doc_root/tests/fixtures/document_ui.zsh" "$doc_root" "$doc_base" "$doc_backend"
}
(
  source "$doc_root/lib/util.zsh"
  source "$doc_root/lib/transcript.zsh"
  source "$doc_root/lib/commands.zsh"
  typeset -gi UI_ACTIVE=0
  ui_show_help 'No runtimes available.'
  [[ ${#UI_CONTENTS} == 2 && $UI_CONTENTS[1] == *$'Tools and sessions\n\nPersistent goals\n- /goal OBJECTIVE:'* &&
     $UI_CONTENTS[1] == *$'\n- /queue drop ID:'* &&
     $UI_CONTENTS[2] == 'No runtimes available.' ]]
) || doc_fail 'noninteractive help lost its formatting or content'
typeset doc_backend doc_profile actual baseline stem
typeset -a stale old_anchor new_anchor
typeset -i snapshots=0 native=0 move
typeset -F close_started close_elapsed
for doc_backend doc_profile in stock auto auto auto auto mono; do
  doc_base="$doc_actual/$doc_backend-$doc_profile"
  stale=("$doc_base".*(N) "$doc_base"-*.json(N))
  (( ${#stale} )) && zf_rm -f -- "${stale[@]}"
  doc_output=''
  zpty -b document-ui doc_run || doc_fail startup
  doc_wait phase reader
  native=${mapfile[$doc_base.native]}
  if [[ ${mapfile[$doc_base.backend]} == zdraw ]]; then
    (( native )) || doc_fail 'native document did not compile'
  else (( ! native )) || doc_fail 'stock reader enabled native drawing'; fi
  zpty -w -n document-ui ']'
  doc_wait draws 2
  [[ ${mapfile[$doc_base.anchor]} == 3:* ]] || doc_fail 'next heading did not reach Editing'
  for move in {3..6}; do
    zpty -w -n document-ui $'\eOB'
    doc_wait draws "$move"
  done
  old_anchor=("${(@s.:.)mapfile[$doc_base.anchor]}")
  [[ $old_anchor[1] == 4 ]] || doc_fail 'scroll did not reach the second paragraph'
  command stty rows 10 cols 28 < "${mapfile[$doc_base.tty]}" || doc_fail resize
  doc_wait width 28
  new_anchor=("${(@s.:.)mapfile[$doc_base.anchor]}")
  [[ $new_anchor[1] == "$old_anchor[1]" ]] || doc_fail 'resize lost the source block'
  if (( native )); then
    (( new_anchor[2] <= old_anchor[2] && new_anchor[3] > old_anchor[2] )) || doc_fail 'resize lost the source byte'
  fi
  zpty -w -n document-ui '['
  doc_wait block 3
  # Home works after heading navigation and returns to the beginning.
  zpty -w -n document-ui $'\eOH'
  doc_wait first 1
  zpty -w -n document-ui q
  doc_wait phase help
  command stty rows 24 cols 92 < "${mapfile[$doc_base.tty]}" || doc_fail 'help resize'
  doc_wait width 92
  for stem in navigation commands tools; do
    zpty -w -n document-ui ']'
    doc_wait block_id "$stem"
  done
  doc_wait phase tools
  close_started=$EPOCHREALTIME
  zpty -w -n document-ui $'\e'
  doc_wait phase fallback
  close_elapsed=$(( EPOCHREALTIME-close_started ))
  (( close_elapsed < 0.8 )) || doc_fail "Escape took ${close_elapsed}s to close help"
  [[ ${mapfile[$doc_base.native]} == 0 ]] || doc_fail 'partial draw did not fall back'
  zpty -w -n document-ui q
  doc_wait phase large
  [[ ${mapfile[$doc_base.native]} == 0 ]] || doc_fail 'oversized document did not fall back'
  zpty -w -n document-ui q
  doc_wait done 1
  zpty -d document-ui
  for stem in reader-28 help-28 tools-92 fallback-92; do
    [[ ${mapfile[$doc_base.backend]} == zdraw ]] || continue
    actual="$doc_base-$stem.json"
    [[ -s $actual ]] || doc_fail "missing capture: $actual"
    baseline="$doc_expected/${actual:t}"
    if [[ ${ZCODER_UPDATE_VISUALS:-0} == 1 ]]; then
      zf_mkdir -p "$doc_expected" || exit 1
      print -r -- "$(<"$actual")" > "$baseline"
    elif [[ ! -r $baseline || "$(<"$actual")" != "$(<"$baseline")" ]]; then
      print -ru2 -- "Visual mismatch: $baseline" "Actual: $actual"
      print -ru2 -- "Compare: python3 vendor/zdraw/scripts/visual_diff.py ${(q)baseline} ${(q)actual} --html ${(q)actual}.html"
      exit 1
    fi
    (( snapshots++ ))
  done
  print -r -- "PASS: document $doc_backend/$doc_profile navigation, reflow, help and fallback"
done
if (( snapshots )); then print -r -- "PASS: $snapshots document visual baselines"
else
  [[ ${ZCODER_REQUIRE_VISUALS:-0} == 1 ]] && doc_fail 'visual tests require a matching zdraw build'
  print -r -- 'SKIP: document baselines require a matching zdraw build'
fi
