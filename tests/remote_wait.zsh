typeset -g remote_wait_base="$TEST_TMP/remote-wait" remote_wait_chunk=''
remote_wait_for() {
  local file="$1" expected="$2"
  local -F deadline=$(( EPOCHREALTIME + 12.0 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r remote-wait remote_wait_chunk 2>/dev/null; do :; done
    [[ "${mapfile[$file]:-}" == "$expected"* ]] && return 0
    zselect -t 1
  done
  return 1
}
remote_wait_fixture() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/remote_wait_ui.zsh" "$PROJECT_DIR" "$remote_wait_base"
}
TERM=xterm-256color zpty -b remote-wait remote_wait_fixture
remote_wait_for "$remote_wait_base.started" success:/v1/events
assert_success "a real remote event response can stall midway through HTTP framing" $?
zpty -w -n remote-wait $'draft\e[200~one\ntwo\e[201~'
remote_wait_for "$remote_wait_base.draft" $'draftone\ntwo'
assert_success "remote HTTP waits accept draft editing and bracketed paste" $?
zpty -w -n remote-wait $'\t\eOH\r'
remote_wait_for "$remote_wait_base.state" '80:chat:0'
assert_success "remote HTTP waits preserve transcript selection and folding" $?
remote_wait_tty="${mapfile[$remote_wait_base.tty]:-}"
[[ -c "$remote_wait_tty" ]] && command stty cols 60 < "$remote_wait_tty"
remote_wait_for "$remote_wait_base.state" '60:chat:0'
assert_success "remote HTTP waits process terminal resize" $?
mapfile[$remote_wait_base.release]=1
remote_wait_for "$remote_wait_base.result_success" '0:0:Ready:Remote reply 世界'
assert_success "authenticated HTTP completion returns the exact remote reply and releases activity" $?
for remote_wait_phase in events_cancel submit_cancel; do
  remote_wait_for "$remote_wait_base.started" "$remote_wait_phase:"
  assert_success "$remote_wait_phase reaches its in-flight HTTP wait" $?
  zpty -w -n remote-wait $'\e'
  remote_wait_for "$remote_wait_base.result_$remote_wait_phase" '130:0:Stopped:'
  assert_success "$remote_wait_phase sends an explicit stop and preserves cancellation status" $?
  assert_contains "${mapfile[$remote_wait_base.message_$remote_wait_phase]:-}" 'acknowledged' "$remote_wait_phase reports the server acknowledgement"
  assert_eq 5 "${mapfile[$remote_wait_base.eof_$remote_wait_phase]:-}" "$remote_wait_phase closes its stalled TCP connection"
done
for remote_wait_phase in approval_deny approval_allow; do
  remote_wait_for "$remote_wait_base.approval_ready" "$remote_wait_phase"
  assert_success "$remote_wait_phase waits for explicit external-action approval" $?
  if [[ "$remote_wait_phase" == approval_deny ]]; then zpty -w -n remote-wait n
  else zpty -w -n remote-wait y
  fi
  remote_wait_for "$remote_wait_base.started" "$remote_wait_phase:/v1/approval"
  assert_success "$remote_wait_phase keeps input responsive while transmitting the decision" $?
  zpty -w -n remote-wait $'\e'
  remote_wait_for "$remote_wait_base.result_$remote_wait_phase" '130:0:Stopped:'
  assert_success "$remote_wait_phase can stop after the approval was already sent" $?
done
assert_eq '{"id":"exact-approval","decision":"n"}' "${mapfile[$remote_wait_base.approval_approval_deny]:-}" "denial transmits the exact negative approval decision"
assert_eq '{"id":"exact-approval","decision":"y"}' "${mapfile[$remote_wait_base.approval_approval_allow]:-}" "approval transmits only the explicitly accepted decision"
for remote_wait_phase in approval_deny approval_allow; do
  assert_eq $'POST:/v1/turn\nGET:/v1/events?after=0\nPOST:/v1/approval\nPOST:/v1/cancel\n' "${mapfile[$remote_wait_base.requests_$remote_wait_phase]:-}" "$remote_wait_phase never replays the transmitted decision"
done
remote_wait_for "$remote_wait_base.started" cancel_unconfirmed:/v1/events
zpty -w -n remote-wait $'\e'
remote_wait_for "$remote_wait_base.result_cancel_unconfirmed" '130:0:Stop unconfirmed:'
assert_success "an unresponsive cancellation endpoint has a bounded acknowledgement wait" $?
assert_contains "${mapfile[$remote_wait_base.message_cancel_unconfirmed]:-}" 'may still be running' "missing acknowledgement never claims remote work stopped"
for remote_wait_phase in warmup_cancel poll_cancel; do
  remote_wait_for "$remote_wait_base.started" "$remote_wait_phase:"
  assert_success "$remote_wait_phase reaches responsive remote model preparation" $?
  zpty -w -n remote-wait $'\e'
  remote_wait_for "$remote_wait_base.result_$remote_wait_phase" '130:0:Stopped:'
  assert_success "$remote_wait_phase stops before submitting a prompt" $?
  assert_not_contains "${mapfile[$remote_wait_base.requests_$remote_wait_phase]:-}" /v1/turn "$remote_wait_phase never sends the cancelled prompt"
  assert_not_contains "${mapfile[$remote_wait_base.requests_$remote_wait_phase]:-}" /v1/cancel "$remote_wait_phase leaves remote model preparation alone"
done
remote_wait_for "$remote_wait_base.result_timeout" '1:0:Error:'
assert_success "remote request deadlines remain distinct from user cancellation" $?
remote_wait_for "$remote_wait_base.done" 1
assert_success "remote HTTP waits finish without leaked terminal ownership" $?
assert_eq "1:$remote_wait_base.unrelated" "${mapfile[$remote_wait_base.isolated]:-}" "remote HTTP workers preserve unrelated HTTP ownership"
assert_eq 0 "${mapfile[$remote_wait_base.scratch]:-}" "remote HTTP workers remove completion and cancellation scratch files"
[[ ! -e "$remote_wait_base.auth_failed" ]]
assert_success "every asynchronous remote request carries the bearer header" $?
assert_eq $'POST:/v1/turn\nPOST:/v1/cancel\n' "${mapfile[$remote_wait_base.requests_submit_cancel]:-}" "an interrupted submission is never replayed"
zpty -d remote-wait
unfunction remote_wait_for remote_wait_fixture

test_remote_error_classification() {
  local saved_http_request="${functions[http_request]}"
  local -i UI_ACTIVE=0 REMOTE_REQUEST_CANCELLED=0 classified_response=1
  local REMOTE_ERROR='' HTTP_ERROR='' HTTP_BODY=''
  {
    http_request() {
      HTTP_ERROR='Ollama HTTP error: HTTP/1.1 409 Conflict'
      if (( classified_response )); then HTTP_BODY='{"error":"model is warming"}'
      else HTTP_BODY=''; HTTP_ERROR='Ollama closed the connection before returning an HTTP response'
      fi
      return 1
    }
    remote_client_request POST /v1/turn '{}'
    assert_eq 'model is warming' "$REMOTE_ERROR" "explicit server rejection preserves the model-readiness retry signal"
    classified_response=0
    remote_client_request POST /v1/turn '{}'
    assert_contains "$REMOTE_ERROR" 'may already have acted' "transport failure preserves uncertainty about a sent mutation"
  } always { functions[http_request]="$saved_http_request"; }
}
test_remote_error_classification
unfunction test_remote_error_classification
