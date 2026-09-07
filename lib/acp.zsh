# Agent Client Protocol v1 agent over newline-delimited JSON-RPC stdio.

typeset -gr ACP_PROTOCOL_VERSION=1
typeset -gi ACP_MODE="${ACP_MODE:-0}"
typeset -gi ACP_INITIALIZED=0 ACP_WORKER_ACTIVE=0 ACP_WORKER_RUNNING=0
typeset -gi ACP_WORKER_PID=0 ACP_WORKER_FD=-1 ACP_PROMPT_CANCELLED=0
typeset -gi ACP_REQUEST_SEQUENCE=0 ACP_TOOL_SEQUENCE=0 ACP_MESSAGE_SEQUENCE=0
typeset -g ACP_MESSAGE_ID_RAW="" ACP_MESSAGE_ID="" ACP_MESSAGE_METHOD=""
typeset -g ACP_MESSAGE_PARAMS="{}" ACP_MESSAGE_RESULT="" ACP_MESSAGE_ERROR=""
typeset -g ACP_SESSION_ID="" ACP_PROMPT_ID_RAW="" ACP_CURRENT_TOOL_CALL_ID=""
typeset -g ACP_INPUT_TURN_ID=''
typeset -gA ACP_SESSION_CWD=() ACP_SESSION_MCP=() ACP_SESSION_COMMAND_ALLOW=()

_acp_valid_json() {
  json_begin "$1" || return 1
  json_skip_value || return 1
  [[ "$JSON_TOKEN_TYPE" == eof ]]
}

_acp_raw_string() {
  json_begin "$1" || return 1
  [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
  REPLY="$JSON_TOKEN_VALUE"
}

_acp_parse_message() {
  local source="$1" raw=""
  ACP_MESSAGE_ID_RAW=""
  ACP_MESSAGE_ID=""
  ACP_MESSAGE_METHOD=""
  ACP_MESSAGE_PARAMS="{}"
  ACP_MESSAGE_RESULT=""
  ACP_MESSAGE_ERROR=""

  _acp_valid_json "$source" || return 1
  [[ "$source" == \{* ]] || return 1
  _mcp_raw_member "$source" jsonrpc || return 1
  _acp_raw_string "$REPLY" || return 1
  [[ "$REPLY" == 2.0 ]] || return 1

  if _mcp_raw_member "$source" id; then
    raw="$REPLY"
    json_begin "$raw" || return 1
    case "$JSON_TOKEN_TYPE" in
      string|number|null)
        ACP_MESSAGE_ID_RAW="$raw"
        ACP_MESSAGE_ID="$JSON_TOKEN_VALUE"
        ;;
      *) return 1 ;;
    esac
  fi
  if _mcp_raw_member "$source" method; then
    _acp_raw_string "$REPLY" || return 1
    ACP_MESSAGE_METHOD="$REPLY"
  fi
  _mcp_raw_member "$source" params && ACP_MESSAGE_PARAMS="$REPLY"
  _mcp_raw_member "$source" result && ACP_MESSAGE_RESULT="$REPLY"
  _mcp_raw_member "$source" error && ACP_MESSAGE_ERROR="$REPLY"
  return 0
}

_acp_send() {
  print -r -- "$1"
}

_acp_result() {
  local id_raw="$1" result="${2:-null}"
  [[ -n "$id_raw" ]] || return 0
  _acp_send "{\"jsonrpc\":\"2.0\",\"id\":${id_raw},\"result\":${result}}"
}

_acp_error() {
  local id_raw="${1:-null}" code="$2" message="$3" message_json=""
  # JSON-RPC notifications never receive a response. The literal `null` is
  # reserved for parse errors where no request ID can be recovered.
  [[ -n "$id_raw" ]] || return 0
  json_quote "$message"; message_json="$REPLY"
  _acp_send "{\"jsonrpc\":\"2.0\",\"id\":${id_raw},\"error\":{\"code\":${code},\"message\":${message_json}}}"
}

_acp_notify_update() {
  local session_id="$1" update="$2" session_json=""
  json_quote "$session_id"; session_json="$REPLY"
  _acp_send "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":${session_json},\"update\":${update}}}"
}

_acp_content_update() {
  local kind="$1" content="$2" session_id="${3:-$ACP_SESSION_ID}"
  local content_json=""
  [[ -n "$content" ]] || return 0
  json_quote "$content"; content_json="$REPLY"
  _acp_notify_update "$session_id" "{\"sessionUpdate\":\"${kind}\",\"content\":{\"type\":\"text\",\"text\":${content_json}}}"
}

