diff_tests() {
  local ZCODER_WORKSPACE="$TEST_TMP/diff-work" TOOL_DIFF='' TOOL_RESULT=''
  local -i TOOL_PATCH_RETRY_REQUIRED=0 TOOL_RESULT_OK=0 UI_CURRENT_TOOL=0 UI_TRANSCRIPT_GENERATION=0
  local -a UI_ROLES=() UI_CONTENTS=() UI_THINKINGS=() UI_TIMES=() UI_REASONING_OPEN=()
  local -a UI_IDS=() UI_BLOCK_OPEN=() UI_TOOL_NAMES=() UI_TOOL_SUMMARIES=() UI_TOOL_ARGS=() UI_TOOL_RESULTS=() UI_TOOL_STATES=() UI_TOOL_DIFFS=()
  local patch='' metadata='' replacement='' old='' new=''
  zf_mkdir -p "$ZCODER_WORKSPACE"
  old=$'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n'
  print -rn -- "$old" > "$ZCODER_WORKSPACE/demo.zsh"
  transcript_tool_event begin replace_text '{"path":"demo.zsh","old_text":"five","new_text":"new five"}'
  tool_replace_text demo.zsh five 'new five'
  assert_success 'replace_text records a preview after a successful write' $?
  replacement="$TOOL_DIFF"
  assert_contains "$replacement" '-five' 'replacement previews contain removed text'
  assert_contains "$replacement" '+new five' 'replacement previews contain added text'
  transcript_tool_event complete replace_text '{}' "$TOOL_RESULT" 1 '' "$TOOL_DIFF"
  assert_eq 1 "${UI_BLOCK_OPEN[1]}" 'successful edit previews open automatically in chat'
  ui_diff_rows 1
  assert_success 'replacement previews produce zdraw change-gutter rows' $?
  assert_contains "${(j:|:)UI_DIFF_ROWS}" 'remove|5|-|five' 'replacement gutters use the actual old file line'
  assert_contains "${(j:|:)UI_DIFF_ROWS}" 'add|-|5|new five' 'replacement gutters use the actual new file line'
  transcript_metadata_json 1; metadata="$REPLY"
  ui_append_message tool restored
  transcript_restore_metadata 2 "$metadata"
  assert_eq "$replacement" "${UI_TOOL_DIFFS[2]}" 'saved transcript metadata restores the complete edit preview'
  ui_render_messages 72
  assert_contains "${(j:|:)UI_LINE_NATIVE}" 'diff:1:' 'chat layout reserves inline native change rows'

  patch=$'--- a/demo.zsh\n+++ b/demo.zsh\n@@ -5,1 +5,1 @@\n-new five\n+patched five\n'
  tool_apply_patch "$patch"
  assert_success 'apply_patch still applies the requested edit' $?
  assert_eq "$patch" "$TOOL_DIFF" 'successful patches retain their accepted unified diff'
  tool_replace_text demo.zsh missing replacement
  assert_failure 'missing literal replacement still fails' $?
  assert_eq '' "$TOOL_DIFF" 'a failed edit cannot reuse the previous successful preview'

  _tool_replacement_diff demo.zsh $'same\n' same
  assert_contains "$REPLY" $'-same\n+same\n\\ No newline' 'newline-only edits remain visible'
  UI_TOOL_DIFFS[1]="$REPLY"
  ui_diff_rows 1
  assert_contains "${(j:|:)UI_DIFF_ROWS}" 'No newline at end of file' 'the gutter retains the final-newline annotation'
  _tool_replacement_diff demo.zsh same $'same\n'
  assert_contains "$REPLY" $'-same\n\\ No newline at end of file\n+same' 'adding the final newline marks the old unterminated line'
  _tool_replacement_diff demo.zsh same same
  assert_eq '' "$REPLY" 'no-op replacements do not invent changed lines'

  UI_TOOL_DIFFS[1]=$'--- a/one\n+++ b/one\n@@ -1 +1 @@\n--- marker\n+++ marker\n--- a/two\n+++ b/two\n@@ -0,0 +1 @@\n+new file\n'
  ui_diff_rows 1
  assert_contains "${(j:|:)UI_DIFF_ROWS}" 'remove|1|-|-- marker' 'source text resembling a file header stays a removal'
  assert_contains "${(j:|:)UI_DIFF_ROWS}" 'add|-|1|++ marker' 'source text resembling a file header stays an addition'
  assert_contains "${(j:|:)UI_DIFF_ROWS}" 'two  @@' 'multi-file patches keep their file headings'
  UI_TOOL_DIFFS[1]=$'--- a/one\n+++ b/one\n@@ -1 +1 @@\n-old\n+\e[31mnew\ttext\n'
  ui_diff_rows 1
  assert_not_contains "${(j:|:)UI_DIFF_ROWS}" $'\e' 'diff source cannot inject terminal escapes'
  assert_not_contains "${(j:|:)UI_DIFF_ROWS}" $'\t' 'diff tabs normalize before strict native drawing'

  local REMOTE_RUNTIME_DIR="$TEST_TMP/diff-events" REMOTE_TURN_ID=diff REMOTE_SERVER_TOOL_CALL_ID=''
  local -i REMOTE_STRUCTURED_TOOL_EVENTS=1 REMOTE_SERVER_TOOL_SEQUENCE=0
  zf_mkdir -p "$REMOTE_RUNTIME_DIR/events"
  remote_server_worker_tool_event begin replace_text '{"path":"demo.zsh"}'
  remote_server_worker_tool_event complete replace_text '{}' 'Updated demo.zsh' 1 "$replacement"
  _remote_server_next_event 1
  json_parse_flat_object "$REPLY"
  assert_eq "$replacement" "${JSON_OBJECT[diff]}" 'remote completion events transport the complete edit preview'
  assert_eq "$replacement" "${UI_TOOL_DIFFS[-1]}" 'remote workers retain edit previews in their saved transcript'
}
diff_tests
unfunction diff_tests
