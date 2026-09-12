typeset -g integration_base="$TEST_TMP/tui-integration" integration_chunk='' integration_output=''
integration_wait() {
  local file="$1" expected="$2"
  local -F deadline=$(( EPOCHREALTIME + 12.0 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r local-application integration_chunk 2>/dev/null; do integration_output+="$integration_chunk"; done
    if [[ "$file" == output ]]; then
      [[ "$integration_output" == *"$expected"* ]] && return 0
    elif [[ "${mapfile[$file]:-}" == "$expected"* ]]; then return 0
    fi
    zselect -t 1
  done
  return 1
}
integration_server() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/local_application_server.zsh" "$PROJECT_DIR" "$integration_base"
}
integration_application() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/local_application.zsh" "$PROJECT_DIR" "$integration_base"
}
zf_mkdir -p "$integration_base.workspace" "$integration_base.tmp"
integration_server >/dev/null 2> "$integration_base.server_log" &
typeset -g integration_server_pid=$!
integration_wait "$integration_base.endpoint" 127.
assert_success "local entrypoint fixture starts a native Ollama listener" $?
TERM=xterm-256color zpty -b local-application integration_application
integration_wait "$integration_base.started" 1
assert_success "the actual local entrypoint gives curses ownership before context discovery" $?
zpty -w -n local-application $'preserved draft\e'
integration_wait "$integration_base.cancel_eof" 5
assert_success "Escape closes the startup context request in the actual application" $?
assert_eq $'/api/ps\n' "${mapfile[$integration_base.requests]:-}" "startup cancellation does not send a warm-up chat"
zpty -w -n local-application $'\x02\r'
integration_wait "$integration_base.chat_count" 1
assert_success "Enter after cancellation submits the preserved draft from the idle loop" $?
assert_contains "${mapfile[$integration_base.prompt]:-}" '"content":"preserved draft"' "the resumed local turn receives the exact preserved draft"
assert_contains "${mapfile[$integration_base.prompt]:-}" '"num_ctx":98304' "the resumed turn uses freshly discovered context allocation"
assert_contains "${mapfile[$integration_base.prompt]:-}" '"stream":true' "the actual ordinary local turn retains streaming"
integration_wait output 'Integration complete.'
assert_success "the actual entrypoint displays its completed streamed answer" $?
zpty -w -n local-application '/'
integration_wait output 'Tab/Enter Complete'
assert_success "typing slash in the actual entrypoint displays command suggestions" $?
zpty -w -n local-application $'co\eOB\eOA\t\r'
integration_wait output 'Context usage'
assert_success "the context inspector opens after the recovered turn" $?
zpty -w -n local-application $'\e'
zselect -t 20
integration_output=''
zpty -w -n local-application $'/sessions\r'
integration_wait output 'Sessions (1)'
assert_success "sessions command reveals the sidebar hidden by the idle Ctrl+B shortcut" $?
zpty -w -n local-application $'\x02/copy\r'
integration_wait output 'Press Enter to return:'
assert_success "the transcript copy view releases curses after the recovered turn" $?
zpty -w -n local-application $'\r'
zselect -t 20
# Another session's writer must not delay quitting this one. The final save
# only needs the current session; a redundant sidebar refresh would wait here.
typeset -g integration_busy_session="$integration_base.home/sessions/1_1.session"
typeset -g integration_quit_lock=''
zf_mkdir -p "$integration_busy_session"
print -rn -- '' > "$integration_busy_session/save.lock"
zsystem flock -f integration_quit_lock "$integration_busy_session/save.lock"
assert_success "quit fixture locks an unrelated session" $?
typeset -F integration_quit_started=$EPOCHREALTIME integration_quit_elapsed
zpty -w -n local-application $'/quit\r'
integration_wait "$integration_base.application_exit" 0
assert_success "the real application exits cleanly after modal and copy-view re-entry" $?
integration_quit_elapsed=$(( EPOCHREALTIME-integration_quit_started ))
assert_success "quit does not wait for an unrelated session writer" $(( integration_quit_elapsed < 1.0 ? 0 : 1 ))
zsystem flock -u "$integration_quit_lock"
zf_rm -r -- "$integration_busy_session"
integration_wait "$integration_base.terminal_restored" 1
assert_success "the real application restores its original terminal settings" $?
assert_eq 1 "${mapfile[$integration_base.chat_count]:-}" "inspector, copy, and quit commands never become model prompts"
typeset -a integration_sessions=("$integration_base.home"/sessions/*.session(N/))
assert_eq 1 "${#integration_sessions}" "the recovered interaction remains in one saved session"
if (( ${#integration_sessions} == 1 )); then
  state_snapshot_dir "$integration_sessions[1]"
  integration_snapshot="$REPLY"
  assert_eq 2 "${mapfile[$integration_snapshot/agent_message_count]:-}" "saved history contains only the user and completed assistant response"
  state_record_paths "$integration_snapshot" agent_messages 2
  assert_contains "${mapfile[$reply[2]]:-}" 'Integration complete.' "session persistence retains the final streamed response"
fi
typeset -a integration_scratch=("$integration_base.tmp"/*(ND))
assert_eq 0 "${#integration_scratch}" "the real entrypoint removes all private worker storage on exit"
zpty -d local-application
kill -TERM "$integration_server_pid" 2>/dev/null || true
wait "$integration_server_pid" 2>/dev/null || true
unfunction integration_wait integration_server integration_application

command zsh -f "$TEST_DIR/fixtures/long_transcript.zsh" "$PROJECT_DIR" "$integration_base.long"
assert_success "long-session rendering fixture completes" $?
assert_eq 1000 "${mapfile[$integration_base.long.initial]:-}" "initial layout covers a thousand retained conversation entries"
assert_eq '0:0' "${mapfile[$integration_base.long.idle]:-}" "one hundred idle refreshes do no layout or curses work"
assert_eq '0:0:20' "${mapfile[$integration_base.long.editing]:-}" "draft editing leaves the thousand-entry transcript untouched"
assert_eq '25:1001' "${mapfile[$integration_base.long.streaming]:-}" "twenty-five stream updates lay out only the changing entry"
assert_eq '0:501' "${mapfile[$integration_base.long.selection]:-}" "long-session selection reuses existing layout"
assert_eq '1001:501' "${mapfile[$integration_base.long.resize]:-}" "narrowing a long transcript rewraps once and preserves selection"

# zsh -n accepts one script, with subsequent words becoming its arguments.
# Exercise the real Makefile in isolation to ensure later files are checked.
integration_check_root="$TEST_TMP/syntax-check"
zf_mkdir -p "$integration_check_root/lib" "$integration_check_root/scripts" "$integration_check_root/tests/fixtures" "$integration_check_root/vendor/zjson/lib"
zcoder_write_text_file "$integration_check_root/Makefile" "${mapfile[$PROJECT_DIR/Makefile]}"
zcoder_write_text_file "$integration_check_root/scripts/setup-json.zsh" "${mapfile[$PROJECT_DIR/scripts/setup-json.zsh]}"
for integration_check_file in "$PROJECT_DIR/vendor/zjson/zjson.zsh" "$PROJECT_DIR"/vendor/zjson/lib/*.zsh; do
  zcoder_write_text_file "$integration_check_root/${integration_check_file#$PROJECT_DIR/}" "${mapfile[$integration_check_file]}"
done
for integration_check_file in zcoder.zsh chat.sh lib/valid.zsh scripts/valid.zsh tests/valid.zsh; do
  zcoder_write_text_file "$integration_check_root/$integration_check_file" ':'
done
zcoder_write_text_file "$integration_check_root/tests/fixtures/invalid.zsh" 'if then'
command make -s -C "$integration_check_root" check > "$integration_check_root/output" 2>&1
assert_failure "make check rejects a syntax error in a fixture after valid entrypoints" $?
assert_contains "${mapfile[$integration_check_root/output]:-}" 'tests/fixtures/invalid.zsh' "syntax checks identify the later file that failed"
