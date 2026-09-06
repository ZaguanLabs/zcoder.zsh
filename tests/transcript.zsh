# Sourced by run.zsh after installing its terminal-free curses recorder.
transcript_reset
STATE_ENABLED=0
UI_ACTIVE=1; UI_FOCUS=input
SCREEN_H=24; SCREEN_W=80; SIDE_W=0; TOP_H=3; INPUT_H=3; FOOT_H=1
ui_append_message user "Inspect the file"
transcript_tool_event begin read_file '{"path":"example.zsh"}' "" 0 remote_tool_1
tool_block_id="${UI_IDS[2]}"
assert_eq "pending" "${UI_TOOL_STATES[2]}" "tool blocks begin pending before execution"
assert_eq "0" "${UI_BLOCK_OPEN[2]}" "structured tool details start collapsed"
assert_contains "${UI_TOOL_SUMMARIES[2]}" "example.zsh" "collapsed tool summaries identify their target"
transcript_tool_event running read_file
assert_eq "running" "${UI_TOOL_STATES[2]}" "execution updates the existing tool block"
transcript_tool_event complete read_file '{"path":"example.zsh"}' $'first line\nsecond line' 1 remote_tool_1
assert_eq "2" "${#UI_ROLES}" "tool lifecycle produces exactly one transcript entry"
assert_eq "$tool_block_id" "${UI_IDS[2]}" "tool identity survives lifecycle updates"
assert_eq "completed" "${UI_TOOL_STATES[2]}" "successful tool completion is explicit"
assert_eq $'first line\nsecond line' "${UI_TOOL_RESULTS[2]}" "tool blocks retain inspectable read results"
transcript_tool_event complete read_file '{}' "stale replacement" 0 remote_tool_1
assert_failure "completed tool blocks reject stale completion events" $?
assert_eq "completed" "${UI_TOOL_STATES[2]}" "stale completion cannot overwrite success"
transcript_tool_event begin read_file '{}' "" 0 remote_tool_1
assert_eq "2" "${#UI_ROLES}" "replayed tool starts do not duplicate their block"
transcript_tool_event complete read_file '{}' "wrong call" 1 missing_tool_id
assert_failure "unknown tool IDs cannot complete a different call" $?

ui_draw_chat
assert_not_contains "${(F)UI_LINES}" "first line" "collapsed read results stay out of the rendered transcript"
ui_plain_transcript
assert_not_contains "$REPLY" "first line" "copy view respects collapsed tool details"
UI_FOCUS=chat; UI_SELECTED_EVENT=2
ui_chat_input $'\r' ENTER
assert_eq "1" "${UI_BLOCK_OPEN[2]}" "Enter expands the selected tool block"
assert_contains "${(F)UI_LINES}" "second line" "expanding a tool reveals its retained result"
ui_plain_transcript
assert_contains "$REPLY" "second line" "copy view includes expanded tool results"

# Only the changed suffix should be laid out again, including styled segments.
functions[_test_render_message]="${functions[_ui_render_one_message]}"
typeset -ga TRANSCRIPT_RENDERED=()
_ui_render_one_message() { TRANSCRIPT_RENDERED+=("$1"); _test_render_message "$@"; }
ui_append_message assistant "An explanation" "Private reasoning"
ui_draw_chat
assert_eq "3" "${(j:,:)TRANSCRIPT_RENDERED}" "appending a block renders only its new content"
TRANSCRIPT_RENDERED=()
ui_chat_input '' UP
assert_eq "1" "$UI_SELECTED_EVENT" "Up selects an earlier transcript entry"
assert_eq "0" "${#TRANSCRIPT_RENDERED}" "selection changes reuse cached message layout"
ui_chat_input '' DOWN
ui_chat_input ' ' ''
assert_eq "2,3" "${(j:,:)TRANSCRIPT_RENDERED}" "folding invalidates the selected block and following layout only"
assert_eq "0" "${UI_BLOCK_OPEN[2]}" "Space folds the selected block"
ui_chat_input '' DOWN
ui_toggle_reasoning
assert_eq "1" "${UI_REASONING_OPEN[3]}" "reasoning toggles on the selected assistant"
assert_contains "${(F)UI_LINES}" "Private reasoning" "selected reasoning expands in the transcript"
UI_SELECTED_EVENT=1
ui_toggle_block
assert_eq "0" "${UI_BLOCK_OPEN[1]}" "ordinary conversation bodies can be folded"
assert_not_contains "${(F)UI_LINES}" "Inspect the file" "folded conversation bodies leave only their header"
assert_eq "3" "${#UI_MESSAGE_STARTS}" "folding the first entry preserves block-to-row mapping"
functions[_ui_render_one_message]="${functions[_test_render_message]}"
unfunction _test_render_message

