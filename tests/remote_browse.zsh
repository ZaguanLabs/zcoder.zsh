typeset -g browse_base="$TEST_TMP/remote-browse" browse_chunk='' browse_pty=remote-browse
remote_browse_wait() {
  local file="$1" expected="$2"
  local -F deadline=$(( EPOCHREALTIME + 12.0 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r "$browse_pty" browse_chunk 2>/dev/null; do :; done
    [[ "${mapfile[$file]:-}" == "$expected"* ]] && return 0
    zselect -t 1
  done
  return 1
}
remote_browse_server() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/remote_browse_server.zsh" "$PROJECT_DIR" "$browse_base"
}
remote_browse_fixture() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/remote_browse_ui.zsh" "$PROJECT_DIR" "$browse_base"
}
remote_browse_application() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/remote_application.zsh" "$PROJECT_DIR" "$browse_base"
}
remote_browse_server >/dev/null 2> "$browse_base.server_log" &
typeset -g browse_server_pid=$!
remote_browse_wait "$browse_base.endpoint" 127.
assert_success "remote browsing fixture starts a native TCP listener" $?
TERM=xterm-256color zpty -b "$browse_pty" remote_browse_fixture
remote_browse_wait "$browse_base.started" list_cancel:
assert_success "remote session listing can pause after receiving its first page" $?
zpty -w -n "$browse_pty" $'draft\e'
remote_browse_wait "$browse_base.list_cancelled" '130:1000000000_1:1000000000_1'
assert_success "cancelled session pagination preserves the published list and selection" $?
remote_browse_wait "$browse_base.started" select_cancel:
zpty -w -n "$browse_pty" $'\t\eOH\r'
remote_browse_wait "$browse_base.view" '1000000000_1:Original conversation:0:80'
assert_success "a staged remote transcript leaves the original conversation visible and foldable" $?
browse_tty="${mapfile[$browse_base.tty]:-}"
[[ -c "$browse_tty" ]] && command stty cols 60 < "$browse_tty"
remote_browse_wait "$browse_base.view" '1000000000_1:Original conversation:0:60'
assert_success "remote session loading remains responsive to resize" $?
zpty -w -n "$browse_pty" $'\e'
remote_browse_wait "$browse_base.select_cancelled" '130:1000000000_1:Original conversation:1'
assert_success "cancelling an acknowledged switch preserves the old view and requires reconciliation" $?
remote_browse_wait "$browse_base.started" reconcile_cancel:
zpty -w -n "$browse_pty" $'\e'
remote_browse_wait "$browse_base.reconcile_cancelled" '130:1000000000_1:Original conversation:1'
assert_success "cancelling reconciliation keeps the pending prompt unsent" $?
[[ ! -e "$browse_base.turn_reconcile_cancel" ]]
assert_success "cancelled reconciliation never reaches the turn endpoint" $?
remote_browse_wait "$browse_base.reconciled" '0:1000000000_2:Conversation 1000000000_2:0:saved-entry:1'
assert_success "successful reconciliation publishes transcript metadata and server selection together" $?
assert_eq '1000000000_2:Conversation 1000000000_2:0' "${mapfile[$browse_base.submitted_view]:-}" "the reconciled conversation is visible before a new prompt is submitted"
remote_browse_wait "$browse_base.started" new_cancel:
zpty -w -n "$browse_pty" $'\e'
remote_browse_wait "$browse_base.new_cancelled" '130:1000000000_2:Conversation 1000000000_2:1'
assert_success "an interrupted new-session reply retains the old conversation and uncertainty guard" $?
assert_eq $'POST:/v1/session/new\n' "${mapfile[$browse_base.requests_new_cancel]:-}" "uncertain session creation is never replayed"
remote_browse_wait "$browse_base.failed" '1:1000000000_2:Conversation 1000000000_2:1'
assert_success "malformed replacement transcripts do not overwrite the visible conversation" $?
[[ ! -e "$browse_base.turn_load_failure" ]]
assert_success "malformed reconciliation blocks prompt submission" $?
remote_browse_wait "$browse_base.new_success" '0:1000000000_4:Conversation 1000000000_4:0'
assert_success "a later explicit new session commits normally and clears uncertainty" $?
remote_browse_wait "$browse_base.idle_started" '1:0:1'
assert_success "idle model polling returns immediately without taking activity ownership" $?
remote_browse_wait "$browse_base.started" idle_cancel:
zpty -w -n "$browse_pty" $'\tZ'
remote_browse_wait "$browse_base.draft" draftZ
assert_success "a stalled background model poll leaves draft editing available" $?
mapfile[$browse_base.submit_idle]=1
remote_browse_wait "$browse_base.idle_superseded" '0:ready::0'
assert_success "a foreground prompt supersedes idle work and retains the fresh model state" $?
assert_eq 5 "${mapfile[$browse_base.eof_idle_cancel]:-}" "superseding an idle poll closes its TCP connection"
remote_browse_wait "$browse_base.idle_timeout" 'error::0:'
assert_success "an idle polling deadline releases its worker without blocking input" $?
remote_browse_wait "$browse_base.idle_success" 'ready::0'
assert_success "idle poll completion updates parent model state and releases its worker" $?
remote_browse_wait "$browse_base.done" 1
assert_success "session and idle polling fixtures restore terminal ownership" $?
assert_eq 0 "${mapfile[$browse_base.scratch]:-}" "session and idle HTTP spools are cleaned"
zpty -d "$browse_pty"

# Exercise the actual entrypoint: curses must own startup waits, and Enter
# must submit a draft while the ordinary idle loop has a pending model poll.
zcoder_write_text_file "$browse_base.token" fixture_token_012345678901234567890
zf_chmod 600 "$browse_base.token"
browse_pty=remote-startup
mapfile[$browse_base.phase]=startup_cancel
TERM=xterm-256color zpty -b "$browse_pty" remote_browse_application
remote_browse_wait "$browse_base.started" startup_cancel:/v1/hello
assert_success "the real interactive entrypoint starts its handshake after curses initialization" $?
zpty -w -n "$browse_pty" $'cancelled draft\e'
remote_browse_wait "$browse_base.application_exit" 130
assert_success "Escape cancels a real startup handshake and restores the terminal" $?
assert_eq 5 "${mapfile[$browse_base.eof_startup_cancel]:-}" "startup cancellation closes the pending connection"
zpty -d "$browse_pty"
zf_rm -f "$browse_base.application_exit"
mapfile[$browse_base.phase]=startup_success
TERM=xterm-256color zpty -b "$browse_pty" remote_browse_application
remote_browse_wait "$browse_base.started" startup_success:/v1/hello
zpty -w -n "$browse_pty" hello
mapfile[$browse_base.release_hello]=1
remote_browse_wait "$browse_base.started" startup_success:/v1/model
assert_success "startup completion starts background readiness polling in the real idle loop" $?
zpty -w -n "$browse_pty" $' world\r'
remote_browse_wait "$browse_base.turn_startup_success" '{"prompt":"hello world"'
assert_success "Enter submits the draft preserved across startup and a stalled idle poll" $?
zselect -t 20
zpty -w -n "$browse_pty" $'/quit\r'
remote_browse_wait "$browse_base.application_exit" 0
assert_success "the real application exits cleanly after superseding its background request" $?
zpty -d "$browse_pty"
[[ ! -e "$browse_base.auth_failed" ]]
assert_success "startup, browsing, and idle requests retain authentication" $?
kill -TERM "$browse_server_pid" 2>/dev/null || true
wait "$browse_server_pid" 2>/dev/null || true
unfunction remote_browse_wait remote_browse_server remote_browse_fixture remote_browse_application
