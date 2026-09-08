# Protocol regression tests; source from tests/run.zsh after loading libraries.
hardening_protocol_tests() {
  local wire='' line='' output='' read_fd='' write_fd='' peer_pid='' permission_pid='' barrier='' mode=''
  local -i result=0 try=0
  local -F started=0 elapsed=0 deadline=0
  local MCP_BROKER_BUFFER='' MCP_BROKER_READ_FD='' MCP_BROKER_WRITE_FD=''
  local ACP_PERMISSION_ID='' ACP_PERMISSION_SESSION='' ACP_SESSION_ID=demo ZCODER_PROFILE=coding
  local -i ACP_WORKER_RUNNING=1 ACP_PERMISSION_ALWAYS=0 ACP_PROMPT_CANCELLED=0
  local -A ACP_SESSION_COMMAND_ALLOW=()
  local send_function="${functions[_acp_send]}"
  _acp_send() { :; }
  {
    for wire in $'3\r\nabc\r\n' $'3\r\nabcXX0\r\n\r\n' $'0\r\n' $'0\r\n\r\njunk' $'0\r\nbad\r\n\r\n' $'0\r\nX: 1\nY: 2\r\n\r\n'; do
      _http_dechunk "$wire"
      assert_failure 'chunk decoder rejects incomplete or malformed framing' $?
    done
    _http_dechunk $'3;ignored=yes\r\nabc\r\n0\r\nX-Checksum: ok\r\n\r\n'
    assert_success 'chunk extensions and complete trailers remain supported' $?
    assert_eq abc "$REPLY" 'chunk decoder returns only body bytes'
    _mcp_wire_envelope '{"jsonrpc":"2.0","result":{"id":999,"method":"nested"},"id":1}'
    assert_eq 1 "$MCP_WIRE_ID" 'MCP routing uses the top-level response ID'
    assert_eq '' "$MCP_WIRE_METHOD" 'MCP routing ignores nested methods'
    _mcp_wire_envelope '{"jsonrpc":"2.0","method":"notice","params":{"id":1}}'
    assert_eq '' "$MCP_WIRE_ID" 'MCP notifications cannot inherit a nested request ID'
    _mcp_wire_envelope ' {"jsonrpc":"2.0","id":1,"result":{}}'
    assert_eq 1 "$MCP_WIRE_ID" 'MCP envelope parsing accepts leading JSON whitespace'
    hardening_mcp_native_scan_test

    # Prior integration fixtures can leave a saved coprocess write endpoint
    # whose reader has exited. Matched replies need a live consumer here.
    coproc {
      trap - EXIT INT TERM HUP
      local response=''
      while IFS= read -r response; do :; done
    }
    permission_pid=$!
    line='{"jsonrpc":"2.0","id":"permission","method":"session/request_permission","params":{"sessionId":"demo","options":[{"optionId":"allow-always","kind":"allow_always"}]}}'
    _acp_handle_line '{"jsonrpc":"2.0","id":"unknown","result":{"outcome":{"outcome":"selected","optionId":"allow-always"}}}' 2>/dev/null
    assert_eq 0 "${ACP_SESSION_COMMAND_ALLOW[demo]:-0}" 'unsolicited ACP approval does not persist command permission'
    _acp_forward_worker_line "$line"
    _acp_handle_line '{"jsonrpc":"2.0","id":"unknown","result":{"outcome":{"outcome":"selected","optionId":"allow-always"}}}' 2>/dev/null
    assert_eq 0 "${ACP_SESSION_COMMAND_ALLOW[demo]:-0}" 'wrong ACP permission ID cannot grant session permission'
    assert_eq permission "$ACP_PERMISSION_ID" 'an unrelated response leaves the real permission pending'
    _acp_handle_line '{"jsonrpc":"2.0","id":"permission","result":{"outcome":{"outcome":"selected","optionId":"allow-always"}}}' 2>/dev/null
    assert_eq 1 "${ACP_SESSION_COMMAND_ALLOW[demo]:-0}" 'a matching offered ACP permission persists for the session'
    assert_eq '' "$ACP_PERMISSION_ID" 'a matched permission response is consumed once'
    ACP_SESSION_COMMAND_ALLOW=()
    _acp_forward_worker_line "${line/allow_always/allow_once}"
    _acp_handle_line '{"jsonrpc":"2.0","id":"permission","result":{"outcome":{"outcome":"selected","optionId":"allow-always"}}}' 2>/dev/null
    assert_eq 0 "${ACP_SESSION_COMMAND_ALLOW[demo]:-0}" 'an option without allow_always kind cannot persist permission'
    ACP_PROMPT_CANCELLED=1
    _acp_forward_worker_line "$line"
    assert_eq '' "$ACP_PERMISSION_ID" 'buffered permission requests cannot reopen a cancelled prompt'
    ACP_PROMPT_CANCELLED=0
    kill -TERM "$permission_pid" 2>/dev/null || true
    wait "$permission_pid" 2>/dev/null || true
    permission_pid=''

    # Keep stdout open after a partial frame: EOF must not be what ends the
    # request. The timeout remains effective despite the readable prefix.
    coproc { print -rn -- '{"id":1'; zselect -t 200; }
    peer_pid=$!
    exec {MCP_BROKER_READ_FD}<&p
    exec {MCP_BROKER_WRITE_FD}>/dev/null
    started=$EPOCHREALTIME
    _mcp_broker_exchange '{}' 1 0.15
    result=$?; elapsed=$(( EPOCHREALTIME - started ))
    assert_failure 'partial MCP frame ends with request timeout' "$result"
    assert_contains "$REPLY" 'timed out' 'partial MCP frame reports its deadline rather than EOF'
    assert_success 'partial MCP frame cannot block beyond the deadline' $(( elapsed < 1 ? 0 : 1 ))
    kill -TERM "$peer_pid" 2>/dev/null
    wait "$peer_pid" 2>/dev/null || true
    peer_pid=''
    exec {MCP_BROKER_READ_FD}<&-
    exec {MCP_BROKER_WRITE_FD}>&-

    MCP_BROKER_BUFFER=$'{"jsonrpc":"2.0","method":"notice","params":{"id":1}}\n{"jsonrpc":"2.0","result":{"id":999},"id":1}\n{"jsonrpc":"2.0","id":2,"result":{}}\n'
    exec {MCP_BROKER_WRITE_FD}>/dev/null
    _mcp_broker_exchange '{}' 1 1
    assert_success 'MCP ignores a notification and accepts the actual response' $?
    assert_contains "$REPLY" '"result":{"id":999}' 'MCP returns the response with an independently nested ID'
    _mcp_broker_exchange '{}' 2 1
    assert_success 'coalesced MCP replies remain buffered for the next exchange' $?
    assert_eq '' "$MCP_BROKER_BUFFER" 'complete MCP records consume exactly their own bytes'

    # Exercise framing itself: routing-only tests miss quadratic removal of
    # a long consumed line. Retain a following reply and an incomplete tail.
    json_quote "${(pl:50000::é:)}"
    wire='{"jsonrpc":"2.0","id":3,"result":{"text":'"$REPLY"'}}'
    MCP_BROKER_BUFFER="$wire"$'\n{"jsonrpc":"2.0","id":4,"result":{}}\n{"partial":"é'
    started=$EPOCHREALTIME
    _mcp_broker_exchange '{}' 3 10
    result=$?; elapsed=$(( EPOCHREALTIME - started ))
    assert_success 'MCP framing accepts a large Unicode catalog response' "$result"
    assert_eq "$wire" "$REPLY" 'MCP framing returns the complete large response unchanged'
    assert_success 'MCP framing consumes a large line without a startup CPU stall' $(( elapsed < 1.5 ? 0 : 1 ))
    _mcp_broker_exchange '{}' 4 1
    assert_success 'a response following a large MCP frame remains readable' $?
    assert_eq '{"partial":"é' "$MCP_BROKER_BUFFER" 'large MCP framing preserves an incomplete Unicode tail'
    MCP_BROKER_BUFFER=''
    exec {MCP_BROKER_WRITE_FD}>&-

    hardening_mcp_timeout_test

    for mode in input output; do
      barrier="$TEST_TMP/hardening-acp-$mode"
      zf_rm -f "$barrier"
      coproc command zsh "$TEST_DIR/fixtures/hardening_acp.zsh" "$mode" "$barrier"
      peer_pid=$!
      exec {read_fd}<&p
      exec {write_fd}>&p
      if [[ "$mode" == input ]]; then
        print -rn -u "$write_fd" -- '{"jsonrpc":'
        : > "$barrier"
      else
        deadline=$(( EPOCHREALTIME + 2 ))
        while [[ ! -f "$barrier" ]] && (( EPOCHREALTIME < deadline )); do zselect -t 1; done
        print -r -u "$write_fd" -- '{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"demo"}}'
      fi
      output=''; deadline=$(( EPOCHREALTIME + 2 ))
      while (( EPOCHREALTIME < deadline )); do
        line=''
        sysread -i "$read_fd" -s 32768 -t 0.1 line 2>/dev/null && output+="$line"
        [[ "$mode" == input && "$output" == *worker-progress* || "$mode" == output && "$output" == *cancelled* ]] && break
      done
      if [[ "$mode" == input ]]; then
        assert_contains "$output" worker-progress 'partial ACP client input does not block worker events'
        print -r -u "$write_fd" -- '"2.0","method":"session/cancel","params":{"sessionId":"demo"}}'
      else
        assert_contains "$output" cancelled 'partial ACP worker output does not block cancellation'
      fi
      exec {write_fd}>&-
      # Replacing the coprocess closes Zsh's own saved pipe endpoints too.
      coproc :
      kill -TERM "$peer_pid" 2>/dev/null || true
      wait "$peer_pid" 2>/dev/null || true
      peer_pid=''
      exec {read_fd}<&-
    done
  } always {
    functions[_acp_send]="$send_function"
    [[ -n "$permission_pid" ]] && kill -TERM "$permission_pid" 2>/dev/null
    [[ -n "$permission_pid" ]] && wait "$permission_pid" 2>/dev/null
    [[ -n "$peer_pid" ]] && kill -TERM "$peer_pid" 2>/dev/null
    [[ -n "$peer_pid" ]] && wait "$peer_pid" 2>/dev/null
  }
}

