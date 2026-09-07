# Model Context Protocol configuration, stdio transport, and tool catalog.

typeset -gr MCP_VERSION_LEGACY="2025-11-25"
typeset -gr MCP_VERSION_MODERN="2026-07-28"
typeset -g MCP_USER_CONFIG="${ZCODER_HOME}/mcp.json"
typeset -g MCP_PROJECT_CONFIG=""
typeset -g MCP_RUNTIME_ROOT=""
typeset -gi MCP_RUNTIME_OWNED=0
typeset -gi MCP_REQUEST_TIMEOUT="${MCP_REQUEST_TIMEOUT:-120}"
typeset -gi MCP_STARTUP_TIMEOUT="${MCP_STARTUP_TIMEOUT:-20}"
typeset -gi MCP_NEXT_ID=0
typeset -gi MCP_CONNECT_CANCELLED=0
typeset -g MCP_ERROR=""
typeset -g MCP_RESPONSE=""
typeset -g MCP_RESPONSE_ID=""
typeset -g MCP_RESPONSE_METHOD=""
typeset -g MCP_RESPONSE_RESULT=""
typeset -g MCP_RESPONSE_ERROR=""
typeset -g MCP_WIRE_ID=""
typeset -g MCP_WIRE_METHOD=""
typeset -g MCP_BROKER_BUFFER=""
typeset -gi MCP_RAW_START=0 MCP_RAW_END=0
typeset -ga MCP_RAW_ITEMS=()
typeset -gi MCP_PCRE_JSON_STATE=-1
typeset -gr MCP_PCRE_JSON_PATTERN='(?(DEFINE)(?<string>"(?:\\.|[^"\\])*")(?<value>(?&string)|\{\s*(?:(?&string)\s*:\s*(?&value)(?:\s*,\s*(?&string)\s*:\s*(?&value))*)?\s*\}|\[\s*(?:(?&value)(?:\s*,\s*(?&value))*)?\s*\]|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null))\A(?&value)'

typeset -gA MCP_USER_RAW=() MCP_PROJECT_RAW=()
typeset -gA MCP_RAW=() MCP_SCOPE=() MCP_TYPE=() MCP_COMMAND=() MCP_ARGS=()
typeset -gA MCP_ENV=() MCP_CWD=() MCP_URL=() MCP_ENABLED=()
typeset -gA MCP_STATUS=() MCP_PROTOCOL=() MCP_DETAIL=() MCP_SERVER_TOOLS=()
typeset -gA MCP_BROKER_PID=() MCP_BROKER_DIR=() MCP_BROKER_SEQ=()
typeset -ga MCP_NAMES=() MCP_TOOL_NAMES=()
typeset -gA MCP_TOOL_SERVER=() MCP_TOOL_ORIGINAL=() MCP_TOOL_SCHEMA=() MCP_TOOL_EFFECT=()
typeset -gi MCP_PROMPT_MAX_BYTES="${MCP_PROMPT_MAX_BYTES:-8192}"

