#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
typeset fixture_root=$1 fixture_backend=${2:-auto}
source "$fixture_root/lib/curses.zsh"
source "$fixture_root/lib/util.zsh"
source "$fixture_root/lib/input.zsh"
ZCODER_CURSES=$fixture_backend zcoder_curses_load "$fixture_root" || exit 1
input_detect_boundaries
check() {
  [[ $1 == "$2" ]] && return 0
  print -ru2 -- "$3: expected ${(qqq)1}, got ${(qqq)2}"
  exit 1
}
typeset -a reply=()
zcoder_curses_features || true
if (( ${reply[(Ie)grapheme_boundaries]} )); then
  check 1 "$INPUT_GRAPHEME" 'UTF-8 native boundary discovery'
fi
typeset unit mode=$INPUT_GRAPHEME
for unit in $'e\u0301' '👍🏽' '🇳🇴' '👩‍💻' '👨‍👩‍👧‍👦' $'\u0301\u0308'; do
  if (( ! mode )); then
    INPUT_BUF="$unit"; INPUT_POS=${#unit}
    input_backspace
    check "${unit[1,-2]}" "$INPUT_BUF" 'fallback retains character deletion'
    continue
  fi
  INPUT_BUF="$unit"; INPUT_POS=0
  input_right
  check "${#unit}" "$INPUT_POS" 'right crosses the complete unit'
  input_left
  check 0 "$INPUT_POS" 'left crosses the complete unit'
  input_delete
  check '' "$INPUT_BUF" 'delete removes the complete unit'
  INPUT_BUF="x${unit}y"; INPUT_POS=$(( ${#unit}+1 ))
  # Leading marks attach to x here; test their isolated backspace separately.
  if [[ $unit == $'\u0301\u0308' ]]; then INPUT_BUF=$unit; INPUT_POS=${#unit}; fi
  input_backspace
  if [[ $unit == $'\u0301\u0308' ]]; then check '' "$INPUT_BUF" 'leading mark deletion'
  else check xy "$INPUT_BUF" 'backspace preserves both neighbors'; check 1 "$INPUT_POS" 'backspace caret position'; fi
done

if (( mode )); then
  INPUT_BUF='👩💻'; INPUT_POS=1
  input_insert $'\u200d'
  check '👩‍💻' "$INPUT_BUF" 'insertion joins the adjacent emoji'
  check 3 "$INPUT_POS" 'caret follows the joined emoji'
  INPUT_BUF=$'a\n\u0301b'; INPUT_POS=1
  input_delete
  check $'a\u0301b' "$INPUT_BUF" 'newline deletion preserves combining bytes'
  check 2 "$INPUT_POS" 'caret follows marks joined across a deleted newline'
  INPUT_BUF=$'a\n👩‍💻z'; INPUT_POS=5
  input_backspace
  check $'a\nz' "$INPUT_BUF" 'logical-line offsets preserve the preceding line'
  check 2 "$INPUT_POS" 'multiline deletion uses character offsets'
  input_backspace
  check az "$INPUT_BUF" 'newline is independently removable'
  INPUT_BUF=$'a \u0301'; INPUT_POS=3
  input_kill_word
  check a "$INPUT_BUF" 'word deletion never leaves half a space-and-mark unit'
  INPUT_BUF=$'ab\n👩‍💻Z'; INPUT_POS=2; INPUT_GOAL_COL=-1
  input_move_vertical 1 20 4
  check 3 "$INPUT_POS" 'vertical hit-testing avoids an interior emoji boundary'
  check 2 "$INPUT_GOAL_COL" 'vertical movement retains its requested column'
  INPUT_BUF='👩‍💻x'; INPUT_POS=1
  input_delete
  check x "$INPUT_BUF" 'an old interior cursor cannot delete half a unit'
  # Unsupported locales must fall back without requiring a terminal or crash.
  LC_ALL=C input_detect_boundaries
  check 0 "$INPUT_GRAPHEME" 'C locale rejects native grapheme policy'
  input_detect_boundaries
  check 1 "$INPUT_GRAPHEME" 'UTF-8 policy can be reacquired'
fi

input_reset
INPUT_BUF=abc; INPUT_POS=1
input_delete; check ac "$INPUT_BUF" 'ASCII deletion'
input_backspace; check c "$INPUT_BUF" 'ASCII backspace'
input_insert xy; check xyc "$INPUT_BUF" 'ASCII insertion'
input_home; input_left; check 0 "$INPUT_POS" 'left at start is stable'
input_end; input_right; check 3 "$INPUT_POS" 'right at end is stable'
print -r -- "PASS: $fixture_backend grapheme=$mode editing and fallback"