UI_SCROLL=0; UI_AUTO_SCROLL=0; UI_SELECTED_EVENT=1
ui_append_message assistant "New activity"
ui_draw_chat
assert_eq "1" "$UI_SELECTED_EVENT" "incoming activity preserves the selected entry"
assert_eq "0" "$UI_AUTO_SCROLL" "incoming activity does not resume automatic scrolling"
selected_before_resize="${UI_IDS[UI_SELECTED_EVENT]}"
SCREEN_W=45
ui_draw_chat
assert_eq "$selected_before_resize" "${UI_IDS[UI_SELECTED_EVENT]}" "rewrapping preserves selected block identity"
ui_chat_input '' END
assert_eq "4" "$UI_SELECTED_EVENT" "End selects the final transcript block"
ui_chat_input '' HOME
assert_eq "1" "$UI_SELECTED_EVENT" "Home selects the first transcript block"

transcript_tool_event begin mcp__demo__echo '{}' "" 0 mcp_call
transcript_tool_event complete mcp__demo__echo '{}' $'result\e]52;c;injected\a' 0 mcp_call
UI_SELECTED_EVENT=5
ui_toggle_block
assert_eq "failed" "${UI_TOOL_STATES[5]}" "failed MCP calls remain inspectable with explicit failure state"
assert_contains "${(F)UI_LINES}" "injected" "expanded MCP results are visible"
assert_not_contains "${(F)UI_LINES}" $'\e' "structured tool rendering exposes rather than emits terminal controls"
assert_contains "${(F)UI_ATTRS}" "bold red/black" "failed tool headers carry failure styling"