_mcp_valid_name() {
  [[ -n "$1" && ${#1} -le 80 && "$1" == [A-Za-z0-9_.-]## ]]
}

_mcp_byte_length() {
  setopt localoptions nomultibyte
  REPLY=${#1}
}

_mcp_pcre_json_init() {
  (( MCP_PCRE_JSON_STATE >= 0 )) && return "$(( ! MCP_PCRE_JSON_STATE ))"
  if zmodload zsh/pcre 2>/dev/null && pcre_compile "$MCP_PCRE_JSON_PATTERN" 2>/dev/null; then
    MCP_PCRE_JSON_STATE=1
    return 0
  fi
  MCP_PCRE_JSON_STATE=0
  return 1
}

# Locate one JSON value without decoding or rebuilding its contents. MCP tool
# schemas are already valid JSON and can be tens of kilobytes, so slicing the
# original source is dramatically cheaper than token-by-token re-encoding in
# Zsh. The scanner tracks strings and escapes while balancing arrays/objects.
_mcp_raw_value_bounds() {
  local source="$1"
  local -i index="${2:-1}" length=${#source} depth=0 escaped=0 in_string=0
  local ch="" first="" tail="" MATCH=""
  while (( index <= length )) && [[ "${source[index]}" == [[:space:]] ]]; do (( index++ )); done
  (( index <= length )) || return 1
  MCP_RAW_START=$index
  if _mcp_pcre_json_init; then
    tail="${source[index,-1]}"
    if pcre_match -- "$tail" 2>/dev/null; then
      MCP_RAW_END=$(( index + ${#MATCH} - 1 ))
      return 0
    fi
  fi
  first="${source[index]}"
  if [[ "$first" == '"' ]]; then
    (( index++ ))
    while (( index <= length )); do
      ch="${source[index]}"
      if (( escaped )); then
        escaped=0
      elif [[ "$ch" == $'\\' ]]; then
        escaped=1
      elif [[ "$ch" == '"' ]]; then
        MCP_RAW_END=$index
        return 0
      fi
      (( index++ ))
    done
    return 1
  fi
  if [[ "$first" == '{' || "$first" == '[' ]]; then
    for (( ; index<=length; index++ )); do
      ch="${source[index]}"
      if (( in_string )); then
        if (( escaped )); then
          escaped=0
        elif [[ "$ch" == $'\\' ]]; then
          escaped=1
        elif [[ "$ch" == '"' ]]; then
          in_string=0
        fi
        continue
      fi
      if [[ "$ch" == '"' ]]; then
        in_string=1
      elif [[ "$ch" == '{' || "$ch" == '[' ]]; then
        (( depth++ ))
      elif [[ "$ch" == '}' || "$ch" == ']' ]]; then
        (( depth-- ))
        if (( depth == 0 )); then
          MCP_RAW_END=$index
          return 0
        fi
      fi
    done
    return 1
  fi
  while (( index <= length )); do
    ch="${source[index]}"
    [[ "$ch" == ',' || "$ch" == '}' || "$ch" == ']' || "$ch" == [[:space:]] ]] && break
    (( index++ ))
  done
  MCP_RAW_END=$(( index - 1 ))
  (( MCP_RAW_END >= MCP_RAW_START ))
}

_mcp_raw_member() {
  local source="$1" wanted="$2" needle="" key=""
  local -i index=2 length=${#source} value_start=0 value_end=0
  json_quote "$wanted"; needle="$REPLY"
  [[ "${source[1]}" == '{' ]] || return 1
  while (( index <= length )); do
    while (( index <= length )) && [[ "${source[index]}" == [[:space:]] ]]; do (( index++ )); done
    [[ "${source[index]}" == '}' ]] && return 1
    [[ "${source[index]}" == '"' ]] || return 1
    _mcp_raw_value_bounds "$source" "$index" || return 1
    key="${source[MCP_RAW_START,MCP_RAW_END]}"
    index=$(( MCP_RAW_END + 1 ))
    while (( index <= length )) && [[ "${source[index]}" == [[:space:]] ]]; do (( index++ )); done
    [[ "${source[index]}" == ':' ]] || return 1
    (( index++ ))
    _mcp_raw_value_bounds "$source" "$index" || return 1
    value_start=$MCP_RAW_START
    value_end=$MCP_RAW_END
    if [[ "$key" == "$needle" ]]; then
      REPLY="${source[value_start,value_end]}"
      return 0
    fi
    index=$(( value_end + 1 ))
    while (( index <= length )) && [[ "${source[index]}" == [[:space:]] ]]; do (( index++ )); done
    [[ "${source[index]}" == ',' ]] || return 1
    (( index++ ))
  done
  return 1
}

_mcp_raw_array_items() {
  local source="$1"
  local -i index=2 length=${#source}
  MCP_RAW_ITEMS=()
  [[ "${source[1]}" == '[' ]] || return 1
  while (( index <= length )); do
    while (( index <= length )) && [[ "${source[index]}" == [[:space:],] ]]; do (( index++ )); done
    [[ "${source[index]}" == ']' ]] && return 0
    _mcp_raw_value_bounds "$source" "$index" || return 1
    MCP_RAW_ITEMS+=("${source[MCP_RAW_START,MCP_RAW_END]}")
    index=$(( MCP_RAW_END + 1 ))
    while (( index <= length )) && [[ "${source[index]}" == [[:space:]] ]]; do (( index++ )); done
    [[ "${source[index]}" == ']' ]] && return 0
    [[ "${source[index]}" == ',' ]] || return 1
    (( index++ ))
  done
  return 1
}

# Capture a named object member without losing nested JSON. json_capture_value
# returns in REPLY, so preserve it before the next tokenizer operation.
_mcp_json_get() {
  local source="$1" wanted="$2" key="" captured=""
  REPLY=""
  json_begin "$source" || return 1
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || { JSON_ERROR="expected JSON object"; return 1; }
  json_next || return 1
  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1
    json_capture_raw_value || return 1
    captured="$REPLY"
    if [[ "$key" == "$wanted" ]]; then
      REPLY="$captured"
      return 0
    fi
    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  return 1
}

_mcp_json_string() {
  local source="$1"
  json_begin "$source" || return 1
  [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
  REPLY="$JSON_TOKEN_VALUE"
}

_mcp_parse_string_array() {
  local source="$1"
  MCP_PARSED_ARRAY=()
  json_begin "$source" || return 1
  [[ "$JSON_TOKEN_TYPE" == '[' ]] || return 1
  json_next || return 1
  while [[ "$JSON_TOKEN_TYPE" != ']' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    MCP_PARSED_ARRAY+=("$JSON_TOKEN_VALUE")
    json_next || return 1
    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != ']' ]]; then
      return 1
    fi
  done
  return 0
}
typeset -ga MCP_PARSED_ARRAY=()

_mcp_config_parse_servers() {
  local source="$1" scope="$2" key="" name="" captured=""
  json_begin "$source" || return 1
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || { JSON_ERROR="MCP config must be a JSON object"; return 1; }
  json_next || return 1
  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1
    if [[ "$key" == mcpServers && "$JSON_TOKEN_TYPE" == '{' ]]; then
      json_next || return 1
      while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
        [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
        name="$JSON_TOKEN_VALUE"
        _mcp_valid_name "$name" || { JSON_ERROR="invalid MCP server name: $name"; return 1; }
        json_next || return 1
        [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
        json_next || return 1
        json_capture_raw_value || return 1
        captured="$REPLY"
        [[ "$captured" == \{* ]] || { JSON_ERROR="MCP server '$name' must be an object"; return 1; }
        if [[ "$scope" == user ]]; then
          MCP_USER_RAW[$name]="$captured"
        else
          MCP_PROJECT_RAW[$name]="$captured"
        fi
        if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
          json_next || return 1
        elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
          return 1
        fi
      done
      json_next || return 1
    else
      json_skip_value || return 1
    fi
    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  return 0
}

_mcp_config_read() {
  local path="$1" scope="$2" content=""
  [[ -e "$path" ]] || return 0
  [[ -f "$path" ]] || { MCP_ERROR="MCP config is not a regular file: $path"; return 1; }
  content="${mapfile[$path]}"
  [[ -n "$content" ]] || return 0
  if ! _mcp_config_parse_servers "$content" "$scope"; then
    MCP_ERROR="Could not parse $path: ${JSON_ERROR:-invalid JSON}"
    return 1
  fi
}

_mcp_register_raw() {
  local name="$1" scope="$2" raw="$3" value="" type="stdio" command_name=""
  MCP_RAW[$name]="$raw"
  MCP_SCOPE[$name]="$scope"
  if _mcp_json_get "$raw" type && _mcp_json_string "$REPLY"; then type="$REPLY"; fi
  if _mcp_json_get "$raw" command && _mcp_json_string "$REPLY"; then command_name="$REPLY"; fi
  [[ -n "$command_name" ]] && type="stdio"
  MCP_TYPE[$name]="$type"
  MCP_COMMAND[$name]="$command_name"
  if _mcp_json_get "$raw" args; then MCP_ARGS[$name]="$REPLY"; else MCP_ARGS[$name]='[]'; fi
  if _mcp_json_get "$raw" env; then MCP_ENV[$name]="$REPLY"; else MCP_ENV[$name]='{}'; fi
  if _mcp_json_get "$raw" cwd && _mcp_json_string "$REPLY"; then MCP_CWD[$name]="$REPLY"; else MCP_CWD[$name]=""; fi
  if _mcp_json_get "$raw" url && _mcp_json_string "$REPLY"; then MCP_URL[$name]="$REPLY"; else MCP_URL[$name]=""; fi
  MCP_ENABLED[$name]=1
  if _mcp_json_get "$raw" enabled; then
    [[ "$REPLY" == false ]] && MCP_ENABLED[$name]=0
  fi
  if (( ! MCP_ENABLED[$name] )); then
    MCP_STATUS[$name]="disabled"
  elif [[ "$type" != stdio ]]; then
    MCP_STATUS[$name]="unsupported"
    MCP_DETAIL[$name]="Streamable HTTP is configured but not available in this stdio-first release"
  elif [[ -z "$command_name" ]]; then
    MCP_STATUS[$name]="invalid"
    MCP_DETAIL[$name]="stdio server has no command"
  else
    MCP_STATUS[$name]="configured"
  fi
}

mcp_load() {
  local name=""
  mcp_shutdown_all
  MCP_ERROR=""
  MCP_USER_RAW=(); MCP_PROJECT_RAW=(); MCP_RAW=(); MCP_SCOPE=(); MCP_TYPE=(); MCP_COMMAND=()
  MCP_ARGS=(); MCP_ENV=(); MCP_CWD=(); MCP_URL=(); MCP_ENABLED=(); MCP_STATUS=()
  MCP_PROTOCOL=(); MCP_DETAIL=(); MCP_SERVER_TOOLS=(); MCP_NAMES=()
  MCP_TOOL_NAMES=(); MCP_TOOL_SERVER=(); MCP_TOOL_ORIGINAL=(); MCP_TOOL_SCHEMA=(); MCP_TOOL_EFFECT=()
  MCP_USER_CONFIG="${ZCODER_HOME}/mcp.json"
  MCP_PROJECT_CONFIG="${ZCODER_WORKSPACE:A}/.mcp.json"
  _mcp_config_read "$MCP_USER_CONFIG" user || return 1
  _mcp_config_read "$MCP_PROJECT_CONFIG" project || return 1
  for name in ${(ok)MCP_USER_RAW}; do _mcp_register_raw "$name" user "${MCP_USER_RAW[$name]}"; done
  for name in ${(ok)MCP_PROJECT_RAW}; do _mcp_register_raw "$name" project "${MCP_PROJECT_RAW[$name]}"; done
  MCP_NAMES=( ${(ok)MCP_RAW} )
  return 0
}

_mcp_config_write() {
  local scope="$1" path="" name="" raw="" comma="" output='{"mcpServers":{'
  local -a names=()
  if [[ "$scope" == user ]]; then
    path="$MCP_USER_CONFIG"; names=( ${(ok)MCP_USER_RAW} )
  else
    path="$MCP_PROJECT_CONFIG"; names=( ${(ok)MCP_PROJECT_RAW} )
  fi
  local old_umask="$(umask)" tmp="${path}.tmp.${sysparams[pid]:-$$}.${RANDOM}"
  for name in "${names[@]}"; do
    json_quote "$name"
    [[ "$scope" == user ]] && raw="${MCP_USER_RAW[$name]}" || raw="${MCP_PROJECT_RAW[$name]}"
    output+="${comma}${REPLY}:${raw}"
    comma=,
  done
  output+='}}'$'\n'
  umask 077
  zf_mkdir -p "${path:h}" 2>/dev/null || { umask "$old_umask"; MCP_ERROR="Could not create ${path:h}"; return 1; }
  mapfile[$tmp]="$output" || { umask "$old_umask"; MCP_ERROR="Could not write $tmp"; return 1; }
  zf_mv -f "$tmp" "$path" 2>/dev/null || { zf_rm -f "$tmp" 2>/dev/null; umask "$old_umask"; MCP_ERROR="Could not replace $path"; return 1; }
  zf_chmod 600 "$path" 2>/dev/null || true
  umask "$old_umask"
}

_mcp_response_parse() {
  local source="$1"
  MCP_RESPONSE_ID=""; MCP_RESPONSE_METHOD=""; MCP_RESPONSE_RESULT=""; MCP_RESPONSE_ERROR=""
  [[ "$source" == \{* ]] || return 1
  _mcp_wire_envelope "$source"
  MCP_RESPONSE_ID="$MCP_WIRE_ID"; MCP_RESPONSE_METHOD="$MCP_WIRE_METHOD"
  if _mcp_raw_member "$source" result; then
    MCP_RESPONSE_RESULT="$REPLY"
  elif _mcp_raw_member "$source" error; then
    MCP_RESPONSE_ERROR="$REPLY"
  fi
  [[ -n "$MCP_RESPONSE_ID" || -n "$MCP_RESPONSE_METHOD" ]]
}

# The broker only routes a line to the request that owns its JSON-RPC id. Do
# not run the full JSON decoder here: tools/list responses can contain very
# large schemas and the parent is the process that actually consumes them.
_mcp_wire_envelope() {
  setopt localoptions extendedglob
  local line="$1" raw=""
  line="${line##[[:space:]]#}"
  MCP_WIRE_ID=""; MCP_WIRE_METHOD=""
  # JSON member order is arbitrary; nested tool results may themselves contain
  # id/method fields. Slice only top-level members without decoding the result.
  if _mcp_raw_member "$line" id; then
    raw="$REPLY"
    if json_begin "$raw" && [[ "$JSON_TOKEN_TYPE" == number || "$JSON_TOKEN_TYPE" == string ]]; then
      MCP_WIRE_ID="$raw"
    fi
  fi
  if _mcp_raw_member "$line" method && json_begin "$REPLY" && [[ "$JSON_TOKEN_TYPE" == string ]]; then
    MCP_WIRE_METHOD="$JSON_TOKEN_VALUE"
  fi
  return 0
}

_mcp_broker_exchange() {
  local request="$1" expected_id="$2" timeout_seconds="$3" line="" error_json="" chunk=""
  local -i read_status=0 buffered_bytes=0 received=0
  local -F deadline=$(( EPOCHREALTIME + timeout_seconds )) remaining=0
  _mcp_byte_length "$MCP_BROKER_BUFFER"; buffered_bytes=$REPLY
  print -r -u "$MCP_BROKER_WRITE_FD" -- "$request" || { REPLY="server stdin closed"; return 1; }
  while (( EPOCHREALTIME < deadline )); do
    if [[ "$MCP_BROKER_BUFFER" == *$'\n'* ]]; then
      line="${MCP_BROKER_BUFFER%%$'\n'*}"
      MCP_BROKER_BUFFER="${MCP_BROKER_BUFFER#*$'\n'}"
      _mcp_byte_length "$line"; (( buffered_bytes -= REPLY + 1 ))
      [[ -n "$line" ]] || continue
      _mcp_wire_envelope "$line"
      if [[ "$MCP_WIRE_ID" == "$expected_id" && -z "$MCP_WIRE_METHOD" ]]; then
        REPLY="$line"
        return 0
      fi
      if [[ -n "$MCP_WIRE_ID" && -n "$MCP_WIRE_METHOD" ]]; then
        local response_id="$MCP_WIRE_ID"
        json_quote "Client method not supported: $MCP_WIRE_METHOD"
        error_json="{\"jsonrpc\":\"2.0\",\"id\":${response_id},\"error\":{\"code\":-32601,\"message\":${REPLY}}}"
        print -r -u "$MCP_BROKER_WRITE_FD" -- "$error_json" || true
      fi
      continue
    fi
    remaining=$(( deadline - EPOCHREALTIME ))
    (( remaining > 0 )) || break
    (( remaining > 0.1 )) && remaining=0.1
    chunk=""
    sysread -i "$MCP_BROKER_READ_FD" -s 32768 -t "$remaining" -c received chunk 2>/dev/null
    read_status=$?
    if (( read_status == 0 )); then
      MCP_BROKER_BUFFER+="$chunk"
      (( buffered_bytes += received ))
      (( buffered_bytes <= 67108864 )) || { REPLY="server response exceeds 64 MiB"; return 1; }
    elif (( read_status != 4 )); then
      REPLY="server stdout closed or failed before a complete response"
      return 1
    fi
  done
  REPLY="request timed out after ${timeout_seconds}s"
  return 1
}

_mcp_broker_main() {
  # A broker must never run the parent's terminal/session EXIT cleanup when
  # its transport is cancelled or shut down.
  trap - EXIT INT TERM HUP WINCH
  UI_ACTIVE=0
  local name="$1" runtime="$2" command_name="$3" args_json="$4" env_json="$5" cwd="$6"
  local request_file="" response_file="" envelope="" mode="" expected_id="" timeout_seconds="" request="" reply_status="" result=""
  local -a command_args=()
  local -A command_env=()
  local -i seq=1 server_pid=0
  local MCP_BROKER_BUFFER=""
  _mcp_parse_string_array "$args_json" || { mapfile[$runtime/start.error]="invalid args array"; return 1; }
  command_args=("${MCP_PARSED_ARRAY[@]}")
  json_parse_flat_object "$env_json" || { mapfile[$runtime/start.error]="invalid env object"; return 1; }
  command_env=("${(@kv)JSON_OBJECT}")
  local env_name=""
  for env_name in ${(k)command_env}; do
    [[ "$env_name" == [A-Za-z_][A-Za-z0-9_]## ]] || { mapfile[$runtime/start.error]="invalid environment name: $env_name"; return 1; }
    export "$env_name=${command_env[$env_name]}"
  done
  [[ -d "$cwd" ]] || { mapfile[$runtime/start.error]="working directory does not exist: $cwd"; return 1; }
  coproc {
    builtin cd "$cwd" || return 1
    command "$command_name" "${command_args[@]}"
  } 2>> "$runtime/server.log"
  server_pid=$!
  exec {MCP_BROKER_READ_FD}<&p
  exec {MCP_BROKER_WRITE_FD}>&p
  mapfile[$runtime/ready]="$server_pid"

  while [[ ! -e "$runtime/stop" ]]; do
    request_file="$runtime/request.$seq"
    if [[ ! -e "$request_file" ]]; then
      kill -0 "$server_pid" 2>/dev/null || { mapfile[$runtime/exited]="server process exited"; break; }
      zselect -t 10
      continue
    fi
    envelope="${mapfile[$request_file]}"
    zf_rm -f "$request_file" 2>/dev/null
    mode="${envelope%%$'\t'*}"; envelope="${envelope#*$'\t'}"
    expected_id="${envelope%%$'\t'*}"; envelope="${envelope#*$'\t'}"
    timeout_seconds="${envelope%%$'\t'*}"; request="${envelope#*$'\t'}"
    response_file="$runtime/response.$seq"
    reply_status=OK; result=""
    if [[ "$mode" == N ]]; then
      print -r -u "$MCP_BROKER_WRITE_FD" -- "$request" || { reply_status=ERR; result="server stdin closed"; }
    elif ! _mcp_broker_exchange "$request" "$expected_id" "$timeout_seconds"; then
      reply_status=ERR; result="$REPLY"
    else
      result="$REPLY"
    fi
    mapfile[$response_file.tmp]="${reply_status}"$'\t'"${result}"
    zf_mv -f "$response_file.tmp" "$response_file" 2>/dev/null
    (( seq++ ))
  done
  exec {MCP_BROKER_WRITE_FD}>&-
  # Closing stdin is the MCP stdio shutdown signal. Give the server a short
  # grace period, then bound cleanup and reap it; kill -0 also matches zombies
  # and made every normal zcoder exit wait out the old timeout.
  zselect -t 5
  if kill -0 "$server_pid" 2>/dev/null; then
    kill -TERM "$server_pid" 2>/dev/null
    zselect -t 5
  fi
  kill -KILL "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  mapfile[$runtime/stopped]="1"
}

_mcp_runtime_name() {
  REPLY="${1//[^A-Za-z0-9_.-]/_}"
}

mcp_broker_start() {
  local name="$1" runtime="" cwd="" old_umask="$(umask)"
  cwd="${MCP_CWD[$name]}"
  [[ "${MCP_TYPE[$name]}" == stdio ]] || { MCP_ERROR="Only stdio MCP servers are supported in this release"; return 1; }
  [[ -n "${MCP_COMMAND[$name]}" ]] || { MCP_ERROR="MCP server '$name' has no command"; return 1; }
  if [[ -n "${MCP_BROKER_PID[$name]:-}" ]] && kill -0 "${MCP_BROKER_PID[$name]}" 2>/dev/null; then return 0; fi
  [[ -n "$cwd" ]] || cwd="$ZCODER_WORKSPACE"
  [[ "$cwd" == /* ]] || cwd="${ZCODER_WORKSPACE}/${cwd}"
  cwd="${cwd:A}"
  if [[ -z "$MCP_RUNTIME_ROOT" ]]; then
    zcoder_runtime_init || { MCP_ERROR="Could not create private MCP runtime storage"; return 1; }
    MCP_RUNTIME_ROOT="${ZCODER_RUNTIME_DIR}/mcp"
    MCP_RUNTIME_OWNED=1
  fi
  _mcp_runtime_name "$name"; runtime="$MCP_RUNTIME_ROOT/$REPLY"
  umask 077
  zf_mkdir -p "$runtime" 2>/dev/null || { umask "$old_umask"; MCP_ERROR="Could not create MCP runtime directory"; return 1; }
  zf_rm -f "$runtime"/{ready,stop,stopped,exited,start.error}(N) "$runtime"/request.*(N) "$runtime"/response.*(N) 2>/dev/null
  (_mcp_broker_main "$name" "$runtime" "${MCP_COMMAND[$name]}" "${MCP_ARGS[$name]}" "${MCP_ENV[$name]}" "$cwd") &
  local broker_pid="$!"
  MCP_BROKER_PID[$name]="$broker_pid"
  MCP_BROKER_DIR[$name]="$runtime"
  MCP_BROKER_SEQ[$name]=0
  umask "$old_umask"
  local -F deadline=$(( EPOCHREALTIME + MCP_STARTUP_TIMEOUT ))
  if (( ${MCP_INTERACTIVE_CONNECT:-0} )); then
    ui_wait_for_mcp_start
    local -i start_status=$?
    if (( start_status != 0 )); then
      (( start_status == 130 )) && MCP_CONNECT_CANCELLED=1
      _mcp_disconnect_request "$name" 'MCP connection setup stopped or timed out'
      return "$start_status"
    fi
  else
    while ! _mcp_start_ready && (( EPOCHREALTIME < deadline )); do zselect -t 5; done
  fi
  if [[ -e "$runtime/ready" ]]; then return 0; fi
  MCP_ERROR="${mapfile[$runtime/start.error]:-${mapfile[$runtime/exited]:-MCP server did not start within ${MCP_STARTUP_TIMEOUT}s}}"
  mcp_broker_stop "$name"
  return 1
}

# Startup and request callbacks use their caller's dynamically scoped runtime,
# server name, and deadline. No registry state is copied into a UI worker.
_mcp_start_ready() {
  [[ -e "$runtime/ready" || -e "$runtime/start.error" || -e "$runtime/exited" ]] && return 0
  ! kill -0 "${MCP_BROKER_PID[$name]:-}" 2>/dev/null
}

# These callbacks read the request-local variables in mcp_broker_request. The
# broker continues to own stdio and framing; only the parent's wait changes.
_mcp_request_ready() {
  [[ -e "$response_file" ]] && return 0
  ! kill -0 "${MCP_BROKER_PID[$name]:-}" 2>/dev/null
}
_mcp_request_expired() { (( EPOCHREALTIME >= deadline )); }

_mcp_disconnect_request() {
  local name="$1" reason="$2"
  mcp_broker_stop "$name"
  MCP_STATUS[$name]=configured
  MCP_DETAIL[$name]="$reason; reconnect on next use"
  MCP_ERROR="$reason"
  _mcp_rebuild_tool_catalog
  (( ${MCP_INTERACTIVE_CONNECT:-0} )) && MCP_CONNECT_ABORTED=1
  return 0
}

mcp_broker_request() {
  local name="$1" mode="$2" expected_id="$3" request="$4" timeout_seconds="${5:-$MCP_REQUEST_TIMEOUT}"
  local runtime="" request_file="" response_file="" envelope="" reply_status=""
  local -i seq=0 wait_status=0
  runtime="${MCP_BROKER_DIR[$name]}"
  seq=$(( ${MCP_BROKER_SEQ[$name]:-0} + 1 ))
  MCP_BROKER_SEQ[$name]=$seq
  request_file="$runtime/request.$seq"; response_file="$runtime/response.$seq"
  envelope="${mode}"$'\t'"${expected_id}"$'\t'"${timeout_seconds}"$'\t'"${request}"
  zcoder_write_text_file "$request_file.tmp" "$envelope" || { MCP_ERROR="Could not queue MCP request"; return 1; }
  zf_mv -f "$request_file.tmp" "$request_file" 2>/dev/null || { MCP_ERROR="Could not publish MCP request"; return 1; }
  local -F deadline=$(( EPOCHREALTIME + timeout_seconds + 1 ))
  if (( ${MCP_INTERACTIVE_TOOL:-0} || ${MCP_INTERACTIVE_CONNECT:-0} )); then
    ui_wait_for_mcp_request
    wait_status=$?
    if (( wait_status == 130 )); then
      if (( ${MCP_INTERACTIVE_CONNECT:-0} )); then
        MCP_CONNECT_CANCELLED=1
        _mcp_disconnect_request "$name" 'MCP connection setup cancelled by user'
      else
        TOOL_CANCELLED=1
        _mcp_disconnect_request "$name" 'request cancelled by user; server disconnected; external side effects may have completed or may still be running'
      fi
      return 130
    elif (( wait_status != 0 )); then
      _mcp_disconnect_request "$name" 'MCP request wait stopped or timed out; outcome unknown'
      return 1
    fi
  else
    while [[ ! -e "$response_file" ]] && (( EPOCHREALTIME < deadline )); do
      kill -0 "${MCP_BROKER_PID[$name]}" 2>/dev/null || break
      zselect -t 5
    done
  fi
  if [[ ! -e "$response_file" ]]; then
    MCP_ERROR="MCP broker stopped or timed out"
    _mcp_disconnect_request "$name" "$MCP_ERROR; outcome unknown"
    return 1
  fi
  envelope="${mapfile[$response_file]}"; zf_rm -f "$response_file" 2>/dev/null
  reply_status="${envelope%%$'\t'*}"; MCP_RESPONSE="${envelope#*$'\t'}"
  if [[ "$reply_status" != OK ]]; then
    MCP_ERROR="$MCP_RESPONSE"
    _mcp_disconnect_request "$name" "$MCP_ERROR; outcome unknown"
    return 1
  fi
  return 0
}

mcp_broker_stop() {
  local name="$1" runtime="" pid=""
  runtime="${MCP_BROKER_DIR[$name]:-}"; pid="${MCP_BROKER_PID[$name]:-}"
  local server_pid=""
  [[ -n "$runtime" && -e "$runtime/ready" ]] && server_pid="${mapfile[$runtime/ready]}"
  [[ -n "$runtime" && -d "$runtime" ]] && mapfile[$runtime/stop]="1"
  if [[ "$pid" == <1-> ]]; then
    local -F deadline=$(( EPOCHREALTIME + 1.0 ))
    while [[ ! -e "$runtime/stopped" ]] && kill -0 "$pid" 2>/dev/null && (( EPOCHREALTIME < deadline )); do
      if (( (${MCP_INTERACTIVE_TOOL:-0} || ${MCP_INTERACTIVE_CONNECT:-0}) && ${UI_ACTIVE:-0} && ${RUNNING:-1} )); then ui_poll_activity 20 || true
      else zselect -t 2
      fi
    done
    if [[ ! -e "$runtime/stopped" ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      zselect -t 5
      kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
  fi
  if [[ "$server_pid" == <1-> ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill -TERM "$server_pid" 2>/dev/null || true
    zselect -t 5
    kill -KILL "$server_pid" 2>/dev/null || true
  fi
  unset "MCP_BROKER_PID[$name]" "MCP_BROKER_DIR[$name]" "MCP_BROKER_SEQ[$name]"
}

mcp_shutdown_all() {
  local name=""
  for name in ${(k)MCP_BROKER_PID}; do mcp_broker_stop "$name"; done
  if (( MCP_RUNTIME_OWNED )) && [[ -n "$MCP_RUNTIME_ROOT" && -d "$MCP_RUNTIME_ROOT" && \
        "${MCP_RUNTIME_ROOT:h:A}" == "${ZCODER_RUNTIME_DIR:A}" && "${MCP_RUNTIME_ROOT:t}" == mcp ]]; then
    zf_rm -rf -- "$MCP_RUNTIME_ROOT" 2>/dev/null
  fi
  MCP_RUNTIME_ROOT=""
  MCP_RUNTIME_OWNED=0
}

_mcp_client_meta() {
  REPLY='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"zcoder.zsh","version":"'"${ZCODER_VERSION:-dev}"'"},"io.modelcontextprotocol/clientCapabilities":{}}'
}

mcp_rpc() {
  local name="$1" method="$2" params_members="${3:-}" timeout_seconds="${4:-$MCP_REQUEST_TIMEOUT}"
  local id request params=""
  (( MCP_NEXT_ID++ )); id=$MCP_NEXT_ID
  if [[ "${MCP_PROTOCOL[$name]}" == "$MCP_VERSION_MODERN" ]]; then
    _mcp_client_meta
    params="{${params_members:+${params_members},}${REPLY}}"
  else
    params="{${params_members}}"
  fi
  json_quote "$method"
  request="{\"jsonrpc\":\"2.0\",\"id\":${id},\"method\":${REPLY},\"params\":${params}}"
  mcp_broker_request "$name" R "$id" "$request" "$timeout_seconds" || return 1
  _mcp_response_parse "$MCP_RESPONSE" || { MCP_ERROR="MCP server returned malformed JSON"; return 1; }
  [[ -z "$MCP_RESPONSE_ERROR" ]] || { MCP_ERROR="MCP error: $MCP_RESPONSE_ERROR"; return 1; }
  [[ -n "$MCP_RESPONSE_RESULT" ]] || { MCP_ERROR="MCP response omitted result"; return 1; }
  REPLY="$MCP_RESPONSE_RESULT"
}

_mcp_notify_initialized() {
  local name="$1" request='{"jsonrpc":"2.0","method":"notifications/initialized"}'
  mcp_broker_request "$name" N 0 "$request" 5
}

_mcp_discover_modern() {
  local name="$1" id request versions=""
  (( MCP_NEXT_ID++ )); id=$MCP_NEXT_ID
  _mcp_client_meta
  request="{\"jsonrpc\":\"2.0\",\"id\":${id},\"method\":\"server/discover\",\"params\":{${REPLY}}}"
  mcp_broker_request "$name" R "$id" "$request" "$MCP_STARTUP_TIMEOUT" || return 1
  _mcp_response_parse "$MCP_RESPONSE" || return 1
  [[ -z "$MCP_RESPONSE_ERROR" && -n "$MCP_RESPONSE_RESULT" ]] || return 1
  _mcp_json_get "$MCP_RESPONSE_RESULT" supportedVersions || return 1
  versions="$REPLY"
  _mcp_parse_string_array "$versions" || return 1
  [[ " ${(j: :)MCP_PARSED_ARRAY} " == *" $MCP_VERSION_MODERN "* ]] || return 1
  MCP_PROTOCOL[$name]="$MCP_VERSION_MODERN"
  return 0
}

_mcp_initialize_legacy() {
  local name="$1" id request version_raw="" version=""
  (( MCP_NEXT_ID++ )); id=$MCP_NEXT_ID
  request="{\"jsonrpc\":\"2.0\",\"id\":${id},\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"${MCP_VERSION_LEGACY}\",\"capabilities\":{},\"clientInfo\":{\"name\":\"zcoder.zsh\",\"version\":\"${ZCODER_VERSION:-dev}\"}}}"
  mcp_broker_request "$name" R "$id" "$request" "$MCP_STARTUP_TIMEOUT" || return 1
  _mcp_response_parse "$MCP_RESPONSE" || { MCP_ERROR="legacy initialize returned malformed JSON"; return 1; }
  [[ -z "$MCP_RESPONSE_ERROR" && -n "$MCP_RESPONSE_RESULT" ]] || { MCP_ERROR="legacy initialize failed: ${MCP_RESPONSE_ERROR:-missing result}"; return 1; }
  _mcp_json_get "$MCP_RESPONSE_RESULT" protocolVersion || { MCP_ERROR="legacy initialize omitted protocolVersion"; return 1; }
  version_raw="$REPLY"; _mcp_json_string "$version_raw" || return 1; version="$REPLY"
  [[ "$version" == "$MCP_VERSION_LEGACY" ]] || { MCP_ERROR="unsupported MCP version: $version"; return 1; }
  MCP_PROTOCOL[$name]="$version"
  _mcp_notify_initialized "$name" || return 1
}

_mcp_exposed_name() {
  local value="mcp__${1}__${2}"
  value="${value//[^A-Za-z0-9_]/_}"
  (( ${#value} > 128 )) && value="${value[1,128]}"
  REPLY="$value"
}

# MCP annotations are capability hints supplied by the server. Prefer their
# explicit read/write and open-world declarations; when an older server omits
# them, admit only clearly read-shaped names without external confirmation.
_mcp_tool_effect_from_record() {
  local original="$1" tool_raw="$2" annotations="" read_only="" open_world="" destructive=""
  local normalized="${(L)original}"
  normalized="${normalized//[^a-z0-9]/_}"
  if _mcp_raw_member "$tool_raw" annotations; then
    annotations="$REPLY"
    _mcp_raw_member "$annotations" readOnlyHint && read_only="$REPLY"
    _mcp_raw_member "$annotations" openWorldHint && open_world="$REPLY"
    _mcp_raw_member "$annotations" destructiveHint && destructive="$REPLY"
  fi
  if [[ "$destructive" == true ]]; then
    REPLY="external_write"
    return 0
  fi
  if [[ "$read_only" == true ]]; then
    REPLY="read_only"
    return 0
  fi
  if [[ "$read_only" == false ]]; then
    [[ "$open_world" == false ]] && REPLY="workspace_write" || REPLY="external_write"
    return 0
  fi
  case "$normalized" in
    get*|list*|read*|search*|find*|fetch*|show*|view*|inspect*|lookup*|query*|status*|check*|resolve*|describe*|explain*|analy[sz]e*|locate*|scan*|echo*) REPLY="read_only" ;;
    *) REPLY="external_write" ;;
  esac
}

mcp_tool_effect() {
  REPLY="${MCP_TOOL_EFFECT[$1]:-external_write}"
}

_mcp_rebuild_tool_catalog() {
  local server="" array_raw="" tool_raw="" original="" description="" schema="" exposed="" effect="" effect_note=""
  local -a tool_records=()
  MCP_TOOL_NAMES=(); MCP_TOOL_SERVER=(); MCP_TOOL_ORIGINAL=(); MCP_TOOL_SCHEMA=(); MCP_TOOL_EFFECT=()
  for server in "${MCP_NAMES[@]}"; do
    [[ "${MCP_STATUS[$server]}" == connected ]] || continue
    array_raw="${MCP_SERVER_TOOLS[$server]:-[]}"
    _mcp_raw_array_items "$array_raw" || continue
    tool_records=("${MCP_RAW_ITEMS[@]}")
    for tool_raw in "${tool_records[@]}"; do
      if _mcp_raw_member "$tool_raw" name && _mcp_json_string "$REPLY"; then original="$REPLY"; else original=""; fi
      [[ -n "$original" ]] || continue
      if _mcp_raw_member "$tool_raw" description && _mcp_json_string "$REPLY"; then description="$REPLY"; else description="MCP tool ${server}/${original}"; fi
      if _mcp_raw_member "$tool_raw" inputSchema; then schema="$REPLY"; else schema='{"type":"object"}'; fi
      _mcp_tool_effect_from_record "$original" "$tool_raw"; effect="$REPLY"
      case "$effect" in
        read_only) effect_note="read-only capability" ;;
        workspace_write) effect_note="workspace mutation" ;;
        *) effect_note="external mutation; per-call user confirmation required" ;;
      esac
      _mcp_exposed_name "$server" "$original"; exposed="$REPLY"
      if [[ -n "${MCP_TOOL_SERVER[$exposed]:-}" ]]; then
        MCP_DETAIL[$server]="tool name collision: $exposed"
      else
        MCP_TOOL_NAMES+=("$exposed")
        MCP_TOOL_SERVER[$exposed]="$server"
        MCP_TOOL_ORIGINAL[$exposed]="$original"
        MCP_TOOL_EFFECT[$exposed]="$effect"
        json_quote "$exposed"; local exposed_json="$REPLY"
        json_quote "[MCP server '$server'; short tool name '$original'; $effect_note. When instructions mention '$original', call this exact function.] $description"; local description_json="$REPLY"
        MCP_TOOL_SCHEMA[$exposed]="{\"type\":\"function\",\"function\":{\"name\":${exposed_json},\"description\":${description_json},\"parameters\":${schema}}}"
      fi
    done
  done
}

mcp_fetch_tools() {
  local name="$1" result="" tools="" cursor="" all='[' comma="" member="" tool_raw=""
  while true; do
    member=""
    if [[ -n "$cursor" ]]; then json_quote "$cursor"; member="\"cursor\":${REPLY}"; fi
    mcp_rpc "$name" tools/list "$member" "$MCP_STARTUP_TIMEOUT" || return 1
    result="$REPLY"
    _mcp_raw_member "$result" tools || { MCP_ERROR="tools/list omitted tools"; return 1; }
    tools="$REPLY"
    _mcp_raw_array_items "$tools" || { MCP_ERROR="tools/list tools is not an array"; return 1; }
    for tool_raw in "${MCP_RAW_ITEMS[@]}"; do all+="${comma}${tool_raw}"; comma=,; done
    cursor=""
    if _mcp_raw_member "$result" nextCursor; then _mcp_json_string "$REPLY" && cursor="$REPLY"; fi
    [[ -n "$cursor" ]] || break
  done
  MCP_SERVER_TOOLS[$name]="${all}]"
}

mcp_connect() {
  local name="$1"
  local -i MCP_INTERACTIVE_CONNECT=0 MCP_CONNECT_ABORTED=0
  MCP_CONNECT_CANCELLED=0
  (( ${UI_ACTIVE:-0} && $+functions[ui_wait_for_mcp_start] )) && MCP_INTERACTIVE_CONNECT=1
  [[ -n "${MCP_RAW[$name]:-}" ]] || { MCP_ERROR="unknown MCP server: $name"; return 1; }
  (( ${MCP_ENABLED[$name]:-0} )) || { MCP_STATUS[$name]=disabled; MCP_ERROR="MCP server is disabled: $name"; return 1; }
  [[ "${MCP_TYPE[$name]}" == stdio ]] || { MCP_STATUS[$name]=unsupported; MCP_ERROR="HTTP MCP is not available yet: $name"; return 1; }
  [[ "${MCP_STATUS[$name]}" == connected ]] && return 0
  MCP_STATUS[$name]="starting"; MCP_DETAIL[$name]=""
  if ! mcp_broker_start "$name"; then
    (( MCP_CONNECT_CANCELLED )) && return 130
    MCP_STATUS[$name]="failed"; MCP_DETAIL[$name]="$MCP_ERROR"; return 1
  fi
  if ! _mcp_discover_modern "$name"; then
    # A cancelled or broken transport cannot negotiate a fallback protocol.
    (( MCP_CONNECT_CANCELLED )) && return 130
    (( MCP_CONNECT_ABORTED )) && return 1
    if ! _mcp_initialize_legacy "$name"; then
      (( MCP_CONNECT_CANCELLED )) && return 130
      (( MCP_CONNECT_ABORTED )) && return 1
      MCP_STATUS[$name]="protocol mismatch"; MCP_DETAIL[$name]="$MCP_ERROR"; mcp_broker_stop "$name"; return 1
    fi
  fi
  if ! mcp_fetch_tools "$name"; then
    (( MCP_CONNECT_CANCELLED )) && return 130
    MCP_STATUS[$name]="failed"; MCP_DETAIL[$name]="$MCP_ERROR"; mcp_broker_stop "$name"; return 1
  fi
  MCP_STATUS[$name]="connected"
  MCP_DETAIL[$name]="tools loaded"
  _mcp_rebuild_tool_catalog
  return 0
}

mcp_connect_all() {
  local name="" failures=""
  MCP_CONNECT_CANCELLED=0
  for name in "${MCP_NAMES[@]}"; do
    (( ${MCP_ENABLED[$name]:-0} )) || continue
    [[ "${MCP_TYPE[$name]}" == stdio ]] || continue
    mcp_connect "$name" || failures+="${failures:+; }${name}: ${MCP_ERROR}"
    (( MCP_CONNECT_CANCELLED )) && return 130
  done
  [[ -z "$failures" ]] || { MCP_ERROR="$failures"; return 1; }
}

mcp_tools_schema_json() {
  local name="" output="" comma=""
  mcp_connect_all >/dev/null 2>&1 || true
  (( MCP_CONNECT_CANCELLED )) && { REPLY=''; return 130; }
  for name in "${MCP_TOOL_NAMES[@]}"; do
    [[ "${MCP_STATUS[${MCP_TOOL_SERVER[$name]}]:-}" == connected ]] || continue
    (( $+functions[agent_tool_is_admitted] )) && ! agent_tool_is_admitted "$name" && continue
    output+="${comma}${MCP_TOOL_SCHEMA[$name]}"; comma=,
  done
  REPLY="$output"
}

mcp_prompt_block() {
  local exposed="" server="" original="" output="" line=""
  local -i bytes=0 line_bytes=0 truncated=0
  (( ${#MCP_TOOL_NAMES} > 0 )) || { REPLY=""; return 0; }
  [[ "$MCP_PROMPT_MAX_BYTES" == <256-> ]] || MCP_PROMPT_MAX_BYTES=8192
  output=$'\n\n<mcp_tool_routing>\nInstalled MCP servers provide model-callable capabilities. Read-only tools may inspect their declared systems. An external-write tool is not authority to publish, message, deploy, or mutate external state; every call still requires the user\x27s explicit confirmation. Project instructions that explicitly require an MCP server or short tool name for the current kind of task are mandatory tool-selection rules. For an applicable repository investigation that needs orientation or navigation, call the designated MCP tool before built-in search, read_file, list_files, or run_command. Do not interpret a mere mention of a repository, codebase, file, or tool as a request to investigate it. If the request can be answered completely from the user message and existing context, respond directly without calling an MCP tool. Do not substitute a generic built-in merely because it appears familiar. After an MCP navigation result identifies a relevant source range, follow project reading instructions and use that exact range instead of reading the whole file. MCP function names are namespaced, so use this exact map when instructions mention a short name:\n'
  _mcp_byte_length "$output"
  bytes=$REPLY
  for exposed in "${MCP_TOOL_NAMES[@]}"; do
    (( $+functions[agent_tool_is_admitted] )) && ! agent_tool_is_admitted "$exposed" && continue
    server="${MCP_TOOL_SERVER[$exposed]}"; original="${MCP_TOOL_ORIGINAL[$exposed]}"
    line="- ${server}/${original} [${MCP_TOOL_EFFECT[$exposed]:-external_write}] -> ${exposed}"$'\n'
    _mcp_byte_length "$line"
    line_bytes=$REPLY
    if (( bytes + line_bytes + 21 > MCP_PROMPT_MAX_BYTES )); then truncated=1; break; fi
    output+="$line"; (( bytes += line_bytes ))
  done
  (( truncated )) && output+="[tool map truncated]"$'\n'
  output+="</mcp_tool_routing>"
  REPLY="$output"
}

mcp_call_tool() {
  local exposed="$1" args_json="$2" server="" original="" result=""
  local -i MCP_INTERACTIVE_TOOL=0
  TOOL_CANCELLED=0
  (( ${UI_ACTIVE:-0} && $+functions[ui_wait_for_mcp_request] )) && MCP_INTERACTIVE_TOOL=1
  server="${MCP_TOOL_SERVER[$exposed]:-}"
  [[ -n "$server" ]] || { _tool_fail "unknown MCP tool: $exposed"; return 1; }
  original="${MCP_TOOL_ORIGINAL[$exposed]}"
  json_begin "$args_json" || { _tool_fail "invalid MCP arguments: $JSON_ERROR"; return 1; }
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || { _tool_fail "MCP tool arguments must be an object"; return 1; }
  json_capture_raw_value || { _tool_fail "invalid MCP arguments: $JSON_ERROR"; return 1; }
  args_json="$REPLY"
  json_quote "$original"; local name_json="$REPLY"
  if ! mcp_rpc "$server" tools/call "\"name\":${name_json},\"arguments\":${args_json}" "$MCP_REQUEST_TIMEOUT"; then
    _tool_fail "MCP ${server}/${original} failed: $MCP_ERROR"
    (( TOOL_CANCELLED )) && return 130
    return 1
  fi
  result="$REPLY"
  if _mcp_json_get "$result" isError && [[ "$REPLY" == true ]]; then
    _tool_fail "MCP ${server}/${original} returned an error: $result"
    return 1
  fi
  _tool_succeed "$result"
}

mcp_status_text() {
  local name="" output="" line="" scope="" server_status="" transport="" protocol="" detail=""
  local -i name_width=0 status_width=0 transport_width=0 scope_width=0 protocol_width=0
  local -i have_protocol=0 have_detail=0
  if (( ${#MCP_NAMES} == 0 )); then REPLY="No MCP servers configured."; return 0; fi
  for name in "${MCP_NAMES[@]}"; do
    server_status="${MCP_STATUS[$name]}"; transport="${MCP_TYPE[$name]}"; scope="${MCP_SCOPE[$name]}"; protocol="${MCP_PROTOCOL[$name]:-}"
    (( ${#name} > name_width )) && name_width=${#name}
    (( ${#server_status} > status_width )) && status_width=${#server_status}
    (( ${#transport} > transport_width )) && transport_width=${#transport}
    (( ${#scope} > scope_width )) && scope_width=${#scope}
    (( ${#protocol} > protocol_width )) && protocol_width=${#protocol}
    [[ -n "$protocol" ]] && have_protocol=1
    [[ -n "${MCP_DETAIL[$name]:-}" ]] && have_detail=1
  done
  for name in "${MCP_NAMES[@]}"; do
    scope="${MCP_SCOPE[$name]}"; server_status="${MCP_STATUS[$name]}"; transport="${MCP_TYPE[$name]}"
    protocol="${MCP_PROTOCOL[$name]:-}"; detail="${MCP_DETAIL[$name]:-}"
    line="${(r:$name_width:: :)name}  ${(r:$status_width:: :)server_status}  ${(r:$transport_width:: :)transport}  "
    if (( have_protocol || have_detail )); then
      line+="${(r:$scope_width:: :)scope}  "
      if (( have_detail )); then line+="${(r:$protocol_width:: :)protocol}  ${detail}"; else line+="$protocol"; fi
    else
      line+="$scope"
    fi
    [[ -n "$output" ]] && output+=$'\n'
    output+="$line"
  done
  REPLY="$output"
}

_mcp_raw_stdio() {
  local command_name="$1" args_json="$2" env_json="$3" enabled="${4:-true}"
  json_quote "$command_name"; local command_json="$REPLY"
  REPLY="{\"type\":\"stdio\",\"command\":${command_json},\"args\":${args_json},\"env\":${env_json},\"enabled\":${enabled}}"
}

_mcp_cli_json_array() {
  local value="" output="[" comma=""
  for value in "$@"; do json_quote "$value"; output+="${comma}${REPLY}"; comma=,; done
  REPLY="${output}]"
}

_mcp_cli_env_json() {
  local pair="" key="" value="" output="{" comma=""
  for pair in "$@"; do
    [[ "$pair" == *=* ]] || { MCP_ERROR="--env expects KEY=VALUE"; return 1; }
    key="${pair%%=*}"; value="${pair#*=}"
    [[ "$key" == [A-Za-z_][A-Za-z0-9_]## ]] || { MCP_ERROR="invalid environment name: $key"; return 1; }
    json_quote "$key"; local key_json="$REPLY"; json_quote "$value"
    output+="${comma}${key_json}:${REPLY}"; comma=,
  done
  REPLY="${output}}"
}

mcp_cli_usage() {
  print -r -- "Usage: ${ZCODER_NAME:-zcoder.zsh} mcp list [--json]"
  print -r -- "       ${ZCODER_NAME:-zcoder.zsh} mcp get NAME [--json]"
  print -r -- "       ${ZCODER_NAME:-zcoder.zsh} mcp add [--scope user|project] [--env KEY=VALUE] NAME -- COMMAND [ARG ...]"
  print -r -- "       ${ZCODER_NAME:-zcoder.zsh} mcp remove|delete [--scope user|project] NAME"
  print -r -- "       ${ZCODER_NAME:-zcoder.zsh} mcp enable|disable [--scope user|project] NAME"
  print -r -- "       ${ZCODER_NAME:-zcoder.zsh} mcp test NAME"
}

mcp_cli() {
  local action="${1:-list}" name="" scope="user" json=0 pair="" raw="" target_scope=""
  local -i scope_explicit=0
  local -a env_pairs=() command_parts=()
  shift 2>/dev/null || true
  ZCODER_WORKSPACE="${ZCODER_WORKSPACE:-$PWD:A}"
  mcp_load || { print -u2 -- "Error: $MCP_ERROR"; return 1; }
  case "$action" in
    list)
      [[ "${1:-}" == --json ]] && json=1
      if (( json )); then
        local output='{"servers":[' comma="" item=""
        for name in "${MCP_NAMES[@]}"; do
          json_quote "$name"; item="{\"name\":${REPLY}"; json_quote "${MCP_SCOPE[$name]}"; item+=",\"scope\":${REPLY}"; json_quote "${MCP_TYPE[$name]}"; item+=",\"transport\":${REPLY},\"enabled\":${MCP_ENABLED[$name]}}"; output+="${comma}${item}"; comma=,; done
        print -r -- "${output}]}"
      else
        mcp_status_text; print -r -- "$REPLY"
      fi
      ;;
    get)
      name="${1:-}"; [[ -n "${MCP_RAW[$name]:-}" ]] || { print -u2 -- "Error: unknown MCP server: $name"; return 1; }
      if [[ "${2:-}" == --json ]]; then print -r -- "${MCP_RAW[$name]}"; else print -r -- "$name\t${MCP_STATUS[$name]}\t${MCP_TYPE[$name]}\t${MCP_SCOPE[$name]}"; print -r -- "${MCP_RAW[$name]}"; fi
      ;;
    add)
      while (( $# > 0 )); do
        case "$1" in
          --scope) [[ "${2:-}" == user || "${2:-}" == project ]] || { print -u2 -- "Error: --scope expects user or project"; return 2; }; scope="$2"; scope_explicit=1; shift 2 ;;
          --env) [[ -n "${2:-}" ]] || { print -u2 -- "Error: --env requires KEY=VALUE"; return 2; }; env_pairs+=("$2"); shift 2 ;;
          --) shift; command_parts=("$@"); break ;;
          *) [[ -z "$name" ]] || { print -u2 -- "Error: unexpected argument: $1"; return 2; }; name="$1"; shift ;;
        esac
      done
      _mcp_valid_name "$name" || { print -u2 -- "Error: invalid MCP server name"; return 2; }
      (( ${#command_parts} > 0 )) || { print -u2 -- "Error: add requires -- COMMAND [ARG ...]"; return 2; }
      local command_name="${command_parts[1]}"
      command_parts[1]=()
      _mcp_cli_json_array "${command_parts[@]}"; local args_json="$REPLY"
      _mcp_cli_env_json "${env_pairs[@]}" || { print -u2 -- "Error: $MCP_ERROR"; return 2; }; local env_json="$REPLY"
      _mcp_raw_stdio "$command_name" "$args_json" "$env_json"; raw="$REPLY"
      if [[ "$scope" == user ]]; then MCP_USER_RAW[$name]="$raw"; else MCP_PROJECT_RAW[$name]="$raw"; fi
      _mcp_config_write "$scope" || { print -u2 -- "Error: $MCP_ERROR"; return 1; }
      print -r -- "Added MCP server '$name' ($scope)."
      ;;
    remove|delete|enable|disable)
      while (( $# > 0 )); do
        case "$1" in
          --scope) [[ "${2:-}" == user || "${2:-}" == project ]] || { print -u2 -- "Error: --scope expects user or project"; return 2; }; scope="$2"; scope_explicit=1; shift 2 ;;
          *) name="$1"; shift ;;
        esac
      done
      [[ "$scope" == user || "$scope" == project ]] || { print -u2 -- "Error: --scope expects user or project"; return 2; }
      target_scope="${MCP_SCOPE[$name]:-}"
      [[ -n "$target_scope" ]] || { print -u2 -- "Error: unknown MCP server: $name"; return 1; }
      # With no explicit project entry, operate on the visible definition.
      (( scope_explicit )) || scope="$target_scope"
      if [[ "$action" == remove || "$action" == delete ]]; then
        if [[ "$scope" == user ]]; then unset "MCP_USER_RAW[$name]"; else unset "MCP_PROJECT_RAW[$name]"; fi
      else
        [[ "$scope" == user ]] && raw="${MCP_USER_RAW[$name]:-${MCP_RAW[$name]}}" || raw="${MCP_PROJECT_RAW[$name]:-${MCP_RAW[$name]}}"
        if _mcp_json_get "$raw" enabled; then
          [[ "$action" == enable ]] && raw="${raw/\"enabled\":false/\"enabled\":true}" || raw="${raw/\"enabled\":true/\"enabled\":false}"
        else
          [[ "$action" == enable ]] && raw="${raw%\}},\"enabled\":true}" || raw="${raw%\}},\"enabled\":false}"
        fi
        [[ "$scope" == user ]] && MCP_USER_RAW[$name]="$raw" || MCP_PROJECT_RAW[$name]="$raw"
      fi
      _mcp_config_write "$scope" || { print -u2 -- "Error: $MCP_ERROR"; return 1; }
      case "$action" in
        disable) print -r -- "Disabled MCP server '$name' ($scope)." ;;
        enable) print -r -- "Enabled MCP server '$name' ($scope)." ;;
        *) print -r -- "Removed MCP server '$name' ($scope)." ;;
      esac
      ;;
    test)
      name="${1:-}"; mcp_connect "$name" || { print -u2 -- "Error: $MCP_ERROR"; return 1; }
      print -r -- "$name"$'\t'"connected"$'\t'"${MCP_PROTOCOL[$name]}"
      mcp_shutdown_all
      ;;
    help|-h|--help) mcp_cli_usage ;;
    *) print -u2 -- "Error: unknown MCP command: $action"; mcp_cli_usage >&2; return 2 ;;
  esac
}
