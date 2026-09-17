# Application grammar checks with zjson's grammar-neutral tokenizer.
() {
  local parser document sample
  local ZCODER_MODEL=lfm
  local -A MCP_USER_RAW=() MCP_PROJECT_RAW=()
  local checkpoint='{"schema_version":1,"objective":"continue","constraints":[],"decisions":[],"artifacts":[],"facts":[],"completed":[],"active":[],"blocked":[],"next":[]}'
  for parser document in \
    json_parse_flat_object '{"x":1,}' \
    json_parse_ollama_response '{"done":true,}' \
    json_parse_ollama_response '{"message":{"content":"hello",}}' \
    json_parse_ollama_response '{"message":{"tool_calls":[{"function":{"name":"read_file","arguments":{}},}]}}' \
    json_parse_ollama_response '{"message":{"tool_calls":[{"function":{"name":"read_file","arguments":{},}}]}}' \
    json_parse_ollama_response '{"message":{"tool_calls":[{"function":{"name":"read_file","arguments":{}}},]}}' \
    json_parse_models '{"models":[],}' \
    json_parse_models '{"models":[{"name":"model",}]}' \
    json_parse_models '{"models":[{"name":"model"},]}' \
    json_parse_running_model_context '{"models":[],}' \
    json_parse_running_model_context '{"models":[{"name":"model",}]}' \
    json_parse_running_model_context '{"models":[{"name":"model"},]}' \
    _mcp_json_get '{"other":1,}' \
    _mcp_parse_string_array '["argument",]' \
    _mcp_config_parse_servers '{"mcpServers":{},}' \
    _mcp_config_parse_servers '{"mcpServers":{"server":{},}}' \
    _agent_content_is_lfm_json_plan '{"plan":"p","analysis":"a","commands":[],}' \
    _agent_content_is_lfm_json_plan '{"plan":"p","analysis":"a","commands":["x",]}' \
    _agent_lfm_json_is_call_object '{"name":"read_file",}' \
    delegate_json_collect_scalars '{"result":"text",}' \
    delegate_json_collect_scalars '["text",]' \
    agent_parse_compaction_summary "${checkpoint%\}},}" \
    agent_parse_compaction_summary "${checkpoint/\"next\":\[\]/\"next\":[\"continue\",]}"; do
    "$parser" "$document" missing
    assert_failure "$parser rejects trailing commas: $document" $?
    assert_eq trailing_comma "$ZJSON_ERROR_CODE" "$parser retains the trailing-comma diagnostic"
    if [[ $parser == json_parse_ollama_response ]]; then
      assert_eq 0 "${#JSON_TOOL_NAMES}" 'rejected Ollama grammar publishes no tool calls'
    fi
  done

  # Byte offsets must agree with upstream, including multibyte keys and LF.
  document=$'{\n "é":1,\n}'
  zjson_validate "$document"
  local diagnostic="$ZJSON_ERROR|$ZJSON_ERROR_CODE|$ZJSON_ERROR_OFFSET|$ZJSON_ERROR_LINE|$ZJSON_ERROR_COLUMN"
  json_parse_flat_object "$document"
  assert_eq "$diagnostic" "$ZJSON_ERROR|$ZJSON_ERROR_CODE|$ZJSON_ERROR_OFFSET|$ZJSON_ERROR_LINE|$ZJSON_ERROR_COLUMN" \
    'application trailing-comma diagnostics match upstream byte locations'

  _mcp_json_string '""'
  assert_success 'generic MCP string decoding accepts an empty string' $?
  assert_eq '' "$REPLY" 'generic MCP string decoding preserves empty text'
  _mcp_json_string '"line\n\u00e9"'
  assert_success 'generic MCP string decoding handles escapes' $?
  assert_eq $'line\né' "$REPLY" 'generic MCP string decoding preserves decoded text'
  assert_eq 0 "${#ZJSON_CHARS}" 'generic MCP string decoding releases the tokenizer byte array'
  for document in '"ok" false' '"ok" garbage' 'null' '{}' '42'; do
    _mcp_json_string "$document"
    assert_failure "MCP string decoding rejects $document" $?
  done

  for sample in $'\xc0\xaf' $'\xe0\x80\xaf' $'\xed\xa0\x80' $'\xf0\x80\x80\xaf' $'\xf4\x90\x80\x80'; do
    json_parse_ollama_response '{"message":{"content":"'"$sample"'"}}'
    assert_failure 'Ollama rejects forbidden UTF-8 encodings' $?
    assert_eq invalid_utf8 "$ZJSON_ERROR_CODE" 'forbidden UTF-8 keeps its structured diagnostic'
  done
}
