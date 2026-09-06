source "$PROJECT_DIR/lib/process.zsh"
functions[_process_saved_wait]="${functions[ui_wait_for_tool_process]}"
functions[_process_saved_poll]="${functions[ui_poll_activity]}"
ui_wait_for_tool_process() {
  while ! tool_process_ready; do
    tool_process_expired && return 124
    zselect -t 1 2>/dev/null
  done
  return 0
}
ui_poll_activity() { zselect -t 1 2>/dev/null; return 0; }
process_test_root="$TEST_TMP/process space's"
zf_mkdir -p -- "$process_test_root"
ZCODER_MAX_TOOL_OUTPUT=1000
tool_process_run "$process_test_root" 5 zsh -fc 'print -r -- "$PWD"; print -r -- "$1"; print -r -- stderr >&2; exit 7' worker '$(print unsafe); * literal'
assert_eq 7 "$?" "native tool workers preserve nonzero exit codes"
assert_contains "$TOOL_PROCESS_OUTPUT" "$process_test_root" "native tool workers enter a directory containing spaces and quotes"
assert_contains "$TOOL_PROCESS_OUTPUT" '$(print unsafe); * literal' "worker argv is never reparsed as shell source"
assert_contains "$TOOL_PROCESS_OUTPUT" stderr "worker output combines stdout and stderr"
assert_eq '' "$TOOL_PROCESS_NAME" "completed workers release their PTY identity"
assert_eq '' "$TOOL_PROCESS_PID" "completed workers release their process-group identity"
tool_process_run "$process_test_root/missing" 5 zsh -fc 'print should-not-run'
assert_eq 125 "$?" "a vanished working directory is not mistaken for a search with no matches"
assert_not_contains "$TOOL_PROCESS_OUTPUT" should-not-run "worker setup failure cannot execute the command"