_acp_session_cwd() {
  local params="$1" raw="" cwd=""
  _mcp_raw_member "$params" cwd || { REPLY="session cwd is required"; return 1; }
  raw="$REPLY"
  _acp_raw_string "$raw" || { REPLY="session cwd must be a string"; return 1; }
  cwd="$REPLY"
  [[ "$cwd" == /* ]] || { REPLY="session cwd must be absolute"; return 1; }
  if [[ "${REMOTE_MODE:-local}" == client ]]; then
    # The ACP client and HTTP-backed agent may live on different systems. The
    # remote server's configured workspace remains authoritative, so its path
    # does not need to exist on this adapter host.
    REPLY="$cwd"
    return 0
  fi
  [[ -d "$cwd" ]] || { REPLY="session cwd is not a directory: $cwd"; return 1; }
  REPLY="${cwd:A}"
}

_acp_session_id_param() {
  local params="$1" raw=""
  _mcp_raw_member "$params" sessionId || { REPLY="sessionId is required"; return 1; }
  raw="$REPLY"
  _acp_raw_string "$raw" || { REPLY="sessionId must be a string"; return 1; }
}

# ACP represents stdio MCP environment entries as an array of name/value
# objects; zcoder's native MCP broker uses an object. Translate without writing
# a temporary configuration file or evaluating any supplied value.
_acp_mcp_servers() {
  local params="$1" servers='[]' item="" name="" command_name="" args='[]' env='[]'
  local env_item="" env_name="" env_value="" env_json='{' comma="" local_raw=""
  local name_json="" command_json="" env_name_json="" env_value_json=""
  local -a server_items=() env_items=()

  if _mcp_raw_member "$params" mcpServers; then servers="$REPLY"; fi
  _mcp_raw_array_items "$servers" || { REPLY="mcpServers must be an array"; return 1; }
  server_items=("${MCP_RAW_ITEMS[@]}")
  for item in "${server_items[@]}"; do
    _mcp_raw_member "$item" name && _acp_raw_string "$REPLY" || { REPLY="every MCP server needs a string name"; return 1; }
    name="$REPLY"
    _mcp_valid_name "$name" || { REPLY="invalid MCP server name: $name"; return 1; }
    _mcp_raw_member "$item" command && _acp_raw_string "$REPLY" || { REPLY="ACP MCP server '$name' is not a supported stdio server"; return 1; }
    command_name="$REPLY"
    if _mcp_raw_member "$item" args; then args="$REPLY"; else args='[]'; fi
    _mcp_parse_string_array "$args" || { REPLY="MCP server '$name' args must be strings"; return 1; }
    if _mcp_raw_member "$item" env; then env="$REPLY"; else env='[]'; fi
    _mcp_raw_array_items "$env" || { REPLY="MCP server '$name' env must be an array"; return 1; }
    env_items=("${MCP_RAW_ITEMS[@]}")
    env_json='{'; comma=""
    for env_item in "${env_items[@]}"; do
      _mcp_raw_member "$env_item" name && _acp_raw_string "$REPLY" || { REPLY="MCP server '$name' has an invalid environment name"; return 1; }
      env_name="$REPLY"
      [[ "$env_name" == [A-Za-z_][A-Za-z0-9_]# ]] || { REPLY="MCP server '$name' has an unsafe environment name"; return 1; }
      _mcp_raw_member "$env_item" value && _acp_raw_string "$REPLY" || { REPLY="MCP server '$name' has an invalid environment value"; return 1; }
      env_value="$REPLY"
      json_quote "$env_name"; env_name_json="$REPLY"
      json_quote "$env_value"; env_value_json="$REPLY"
      env_json+="${comma}${env_name_json}:${env_value_json}"
      comma=,
    done
    env_json+='}'
    json_quote "$command_name"; command_json="$REPLY"
    local_raw="{\"type\":\"stdio\",\"command\":${command_json},\"args\":${args},\"env\":${env_json}}"
    _mcp_register_raw "$name" acp "$local_raw"
  done
  MCP_NAMES=( ${(ok)MCP_RAW} )
  REPLY="$servers"
}

_acp_configure_workspace() {
  local cwd="$1" mcp_servers="${2:-[]}" params=""
  ZCODER_WORKSPACE="$cwd"
  instructions_load "$ZCODER_WORKSPACE"
  skills_load "$ZCODER_WORKSPACE"
  mcp_load || return 1
  params="{\"mcpServers\":${mcp_servers}}"
  _acp_mcp_servers "$params" || return 1
}

_acp_initialize() {
  local id_raw="$1" params="$2" raw="" requested=0
  _mcp_raw_member "$params" protocolVersion || { _acp_error "$id_raw" -32602 "protocolVersion is required"; return 1; }
  raw="$REPLY"
  json_begin "$raw" || { _acp_error "$id_raw" -32602 "protocolVersion must be an integer"; return 1; }
  [[ "$JSON_TOKEN_TYPE" == number && "$JSON_TOKEN_VALUE" == <1-> ]] || { _acp_error "$id_raw" -32602 "protocolVersion must be an integer"; return 1; }
  requested=$JSON_TOKEN_VALUE
  ACP_INITIALIZED=1
  local queue_capability=true
  [[ "${REMOTE_MODE:-local}" == client ]] && queue_capability="${REMOTE_INPUT_SUPPORTED:-false}"
  _acp_result "$id_raw" "{\"protocolVersion\":${ACP_PROTOCOL_VERSION},\"agentCapabilities\":{\"loadSession\":true,\"promptCapabilities\":{\"embeddedContext\":true},\"_meta\":{\"zcoder/inputQueue\":${queue_capability}}},\"agentInfo\":{\"name\":\"zcoder.zsh\",\"title\":\"zcoder.zsh\",\"version\":\"${ZCODER_VERSION}\"},\"authMethods\":[]}"
  (( requested == ACP_PROTOCOL_VERSION )) || print -u2 -r -- "ACP: client requested protocol v${requested}; offered v${ACP_PROTOCOL_VERSION}"
}

_acp_new_session() {
  local id_raw="$1" params="$2" cwd="" mcp_servers='[]' session_json=""
  (( ACP_INITIALIZED )) || { _acp_error "$id_raw" -32002 "connection is not initialized"; return 1; }
  (( ! ACP_WORKER_RUNNING )) || { _acp_error "$id_raw" -32000 "cannot create a session while a prompt is running"; return 1; }
  _acp_session_cwd "$params" || { _acp_error "$id_raw" -32602 "$REPLY"; return 1; }
  cwd="$REPLY"
  if _mcp_raw_member "$params" mcpServers; then mcp_servers="$REPLY"; fi
  if [[ "${REMOTE_MODE:-local}" == client ]]; then
    _mcp_raw_array_items "$mcp_servers" || { _acp_error "$id_raw" -32602 "mcpServers must be an array"; return 1; }
    (( ${#MCP_RAW_ITEMS} == 0 )) || { _acp_error "$id_raw" -32602 "forwarded MCP servers are unavailable through remote protocol 1; configure them on the zcoder server"; return 1; }
    remote_client_new_session || { _acp_error "$id_raw" -32603 "${REMOTE_ERROR:-could not create remote session}"; return 1; }
    ACP_SESSION_CWD[$CURRENT_SESSION_ID]="${ZCODER_WORKSPACE:A}"
    ACP_SESSION_MCP[$CURRENT_SESSION_ID]='[]'
    json_quote "$CURRENT_SESSION_ID"; session_json="$REPLY"
    _acp_result "$id_raw" "{\"sessionId\":${session_json}}"
    return 0
  fi
  _acp_configure_workspace "$cwd" "$mcp_servers" || { _acp_error "$id_raw" -32602 "${REPLY:-could not configure session MCP servers}"; return 1; }
  if (( ! STATE_ENABLED )); then
    state_init storage || { _acp_error "$id_raw" -32603 "could not initialize session storage"; return 1; }
  fi
  # The broker does not retain mutable conversation state between prompt
  # workers. Create and persist exactly one fresh protocol identity without
  # first saving whichever session the broker last inspected.
  STATE_ENABLED=0
  state_new_session || { _acp_error "$id_raw" -32603 "could not create session"; return 1; }
  STATE_ENABLED=1
  state_save_session || { STATE_ENABLED=0; _acp_error "$id_raw" -32603 "could not persist session"; return 1; }
  STATE_ENABLED=0
  ACP_SESSION_CWD[$CURRENT_SESSION_ID]="$cwd"
  ACP_SESSION_MCP[$CURRENT_SESSION_ID]="$mcp_servers"
  json_quote "$CURRENT_SESSION_ID"; session_json="$REPLY"
  _acp_result "$id_raw" "{\"sessionId\":${session_json}}"
}

_acp_replay_session() {
  local session_id="$1" message="" role="" content="" thinking="" raw=""
  for message in "${AGENT_MESSAGES[@]}"; do
    _mcp_raw_member "$message" role && _acp_raw_string "$REPLY" || continue
    role="$REPLY"
    _mcp_raw_member "$message" content && raw="$REPLY" || continue
    _acp_raw_string "$raw" || continue
    content="$REPLY"
    case "$role" in
      user) _acp_content_update user_message_chunk "$content" "$session_id" ;;
      assistant)
        if _mcp_raw_member "$message" thinking; then
          raw="$REPLY"
          _acp_raw_string "$raw" && thinking="$REPLY" || thinking=""
          _acp_content_update agent_thought_chunk "$thinking" "$session_id"
        fi
        _acp_content_update agent_message_chunk "$content" "$session_id"
        ;;
    esac
  done
}

_acp_load_session() {
  local id_raw="$1" params="$2" session_id="" cwd="" mcp_servers='[]'
  (( ACP_INITIALIZED )) || { _acp_error "$id_raw" -32002 "connection is not initialized"; return 1; }
  (( ! ACP_WORKER_RUNNING )) || { _acp_error "$id_raw" -32000 "cannot load a session while a prompt is running"; return 1; }
  _acp_session_id_param "$params" || { _acp_error "$id_raw" -32602 "$REPLY"; return 1; }
  session_id="$REPLY"
  _acp_session_cwd "$params" || { _acp_error "$id_raw" -32602 "$REPLY"; return 1; }
  cwd="$REPLY"
  if _mcp_raw_member "$params" mcpServers; then mcp_servers="$REPLY"; fi
  if [[ "${REMOTE_MODE:-local}" == client ]]; then
    _mcp_raw_array_items "$mcp_servers" || { _acp_error "$id_raw" -32602 "mcpServers must be an array"; return 1; }
    (( ${#MCP_RAW_ITEMS} == 0 )) || { _acp_error "$id_raw" -32602 "forwarded MCP servers are unavailable through remote protocol 1; configure them on the zcoder server"; return 1; }
    remote_client_select_session "$session_id" || { _acp_error "$id_raw" -32602 "${REMOTE_ERROR:-unknown remote session}"; return 1; }
    ACP_SESSION_CWD[$session_id]="${ZCODER_WORKSPACE:A}"
    ACP_SESSION_MCP[$session_id]='[]'
    local -i replay_index
    for (( replay_index=1; replay_index<=${#UI_ROLES}; replay_index++ )); do
      case "${UI_ROLES[replay_index]}" in
        user) _acp_content_update user_message_chunk "${UI_CONTENTS[replay_index]}" "$session_id" ;;
        assistant)
          _acp_content_update agent_thought_chunk "${UI_THINKINGS[replay_index]}" "$session_id"
          _acp_content_update agent_message_chunk "${UI_CONTENTS[replay_index]}" "$session_id"
          ;;
      esac
    done
    _acp_result "$id_raw" null
    return 0
  fi
  _acp_configure_workspace "$cwd" "$mcp_servers" || { _acp_error "$id_raw" -32602 "${REPLY:-could not configure session MCP servers}"; return 1; }
  if (( ! STATE_ENABLED )) && [[ ! -d "$ZCODER_SESSIONS_DIR" ]]; then
    state_init storage || { _acp_error "$id_raw" -32603 "could not initialize session storage"; return 1; }
  fi
  STATE_ENABLED=0
  state_load_session "$session_id" || { _acp_error "$id_raw" -32602 "unknown session for this workspace and profile"; return 1; }
  ACP_SESSION_CWD[$session_id]="$cwd"
  ACP_SESSION_MCP[$session_id]="$mcp_servers"
  _acp_replay_session "$session_id"
  _acp_result "$id_raw" null
}

_acp_prompt_text() {
  local params="$1" prompt='[]' item="" type="" text_value="" resource="" uri=""
  local raw="" block="" separator="" output=""
  local -a items=()
  _mcp_raw_member "$params" prompt || { REPLY="prompt is required"; return 1; }
  prompt="$REPLY"
  _mcp_raw_array_items "$prompt" || { REPLY="prompt must be an array"; return 1; }
  items=("${MCP_RAW_ITEMS[@]}")
  for item in "${items[@]}"; do
    _mcp_raw_member "$item" type && _acp_raw_string "$REPLY" || { REPLY="prompt content needs a string type"; return 1; }
    type="$REPLY"
    block=""
    case "$type" in
      text)
        _mcp_raw_member "$item" text && _acp_raw_string "$REPLY" || { REPLY="text content needs text"; return 1; }
        block="$REPLY"
        ;;
      resource)
        _mcp_raw_member "$item" resource || { REPLY="resource content needs resource"; return 1; }
        resource="$REPLY"
        _mcp_raw_member "$resource" uri && _acp_raw_string "$REPLY" || { REPLY="embedded resource needs a URI"; return 1; }
        uri="$REPLY"
        _mcp_raw_member "$resource" text && _acp_raw_string "$REPLY" || { REPLY="only text embedded resources are supported"; return 1; }
        text_value="$REPLY"
        block="[ACP embedded context: ${uri}]"$'\n'"${text_value}"$'\n'"[End ACP embedded context]"
        ;;
      resource_link)
        _mcp_raw_member "$item" uri && _acp_raw_string "$REPLY" || { REPLY="resource link needs a URI"; return 1; }
        block="[ACP resource link: ${REPLY}]"
        ;;
      *) REPLY="unsupported prompt content type: $type"; return 1 ;;
    esac
    output+="${separator}${block}"
    separator=$'\n\n'
  done
  [[ -n "$output" ]] || { REPLY="prompt must contain text"; return 1; }
  REPLY="$output"
}

acp_worker_emit() {
  local role="$1" content="$2" thinking="${3:-}"
  case "$role" in
    user) _acp_content_update user_message_chunk "$content" ;;
    assistant)
      _acp_content_update agent_thought_chunk "$thinking"
      _acp_content_update agent_message_chunk "$content"
      ;;
    system) _acp_content_update agent_thought_chunk "$content" ;;
    error) _acp_content_update agent_message_chunk "Error: $content" ;;
    tool) : ;;
  esac
}

acp_worker_status() { return 0; }

_acp_tool_kind() {
  case "$1" in
    list_files|read_file|read_file_range|read_skill_resource|list_agents) REPLY=read ;;
    search|discover_skills) REPLY=search ;;
    write_file|replace_text|apply_patch) REPLY=edit ;;
    run_command) REPLY=execute ;;
    mcp__*) REPLY=fetch ;;
    *) REPLY=other ;;
  esac
}

acp_worker_tool_event() {
  local event="$1" name="$2" args_json="{}" result="${4:-}" succeeded="${5:-0}"
  local id_json="" title_json="" result_json="" kind="" tool_status="failed"
  [[ -z "${3:-}" ]] || args_json="$3"
  case "$event" in
    begin)
      (( ACP_TOOL_SEQUENCE++ ))
      ACP_CURRENT_TOOL_CALL_ID="tool_${sysparams[pid]:-$$}_${ACP_TOOL_SEQUENCE}"
      _acp_tool_kind "$name"; kind="$REPLY"
      json_quote "$ACP_CURRENT_TOOL_CALL_ID"; id_json="$REPLY"
      json_quote "$name"; title_json="$REPLY"
      _acp_notify_update "$ACP_SESSION_ID" "{\"sessionUpdate\":\"tool_call\",\"toolCallId\":${id_json},\"title\":${title_json},\"kind\":\"${kind}\",\"status\":\"pending\",\"rawInput\":${args_json}}"
      ;;
    running)
      [[ -n "$ACP_CURRENT_TOOL_CALL_ID" ]] || return 0
      json_quote "$ACP_CURRENT_TOOL_CALL_ID"; id_json="$REPLY"
      _acp_notify_update "$ACP_SESSION_ID" "{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":${id_json},\"status\":\"in_progress\"}"
      ;;
    complete)
      [[ -n "$ACP_CURRENT_TOOL_CALL_ID" ]] || return 0
      [[ "$succeeded" == 1 ]] && tool_status=completed
      json_quote "$ACP_CURRENT_TOOL_CALL_ID"; id_json="$REPLY"
      json_quote "$result"; result_json="$REPLY"
      _acp_notify_update "$ACP_SESSION_ID" "{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":${id_json},\"status\":\"${tool_status}\",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":${result_json}}}]}"
      ACP_CURRENT_TOOL_CALL_ID=""
      ;;
  esac
}

acp_worker_request_permission() {
  local action="$1" permission_kind="${2:-command}" request_id="" request_id_json=""
  local session_id_json="" tool_id_json="" title_json="" line="" raw="" outcome="" option_id="" options_json=""
  (( ACP_REQUEST_SEQUENCE++ ))
  request_id="permission_${sysparams[pid]:-$$}_${ACP_REQUEST_SEQUENCE}"
  json_quote "$request_id"; request_id_json="$REPLY"
  json_quote "$ACP_SESSION_ID"; session_id_json="$REPLY"
  json_quote "$ACP_CURRENT_TOOL_CALL_ID"; tool_id_json="$REPLY"
  json_quote "$action"; title_json="$REPLY"
  options_json='[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"}'
  if [[ "$permission_kind" == command && "$ZCODER_PROFILE" == coding ]]; then
    options_json+=',{"optionId":"allow-always","name":"Allow for this session","kind":"allow_always"}'
  fi
  options_json+=',{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]'
  _acp_send "{\"jsonrpc\":\"2.0\",\"id\":${request_id_json},\"method\":\"session/request_permission\",\"params\":{\"sessionId\":${session_id_json},\"toolCall\":{\"toolCallId\":${tool_id_json},\"title\":${title_json}},\"options\":${options_json}}}"

  while IFS= read -r line; do
    _acp_parse_message "$line" || continue
    [[ "$ACP_MESSAGE_ID" == "$request_id" ]] || continue
    [[ -n "$ACP_MESSAGE_RESULT" ]] || break
    _mcp_raw_member "$ACP_MESSAGE_RESULT" outcome || break
    raw="$REPLY"
    _mcp_raw_member "$raw" outcome && _acp_raw_string "$REPLY" || break
    outcome="$REPLY"
    [[ "$outcome" == selected ]] || break
    _mcp_raw_member "$raw" optionId && _acp_raw_string "$REPLY" || break
    option_id="$REPLY"
    case "$option_id" in
      allow-once) REPLY=y; return 0 ;;
      allow-always) REPLY=a; return 0 ;;
    esac
    break
  done
  REPLY=n
  return 1
}

acp_worker_main() {
  local session_id="$1" prompt="$2" cwd="$3" mcp_servers="$4"
  local -i prompt_status=0
  ACP_WORKER_ACTIVE=1
  ACP_SESSION_ID="$session_id"
  ACP_TOOL_SEQUENCE=0
  ACP_REQUEST_SEQUENCE=0
  ACP_CURRENT_TOOL_CALL_ID=""
  ZCODER_WORKSPACE="$cwd"
  if [[ "$ZCODER_PROFILE" == coding && "${ACP_SESSION_COMMAND_ALLOW[$session_id]:-0}" == 1 ]]; then
    ZCODER_COMMAND_POLICY=allow
  fi
  if [[ "${REMOTE_MODE:-local}" == client ]]; then
    trap 'remote_client_request POST /v1/cancel "{}" >/dev/null 2>&1 || true; return 130' TERM
  else
    trap 'AGENT_CANCELLED=1; return 130' TERM
    STATE_ENABLED=0
    state_load_session "$session_id" || return 1
    STATE_ENABLED=1
    state_note_user "$prompt"
  fi
  _acp_content_update user_message_chunk "$prompt"
  if [[ "$prompt" == '/queue resume' && "${REMOTE_MODE:-local}" != client ]]; then
    input_queue_command resume
  else
    agent_user_turn "$prompt"
  fi
  prompt_status=$?
  if [[ "${REMOTE_MODE:-local}" != client ]]; then
    state_save_session || true
    mcp_shutdown_all
  fi
  return "$prompt_status"
}

_acp_start_prompt() {
  local id_raw="$1" params="$2" session_id="" prompt="" cwd="" mcp_servers='[]'
  (( ACP_INITIALIZED )) || { _acp_error "$id_raw" -32002 "connection is not initialized"; return 1; }
  (( ! ACP_WORKER_RUNNING )) || { _acp_error "$id_raw" -32000 "another prompt is already running"; return 1; }
  _acp_session_id_param "$params" || { _acp_error "$id_raw" -32602 "$REPLY"; return 1; }
  session_id="$REPLY"
  cwd="${ACP_SESSION_CWD[$session_id]:-}"
  if [[ "${REMOTE_MODE:-local}" == client ]]; then
    if [[ "$CURRENT_SESSION_ID" != "$session_id" ]]; then
      remote_client_select_session "$session_id" || { _acp_error "$id_raw" -32602 "${REMOTE_ERROR:-unknown remote session}"; return 1; }
    fi
    cwd="${ZCODER_WORKSPACE:A}"
    ACP_SESSION_CWD[$session_id]="$cwd"
    ACP_SESSION_MCP[$session_id]='[]'
  fi
  [[ -n "$cwd" ]] || {
    local session_dir="$ZCODER_SESSIONS_DIR/${session_id}.session"
    [[ -d "$session_dir" ]] && cwd="${mapfile[$session_dir/workspace]:-}"
  }
  if [[ "${REMOTE_MODE:-local}" == client ]]; then
    [[ -n "$cwd" ]] || { _acp_error "$id_raw" -32602 "unknown session"; return 1; }
  else
    [[ -n "$cwd" && -d "$cwd" ]] || { _acp_error "$id_raw" -32602 "unknown session"; return 1; }
  fi
  mcp_servers="${ACP_SESSION_MCP[$session_id]:-[]}"
  if [[ "${REMOTE_MODE:-local}" != client ]]; then
    _acp_configure_workspace "$cwd" "$mcp_servers" || { _acp_error "$id_raw" -32603 "could not restore session configuration"; return 1; }
    _state_valid_id "$session_id" && [[ -d "$ZCODER_SESSIONS_DIR/${session_id}.session" ]] || {
      _acp_error "$id_raw" -32602 "unknown session"
      return 1
    }
  fi
  _acp_prompt_text "$params" || { _acp_error "$id_raw" -32602 "$REPLY"; return 1; }
  prompt="$REPLY"

  ACP_SESSION_ID="$session_id"
  ACP_PROMPT_ID_RAW="$id_raw"
  ACP_PROMPT_CANCELLED=0
  ACP_INPUT_TURN_ID="${EPOCHSECONDS}_${sysparams[pid]}_$RANDOM"
  if [[ "${REMOTE_MODE:-local}" != client ]]; then
    input_queue_open "$session_id" "$ACP_INPUT_TURN_ID" || {
      _acp_error "$id_raw" -32603 'could not open input queue'; return 1
    }
  fi
  coproc { acp_worker_main "$session_id" "$prompt" "$cwd" "$mcp_servers"; }
  ACP_WORKER_PID=$!
  exec {ACP_WORKER_FD}<&p
  ACP_WORKER_RUNNING=1
}

_acp_finish_prompt() {
  local -i prompt_status=0
  (( ACP_WORKER_RUNNING )) || return 0
  exec {ACP_WORKER_FD}<&- 2>/dev/null
  wait "$ACP_WORKER_PID" 2>/dev/null
  prompt_status=$?
  _acp_close_input_queue
  if (( ACP_PROMPT_CANCELLED || prompt_status == 130 || prompt_status == 143 )); then
    _acp_result "$ACP_PROMPT_ID_RAW" '{"stopReason":"cancelled"}'
  elif (( prompt_status == 0 )); then
    _acp_result "$ACP_PROMPT_ID_RAW" '{"stopReason":"end_turn"}'
  else
    _acp_error "$ACP_PROMPT_ID_RAW" -32603 "zcoder prompt failed"
  fi
  ACP_WORKER_RUNNING=0
  ACP_WORKER_PID=0
  ACP_WORKER_FD=-1
  ACP_PROMPT_ID_RAW=""
  ACP_PROMPT_CANCELLED=0
}

_acp_cancel_prompt() {
  local params="$1" session_id=""
  (( ACP_WORKER_RUNNING )) || return 0
  _acp_session_id_param "$params" || return 0
  session_id="$REPLY"
  [[ "$session_id" == "$ACP_SESSION_ID" ]] || return 0
  ACP_PROMPT_CANCELLED=1
  _acp_close_input_queue
  if [[ "${REMOTE_MODE:-local}" == client ]]; then
    remote_client_request POST /v1/cancel '{}' >/dev/null 2>&1 || true
  fi
  kill -TERM "$ACP_WORKER_PID" 2>/dev/null || true
}

_acp_close_input_queue() {
  [[ "${REMOTE_MODE:-local}" == client ]] && return 0
  local CURRENT_SESSION_ID="$ACP_SESSION_ID" INPUT_QUEUE_TURN_ID="$ACP_INPUT_TURN_ID"
  input_queue_close true || true
}

_acp_input_request() {
  local id_raw="$1" params="$2" session='' action='' turn='' id='' mode='' text='' field=''
  (( ACP_INITIALIZED )) || { _acp_error "$id_raw" -32002 'connection is not initialized'; return 1; }
  json_parse_flat_object "$params" || { _acp_error "$id_raw" -32602 'input parameters must be a flat object'; return 1; }
  for field in sessionId action turnId messageId mode text; do
    if (( ${+JSON_OBJECT[$field]} )) && [[ "${JSON_OBJECT_TYPES[$field]}" != string ]]; then
      _acp_error "$id_raw" -32602 "$field must be a string"; return 1
    fi
  done
  session="${JSON_OBJECT[sessionId]:-}"
  action="${JSON_OBJECT[action]:-submit}"
  turn="${JSON_OBJECT[turnId]:-}"
  id="${JSON_OBJECT[messageId]:-}"
  mode="${JSON_OBJECT[mode]:-steer}"
  text="${JSON_OBJECT[text]:-}"
  [[ -n "$session" && -n "${ACP_SESSION_CWD[$session]:-}" ]] || {
    _acp_error "$id_raw" -32602 'unknown session'; return 1
  }
  if [[ "$action" == submit ]] && { (( ! ACP_WORKER_RUNNING )) || [[ "$session" != "$ACP_SESSION_ID" ]]; }; then
    # An exact retry can retrieve its receipt after the original prompt ends.
    if [[ "${REMOTE_MODE:-local}" == client ]]; then
      local CURRENT_SESSION_ID="$session"
      remote_client_input_request status '' "$id" '' '' || {
        _acp_error "$id_raw" -32000 'no matching active prompt'; return 1
      }
    else
      input_queue_status "$session" "$id" || {
        _acp_error "$id_raw" -32000 'no matching active prompt'; return 1
      }
    fi
  fi
  if [[ "${REMOTE_MODE:-local}" == client ]]; then
    local CURRENT_SESSION_ID="$session"
    remote_client_input_request "$action" "$turn" "$id" "$mode" "$text" || {
      _acp_error "$id_raw" -32000 "$REMOTE_ERROR"; return 1
    }
  else
    input_queue_request "$action" "$session" "$turn" "$id" "$mode" "$text" || {
      _acp_error "$id_raw" -32000 "${INPUT_QUEUE_ERROR:-input queue operation failed}"; return 1
    }
  fi
  _acp_result "$id_raw" "$REPLY"
}

_acp_handle_line() {
  local line="$1" id_raw="" method="" params="{}" raw="" option_id=""
  if (( ${#line} > 1048576 )); then
    _acp_error null -32700 "ACP message exceeds 1 MiB"
    return 1
  fi
  _acp_parse_message "$line" || { _acp_error null -32700 "Parse error"; return 1; }
  id_raw="$ACP_MESSAGE_ID_RAW"
  method="$ACP_MESSAGE_METHOD"
  params="$ACP_MESSAGE_PARAMS"

  # Responses belong to requests made by the active prompt worker, currently
  # permission requests. Preserve the complete response for strict ID matching
  # and nested outcome parsing in that worker.
  if [[ -z "$method" ]]; then
    if (( ACP_WORKER_RUNNING )); then
      if [[ -n "$ACP_MESSAGE_RESULT" ]] && _mcp_raw_member "$ACP_MESSAGE_RESULT" outcome; then
        raw="$REPLY"
        if _mcp_raw_member "$raw" outcome && _acp_raw_string "$REPLY" && [[ "$REPLY" == selected ]] &&
            _mcp_raw_member "$raw" optionId && _acp_raw_string "$REPLY"; then
          option_id="$REPLY"
          [[ "$option_id" == allow-always && "$ZCODER_PROFILE" == coding ]] && ACP_SESSION_COMMAND_ALLOW[$ACP_SESSION_ID]=1
        fi
      fi
      print -p -r -- "$line"
    fi
    return 0
  fi
  case "$method" in
    initialize) _acp_initialize "$id_raw" "$params" ;;
    session/new) _acp_new_session "$id_raw" "$params" ;;
    session/load) _acp_load_session "$id_raw" "$params" ;;
    session/prompt) _acp_start_prompt "$id_raw" "$params" ;;
    session/cancel) _acp_cancel_prompt "$params" ;;
    _zcoder/input) _acp_input_request "$id_raw" "$params" ;;
    *) [[ -n "$id_raw" ]] && _acp_error "$id_raw" -32601 "Method not found: $method" ;;
  esac
}

acp_shutdown() {
  if (( ACP_WORKER_RUNNING )); then
    ACP_PROMPT_CANCELLED=1
    _acp_close_input_queue
    kill -TERM "$ACP_WORKER_PID" 2>/dev/null || true
    exec {ACP_WORKER_FD}<&- 2>/dev/null
    wait "$ACP_WORKER_PID" 2>/dev/null || true
  fi
  ACP_WORKER_RUNNING=0
  ACP_WORKER_PID=0
  ACP_WORKER_FD=-1
}

acp_main() {
  emulate -L zsh
  setopt extendedglob no_monitor no_notify
  local line=""
  local -a ready=()
  local -i stdin_ready=0 worker_ready=0

  while true; do
    if (( ! ACP_WORKER_RUNNING )); then
      IFS= read -r line || break
      _acp_handle_line "$line"
      continue
    fi

    reply=()
    zselect -t 10 -r 0 -r "$ACP_WORKER_FD" 2>/dev/null || continue
    ready=("${reply[@]}")
    stdin_ready=$(( ${ready[(I)0]} > 0 ))
    worker_ready=$(( ${ready[(I)$ACP_WORKER_FD]} > 0 ))
    if (( stdin_ready )); then
      if IFS= read -r line; then
        _acp_handle_line "$line"
      else
        acp_shutdown
        break
      fi
    fi
    if (( worker_ready && ACP_WORKER_RUNNING )); then
      if IFS= read -r -u "$ACP_WORKER_FD" line; then
        _acp_send "$line"
      else
        _acp_finish_prompt
      fi
    fi
  done
}
