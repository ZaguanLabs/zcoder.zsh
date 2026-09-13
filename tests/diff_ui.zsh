diff_ui_run() {
  trap - EXIT INT TERM
  export TERM=xterm-256color ZCODER_COLOR="$diff_policy" NO_COLOR=''
  exec zsh -df "$TEST_DIR/fixtures/diff_ui.zsh" "$PROJECT_DIR" "$diff_base" "$diff_backend" "$diff_columns"
}
typeset -a diff_scenarios=(stock basic 110)
[[ $resize_backend == bundled ]] && diff_scenarios+=(auto auto 110 auto auto 48 auto mono 110)
typeset diff_backend diff_policy diff_columns diff_base diff_chunk diff_output
typeset -F diff_deadline
for diff_backend diff_policy diff_columns in "${diff_scenarios[@]}"; do
  diff_base="$TEST_TMP/diff-$diff_backend-$diff_policy-$diff_columns"
  diff_output=''
  zpty -b diff-ui diff_ui_run
  diff_deadline=$(( EPOCHREALTIME + 15 ))
  while (( EPOCHREALTIME < diff_deadline )); do
    while zpty -r diff-ui diff_chunk 2>/dev/null; do diff_output+="$diff_chunk"; done
    [[ "${mapfile[$diff_base.done]:-}" == 1 ]] && break
    zpty -t diff-ui || break
    zselect -t 1
  done
  assert_eq 1 "${mapfile[$diff_base.done]:-}" "$diff_backend/$diff_policy/$diff_columns renders inline edits, scrolls and folds in a real terminal"
  [[ "${mapfile[$diff_base.done]:-}" == 1 ]] || print -ru2 -- "${(V)diff_output}"
  zpty -d diff-ui
done
unfunction diff_ui_run
