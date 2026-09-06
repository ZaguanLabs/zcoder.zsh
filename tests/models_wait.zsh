typeset -g models_base="$TEST_TMP/models" models_chunk='' models_output=''
models_wait() {
  local file="$1" expected="$2"
  local -F deadline=$(( EPOCHREALTIME + 10.0 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r models-ui models_chunk 2>/dev/null; do models_output+="$models_chunk"; done
    [[ "${mapfile[$file]:-}" == "$expected"* ]] && return 0
    zselect -t 1
  done
  return 1
}
models_server() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/models_server.zsh" "$PROJECT_DIR" "$models_base"
}
models_fixture() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/models_ui.zsh" "$PROJECT_DIR" "$models_base"
}
if ! { zf_mkdir "$models_base.bin" &&
    zcoder_write_text_file "$models_base.bin/opencode" "${mapfile[$TEST_DIR/fixtures/models_opencode.zsh]}" &&
    zf_chmod 700 "$models_base.bin/opencode"; }; then
  assert_success "model discovery fixture creates its private executable" 1
  return 1
fi
models_server >/dev/null 2> "$models_base.server_log" &
typeset -g models_server_pid=$!
models_wait "$models_base.endpoint" 127.
assert_success "model discovery fixture starts a native TCP listener" $?
TERM=xterm-256color zpty -b models-ui models_fixture
models_wait "$models_base.started" cancel
assert_success "Ollama model discovery waits for a complete response" $?
zpty -w -n models-ui $'draft\e[200~one\ntwo\e[201~'
models_wait "$models_base.draft" $'draftone\ntwo'
assert_success "model discovery admits draft editing and multiline paste" $?
zpty -w -n models-ui $'\t\eOH\r'
models_wait "$models_base.view" chat:0:80
assert_success "transcript folding remains available while models load" $?
models_tty="${mapfile[$models_base.tty]:-}"
[[ -c "$models_tty" ]] && command stty cols 60 < "$models_tty"
models_wait "$models_base.view" chat:0:60
assert_success "model discovery admits terminal resize" $?
zpty -w -n models-ui $'\e'
models_wait "$models_base.result_cancel" '130:alpha:Ready:0:0:0'
assert_success "Escape cancels discovery without changing the model or reporting an error" $?
models_wait "$models_base.eof_cancel" 5
assert_success "cancelled Ollama discovery closes its connection" $?
models_wait "$models_base.modal" success:1:1
assert_success "a complete Ollama catalog opens the model picker" $?
zpty -w -n models-ui $'\eOB\r'
models_wait "$models_base.result_success" '0:beta:Ready:2:0:0'
assert_success "the Ollama picker commits only the accepted model" $?
models_wait "$models_base.result_malformed" '1:beta:Error:0:0:0'
assert_success "malformed catalogs preserve the selected model and discard old choices" $?
models_wait "$models_base.result_timeout" '1:beta:Error:0:0:0'
assert_success "an Ollama discovery deadline returns control without changing the model" $?
models_wait "$models_base.eof_timeout" 5
assert_success "a discovery deadline closes the stalled TCP connection" $?
models_wait "$models_base.warmup_result" '0:{"warmup":true}'
assert_success "model discovery leaves an existing warm-up result collectable" $?
assert_eq '1:1' "${mapfile[$models_base.warmup_owned]:-}" "discovery preserves parent warm-up worker ownership"
models_wait "$models_base.command_started" opencode_cancel:
assert_success "OpenCode discovery starts the exact models command in a worker" $?
models_command_pid="${${mapfile[$models_base.command_started]}##*:}"
zpty -w -n models-ui $'\tZ'
models_wait "$models_base.draft" $'draftone\ntwoZ'
assert_success "OpenCode model discovery preserves and admits draft edits" $?
zpty -w -n models-ui $'\e'
models_wait "$models_base.result_opencode_cancel" '130:provider/alpha:Ready:0:0:0:'
assert_success "OpenCode cancellation discards partial choices and restores activity ownership" $?
kill -0 "$models_command_pid" 2>/dev/null
assert_failure "OpenCode cancellation stops the discovery command" $?
models_wait "$models_base.modal" opencode_success:1:1
assert_success "a successful OpenCode catalog opens the shared picker" $?
zpty -w -n models-ui $'\eOB\r'
models_wait "$models_base.result_opencode_success" '0:provider/beta:Ready:2:0:0:'
assert_success "OpenCode discovery commits the selected provider/model" $?
models_wait "$models_base.result_opencode_failure" '1:provider/beta:Error:0:0:0:'
assert_success "failed OpenCode discovery retains the selected model" $?
models_wait "$models_base.result_opencode_large" '1:provider/beta:Error:0:0:0:'
assert_success "oversized OpenCode catalogs cannot publish partial model choices" $?
models_wait "$models_base.result_opencode_timeout" '1:provider/beta:Error:0:0:0:'
assert_success "OpenCode discovery deadlines discard partial output and clean up" $?
models_wait "$models_base.done" 1
assert_success "model discovery fixtures restore the terminal" $?
assert_eq 0 "${mapfile[$models_base.scratch]:-}" "model discovery cleans all worker spools"
assert_not_contains "$models_output" PRIVATE_MODEL_WORKER "model discovery commands cannot write to the application terminal"
zpty -d models-ui
kill -TERM "$models_server_pid" 2>/dev/null || true
wait "$models_server_pid" 2>/dev/null || true
unfunction models_wait models_server models_fixture
