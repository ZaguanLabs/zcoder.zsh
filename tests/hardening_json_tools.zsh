# Shared parser and workspace regressions; sourced by tests/run.zsh.
() {
  local malformed='' sample='' encoded='' ch='' escaped='' quoted='' wire=''
  local -i code=0
  for malformed in '{"x":01}' '{"x":-}' '{"x":1.}' '{"x":1e+}' \
    '{"x":1,}' '{"x":true} false' '{"x":true} garbage' \
    $'{\v"x":1}' $'{\f"x":1}'; do
    json_parse_flat_object "$malformed"
    assert_failure "flat JSON rejects ${(qqq)malformed}" $?
  done
  for sample in '{"x":0}' '{"x":-0}' '{"x":-10.25e+2}' \
    $' \r\n\t{"x":1E-3}\t\n'; do
    json_parse_flat_object "$sample"
    assert_success "flat JSON accepts ${(qqq)sample}" $?
  done
  for malformed in '{"x":[1,]}' '{"x":{"y":1,}}'; do
    zjson_begin "$malformed" && zjson_capture_value
    assert_failure "nested JSON rejects trailing comma ${(qqq)malformed}" $?
  done
  json_parse_models '{"models":[]} true'
  assert_failure 'model catalog parser requires EOF' $?
  json_parse_running_model_context '{"models":[]} true' model
  assert_failure 'running model parser requires EOF' $?
  json_parse_ollama_response '{"message":{"tool_calls":[{"function":{"name":"read_file","arguments":{"path":"x",}}}]}}'
  assert_failure 'Ollama rejects malformed nested tool arguments' $?
  json_parse_ollama_response $'{"message":{"tool_calls":[{"function":{"name":"read_file","arguments":{"path":"x"}}}]},"extra":"\xff"}'
  assert_failure 'Ollama rejects invalid UTF-8 even in an unused field' $?
  assert_eq invalid_utf8 "$ZJSON_ERROR_CODE" 'Ollama exposes the zjson validation diagnostic'
  assert_eq 0 "${#JSON_TOOL_NAMES}" 'invalid UTF-8 cannot publish executable tool calls'

  for (( code=0; code<32; code++ )); do
    printf -v encoded '\\x%02x' "$code"
    printf -v ch '%b' "$encoded"
    sample="${ch}é${ch}"
    zjson_quote "$sample"; quoted="$REPLY"
    zjson_begin "$quoted"
    assert_success "JSON encodes and decodes control $code" $?
    assert_eq "$sample" "$ZJSON_TOKEN_VALUE" "JSON preserves control $code at both string boundaries"
    zjson_begin "\"${sample}\""
    assert_failure "JSON rejects literal control $code" $?
  done
  sample=$'é\177é'
  zjson_quote "$sample"; quoted="$REPLY"
  assert_eq "\"${sample}\"" "$quoted" 'DEL stays literal in valid JSON'
  zjson_begin '"\ud800\u0041\udc00"'
  assert_success 'strict JSON preserves surrogate recovery' $?
  assert_eq $'�A�' "$ZJSON_TOKEN_VALUE" 'unpaired surrogates still become replacement characters'
  zjson_begin $'"\\u0041\1"'
  assert_failure 'slow Unicode scanner rejects literal controls' $?
  zjson_begin $'"\\n\1"'
  assert_failure 'simple escape scanner rejects literal controls' $?

  local fixture="$TEST_TMP/hardening-json-tools"
  local ZCODER_WORKSPACE="$fixture/workspace" ZCODER_COMMAND_POLICY=deny
  local ZCODER_MAX_TOOL_OUTPUT=32768 UI_ACTIVE=0
  local -x RIPGREP_CONFIG_PATH="$fixture/rgconfig"
  local marker="$fixture/pre-executed" pre="$fixture/pre"
  zf_mkdir -p -- "$fixture/workspace" "$fixture/outside"
  mapfile[$fixture/workspace/input]='inside'
  mapfile[$fixture/outside/secret]='OUTSIDE_REVIEW_SECRET'
  zf_ln -s -- "$fixture/outside" "$fixture/workspace/link"
  mapfile[$RIPGREP_CONFIG_PATH]='--follow'
  tool_search OUTSIDE_REVIEW_SECRET . 10
  assert_success 'search succeeds with inherited follow configuration disabled' $?
  assert_not_contains "$TOOL_RESULT" 'OUTSIDE_REVIEW_SECRET' 'search does not traverse an outside symlink from rg config'
  tool_list_files . 100
  assert_success 'listing succeeds with inherited follow configuration disabled' $?
  assert_not_contains "$TOOL_RESULT" 'secret' 'listing does not follow an outside symlink from rg config'
  mapfile[$pre]=$'#!/bin/zsh\nprint -r -- executed > '"${(q)marker}"$'\nprint -r -- PRE_EXECUTED\n'
  zf_chmod 700 "$pre"
  mapfile[$RIPGREP_CONFIG_PATH]="--pre=$pre"
  tool_search inside . 10
  assert_success 'search ignores configured preprocessor under deny policy' $?
  assert_contains "$TOOL_RESULT" inside 'search examines the original file content'
  [[ ! -e "$marker" ]]
  assert_success 'ripgrep preprocessor never executes' $?

  mapfile[$fixture/workspace/range]=$'one\n'
  tool_read_file_range range 2 2
  assert_failure 'trailing newline does not invent a second line' $?
  zcoder_write_text_file "$fixture/workspace/range" ''
  tool_read_file_range range 1 1
  assert_failure 'empty file has zero lines' $?
  mapfile[$fixture/workspace/range]=$'\n\none\nlast'
  tool_read_file_range range 1 9
  assert_success 'range handles empty and unterminated lines' $?
  assert_eq $'1: \n2: \n3: one\n4: last' "$TOOL_RESULT" 'range preserves exact line numbering and content'
  tool_read_file_range range 999999999999999999999 999999999999999999999
  assert_failure 'range rejects overflowing line numbers before arithmetic' $?

  # Reproduce the logged model calls: distinct ranges sent to read_file used
  # to discard their bounds and each return the same complete HTML file.
  local AGENT_TOOL_PHASE=full
  local -i line_index=0 first_line=0 last_line=0
  local expected='' bounds='' read_args=''
  sample=''
  for (( line_index=1; line_index<=1200; line_index++ )); do
    sample+="payload $line_index"$'\n'
  done
  mapfile[$fixture/workspace/range]="$sample"
  for bounds in 1:50 100:200 820:1000 1000:1100 695:730 400:420; do
    first_line=${bounds%:*}; last_line=${bounds#*:}
    read_args='{"path":"range","start_line":"'"$first_line"'","end_line":"'"$last_line"'"}'
    tool_dispatch read_file "$read_args"
    assert_failure "read_file rejects logged misplaced range $bounds" $?
    assert_eq 0 "$TOOL_RESULT_OK" 'misplaced ranges are tool failures, not successful partial reads'
    assert_contains "$TOOL_RESULT" 'call read_file_range with path, start_line, and end_line' 'misplaced range diagnostic names the correct tool and required arguments'
    assert_not_contains "$TOOL_RESULT" 'payload' 'misplaced range rejection returns no file contents'
    tool_dispatch read_file_range "$read_args"
    assert_success "corrected read_file_range accepts logged range $bounds" $?
    expected=''
    for (( line_index=first_line; line_index<=last_line; line_index++ )); do
      [[ -n "$expected" ]] && expected+=$'\n'
      expected+="$line_index: payload $line_index"
    done
    assert_eq "$expected" "$TOOL_RESULT" "corrected read_file_range returns the requested range $bounds"
  done
  tool_dispatch read_file '{"path":"range","start_line":"1000"}'
  assert_failure 'start-only read_file fails rather than supplying an implicit range' $?
  tool_dispatch read_file '{"path":"range","end_line":2}'
  assert_failure 'end-only read_file fails rather than supplying an implicit start' $?
  tool_dispatch read_file_range '{"path":"range","start_line":1}'
  assert_failure 'read_file_range requires an explicit end line' $?
  tool_dispatch read_file_range '{"path":"range","end_line":200}'
  assert_failure 'read_file_range requires an explicit start line' $?
  tool_dispatch read_file_range '{"path":"range","start_line":1,"end_line":1200}'
  assert_success 'explicit range may exceed 200 lines' $?
  assert_contains "$TOOL_RESULT" '1200: payload 1200' 'explicit large range reaches its requested last line'
  tool_dispatch read_file '{"path":"range"}'
  assert_success 'whole-file read of 1200 lines succeeds within the output-size limit' $?
  assert_eq "$sample" "$TOOL_RESULT" 'whole-file read returns all 1200 lines exactly without numbering'
  ZCODER_MAX_TOOL_OUTPUT=${#sample}
  tool_dispatch read_file '{"path":"range"}'
  assert_eq "$sample" "$TOOL_RESULT" 'whole-file read at the output-size limit remains complete'
  (( ZCODER_MAX_TOOL_OUTPUT-- ))
  tool_dispatch read_file '{"path":"range"}'
  assert_failure 'whole-file read exceeding the output-size limit fails instead of truncating' $?
  assert_eq 0 "$TOOL_RESULT_OK" 'oversized whole-file reads are not successful tool results'
  assert_contains "$TOOL_RESULT" 'No file content was returned.' 'oversized whole-file diagnostic explicitly rules out partial contents'
  assert_contains "$TOOL_RESULT" read_file_range 'oversized whole-file diagnostic explains how to recover'
  assert_not_contains "$TOOL_RESULT" payload 'oversized whole-file result contains no misleading file fragment'
  ZCODER_MAX_TOOL_OUTPUT=32768
  tool_dispatch read_file '{"path":"input"}'
  assert_eq inside "$TOOL_RESULT" 'path-only read still returns exact full content'
  for read_args in '{"path":"range","start_line":"1+1"}' \
    '{"path":"range","start_line":999999999999999999999}' \
    '{"path":"range","start_line":0}' '{"path":"range","start_line":""}' \
    '{"path":"range","start_line":2,"end_line":1}' \
    '{"path":"range","start_line":1,"end_line":""}' \
    '{"path":"range","offset":1,"limit":5}' \
    '{"path":"link/secret","start_line":1,"end_line":5}'; do
    tool_dispatch read_file "$read_args"
    assert_failure "read_file rejects invalid or unsafe bounds ${(qqq)read_args}" $?
    assert_not_contains "$TOOL_RESULT" 'payload 1' 'rejected ranged reads never fall back to the complete file'
    assert_not_contains "$TOOL_RESULT" OUTSIDE_REVIEW_SECRET 'invalid read arguments never expose outside contents'
  done
  tool_dispatch read_file '{"path":"link/secret"}'
  assert_failure 'pure whole-file reads still reject outside symlinks' $?
  tool_dispatch read_file_range '{"path":"link/secret","start_line":1,"end_line":5}'
  assert_failure 'corrected ranged reads still reject outside symlinks' $?
  tool_read_file range 1 5
  assert_failure 'direct whole-file tool calls also reject extra arguments' $?
  tool_dispatch read_file_range '{"path":"range","start_line":1,"end_line":5,"offset":3}'
  assert_failure 'read_file_range rejects unsupported arguments instead of ignoring them' $?

  # Force a Unicode character and a selected line across a sysread block.
  sample="${(l:32767::x:)}"$'é\nlast\n'
  mapfile[$fixture/workspace/range]="$sample"
  ZCODER_MAX_TOOL_OUTPUT=65536
  tool_read_file_range range 1 1
  assert_success 'range joins a Unicode character split across read blocks' $?
  assert_eq "1: ${sample%%$'\n'*}" "$TOOL_RESULT" 'range preserves split UTF-8 bytes'
  tool_read_file_range range 2 2
  assert_eq '2: last' "$TOOL_RESULT" 'range skips a long preceding line across blocks'
  local unit=$'abcdefghi\n'
  sample="${(pl:100000::$unit:)}"
  mapfile[$fixture/workspace/range]="$sample"
  tool_read_file_range range 10000 10000
  assert_eq '10000: abcdefghi' "$TOOL_RESULT" 'range skips preceding lines by complete chunks'
  ZCODER_MAX_TOOL_OUTPUT=128
  tool_read_file_range range 1 10000
  assert_success 'large selected ranges preserve bounded head and tail' $?
  (( ${#TOOL_RESULT} <= ZCODER_MAX_TOOL_OUTPUT ))
  assert_success 'range result obeys configured character cap' $?
  assert_contains "$TOOL_RESULT" '1: abcdefghi' 'bounded range keeps its beginning'
  assert_contains "$TOOL_RESULT" '10000: abcdefghi' 'bounded range keeps its ending'
  assert_contains "$TOOL_RESULT" 'characters omitted' 'bounded range explains omitted content'

  ZCODER_WORKSPACE=/
  _tool_resolve_existing "$fixture/workspace/input"
  assert_success 'root workspace admits its descendants' $?
}
