# Both tests use real native workers and curses; only delayed command/server
# completion is controlled by fixtures and private files.
typeset -g wait_pty_base='' wait_pty_output='' wait_pty_chunk='' wait_pty_fixture=''
tool_wait_pty_wait() {
  local file="$1" expected="$2"
  local -F deadline=$(( EPOCHREALTIME + 10.0 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r tool-wait wait_pty_chunk 2>/dev/null; do wait_pty_output+="$wait_pty_chunk"; done
    [[ "${mapfile[$file]:-}" == "$expected"* ]] && return 0
    zselect -t 1 2>/dev/null
  done
  return 1
}
tool_wait_pty_run() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/$wait_pty_fixture" "$PROJECT_DIR" "$wait_pty_base"
}
wait_pty_base="$TEST_TMP/patch-wait"; wait_pty_fixture=patch_wait_ui.zsh
TERM=xterm-256color zpty -b tool-wait tool_wait_pty_run
tool_wait_pty_wait "$wait_pty_base.started" check
assert_success "patch validation starts through the real process runner" $?
zpty -w -n tool-wait draft
tool_wait_pty_wait "$wait_pty_base.draft" draft
assert_success "typing remains responsive during patch validation" $?
zpty -w -n tool-wait $'\e'
tool_wait_pty_wait "$wait_pty_base.check_cancelled" '130:1:1:1:before'
assert_success "cancelling validation prevents mutation and fallback, retaining the patch guard" $?
tool_wait_pty_wait "$wait_pty_base.started" apply
assert_success "a real patch can finish its mutation while completion is pending" $?
zpty -w -n tool-wait $'\e'
tool_wait_pty_wait "$wait_pty_base.apply_cancelled" '130:1:1:2:'
assert_success "cancelling patch application never starts a fallback engine" $?
assert_contains "${mapfile[$wait_pty_base.apply_cancelled]:-}" 'not rolled back' "patch cancellation reports that completed changes remain"
assert_eq $'after\n' "${mapfile[$wait_pty_base.changed]:-}" "cancellation does not claim or attempt to undo a completed patch"
tool_wait_pty_wait "$wait_pty_base.success" '1:0:2:after'
assert_success "successful asynchronous check and application clear the parent retry guard" $?
tool_wait_pty_wait "$wait_pty_base.fallback" '1:0:3:AFTER'
assert_success "ordinary diff rejection still permits a checked asynchronous patch fallback" $?
tool_wait_pty_wait "$wait_pty_base.confined" '0:1:outside'
assert_success "asynchronous patch execution preserves workspace confinement and rejects unsafe fallback" $?
assert_eq 0 "${mapfile[$wait_pty_base.write_guard]:-}" "interrupted patches still block replacement through write_file"
tool_wait_pty_wait "$wait_pty_base.done" 1
assert_success "patch execution restores terminal ownership" $?
assert_eq 0 "${mapfile[$wait_pty_base.scratch]:-}" "patch scratch files are removed on success and cancellation"
zpty -d tool-wait

wait_pty_base="$TEST_TMP/mcp-wait"; wait_pty_fixture=mcp_wait_ui.zsh; wait_pty_output=''
TERM=xterm-256color zpty -b tool-wait tool_wait_pty_run
tool_wait_pty_wait "$wait_pty_base.started" first
assert_success "an MCP tool call waits on a real stdio broker" $?
zpty -w -n tool-wait $'draft\e[200~one\ntwo\e[201~'
tool_wait_pty_wait "$wait_pty_base.draft" $'draftone\ntwo'
assert_success "MCP waits preserve draft editing and multiline paste" $?
zpty -w -n tool-wait $'\t\eOH\r'
tool_wait_pty_wait "$wait_pty_base.state" '80:chat:0'
assert_success "transcript selection and folding work during an MCP request" $?
wait_pty_tty="${mapfile[$wait_pty_base.tty]:-}"
[[ -n "$wait_pty_tty" && -c "$wait_pty_tty" ]] && command stty cols 60 < "$wait_pty_tty"
tool_wait_pty_wait "$wait_pty_base.state" '60:chat:0'
assert_success "MCP waits process terminal resize events" $?
mapfile[$wait_pty_base.release-first]=1
tool_wait_pty_wait "$wait_pty_base.success" '1:connected:1:'
assert_success "MCP completion preserves the parent's live broker connection" $?
assert_contains "${mapfile[$wait_pty_base.success]:-}" reply-first "the parent receives the completed MCP result"
tool_wait_pty_wait "$wait_pty_base.started" cancel
assert_success "the broker accepts a second call with a deliberately partial reply" $?
zpty -w -n tool-wait $'\e'
tool_wait_pty_wait "$wait_pty_base.cancelled" '130:1:configured:0:0:'
assert_success "Escape cancels a partial MCP reply and disconnects its broker" $?
assert_eq clean "${mapfile[$wait_pty_base.inherited_cleanup]:-}" "broker cancellation never executes the parent's EXIT cleanup"
tool_wait_pty_wait "$wait_pty_base.fresh" '1:'
assert_success "a cancelled MCP connection can reconnect for a fresh request" $?
assert_contains "${mapfile[$wait_pty_base.fresh]:-}" reply-fresh "fresh requests cannot consume a cancelled request's reply"
tool_wait_pty_wait "$wait_pty_base.approval" 1
assert_success "external MCP writes still wait for explicit approval" $?
zpty -w -n tool-wait n
tool_wait_pty_wait "$wait_pty_base.denied" '0:1'
assert_success "denying an external action sends no tools/call to the server" $?
tool_wait_pty_wait "$wait_pty_base.approval" 2
assert_success "a subsequent external write asks again" $?
zpty -w -n tool-wait y
tool_wait_pty_wait "$wait_pty_base.started" write
assert_success "approval admits the exact external MCP call" $?
zpty -w -n tool-wait $'\e'
tool_wait_pty_wait "$wait_pty_base.write_cancelled" '1:'
assert_success "an approved external MCP request remains cancellable" $?
assert_contains "${mapfile[$wait_pty_base.write_cancelled]:-}" 'may still be running' "cancellation never claims to undo or stop external side effects"
assert_eq applied "${mapfile[$wait_pty_base.external_effect]:-}" "already-completed external effects remain recorded"
tool_wait_pty_wait "$wait_pty_base.timeout" '0:0:configured:0:'
assert_success "a partial MCP reply times out and disconnects without hanging the UI" $?
tool_wait_pty_wait "$wait_pty_base.done" 1
assert_success "MCP wait cleanup restores terminal and transport ownership" $?
zpty -d tool-wait
unfunction tool_wait_pty_wait tool_wait_pty_run

# A process deadline is different from an ordinary git rejection: attempting
# the fallback after it could repeat a partially completed mutation.
functions[_tool_wait_saved_process]="${functions[tool_process_run]}"
typeset -gi tool_wait_process_calls=0
tool_process_run() {
  (( tool_wait_process_calls++ ))
  TOOL_PROCESS_TIMED_OUT=1; TOOL_PROCESS_CANCELLED=0; TOOL_PROCESS_ERROR=''; TOOL_PROCESS_OUTPUT=''
  return 124
}
UI_ACTIVE=1
tool_apply_patch $'--- a/note\n+++ b/note\n@@ -1 +1 @@\n-before\n+after\n'
assert_eq 124 "$?" "patch timeouts retain their distinct failure status"
assert_eq 1 "$tool_wait_process_calls" "patch timeouts never invoke another engine"
assert_eq 1 "$TOOL_PATCH_RETRY_REQUIRED" "patch timeouts preserve the parent retry guard"
assert_contains "$TOOL_RESULT" 'no fallback attempted' "patch timeout results explain the interrupted operation"
functions[tool_process_run]="${functions[_tool_wait_saved_process]}"
unfunction _tool_wait_saved_process