hardening_mcp_native_scan_test() {
  # Hosts without zsh/pcre and responses exceeding PCRE's resource limits
  # both use this path. A long description used to pin a core at startup.
  local -i MCP_PCRE_JSON_STATE=0
  local description="${(pl:50000::é:)}" value='' wire=''
  local -F started elapsed
  json_quote "$description"; description="$REPLY"
  wire='{"jsonrpc":"2.0","result":{"description":'"$description"',"id":999,"method":"nested"},"id":"outer"}'
  started=$EPOCHREALTIME
  _mcp_wire_envelope "$wire"
  elapsed=$(( EPOCHREALTIME - started ))
  assert_eq '"outer"' "$MCP_WIRE_ID" 'native MCP routing finds an ID after a large Unicode result'
  assert_eq '' "$MCP_WIRE_METHOD" 'native MCP routing ignores methods inside a large result'
  assert_success 'native MCP routing skips long text without a startup CPU stall' $(( elapsed < 1.5 ? 0 : 1 ))

  for value in '""' '"é"' '"escaped \\\" ] } and \\\\"' '{"é":[1,{"text":"[ ] } \\\""}],"empty":{}}' '[true,false,null,-1.5e2]' true null -1.5e2; do
    wire=$' \t'"$value"',42'
    _mcp_raw_value_bounds "$wire"
    assert_success 'native MCP scanner locates a complete JSON value' $?
    assert_eq "$value" "${wire[MCP_RAW_START,MCP_RAW_END]}" 'native MCP bounds preserve Unicode, escapes and nested delimiters'
  done
  for value in '"unfinished' '"trailing\' '{"text":"closed"' '[1,{"text":"unfinished'; do
    _mcp_raw_value_bounds "$value"
    assert_failure 'native MCP scanner rejects unterminated strings and containers' $?
  done
  _mcp_raw_array_items '[{"name":"é","text":"escaped \\\" ] }"},[1,2],"",true]'
  assert_success 'native MCP scanner splits a catalog with escaped structural text' $?
  assert_eq 4 "${#MCP_RAW_ITEMS}" 'native MCP array slicing preserves item boundaries'
}

hardening_mcp_timeout_test() {
  local name=protocol-stall ZCODER_WORKSPACE="$TEST_TMP"
  local MCP_RUNTIME_ROOT="$TEST_TMP/protocol-mcp" MCP_ERROR='' MCP_RESPONSE=''
  local -i MCP_RUNTIME_OWNED=0 MCP_INTERACTIVE_TOOL=0 MCP_INTERACTIVE_CONNECT=0
  local -A MCP_TYPE=([$name]=stdio) MCP_COMMAND=([$name]=zsh)
  local -A MCP_ARGS=([$name]='[]') MCP_ENV=([$name]='{}') MCP_CWD=([$name]="$TEST_TMP")
  local -A MCP_BROKER_PID=() MCP_BROKER_DIR=() MCP_BROKER_SEQ=() MCP_STATUS=() MCP_DETAIL=() MCP_SERVER_TOOLS=()
  local -a MCP_NAMES=() MCP_TOOL_NAMES=()
  local -A MCP_TOOL_SERVER=() MCP_TOOL_ORIGINAL=() MCP_TOOL_SCHEMA=() MCP_TOOL_EFFECT=()
  local broker_pid='' server_pid='' runtime=''
  json_quote "$TEST_DIR/fixtures/hardening_mcp.zsh"
  MCP_ARGS[$name]="[$REPLY]"
  {
    mcp_broker_start "$name"
    assert_success 'headless MCP framing fixture starts' $?
    broker_pid="${MCP_BROKER_PID[$name]}"; runtime="${MCP_BROKER_DIR[$name]}"
    server_pid="${mapfile[$runtime/ready]}"
    mcp_broker_request "$name" R 1 '{"jsonrpc":"2.0","id":1,"method":"test"}' 0.15
    assert_failure 'headless MCP partial frame times out' $?
    assert_eq '' "${MCP_BROKER_PID[$name]:-}" 'headless timeout removes the unusable broker'
    assert_contains "${MCP_DETAIL[$name]}" 'reconnect on next use' 'headless timeout permits a fresh transport next time'
    kill -0 "$broker_pid" 2>/dev/null
    assert_failure 'headless timeout reaps the broker process' $?
  } always {
    mcp_broker_stop "$name"
    [[ -n "$server_pid" ]] && kill -KILL "$server_pid" 2>/dev/null || true
  }
}
hardening_protocol_tests

hardening_remote_goal_test() {
  local ZCODER_SESSIONS_DIR="$TEST_TMP/protocol-goal-sessions" CURRENT_SESSION_ID=9000000002_1
  local ZCODER_WORKSPACE="$TEST_TMP" ZCODER_PROFILE=coding SESSION_TITLE='Remote goal'
  local STATE_SAVED_SESSION_ID='' STATE_SAVED_SNAPSHOT='' STATE_ERROR=''
  local REMOTE_SESSION_ID="$CURRENT_SESSION_ID" REMOTE_TURN_ID=test REMOTE_RUNTIME_DIR="$TEST_TMP/protocol-goal-runtime"
  local GOAL_STATUS=active GOAL_BLOCK_REASON='' GOAL_ID=test GOAL_OBJECTIVE=fixture
  local -i STATE_ENABLED=1 STATE_LOADING=0 AGENT_COMPACTION_COUNT=0 UI_PERSIST_DIRTY_FROM=0
  local -a AGENT_MESSAGES=('{"role":"user","content":"fixture"}') AGENT_USER_MESSAGES=(fixture) SKILL_ACTIVE_NAMES=()
  local -a UI_ROLES=() UI_CONTENTS=() UI_THINKINGS=() UI_TIMES=() UI_REASONING_OPEN=() UI_IDS=()
  local -A saved=()
  local snapshot='' next='' name='' notices=''
  for name in input_queue_close remote_server_emit_message remote_server_emit_status _remote_server_publish_json; do
    saved[$name]="${functions[$name]}"
  done
  input_queue_close() { :; }
  remote_server_emit_message() { notices+="$1:$2"; }
  remote_server_emit_status() { :; }
  _remote_server_publish_json() { :; }
  {
    state_save_session
    assert_success 'remote cancellation fixture saves an active goal' $?
    state_snapshot_dir "$ZCODER_SESSIONS_DIR/$CURRENT_SESSION_ID.session"; snapshot="$REPLY"
    zf_mkdir -p "$REMOTE_RUNTIME_DIR"
    # An already-exited worker still requires its committed goal to be paused.
    mapfile[$REMOTE_RUNTIME_DIR/active.pid]=99999999
    _remote_server_cancel_turn
    assert_success 'remote cancellation updates an exited worker goal' $?
    state_snapshot_dir "$ZCODER_SESSIONS_DIR/$CURRENT_SESSION_ID.session"; next="$REPLY"
    assert_eq paused "${mapfile[$next/goal_status]}" 'remote cancellation commits the paused goal status'
    assert_eq 'remote goal execution stopped by user' "${mapfile[$next/goal_block_reason]}" 'remote cancellation commits its reason'
    assert_eq active "${mapfile[$snapshot/goal_status]}" 'remote cancellation preserves the prior immutable generation'
    assert_eq active "$GOAL_STATUS" 'detached cancellation does not replace listener goal state'
    assert_eq '' "$notices" 'successful goal persistence emits no save error'
  } always {
    for name in "${(@k)saved}"; do functions[$name]="${saved[$name]}"; done
  }
}
hardening_remote_goal_test