ZCODER_MAX_TOOL_OUTPUT=120
tool_process_run "$process_test_root" 5 zsh -fc 'print -rn HEAD; print -rn -- ${(pl:10000::x:)}; print -rn TAIL'
assert_success "large command output is collected through bounded reads" $?
assert_contains "$TOOL_PROCESS_OUTPUT" HEAD "bounded output retains its beginning"
assert_contains "$TOOL_PROCESS_OUTPUT" TAIL "bounded output retains its ending"
assert_contains "$TOOL_PROCESS_OUTPUT" omitted "bounded output labels omitted content"
assert_success "bounded output respects the configured character limit" $(( ${#TOOL_PROCESS_OUTPUT} <= 120 ? 0 : 1 ))
ZCODER_MAX_TOOL_OUTPUT=32768

tool_process_run "$process_test_root" 1 zsh -fc 'trap "" TERM; print waiting; sleep 20'
assert_eq 124 "$?" "interactive tool deadlines need no external timeout utility"
assert_eq 1 "$TOOL_PROCESS_TIMED_OUT" "deadline expiry remains distinct from cancellation"
assert_contains "$TOOL_PROCESS_OUTPUT" waiting "timeout retains partial command output"
assert_eq '' "$TOOL_PROCESS_BASE" "timeout removes worker storage ownership"

tool_process_run "$process_test_root" 5 zsh -fc 'kill -KILL $PPID'
assert_failure "a crashed worker cannot publish a successful tool result" $?
assert_contains "$TOOL_PROCESS_ERROR" 'without a complete result' "worker crashes report missing completion"
tool_process_cleanup; tool_process_cleanup
assert_eq '' "$TOOL_PROCESS_NAME" "process cleanup is idempotent"
functions[ui_wait_for_tool_process]="${functions[_process_saved_wait]}"
functions[ui_poll_activity]="${functions[_process_saved_poll]}"
unfunction _process_saved_wait _process_saved_poll

typeset -g process_pty_base="$TEST_TMP/process-pty" process_pty_output='' process_pty_chunk=''
process_pty_wait() {
  local file="$1" expected="$2"
  local -F deadline=$(( EPOCHREALTIME + 8.0 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r process-ui process_pty_chunk 2>/dev/null; do process_pty_output+="$process_pty_chunk"; done
    [[ "${mapfile[$file]:-}" == "$expected"* ]] && return 0
    zselect -t 1 2>/dev/null
  done
  return 1
}
process_pty_run() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/process_ui.zsh" "$PROJECT_DIR" "$process_pty_base"
}
TERM=xterm-256color zpty -b process-ui process_pty_run
assert_success "responsive tool fixture starts in real curses" $?
process_pty_wait "$process_pty_base.approval" 1
assert_success "run_command approval is requested before starting its worker" $?
[[ ! -f "$process_pty_base.started" ]]
assert_success "commands cannot run before their exact approval" $?
zpty -w -n process-ui a
process_pty_wait "$process_pty_base.started" started
assert_success "session approval starts the approved command" $?
zpty -w -n process-ui $'next\e[200~one\ntwo\e[201~'
process_pty_wait "$process_pty_base.draft" $'nextone\ntwo'
assert_success "draft editing and multiline paste remain responsive during a shell command" $?
assert_not_contains "$process_pty_output" PRIVATE_WORKER_TTY "command writes to /dev/tty cannot own the application screen"
zpty -w -n process-ui $'\t\eOH\r'
process_pty_wait "$process_pty_base.fold" 'chat:0'
assert_success "transcript navigation and folding remain responsive during shell execution" $?
zpty -w -n process-ui $'\e'
process_pty_wait "$process_pty_base.cancelled" '130:allow:1:0::'
assert_success "Escape cancels the tool round while preserving the parent's session approval" $?
assert_contains "${mapfile[$process_pty_base.history]:-}" 'not executed because the user cancelled' "cancelled batches close remaining tool calls without executing them"
[[ ! -f "$process_pty_base.should-not-run" ]]
assert_success "cancelling a command prevents later tools in its batch from running"
assert_contains "${mapfile[$process_pty_base.history]:-}" 'not rolled back' "cancelled command results report possible completed side effects"
process_pty_wait "$process_pty_base.search" '1:1'
assert_success "search runs through the responsive process path and returns matching text" $?
assert_contains "${mapfile[$process_pty_base.search]:-}" 'process needle' "responsive search preserves matching results"
process_pty_wait "$process_pty_base.sysadmin" 1
assert_success "sysadmin commands still require exact approval under an allow policy" $?
zpty -w -n process-ui a
process_pty_wait "$process_pty_base.sysadmin_choice" 'a:0'
assert_success "sysadmin approval still rejects a session-wide answer" $?
zpty -w -n process-ui n
process_pty_wait "$process_pty_base.sysadmin_denied" '0:0'
assert_success "denied sysadmin commands never start a worker" $?
process_pty_wait "$process_pty_base.denied" '0:0'
assert_success "the deny policy never starts a process" $?
process_pty_wait "$process_pty_base.done" 1
assert_success "tool cancellation leaves curses and process state clean" $?
process_child="${mapfile[$process_pty_base.child]:-}"
process_child_running=0
if [[ "$process_child" == <1-> ]] && kill -0 "$process_child" 2>/dev/null; then
  process_child_state="${mapfile[/proc/${process_child}/status]:-}"
  [[ "$process_child_state" == *$'State:\tZ'* ]] || process_child_running=1
fi
assert_eq 0 "$process_child_running" "cancellation terminates a descendant that ignores TERM"
zpty -d process-ui
unfunction process_pty_wait process_pty_run

# A verifier's evidence search uses the same cancellation contract, and must
# not continue making model requests after the user stops that search.
functions[_process_saved_chat]="${functions[agent_ollama_chat]}"
functions[_process_saved_payload]="${functions[agent_build_payload]}"
functions[_process_saved_search]="${functions[tool_search]}"
typeset -gi process_verifier_requests=0
agent_build_payload() { REPLY='{}'; }
agent_ollama_chat() {
  (( process_verifier_requests++ ))
  HTTP_BODY='{"message":{"content":"","tool_calls":[{"function":{"name":"search","arguments":{"query":"evidence"}}}]}}'
  HTTP_ERROR=''
  return 0
}
tool_search() { TOOL_CANCELLED=1; TOOL_RESULT_OK=0; TOOL_RESULT='Error: search cancelled by user'; return 130; }
goal_verify_candidate 'Candidate awaiting evidence'
assert_eq 130 "$?" "cancelling a verifier search returns the goal pause signal"
assert_eq 1 "$process_verifier_requests" "cancelled verification cannot request another model turn"
assert_eq cancelled "$GOAL_VERIFIER_VERDICT" "cancelled evidence collection cannot become an acceptance verdict"
functions[agent_ollama_chat]="${functions[_process_saved_chat]}"
functions[agent_build_payload]="${functions[_process_saved_payload]}"
functions[tool_search]="${functions[_process_saved_search]}"
unfunction _process_saved_chat _process_saved_payload _process_saved_search
TOOL_CANCELLED=0
