typeset -g context_base="$TEST_TMP/context" context_chunk=''
context_wait() {
  local file="$1" expected="$2"
  local -F deadline=$(( EPOCHREALTIME + 10.0 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r context-ui context_chunk 2>/dev/null; do :; done
    [[ "${mapfile[$file]:-}" == "$expected"* ]] && return 0
    zselect -t 1
  done
  return 1
}
context_server() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/context_server.zsh" "$PROJECT_DIR" "$context_base"
}
context_fixture() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/context_ui.zsh" "$PROJECT_DIR" "$context_base"
}
context_server >/dev/null 2> "$context_base.server_log" &
typeset -g context_server_pid=$!
context_wait "$context_base.endpoint" 127.
assert_success "context fixture starts a native TCP listener" $?
TERM=xterm-256color zpty -b context-ui context_fixture
context_wait "$context_base.started" cancel
assert_success "warm-up preparation uses responsive context discovery" $?
zpty -w -n context-ui $'draft\e[200~one\ntwo\e[201~'
context_wait "$context_base.draft" $'draftone\ntwo'
assert_success "context discovery admits draft editing and bracketed paste" $?
zpty -w -n context-ui $'\t\eOH\r'
context_wait "$context_base.view" chat:0:80
assert_success "context discovery admits transcript folding" $?
context_tty="${mapfile[$context_base.tty]:-}"
[[ -c "$context_tty" ]] && command stty cols 60 < "$context_tty"
context_wait "$context_base.view" chat:0:60
assert_success "context discovery admits terminal resize" $?
zpty -w -n context-ui $'\e'
context_wait "$context_base.cancelled" '130:0:1:0:'
assert_success "Escape cancels context preparation before warm-up is sent" $?
assert_eq $'/api/ps\n' "${mapfile[$context_base.requests_cancel]:-}" "cancelled preparation never sends an Ollama chat request"
context_wait "$context_base.eof_cancel" 5
assert_success "context cancellation closes the pending TCP connection" $?
context_wait "$context_base.success" '0:98304:0'
assert_success "the next preparation retries and adopts the loaded context allocation" $?
context_wait "$context_base.started" modal
assert_success "warm-up completion starts context discovery beneath an open modal" $?
context_wait "$context_base.modal" '60:1:0'
assert_success "background context discovery never enters an activity wait beneath the modal" $?
[[ -c "$context_tty" ]] && command stty cols 80 < "$context_tty"
context_wait "$context_base.modal" '80:1:0'
assert_success "the modal resizes while its post-warm-up context request stalls" $?
zpty -w -n context-ui $'\e'
context_wait "$context_base.modal_closed" '0:0:1:0'
assert_success "Escape closes the modal without stealing its input for context cancellation" $?
mapfile[$context_base.release_modal]=1
context_wait "$context_base.modal_result" '98304:0:generation body:generation error:assistant response:read_file'
assert_success "background collection preserves generation transport and tool response state" $?
assert_eq 1 "${mapfile[$context_base.parser_preserved]:-}" "background context parsing preserves the caller's tokenizer state"
for context_phase in malformed timeout stale shutdown; do
  context_wait "$context_base.result_$context_phase" '98304:1:'
  assert_success "$context_phase context discovery keeps the last allocation and releases its worker" $?
done
for context_phase in timeout stale shutdown; do
  context_wait "$context_base.eof_$context_phase" 5
  assert_success "$context_phase context discovery closes its TCP connection" $?
done
context_wait "$context_base.done" 1
assert_success "context discovery fixture shuts down cleanly" $?
assert_eq 0 "${mapfile[$context_base.scratch]:-}" "context discovery releases all HTTP spools"
zpty -d context-ui
kill -TERM "$context_server_pid" 2>/dev/null || true
wait "$context_server_pid" 2>/dev/null || true
unfunction context_wait context_server context_fixture