transcript_tool_event begin write_file '{"path":"note.md","content":"## Heading"}'
transcript_tool_event complete write_file '{}' 'Wrote note.md' 1
UI_SELECTED_EVENT=${#UI_ROLES}
ui_chat_input $'\r' ENTER
assert_contains "${(F)UI_SEGMENT_TEXTS}" "## Heading" "expanding a structured write preserves its code preview"
assert_contains "${(F)UI_SEGMENT_ATTRS}" "bold magenta/black" "keyboard navigation preserves Markdown highlighting options"

# Verify incremental persistence of mutations, legacy defaults, and remote replay.
saved_transcript_sessions_dir="$ZCODER_SESSIONS_DIR"
ZCODER_SESSIONS_DIR="$TEST_TMP/transcript-sessions"
CURRENT_SESSION_ID="12345_678"
STATE_SAVED_SESSION_ID=""
STATE_ENABLED=1
UI_SELECTED_EVENT=2
state_save_session
persisted_tool_id="${UI_IDS[2]}"
UI_SELECTED_EVENT=2
ui_toggle_block
transcript_tool_event begin run_command '{"command":"print ok"}' "" 0 pending_command
state_save_session
transcript_tool_event complete run_command '{"command":"print ok"}' "denied by user" 0 pending_command
state_save_session
persisted_tool_count=${#UI_ROLES}
transcript_reset
STATE_ENABLED=0
state_load_session 12345_678
assert_eq "$persisted_tool_count" "${#UI_ROLES}" "saved tool entries reload without duplicate lifecycle messages"
assert_eq "$persisted_tool_id" "${UI_IDS[2]}" "session reload restores stable tool identity"
assert_eq "1" "${UI_BLOCK_OPEN[2]}" "session reload restores an older block's changed expansion state"
assert_eq "2" "$UI_SELECTED_EVENT" "session reload restores the selected block"
assert_eq "failed" "${UI_TOOL_STATES[-1]}" "completion rewrites a previously saved pending tool"
assert_eq "denied by user" "${UI_TOOL_RESULTS[-1]}" "saved failed tools retain their result"
assert_eq $'result\e]52;c;injected\a' "${UI_TOOL_RESULTS[5]}" "persistence preserves exact escaped control bytes without executing them"
transcript_metadata_json 2
saved_tool_metadata="$REPLY"
UI_TOOL_NAMES[2]=""; UI_TOOL_RESULTS[2]=""
transcript_restore_metadata 2 "$saved_tool_metadata"
assert_eq "read_file" "${UI_TOOL_NAMES[2]}" "structured metadata restores tool type"
assert_eq $'first line\nsecond line' "${UI_TOOL_RESULTS[2]}" "structured metadata round-trips multiline results"

_remote_server_session_event 12345_678 1
json_parse_flat_object "$REPLY"
remote_tool_metadata="${JSON_OBJECT[metadata]}"
assert_eq "$saved_tool_metadata" "$remote_tool_metadata" "remote transcript API carries the saved tool metadata"

transcript_tool_event begin search '{"query":"unfinished"}' "" 0 interrupted_call
transcript_metadata_json ${#UI_ROLES}
transcript_restore_metadata ${#UI_ROLES} "$REPLY"
assert_eq "interrupted" "${UI_TOOL_STATES[-1]}" "restored unfinished tools do not pretend to still be running"
assert_success "interrupted restoration marks the record for persistence" $(( UI_PERSIST_DIRTY_FROM > 0 ? 0 : 1 ))
transcript_restore_metadata 2 ''
assert_eq "1" "${UI_BLOCK_OPEN[2]}" "legacy records retain their previously visible body"
assert_eq "" "${UI_TOOL_NAMES[2]}" "legacy tool text does not invent structured metadata"
assert_eq "event_2" "${UI_IDS[2]}" "legacy records receive stable session-local IDs"

STATE_ENABLED=0
ZCODER_SESSIONS_DIR="$saved_transcript_sessions_dir"
transcript_reset
UI_FOCUS=input
MOCK_ZCURSES_CALLS=()

# UI lifecycle observation must leave dispatch arguments and approval intact.
saved_transcript_policy="$ZCODER_COMMAND_POLICY"
ZCODER_COMMAND_POLICY=deny
AGENT_TOOL_PHASE=full; ACP_WORKER_ACTIVE=0; REMOTE_SERVER_WORKER=0
agent_tool_event begin run_command '{"command":"print blocked"}'
tool_dispatch run_command '{"command":"print blocked"}'
assert_failure "structured UI does not bypass command denial" $?
assert_eq "pending" "${UI_TOOL_STATES[1]}" "denied commands never enter the running state"
agent_tool_event complete run_command '{}' "$TOOL_RESULT" "$TOOL_RESULT_OK"
assert_eq "failed" "${UI_TOOL_STATES[1]}" "command denial completes its original card as failed"
assert_contains "${UI_TOOL_RESULTS[1]}" "user denied command" "command cards explain approval denial"
ZCODER_COMMAND_POLICY="$saved_transcript_policy"

# Older servers may emit both structured lifecycle and legacy tool messages.
functions[_test_transcript_remote_request]="${functions[remote_client_request]}"
functions[_test_transcript_remote_model]="${functions[remote_client_model_ensure]}"
saved_transcript_remote_sessions=$REMOTE_SESSIONS_SUPPORTED
REMOTE_SESSIONS_SUPPORTED=0
remote_client_model_ensure() { return 0; }
typeset -ga transcript_remote_events=(
  '{"seq":1,"event":"tool","phase":"begin","tool_call_id":"remote_call","name":"read_file","args":"{\"path\":\"example.zsh\"}"}'
  '{"seq":2,"event":"message","role":"tool","content":"legacy start"}'
  '{"seq":3,"event":"tool","phase":"running","tool_call_id":"remote_call","name":"read_file"}'
  '{"seq":4,"event":"tool","phase":"complete","tool_call_id":"remote_call","name":"read_file","result":"remote result","succeeded":1}'
  '{"seq":5,"event":"message","role":"tool","content":"legacy result"}'
  '{"seq":6,"event":"complete","exit_code":0}'
)
typeset -gi transcript_remote_cursor=0
typeset -g transcript_remote_payload=""
remote_client_request() {
  if [[ "$2" == /v1/turn ]]; then
    transcript_remote_payload="$3"
    HTTP_BODY='{}'
  elif [[ "$2" == /v1/events\?* ]]; then
    (( transcript_remote_cursor++ ))
    if (( transcript_remote_cursor > ${#transcript_remote_events} )); then
      REMOTE_ERROR="fixture connection closed"
      return 1
    fi
    HTTP_BODY="${transcript_remote_events[transcript_remote_cursor]}"
  else HTTP_BODY='{}'
  fi
  return 0
}
transcript_reset
remote_client_user_turn "Inspect remotely"
assert_success "remote UI consumes a complete structured tool lifecycle" $?
assert_contains "$transcript_remote_payload" '"structured_events":true' "remote UI requests structured events"
assert_eq "2" "${#UI_ROLES}" "legacy server summaries do not duplicate structured tool cards"
assert_eq "remote_call" "${UI_IDS[2]}" "remote UI retains the server's call identity"
assert_eq "completed" "${UI_TOOL_STATES[2]}" "remote completion updates the existing card"
assert_eq "remote result" "${UI_TOOL_RESULTS[2]}" "remote UI retains the full supplied result"

transcript_remote_events=("${transcript_remote_events[1]}")
transcript_remote_cursor=0
transcript_reset
remote_client_user_turn "Inspect before disconnect"
assert_failure "remote disconnection remains an error" $?
assert_eq "interrupted" "${UI_TOOL_STATES[2]}" "disconnection does not leave an active-looking tool card"
functions[remote_client_request]="${functions[_test_transcript_remote_request]}"
functions[remote_client_model_ensure]="${functions[_test_transcript_remote_model]}"
unfunction _test_transcript_remote_request _test_transcript_remote_model
REMOTE_SESSIONS_SUPPORTED=$saved_transcript_remote_sessions
transcript_reset
MOCK_ZCURSES_CALLS=()

# Exercise real ncurses key decoding, focus styling, and resize handling.
zmodload zsh/zpty
typeset -g transcript_pty_base="$TEST_TMP/transcript-pty" transcript_pty_output="" transcript_pty_chunk=""
transcript_pty_wait() {
  local file="$1" expected="$2"
  local -F deadline=$(( EPOCHREALTIME + 5.0 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r transcript-ui transcript_pty_chunk 2>/dev/null; do
      transcript_pty_output+="$transcript_pty_chunk"
    done
    [[ "${mapfile[$file]:-}" == "$expected"* ]] && return 0
    zselect -t 1 2>/dev/null
  done
  return 1
}
transcript_pty_run() {
  # zpty forks the current shell before invoking the fixture. Its inherited
  # EXIT trap must not delete the parent suite's private directory.
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/transcript_ui.zsh" "$PROJECT_DIR" "$transcript_pty_base"
}
TERM=xterm-256color zpty -b transcript-ui transcript_pty_run
assert_success "real curses transcript fixture starts in a PTY" $?
transcript_pty_wait "$transcript_pty_base.ready" 1
assert_success "real curses transcript renders its initial frame" $?
zpty -w -n transcript-ui $'\r'
transcript_pty_wait "$transcript_pty_base.state" '1:1:1:0:80:event_1'
assert_success "real Enter expands the selected tool" $?
assert_contains "$transcript_pty_output" "PTY tool result" "expanded tool output reaches the physical terminal"
zpty -w -n transcript-ui $'\eOB'
transcript_pty_wait "$transcript_pty_base.state" '2:2:1:0:80:event_2'
assert_success "real Down selects the next transcript block" $?
zpty -w -n transcript-ui $'\x12'
transcript_pty_wait "$transcript_pty_base.state" '3:2:1:1:80:event_2'
assert_success "real Ctrl+R expands the selected reasoning" $?
zpty -w -n transcript-ui w
transcript_pty_wait "$transcript_pty_base.state" '4:2:1:1:60:event_2'
assert_success "terminal resize preserves selection and expansion" $?
zpty -w -n transcript-ui q
transcript_pty_wait "$transcript_pty_base.done" 1
transcript_pty_exit_status=$?
assert_success "real curses fixture restores the terminal on exit" "$transcript_pty_exit_status"
if (( transcript_pty_exit_status )); then
  print -r -- "PTY exit state: ${mapfile[$transcript_pty_base.state]:-missing}; done: ${mapfile[$transcript_pty_base.done]:-missing}"
  print -r -- "PTY output tail: ${(V)transcript_pty_output[-500,-1]}"
fi
zpty -d transcript-ui
unfunction transcript_pty_wait transcript_pty_run
