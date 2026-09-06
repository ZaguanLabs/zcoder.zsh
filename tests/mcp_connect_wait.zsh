typeset -g connect_base="$TEST_TMP/connect-wait" connect_chunk=''
connect_wait() {
  local file="$1" expected="$2"
  local -F deadline=$(( EPOCHREALTIME + 10.0 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r connect-wait connect_chunk 2>/dev/null; do :; done
    [[ "${mapfile[$file]:-}" == "$expected"* ]] && return 0
    zselect -t 1
  done
  return 1
}
connect_fixture() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/mcp_connect_ui.zsh" "$PROJECT_DIR" "$connect_base"
}
TERM=xterm-256color zpty -b connect-wait connect_fixture
connect_wait "$connect_base.started" startup
assert_success "MCP startup waits expose an activity loop before broker readiness" $?
zpty -w -n connect-wait draft
connect_wait "$connect_base.draft" draft
assert_success "draft editing works while an MCP broker starts" $?
zpty -w -n connect-wait $'\e'
connect_wait "$connect_base.start_cancelled" '130:1:0:0:0'
assert_success "startup cancellation releases its broker and stops connecting remaining servers" $?
connect_wait "$connect_base.started" discover_cancel
assert_success "model preparation starts MCP discovery without sending a model request" $?
zpty -w -n connect-wait $'\e[200~one\ntwo\e[201~'
connect_wait "$connect_base.draft" $'draftone\ntwo'
assert_success "partial discovery replies permit multiline paste" $?
zpty -w -n connect-wait $'\t\eOH\r'
connect_wait "$connect_base.state" '80:chat:0:0'
assert_success "connection preparation supports transcript folding" $?
connect_tty="${mapfile[$connect_base.tty]:-}"
[[ -c "$connect_tty" ]] && command stty cols 60 < "$connect_tty"
connect_wait "$connect_base.state" '60:chat:0:0'
assert_success "connection preparation handles terminal resize" $?
zpty -w -n connect-wait $'\e'
connect_wait "$connect_base.turn_cancelled" '130:1:0:0:configured'
assert_success "discovery cancellation stops the actual agent turn before Ollama dispatch" $?
[[ ! -e "$connect_base.sent" ]]
assert_success "a cancelled catalog never reaches the model" $?
assert_eq $'server/discover\n' "${mapfile[$connect_base.discover_methods]:-}" "cancelled modern discovery never tries legacy negotiation"
connect_wait "$connect_base.started" pages_cancel
assert_success "paginated tool discovery remains cancellable after its first page" $?
zpty -w -n connect-wait $'\e'
connect_wait "$connect_base.pages_cancelled" '130:1:empty:0'
assert_success "cancelling pagination never publishes a partial tool catalog" $?
connect_wait "$connect_base.success" 'connected:2:2026-07-28'
assert_success "reconnection publishes all tool pages with a fresh broker" $?
connect_wait "$connect_base.started" legacy_cancel
assert_success "a valid unsupported-method response still enables legacy negotiation" $?
zpty -w -n connect-wait $'\e'
connect_wait "$connect_base.legacy_cancelled" '130:1:0'
assert_success "legacy initialization cancellation closes its broker" $?
connect_wait "$connect_base.legacy_success" 'connected:2:2025-11-25'
assert_success "legacy initialization and pagination complete after reconnection" $?
connect_wait "$connect_base.timeout" '1:0:0:server/discover'
assert_success "discovery timeout releases the broker without being reported as user cancellation" $?
assert_eq $'1:0:0:server/discover\n' "${mapfile[$connect_base.timeout]:-}" "a broken discovery transport never attempts protocol fallback"
connect_wait "$connect_base.inspector" connected
assert_success "the MCP inspector opens after successful reconnection" $?
zpty -w -n connect-wait r
connect_wait "$connect_base.started" discover_overlay
assert_success "restart from the MCP inspector starts a new connection" $?
zpty -w -n connect-wait $'\tZ'
connect_wait "$connect_base.draft" $'draftone\ntwoZ'
assert_success "inspector restart releases the overlay so draft edits stay visible" $?
assert_eq '60:input:0:0' "${mapfile[$connect_base.state]:-}" "connection activity owns input without an overlapping modal"
zpty -w -n connect-wait $'\e'
connect_wait "$connect_base.inspector" configured
assert_success "the inspector reopens after connection cancellation" $?
zpty -w -n connect-wait $'\e'
connect_wait "$connect_base.overlay_done" '0:0:configured'
assert_success "cancelled inspector restart restores the modal and activity ownership" $?
connect_wait "$connect_base.done" 1
assert_success "MCP connection tests release terminal and transport resources" $?
zpty -d connect-wait
unfunction connect_wait connect_fixture

# Consumers must propagate cancellation before issuing network work or
# replacing conversation history. Exercise them independently of curses.
test_mcp_cancel_consumers() {
  local -a MCP_NAMES=(fixture) AGENT_MESSAGES=('{"role":"user","content":"keep this"}')
  local AGENT_TOOL_PHASE=full ZCODER_TOOL_EXPOSURE=full ZCODER_WARMUP=true REMOTE_MODE=local
  local AGENT_COMPACTION_SUMMARY='' REPLY='' HTTP_ERROR='' MCP_ERROR=''
  local -i UI_ACTIVE=1 GOAL_VERIFIER_ACTIVE=0 AGENT_WARMUP_ACTIVE=0 AGENT_CANCELLED=0
  local -i AGENT_COMPACTION_IN_PROGRESS=0 connect_network_calls=0
  local -A saved_functions=(
    mcp_tools_schema_json "${functions[mcp_tools_schema_json]}"
    http_async_start "${functions[http_async_start]}"
    agent_set_status "${functions[agent_set_status]}"
  )
  local function_name=''
  {
    mcp_tools_schema_json() { MCP_ERROR='MCP connection setup cancelled by user'; REPLY=''; return 130; }
    http_async_start() { (( connect_network_calls++ )); return 0; }
    agent_set_status() { :; }
    agent_warmup_start
    assert_eq 130 "$?" "warm-up preserves connection cancellation status"
    assert_eq 0 "$connect_network_calls" "cancelled warm-up preparation never starts an HTTP worker"
    assert_eq 0 "$AGENT_WARMUP_ACTIVE" "cancelled warm-up leaves no active request"
    agent_context_summary
    assert_eq 130 "$?" "context inspection propagates cancelled tool discovery"
    agent_compact_history manual
    assert_eq 130 "$?" "compaction stops when tool discovery is cancelled"
    assert_eq 0 "$AGENT_COMPACTION_IN_PROGRESS" "cancelled compaction restores its in-progress guard"
    assert_eq '{"role":"user","content":"keep this"}' "${AGENT_MESSAGES[1]}" "cancelled compaction preserves conversation history"
  } always {
    for function_name in ${(k)saved_functions}; do functions[$function_name]="${saved_functions[$function_name]}"; done
  }
}
test_mcp_cancel_consumers
unfunction test_mcp_cancel_consumers
