tool_label_tests() {
  local ZCODER_WORKSPACE="$TEST_TMP/display [work]" REMOTE_MODE=local
  local -i UI_ACTIVE=0 STATE_ENABLED=0 i=1
  local args='' saved_metadata='' expected='' original_path=''
  local -a names=(read_file read_file_range write_file replace_text list_files search)
  local -a labels=(Read 'Read File Range' 'Write File' 'Replace Text' 'List Files' Search)
  zf_mkdir -p "$ZCODER_WORKSPACE/src"
  original_path="$ZCODER_WORKSPACE/src/[draft].zsh"
  zjson_quote "$original_path"
  args='{"path":'"$REPLY"',"start_line":2,"end_line":9}'
  for (( i=1; i<=${#names}; i++ )); do
    transcript_reset
    transcript_tool_event begin "${names[i]}" "$args"
    expected="${labels[i]}(src/[draft].zsh)"
    [[ "${names[i]}" == read_file_range ]] && expected='Read File Range(src/[draft].zsh:2-9)'
    assert_eq "$expected" "${UI_TOOL_SUMMARIES[1]}" "${names[i]} headings use their display name and workspace-relative path"
    assert_eq "$args" "${UI_TOOL_ARGS[1]}" "${names[i]} display formatting preserves exact dispatch arguments"
  done
  transcript_tool_summary read_file '{"path":"src/[draft].zsh","start_line":"1000"}'
  assert_eq 'Read(src/[draft].zsh)' "$REPLY" 'invalid start-only read_file calls are never labeled as ranged reads'
  transcript_tool_summary read_file '{"path":"src/[draft].zsh","end_line":50}'
  assert_eq 'Read(src/[draft].zsh)' "$REPLY" 'invalid end-only read_file calls retain their actual tool name'
  zjson_quote "$original_path"
  args='{"path":'"$REPLY"'}'
  transcript_reset
  transcript_tool_event begin read_file "$args"
  transcript_tool_event running read_file
  assert_eq 'Read(src/[draft].zsh)' "${UI_TOOL_SUMMARIES[1]}" "running tool headings retain the relative display label"
  transcript_tool_event complete read_file "$args" "file mentions $original_path" 1
  assert_eq 'Read(src/[draft].zsh)' "${UI_TOOL_SUMMARIES[1]}" "completed tool headings retain the relative display label"
  assert_eq "file mentions $original_path" "${UI_TOOL_RESULTS[1]}" "display shortening never rewrites file contents or tool results"
  ui_render_messages 200
  assert_contains "${(F)UI_LINES}" 'Read(src/[draft].zsh)' "rendered collapsed tool headings show the friendly relative label"
  assert_not_contains "${(F)UI_LINES}" "$ZCODER_WORKSPACE" "collapsed tool headings omit the absolute workspace prefix"
  ui_plain_transcript
  assert_contains "$REPLY" 'Read(src/[draft].zsh)' "plain transcript headings use the same readable label"
  UI_TOOL_SUMMARIES[1]="read_file ($original_path)"
  transcript_metadata_json 1; saved_metadata="$REPLY"
  transcript_restore_metadata 1 "$saved_metadata"
  assert_eq 'Read(src/[draft].zsh)' "${UI_TOOL_SUMMARIES[1]}" "restored older tool metadata refreshes raw names and absolute paths"
  assert_eq "$args" "${UI_TOOL_ARGS[1]}" "restoring a shortened heading preserves original arguments"

  zcoder_display_path "$ZCODER_WORKSPACE"
  assert_eq . "$REPLY" "the workspace root is displayed as a dot"
  zcoder_display_path "$ZCODER_WORKSPACE-other/file.zsh"
  assert_eq "$ZCODER_WORKSPACE-other/file.zsh" "$REPLY" "similar directory prefixes are not mistaken for the workspace"
  zcoder_display_path 'src/[draft].zsh'
  assert_eq 'src/[draft].zsh' "$REPLY" "already-relative paths are preserved"
  zf_ln -s "$ZCODER_WORKSPACE" "$TEST_TMP/display-alias"
  zcoder_display_path "$TEST_TMP/display-alias/src/[draft].zsh"
  assert_eq 'src/[draft].zsh' "$REPLY" "local display paths resolve workspace aliases"
  zf_ln -s "$TEST_TMP" "$ZCODER_WORKSPACE/remote-link"
  REMOTE_MODE=client
  zcoder_display_path "$ZCODER_WORKSPACE/remote-link/file.zsh"
  assert_eq 'remote-link/file.zsh' "$REPLY" "remote display paths ignore symlinks on the client filesystem"
  ZCODER_WORKSPACE=/
  zcoder_display_path /src/file.zsh
  assert_eq src/file.zsh "$REPLY" "a root workspace still produces relative display paths"
  transcript_tool_summary run_command '{"command":"print /absolute/text"}'
  assert_eq 'Run Command(print /absolute/text)' "$REPLY" "command text is not rewritten as a filesystem path"
  transcript_tool_summary apply_patch '{}'
  assert_eq 'Apply Patch' "$REPLY" "patch headings use the existing display name"
  transcript_tool_summary read_skill_resource '{"name":"zsh-expert","path":"references/intro.md"}'
  assert_eq 'Skill Resource(zsh-expert:references/intro.md)' "$REPLY" "skill-resource headings retain their skill and relative resource path"
  local -A MCP_TOOL_SERVER=(mcp__example__read example) MCP_TOOL_ORIGINAL=(mcp__example__read file.read)
  transcript_tool_summary mcp__example__read '{}'
  assert_eq 'Calling example.file.read' "$REPLY" "MCP headings use the server and original display name"
  transcript_reset
}
tool_label_tests
unfunction tool_label_tests
