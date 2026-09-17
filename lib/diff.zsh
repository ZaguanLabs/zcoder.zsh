# Inline change previews use zdraw's change-gutter without another input loop.
source "${${(%):-%x}:A:h:h}/vendor/zdraw/examples/components/change-gutter.zsh"
typeset -ga UI_DIFF_ROWS=()

ui_diff_rows() {
  emulate -L zsh
  setopt extendedglob
  local diff="${UI_TOOL_DIFFS[$1]}" line='' file='' text='' kind=''
  local -a match=()
  local -i old=0 new=0 old_remaining=0 new_remaining=0 in_hunk=0 total=0 limited=0
  UI_DIFF_ROWS=()
  (( ${#diff} > 60000 )) && { diff="${diff[1,60000]}"; limited=1; }
  for line in "${(@f)diff}"; do
    if [[ "$line" == 'diff --git '* ]] ||
        { (( !in_hunk || (old_remaining <= 0 && new_remaining <= 0) )) && [[ "$line" == '--- '* ]]; }; then
      in_hunk=0
      continue
    elif (( !in_hunk )) && [[ "$line" == '+++ '* ]]; then
      file="${line#+++ }"
      file="${file#b/}"
      in_hunk=0
      continue
    elif [[ "$line" =~ '^@@ -([0-9]+)(,[0-9]+)? \+([0-9]+)(,[0-9]+)? @@' ]]; then
      (( ${#match[1]} <= 6 && ${#match[3]} <= 6 )) || { limited=1; break; }
      old=$(( 10#${match[1]} )); new=$(( 10#${match[3]} ))
      (( ${#match[2]} <= 7 && ${#match[4]} <= 7 )) || { limited=1; break; }
      old_remaining=$(( 10#${${match[2]#,}:-1} )); new_remaining=$(( 10#${${match[4]#,}:-1} ))
      text="$file  $line"; kind=hunk; in_hunk=1
    elif (( in_hunk )); then
      case "${line[1]}" in
        ' ') kind=context; text="${line[2,-1]}" ;;
        '-') kind=remove; text="${line[2,-1]}" ;;
        '+') kind=add; text="${line[2,-1]}" ;;
        '\') kind=hunk; text="$line" ;;
        *) continue ;;
      esac
    else
      continue
    fi
    # Normalize controls before zdraw's strict text validation. Tabs become
    # visible spaces; filenames and source text are never interpreted as code.
    zcoder_terminal_safe "$text"; text="$REPLY"
    (( ${#text} > 2048 )) && { text="${text[1,2045]}..."; limited=1; }
    (( total += ${#text} ))
    (( total <= 60000 && ${#UI_DIFF_ROWS} < 1000 && old <= 999999 && new <= 999999 )) || { limited=1; break; }
    case "$kind" in
      context) (( old > 0 && new > 0 )) || continue; UI_DIFF_ROWS+=(context "$old" "$new" "$text"); (( old++, new++, old_remaining--, new_remaining-- )) ;;
      remove) (( old > 0 )) || continue; UI_DIFF_ROWS+=(remove "$old" - "$text"); (( old++, old_remaining-- )) ;;
      add) (( new > 0 )) || continue; UI_DIFF_ROWS+=(add - "$new" "$text"); (( new++, new_remaining-- )) ;;
      hunk) UI_DIFF_ROWS+=(hunk - - "$text") ;;
    esac
  done
  (( limited )) && UI_DIFF_ROWS+=(hunk - - '[Preview limited; remaining changes are not shown.]')
  (( ${#UI_DIFF_ROWS} > 0 ))
}

ui_add_diff() {
  local index="$1" width="$2" kind='' old='' new='' text='' marker='' number='' attr='' formatted=''
  local -i review_row=0
  ui_diff_rows "$index" || return 1
  _ui_add_line '   LINE   CHANGE' 'dim white/black'
  UI_LINE_NATIVE[-1]="diff:$index:0"
  for kind old new text in "${UI_DIFF_ROWS[@]}"; do
    marker=' '; number="$new"; attr='white/black'
    case "$kind" in
      add) marker='+'; attr='green/black' ;;
      remove) marker='-'; number="$old"; attr='red/black' ;;
      hunk) marker=''; number=''; attr='dim cyan/black' ;;
    esac
    printf -v formatted '%6s %s %s' "$number" "$marker" "$text"
    _ui_add_line "$formatted" "$attr"
    # Preview rows clip horizontally instead of wrapping, keeping file numbers
    # aligned with source lines. The native gutter adds its clipping marker.
    UI_LINE_NATIVE[-1]="diff:$index:$(( ++review_row ))"
  done
}

ui_draw_diff() {
  local win="$1" row="$2" column="$3" height="$4" width="$5" index="$6" first="$7"
  local -A zdraw_ui_theme=() zdraw_ui_gutter=()
  local -a styles=()
  (( height >= 2 )) && ui_widgets_available || return 1
  ui_diff_rows "$index" || return 1
  ui_widget_theme
  case "$UI_COLOR_MODE" in
    rgb|256) styles=(positive:bg='#20382c' negative:bg='#46282b' positive:fg='#a3be8c' negative:fg='#bf616a') ;;
    *) styles=(positive:bold negative:bold) ;;
  esac
  zdraw-change-gutter "$win" "$row" "$column" "$height" "$width" "$first" numbers=single "${styles[@]}" -- "${UI_DIFF_ROWS[@]}"
}
