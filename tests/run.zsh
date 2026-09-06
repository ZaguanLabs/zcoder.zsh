#!/usr/bin/env zsh

setopt EXTENDED_GLOB NO_NOMATCH
zmodload zsh/datetime zsh/files zsh/mapfile zsh/stat zsh/system zsh/zselect

0="${ZERO:-${${0:#$ZSH_ARGZERO}:-${(%):-%N}}}"
0="${${(M)0:#/*}:-$PWD/$0}"
typeset -gr TEST_DIR="${0:A:h}"
typeset -gr PROJECT_DIR="${TEST_DIR:h}"

source "${PROJECT_DIR}/lib/util.zsh"
source "${PROJECT_DIR}/lib/json.zsh"
source "${PROJECT_DIR}/lib/transcript.zsh"
source "${PROJECT_DIR}/lib/relay.zsh"
source "${PROJECT_DIR}/lib/mcp.zsh"
source "${PROJECT_DIR}/lib/http.zsh"
source "${PROJECT_DIR}/lib/instructions.zsh"
source "${PROJECT_DIR}/lib/skills.zsh"
source "${PROJECT_DIR}/lib/input.zsh"
source "${PROJECT_DIR}/lib/tools.zsh"
source "${PROJECT_DIR}/lib/compact.zsh"
source "${PROJECT_DIR}/lib/goal.zsh"
source "${PROJECT_DIR}/lib/agent.zsh"
source "${PROJECT_DIR}/lib/state.zsh"
source "${PROJECT_DIR}/lib/harnesses.zsh"
source "${PROJECT_DIR}/lib/delegate.zsh"
source "${PROJECT_DIR}/lib/remote.zsh"
source "${PROJECT_DIR}/lib/acp.zsh"

typeset -gi TESTS=0 FAILURES=0
typeset -g TEST_TMP=""
typeset -g TEST_RELAY_PEER_PID="" TEST_RELAY_PEER_STOP=""

pass() { print -r -- "ok $TESTS - $1"; }
fail() { print -r -- "not ok $TESTS - $1"; (( FAILURES++ )); }

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  (( TESTS++ ))
  if [[ "$actual" == "$expected" ]]; then pass "$label"; else fail "$label (expected ${(qqq)expected}, got ${(qqq)actual})"; fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  (( TESTS++ ))
  if [[ "$haystack" == *"$needle"* ]]; then pass "$label"; else fail "$label (missing ${(qqq)needle})"; fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  (( TESTS++ ))
  if [[ "$haystack" != *"$needle"* ]]; then pass "$label"; else fail "$label (unexpected ${(qqq)needle})"; fi
}

assert_success() {
  local label="$1" exit_code="$2"
  (( TESTS++ ))
  if (( exit_code == 0 )); then pass "$label"; else fail "$label (status $exit_code: $TOOL_RESULT)"; fi
}

assert_failure() {
  local label="$1" exit_code="$2"
  (( TESTS++ ))
  if (( exit_code != 0 )); then pass "$label"; else fail "$label (unexpected success)"; fi
}

cleanup_tests() {
  [[ -n "$TEST_RELAY_PEER_STOP" ]] && mapfile[$TEST_RELAY_PEER_STOP]="1" 2>/dev/null || true
  if [[ "$TEST_RELAY_PEER_PID" == <1-> ]] && kill -0 "$TEST_RELAY_PEER_PID" 2>/dev/null; then
    kill -TERM "$TEST_RELAY_PEER_PID" 2>/dev/null
    wait "$TEST_RELAY_PEER_PID" 2>/dev/null || true
  fi
  relay_stop 2>/dev/null || true
  zcoder_debug_close 2>/dev/null || true
  zcoder_runtime_cleanup 2>/dev/null || true
  [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]] && zf_rm -rf -- "$TEST_TMP" 2>/dev/null
}
trap cleanup_tests EXIT INT TERM

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/zcoder-tests.XXXXXX")" || exit 1
ZCODER_WORKSPACE="$TEST_TMP"
ZCODER_MAX_TOOL_OUTPUT=32768

print -r -- "1..1006"

# Headless startup must retain transcripts and remote approvals without loading
# terminal libraries, handlers, or the delegate execution runtime.
for headless_mode in server acp; do
  headless_args=(--acp)
  [[ "$headless_mode" == server ]] && headless_args=(--server startup-probe)
  headless_stderr="$TEST_TMP/${headless_mode}-startup.stderr"
  ZCODER_HOME="$TEST_TMP/${headless_mode}-startup-home" REMOTE_MODE=local \
    zsh -f "$TEST_DIR/fixtures/headless_startup.zsh" "$PROJECT_DIR/zcoder.zsh" \
    "${headless_args[@]}" --profile coding --workspace "$TEST_TMP" 2>| "$headless_stderr"
  assert_success "$headless_mode starts without terminal code and preserves required runtime behavior" $?
  assert_eq "" "${mapfile[$headless_stderr]:-}" "$headless_mode startup, worker, and cleanup produce no errors"
  zf_rm -rf -- "$TEST_TMP/${headless_mode}-startup-home"
  zf_rm -f -- "$headless_stderr"
done

# ACP uses newline-delimited JSON-RPC while delegating agent work to the same
# transport-neutral session and tool machinery as the TUI and remote API.
acp_message='{"jsonrpc":"2.0","id":"request-1","method":"session/prompt","params":{"sessionId":"123_456","prompt":[{"type":"text","text":"hello"}]}}'
_acp_parse_message "$acp_message"
assert_success "ACP parses a valid JSON-RPC request envelope" $?
assert_eq '"request-1"' "$ACP_MESSAGE_ID_RAW" "ACP preserves the raw request ID type for responses"
assert_eq "session/prompt" "$ACP_MESSAGE_METHOD" "ACP extracts the requested method"
assert_contains "$ACP_MESSAGE_PARAMS" '"sessionId":"123_456"' "ACP preserves nested method parameters"
_acp_parse_message '{"jsonrpc":"1.0","id":1,"method":"initialize","params":{}}'
assert_failure "ACP rejects non-2.0 JSON-RPC envelopes" $?

_acp_prompt_text '{"prompt":[{"type":"text","text":"Review this"},{"type":"resource","resource":{"uri":"file:///workspace/a.zsh","mimeType":"text/x-zsh","text":"print ok"}}]}'
assert_success "ACP accepts text and embedded text resources" $?
assert_contains "$REPLY" "Review this" "ACP retains ordinary prompt text"
assert_contains "$REPLY" "file:///workspace/a.zsh" "ACP labels embedded context with its URI"
assert_contains "$REPLY" "print ok" "ACP retains embedded resource contents"
_acp_prompt_text '{"prompt":[{"type":"image","mimeType":"image/png","data":"AA=="}]}'
assert_failure "ACP rejects prompt capabilities it did not advertise" $?
assert_contains "$REPLY" "unsupported prompt content type" "unsupported ACP content fails explicitly"

ACP_INITIALIZED=0
acp_capture="$TEST_TMP/acp-initialize.out"
_acp_initialize 7 '{"protocolVersion":1,"clientCapabilities":{}}' >| "$acp_capture"
assert_success "ACP negotiates protocol version 1" $?
assert_eq "1" "$ACP_INITIALIZED" "successful ACP initialization advances connection state"
assert_contains "${mapfile[$acp_capture]}" '"protocolVersion":1' "ACP initialization reports the negotiated version"
assert_contains "${mapfile[$acp_capture]}" '"embeddedContext":true' "ACP advertises only its implemented prompt extension"

saved_remote_mode_for_acp="$REMOTE_MODE"
REMOTE_MODE=client
_acp_session_cwd '{"cwd":"/workspace/on/another/system"}'
assert_success "remote ACP accepts an absolute client cwd that is not local" $?
assert_eq "/workspace/on/another/system" "$REPLY" "remote ACP leaves cross-system client paths opaque"
REMOTE_MODE="$saved_remote_mode_for_acp"

ACP_WORKER_RUNNING=1
acp_busy_capture="$TEST_TMP/acp-busy.out"
_acp_new_session 8 '{"cwd":"/tmp","mcpServers":[]}' >| "$acp_busy_capture"
assert_failure "ACP rejects session creation during an active prompt" $?
assert_contains "${mapfile[$acp_busy_capture]}" "cannot create a session while a prompt is running" "active-prompt session rejection is explicit"
ACP_WORKER_RUNNING=0

ACP_SESSION_ID="123_456"
ACP_TOOL_SEQUENCE=0
ACP_CURRENT_TOOL_CALL_ID=""
acp_tool_capture="$TEST_TMP/acp-tool.out"
acp_worker_tool_event begin read_file '{"path":"src/a.zsh"}' >| "$acp_tool_capture"
assert_contains "${mapfile[$acp_tool_capture]}" '"sessionUpdate":"tool_call"' "ACP publishes tool creation"
assert_contains "${mapfile[$acp_tool_capture]}" '"rawInput":{"path":"src/a.zsh"}' "ACP preserves structured tool input"
acp_worker_tool_event running read_file >> "$acp_tool_capture"
assert_contains "${mapfile[$acp_tool_capture]}" '"status":"in_progress"' "ACP publishes tool execution state"
acp_worker_tool_event complete read_file '{}' $'line one\nline two' 1 >> "$acp_tool_capture"
assert_contains "${mapfile[$acp_tool_capture]}" '"status":"completed"' "ACP publishes successful tool completion"
assert_contains "${mapfile[$acp_tool_capture]}" 'line one\nline two' "ACP JSON-quotes multiline tool results"

saved_remote_runtime_for_acp="$REMOTE_RUNTIME_DIR"
REMOTE_RUNTIME_DIR="$TEST_TMP/acp-remote-events"
zf_mkdir -p "$REMOTE_RUNTIME_DIR/events"
REMOTE_TURN_ID="123_456"
REMOTE_SERVER_TOOL_SEQUENCE=0
REMOTE_SERVER_TOOL_CALL_ID=""
REMOTE_STRUCTURED_TOOL_EVENTS=1
remote_server_worker_tool_event begin search '{"query":"needle"}'
assert_success "remote API publishes structured tool lifecycle events" $?
_remote_server_next_event 0
assert_success "structured remote tool events are cursor-addressable" $?
assert_contains "$REPLY" '"event":"tool"' "remote tool events retain a distinct event type"
json_parse_flat_object "$REPLY"
assert_eq '{"query":"needle"}' "${JSON_OBJECT[args]}" "remote tool events preserve ACP-ready raw input"
REMOTE_STRUCTURED_TOOL_EVENTS=0
REMOTE_RUNTIME_DIR="$saved_remote_runtime_for_acp"

acp_smoke_home="$TEST_TMP/acp-smoke-home"
acp_smoke_stderr="$TEST_TMP/acp-smoke.stderr"
acp_smoke_input=$'{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}\n'
json_quote "$TEST_TMP"; acp_smoke_cwd="$REPLY"
acp_smoke_input+="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/new\",\"params\":{\"cwd\":${acp_smoke_cwd},\"mcpServers\":[]}}"
acp_smoke_output="$(print -r -- "$acp_smoke_input" | ZCODER_HOME="$acp_smoke_home" "$PROJECT_DIR/zcoder.zsh" --acp --workspace "$TEST_TMP" 2>| "$acp_smoke_stderr")"
acp_smoke_exit=$?
acp_smoke_lines=("${(@f)acp_smoke_output}")
assert_success "standalone ACP stdio mode exits cleanly at client EOF" "$acp_smoke_exit"
assert_eq "2" "${#acp_smoke_lines}" "standalone ACP emits exactly one response per request"
assert_contains "${acp_smoke_lines[1]}" '"id":0,"result"' "standalone ACP emits a valid initialize response"
assert_contains "${acp_smoke_lines[2]}" '"sessionId":' "standalone ACP creates a persistent session"
assert_eq "" "${mapfile[$acp_smoke_stderr]:-}" "standalone ACP keeps protocol stdout free of diagnostics"
acp_smoke_sessions=("$acp_smoke_home/sessions"/*.session(N))
assert_eq "1" "${#acp_smoke_sessions}" "ACP session/new persists exactly one fresh session"
zf_rm -rf -- "$acp_smoke_home"

acp_worker_probe="$(
  (
    ZCODER_WORKSPACE="$TEST_TMP/acp-worker-workspace"
    ZCODER_SESSIONS_DIR="$TEST_TMP/acp-worker-home/sessions"
    zf_mkdir -p "$ZCODER_WORKSPACE"
    STATE_ENABLED=0
    state_init storage || exit 1
    STATE_ENABLED=0
    state_new_session || exit 1
    STATE_ENABLED=1
    state_save_session || exit 1
    STATE_ENABLED=0
    acp_worker_session="$CURRENT_SESSION_ID"
    agent_user_turn() {
      agent_add_message user "$1"
      agent_add_message assistant "persisted through ACP worker"
      agent_emit assistant "persisted through ACP worker"
    }
    acp_worker_main "$acp_worker_session" "test prompt" "$ZCODER_WORKSPACE" '[]' >| "$TEST_TMP/acp-worker.out"
    print -r -- "$?"
    AGENT_MESSAGES=()
    STATE_ENABLED=0
    state_load_session "$acp_worker_session" || exit 1
    print -r -- "${#AGENT_MESSAGES}"
    print -r -- "${AGENT_MESSAGES[-1]}"
  )
)"
acp_worker_probe_lines=("${(@f)acp_worker_probe}")
zf_rm -rf -- "$TEST_TMP/acp-worker-home" "$TEST_TMP/acp-worker-workspace"
zf_rm -f -- "$TEST_TMP/acp-worker.out"
assert_eq "0" "${acp_worker_probe_lines[1]:-missing}" "ACP prompt worker runs under native Zsh without special-parameter collisions"
assert_eq "2" "${acp_worker_probe_lines[2]:-missing}" "ACP prompt worker persists the completed turn"
assert_contains "${acp_worker_probe_lines[3]:-}" "persisted through ACP worker" "ACP session reload observes worker-owned state"
acp_help="$($PROJECT_DIR/zcoder.zsh --help)"
assert_contains "$acp_help" "--acp" "command help exposes ACP stdio mode"

input_reset
input_layout 20 4
assert_eq "1" "${#INPUT_VISUAL_LINES}" "empty input occupies one visual row"

input_insert $'hello\nworld'
input_layout 20 4
assert_eq "2" "${#INPUT_VISUAL_LINES}" "hard newline creates another visual row"
assert_eq "hello" "${INPUT_VISUAL_LINES[1]}" "multiline layout preserves the first line"
assert_eq "world" "${INPUT_VISUAL_LINES[2]}" "multiline layout preserves the second line"
assert_eq "2" "$INPUT_CURSOR_ROW" "cursor follows inserted text onto the second line"
assert_eq "5" "$INPUT_CURSOR_COL" "cursor column is relative to its visual line"

input_clear
input_insert "abcdefghij"
input_layout 4 4
assert_eq "3" "${#INPUT_VISUAL_LINES}" "long input wraps at the editor width"

input_clear
input_insert $'one\ntwo\nthree\nfour\nfive'
input_layout 20 4
assert_eq "4" "$INPUT_VISIBLE_ROWS" "multiline viewport is capped at four rows"
assert_eq "2" "$INPUT_VIEW_TOP" "multiline viewport follows the cursor"
input_move_vertical -1 20 4
assert_success "up moves within a multiline prompt" $?
assert_eq "18" "$INPUT_POS" "vertical movement preserves the preferred column"
input_move_vertical 1 20 4
assert_eq "23" "$INPUT_POS" "down returns to the following prompt line"

input_reset
input_sequence=$'\e[13;2u'
for input_byte in ${(s::)input_sequence}; do input_decode_terminal_event "$input_byte" ""; done
assert_eq "newline" "$INPUT_EVENT_ACTION" "CSI-u Shift-Return inserts a newline"
input_reset
input_sequence=$'\e[27;2;13~'
for input_byte in ${(s::)input_sequence}; do input_decode_terminal_event "$input_byte" ""; done
assert_eq "newline" "$INPUT_EVENT_ACTION" "modifyOtherKeys Shift-Return inserts a newline"
input_reset
input_decode_terminal_event $'\e' ""
input_decode_terminal_event $'\n' ""
assert_eq "newline" "$INPUT_EVENT_ACTION" "Alt-Return is a multiline fallback"

input_reset
input_sequence=$'\e[200~'
for input_byte in ${(s::)input_sequence}; do input_decode_terminal_event "$input_byte" ""; done
assert_eq "paste" "$INPUT_TERM_STATE" "bracketed paste start enters paste mode"
input_sequence=$'alpha\r\nbeta\e[201~'
for input_byte in ${(s::)input_sequence}; do input_decode_terminal_event "$input_byte" ""; done
assert_eq "paste" "$INPUT_EVENT_ACTION" "bracketed paste produces one editor event"
assert_eq $'alpha\nbeta' "$INPUT_EVENT_TEXT" "multiline paste preserves and normalizes formatting"

terminal_sample=$'first\nsecond\t\e]52;c;clipboard\a\rthird'
zcoder_terminal_safe "$terminal_sample"
assert_eq $'first\nsecond\\t^[]52;c;clipboard^G^Mthird' "$REPLY" "terminal-safe rendering preserves lines and exposes controls"
assert_not_contains "$REPLY" $'\e' "terminal-safe rendering removes literal escape bytes"

zcoder_truncate_head_tail "BEGIN-${(l:120::x:)}-END" 60
assert_contains "$REPLY" "BEGIN-" "bounded tool output preserves its head"
assert_contains "$REPLY" "-END" "bounded tool output preserves its diagnostic tail"
assert_eq "60" "${#REPLY}" "head-tail bounding honors the character limit"

typeset -g MOCK_SYSWRITE_OUTPUT=""
typeset -gi MOCK_SYSWRITE_CALLS=0
syswrite() {
  local data="${argv[-1]}" chunk="${argv[-1][1,3]}"
  (( MOCK_SYSWRITE_CALLS++ ))
  MOCK_SYSWRITE_OUTPUT+="$chunk"
  written=${#chunk}
  return 0
}
zcoder_syswrite_all 9 "abcdefgh"
assert_success "complete writes tolerate partial syswrite results" $?
assert_eq "abcdefgh" "$MOCK_SYSWRITE_OUTPUT" "complete writes retain every byte in order"
assert_eq "3" "$MOCK_SYSWRITE_CALLS" "complete writes retry only the unwritten suffix"
unfunction syswrite

zcoder_runtime_init
assert_success "private runtime storage initializes" $?
assert_eq "$ZCODER_RUNTIME_PARENT" "${ZCODER_RUNTIME_DIR:h:A}" "runtime storage stays below its validated parent"
typeset -A runtime_stat=()
zstat -H runtime_stat -- "$ZCODER_RUNTIME_DIR"
assert_eq "0" "$(( runtime_stat[mode] & 8#77 ))" "runtime storage denies group and other access"
zcoder_temp_path first .out; first_temp_path="$REPLY"
zcoder_temp_path second .out; second_temp_path="$REPLY"
assert_eq "$ZCODER_RUNTIME_DIR" "${first_temp_path:h}" "temporary files stay inside private runtime storage"
if [[ "$first_temp_path" != "$second_temp_path" ]]; then temp_paths_unique=0; else temp_paths_unique=1; fi
assert_success "temporary path allocation is unique" "$temp_paths_unique"

# Same-host agent relay uses a background Unix-socket listener while all agent
# and UI mutation remains in the foreground process.
saved_relay_dir="$ZCODER_RELAY_DIR"
saved_relay_mode="$ZCODER_RELAY"
saved_relay_workspace="$ZCODER_WORKSPACE"
saved_relay_model="$ZCODER_MODEL"
saved_relay_profile="$ZCODER_PROFILE"
saved_relay_session="$CURRENT_SESSION_ID"
ZCODER_RELAY_DIR="$TEST_TMP/relay-registry"
ZCODER_RELAY=on
ZCODER_WORKSPACE="$TEST_TMP/relay-parent-project"
ZCODER_MODEL="parent-model"
ZCODER_PROFILE="coding"
CURRENT_SESSION_ID="1_1"
zf_mkdir -p "$ZCODER_WORKSPACE"
relay_start
assert_success "local agent relay starts" $?
assert_eq "1" "$RELAY_AVAILABLE" "started relay exposes its model tools"
[[ -S "$RELAY_SOCKET_PATH" && -f "$RELAY_MANIFEST_PATH" ]]
assert_success "relay publishes a socket and manifest" $?
relay_parent_socket="$RELAY_SOCKET_PATH"
relay_parent_manifest="$RELAY_MANIFEST_PATH"
relay_parent_pid="$RELAY_LISTENER_PID"

relay_peer_runtime="$TEST_TMP/relay-peer-runtime"
relay_peer_workspace="$TEST_TMP/peer-project"
relay_peer_ready="$TEST_TMP/relay-peer.ready"
TEST_RELAY_PEER_STOP="$TEST_TMP/relay-peer.stop"
relay_peer_received="$TEST_TMP/relay-peer.received"
zsh "${PROJECT_DIR}/tests/fixtures/relay_peer.zsh" \
  "$ZCODER_RELAY_DIR" "$relay_peer_runtime" "$relay_peer_workspace" \
  "$relay_peer_ready" "$TEST_RELAY_PEER_STOP" "$relay_peer_received" &
TEST_RELAY_PEER_PID=$!
relay_deadline=$(( EPOCHREALTIME + 3.0 ))
while [[ ! -f "$relay_peer_ready" ]] && (( EPOCHREALTIME < relay_deadline )); do zselect -t 2 2>/dev/null; done
[[ -f "$relay_peer_ready" ]]
assert_success "second local relay fixture becomes ready" $?
relay_peer_id="${mapfile[$relay_peer_ready]:-}"

relay_discover
assert_success "relay discovery finds a live peer" $?
assert_eq "1" "${#RELAY_PEER_IDS}" "relay discovery excludes the calling instance"
assert_eq "$relay_peer_id" "${RELAY_PEER_IDS[1]}" "relay discovery returns the exact peer instance ID"
assert_eq "peer-project" "${RELAY_PEER_PROJECTS[1]}" "relay discovery reports the peer project"
relay_agents_text
assert_contains "$REPLY" "$relay_peer_id" "agent listing includes the exact selectable ID"
assert_contains "$REPLY" "$relay_peer_workspace" "agent listing includes the canonical peer workspace"

AGENT_TURN_ORIGIN=user
tools_schema_json
assert_contains "$REPLY" '"name":"list_agents"' "local user turns expose agent discovery"
assert_contains "$REPLY" '"name":"send_agent_message"' "local user turns expose agent delivery"
AGENT_TURN_ORIGIN=relay
AGENT_RELAY_REPLY_TARGET=""
tools_schema_json
assert_contains "$REPLY" '"name":"list_agents"' "relayed turns retain read-only agent discovery"
assert_not_contains "$REPLY" '"name":"send_agent_message"' "relay turns without a sender cannot deliver messages"
tool_dispatch send_agent_message '{"target_instance_id":"blocked","message":"do not forward"}'
assert_failure "dispatch rejects delivery without a relay reply target" $?
assert_contains "$TOOL_RESULT" "unavailable for this turn" "dispatch requires turn-scoped reply authority"
AGENT_RELAY_REPLY_TARGET="$relay_peer_id"
tools_schema_json
assert_contains "$REPLY" '"name":"send_agent_message"' "relayed turns expose delivery for a direct reply"
assert_contains "$REPLY" "forwarding to any other agent is blocked" "relay delivery schema describes its narrow reply scope"
tool_dispatch send_agent_message '{"target_instance_id":"blocked","message":"do not forward"}'
assert_failure "dispatch rejects forwarding to a third agent" $?
assert_contains "$TOOL_RESULT" "may reply only to its sender" "dispatch enforces the exact relay sender"
AGENT_TURN_ORIGIN=user
AGENT_RELAY_REPLY_TARGET=""

relay_message=$'users.name became users.display_name\nVerify the focused consumer test. ÆØÅ'
relay_tool_send_agent_message "$relay_peer_id" "$relay_message"
assert_success "agent message delivery is acknowledged" $?
assert_contains "$TOOL_RESULT" "Delivery does not imply task completion" "delivery result distinguishes acceptance from completion"
relay_deadline=$(( EPOCHREALTIME + 3.0 ))
while [[ ! -f "$relay_peer_received" ]] && (( EPOCHREALTIME < relay_deadline )); do zselect -t 2 2>/dev/null; done
relay_received="${mapfile[$relay_peer_received]:-}"
assert_contains "$relay_received" "relay-parent-project" "receiving peer retains sender identity"
assert_contains "$relay_received" "$relay_message" "receiving peer preserves multiline Unicode task text"

AGENT_TURN_ORIGIN=relay
AGENT_RELAY_REPLY_TARGET="$relay_peer_id"
relay_reply="Second message in the same inter-agent exchange."
typeset -g MOCK_RELAY_APPROVAL_TEXT=""
ui_confirm_external_action() { MOCK_RELAY_APPROVAL_TEXT="$1"; REPLY="y"; }
tool_dispatch send_agent_message "{\"target_instance_id\":\"${relay_peer_id}\",\"message\":\"${relay_reply}\"}"
assert_success "a relayed turn can send a second message back to its sender" $?
assert_contains "$MOCK_RELAY_APPROVAL_TEXT" "$relay_peer_id" "inter-agent dispatch confirms the exact recipient"
unfunction ui_confirm_external_action
relay_deadline=$(( EPOCHREALTIME + 3.0 ))
while [[ "${mapfile[$relay_peer_received]:-}" != *"$relay_reply"* ]] && (( EPOCHREALTIME < relay_deadline )); do zselect -t 2 2>/dev/null; done
assert_contains "${mapfile[$relay_peer_received]:-}" "$relay_reply" "the second message reaches the exact peer"
AGENT_TURN_ORIGIN=user
AGENT_RELAY_REPLY_TARGET=""

relay_pause
assert_success "relay can pause incoming delivery" $?
_relay_ping_peer "$RELAY_SOCKET_PATH" "$RELAY_INSTANCE_ID"
assert_success "paused relay remains discoverable" $?
assert_eq "paused" "$RELAY_ACK_STATE" "relay ping reports paused state"
relay_resume
assert_success "relay can resume incoming delivery" $?

mapfile[$TEST_RELAY_PEER_STOP]="1"
wait "$TEST_RELAY_PEER_PID"
assert_success "relay fixture shuts down cleanly" $?
TEST_RELAY_PEER_PID=""
relay_stop
assert_success "local relay shuts down cleanly" $?
[[ ! -e "$relay_parent_socket" && ! -e "$relay_parent_manifest" ]]
assert_success "relay shutdown removes only its public socket and manifest" $?
kill -0 "$relay_parent_pid" 2>/dev/null
assert_failure "relay shutdown reaps its listener worker" $?

ZCODER_RELAY_DIR="$saved_relay_dir"
ZCODER_RELAY="$saved_relay_mode"
ZCODER_WORKSPACE="$saved_relay_workspace"
ZCODER_MODEL="$saved_relay_model"
ZCODER_PROFILE="$saved_relay_profile"
CURRENT_SESSION_ID="$saved_relay_session"
TEST_RELAY_PEER_STOP=""

mapfile[$TEST_TMP/debug-target.log]="unchanged"
zf_ln -s "$TEST_TMP/debug-target.log" "$TEST_TMP/debug-link.log"
ZCODER_DEBUG_LOG="$TEST_TMP/debug-link.log"
zcoder_debug_init
assert_failure "debug logging refuses a symlink target" $?
assert_eq "unchanged" "${mapfile[$TEST_TMP/debug-target.log]}" "rejected debug symlinks leave their target untouched"

ZCODER_DEBUG_LOG="$TEST_TMP/zcoder-debug.log"
zcoder_debug_init
assert_success "debug log initializes" $?
zcoder_debug unit_test $'first line\nsecond line'
assert_contains "${mapfile[$ZCODER_DEBUG_LOG]}" 'unit_test first line\nsecond line' "debug log escapes multiline records"

quote_sample=$'quote " and slash \\\nline\ttab æøå'
json_quote "$quote_sample"; fast_quoted="$REPLY"
json_begin "$fast_quoted"
assert_success "bulk JSON quoting produces valid JSON" $?
assert_eq "$quote_sample" "$JSON_TOKEN_VALUE" "bulk JSON quoting round-trips mixed content"
control_quote_sample=$'slash \\ and control \x01'
json_quote "$control_quote_sample"; json_begin "$REPLY"
assert_eq "$control_quote_sample" "$JSON_TOKEN_VALUE" "fallback JSON quoting round-trips uncommon controls"

tool_write_file "src/note.txt" $'one\ntwo\nthree\n'
assert_success "write_file creates parent directories" $?
assert_eq $'one\ntwo\nthree\n' "${mapfile[$TEST_TMP/src/note.txt]}" "write_file preserves content"

tool_read_file "src/note.txt"
assert_success "read_file reads a workspace file" $?
assert_eq $'one\ntwo\nthree\n' "$TOOL_RESULT" "read_file returns exact content"

tool_read_file_range "src/note.txt" 2 3
assert_success "read_file_range accepts inclusive lines" $?
assert_eq $'2: two\n3: three' "$TOOL_RESULT" "read_file_range includes line numbers"

tool_write_file "../escape.txt" "nope"
assert_failure "write_file rejects parent traversal" $?
assert_contains "$TOOL_RESULT" "escapes the workspace" "path rejection explains the boundary"

dangling_target="${TEST_TMP:h}/zcoder-dangling-target-${RANDOM}"
zf_ln -s "$dangling_target" "$TEST_TMP/dangling-link"
tool_write_file "dangling-link" "nope"
assert_failure "write_file rejects a dangling symlink" $?
assert_contains "$TOOL_RESULT" "dangling symlink" "dangling-symlink rejection explains the boundary"
if [[ -e "$dangling_target" ]]; then dangling_target_absent=1; else dangling_target_absent=0; fi
assert_success "dangling symlinks cannot create an outside target" "$dangling_target_absent"

zf_mkdir "$TEST_TMP/existing-directory"
tool_write_file "existing-directory" "nope"
assert_failure "write_file rejects a non-regular target" $?
assert_contains "$TOOL_RESULT" "not a regular file" "non-regular write rejection is explicit"

zf_mkdir -p "$TEST_TMP/node_modules/dependency"
mapfile[$TEST_TMP/node_modules/dependency/index.js]="generated"
zf_mkdir -p "$TEST_TMP/ignored-cache" "$TEST_TMP/packages/scratch"
mapfile[$TEST_TMP/.gitignore]=$'ignored-cache/\n*.generated\n!important.generated\n'
mapfile[$TEST_TMP/ignored-cache/secret.txt]="ignored search needle"
mapfile[$TEST_TMP/hidden.generated]="ignored"
mapfile[$TEST_TMP/important.generated]="visible"
mapfile[$TEST_TMP/packages/.gitignore]=$'scratch/\n'
mapfile[$TEST_TMP/packages/scratch/cache.txt]="ignored"
mapfile[$TEST_TMP/packages/source.zsh]="visible"
tool_list_files . 20
assert_success "list_files walks the workspace" $?
assert_contains "$TOOL_RESULT" "src/note.txt" "list_files returns relative paths"
assert_not_contains "$TOOL_RESULT" "node_modules" "list_files excludes dependency trees"
assert_not_contains "$TOOL_RESULT" "ignored-cache" "list_files honors root gitignore directories outside Git"
assert_not_contains "$TOOL_RESULT" "hidden.generated" "list_files honors root gitignore file patterns outside Git"
assert_contains "$TOOL_RESULT" "important.generated" "list_files honors gitignore negation rules outside Git"
assert_not_contains "$TOOL_RESULT" "packages/scratch" "list_files honors nested gitignore files outside Git"

if (( $+commands[rg] )); then
  tool_search "two" . 10
  assert_success "search invokes ripgrep safely" $?
  assert_contains "$TOOL_RESULT" "src/note.txt:2:1:two" "search returns locations"
  tool_search "ignored search needle" . 10
  assert_success "search applies ignore files outside Git" $?
  assert_contains "$TOOL_RESULT" "No text matches." "search excludes gitignored results outside Git"
  assert_contains "$TOOL_RESULT" "use list_files to discover file paths" "empty search results explain filename discovery"
else
  (( TESTS += 5 ))
  pass "search unavailable (rg not installed)"
  pass "search output unavailable (rg not installed)"
  pass "ignore-aware search unavailable (rg not installed)"
  pass "ignored search output unavailable (rg not installed)"
  pass "empty-search guidance unavailable (rg not installed)"
fi

mapfile[$TEST_TMP/src/replace.txt]=$'mode=old\n'
tool_replace_text "src/replace.txt" "mode=old" "mode=new"
assert_success "replace_text updates one exact occurrence" $?
assert_eq $'mode=new\n' "${mapfile[$TEST_TMP/src/replace.txt]}" "replace_text preserves surrounding file content"
tool_replace_text "src/replace.txt" "missing" "value"
assert_failure "replace_text rejects a missing old fragment" $?
assert_contains "$TOOL_RESULT" "not found exactly" "replace_text explains a missing old fragment"
mapfile[$TEST_TMP/src/replace.txt]=$'same\nsame\n'
tool_replace_text "src/replace.txt" "same" "changed"
assert_failure "replace_text rejects an ambiguous old fragment" $?
assert_contains "$TOOL_RESULT" "more than once" "replace_text requests a more specific fragment"

if (( $+commands[git] )); then
  tool_apply_patch $'diff --git a/src/note.txt b/src/note.txt\n--- a/src/note.txt\n+++ b/src/note.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n'
  assert_success "apply_patch works in a non-Git workspace" $?
  assert_contains "${mapfile[$TEST_TMP/src/note.txt]}" "TWO" "apply_patch changes the target"
else
  (( TESTS += 2 )); pass "apply_patch unavailable (git not installed)"; pass "patch output unavailable (git not installed)"
fi

if (( $+commands[patch] )); then
  mapfile[$TEST_TMP/src/fallback.txt]=$'alpha\nbeta\ngamma\n'
  tool_apply_patch $'*** src/fallback.txt\n--- src/fallback.txt\n***************\n*** 1,3 ****\n  alpha\n! beta\n  gamma\n--- 1,3 ----\n  alpha\n! BETA\n  gamma\n'
  assert_success "apply_patch falls back to patch for context diffs" $?
  assert_contains "${mapfile[$TEST_TMP/src/fallback.txt]}" "BETA" "patch fallback changes the target"
else
  (( TESTS += 2 )); pass "patch fallback unavailable (patch not installed)"; pass "fallback output unavailable (patch not installed)"
fi

tool_apply_patch $'*** Begin Patch\n*** Update File: src/note.txt\n@@\n-TWO\n+two\n*** End Patch\n'
assert_failure "apply_patch rejects unsupported patch envelopes clearly" $?
assert_contains "$TOOL_RESULT" "UNIFIED DIFF CONTRACT" "patch errors teach the canonical accepted format"
assert_contains "$TOOL_RESULT" "GOOD (valid focused edit)" "patch errors repeat a valid example"
assert_contains "$TOOL_RESULT" "BAD (invalid in this harness)" "patch errors contrast the unsupported envelope"
assert_contains "$TOOL_RESULT" "Counts describe hunk body lines" "patch errors explain numeric hunk counts"
tool_apply_patch $'--- a/src/note.txt\n+++ b/src/note.txt\n@@ -1,1 +1,1 @@\n-old TWO\n+new two\n'
assert_failure "apply_patch rejects invented semantic diff prefixes" $?
assert_contains "$TOOL_RESULT" "old and new are not diff syntax" "patch errors identify invented semantic prefixes"
tools_schema_json
assert_not_contains "$REPLY" '"name":"write_file"' "write_file is hidden after a rejected patch"
assert_not_contains "$REPLY" '"name":"replace_text"' "replace_text is hidden after a rejected patch"
tool_write_file "src/note.txt" "destructive fallback"
assert_failure "write_file cannot bypass a rejected focused patch" $?
assert_contains "$TOOL_RESULT" "corrected apply_patch" "blocked write_file directs the model back to patching"
assert_contains "${mapfile[$TEST_TMP/src/note.txt]}" "TWO" "blocked write_file leaves the target unchanged"
tool_replace_text "src/note.txt" "TWO" "two"
assert_failure "replace_text cannot bypass a rejected focused patch" $?
assert_contains "$TOOL_RESULT" "corrected apply_patch" "blocked replace_text directs the model back to patching"
tool_apply_patch $'--- a/src/note.txt\n+++ b/src/note.txt\n@@ -1,3 +1,3 @@\n one\n-TWO\n+two\n three\n'
assert_success "a corrected apply_patch releases patch recovery" $?
tools_schema_json
assert_contains "$REPLY" '"name":"write_file"' "write_file returns after the corrected patch succeeds"
assert_contains "$REPLY" '"name":"replace_text"' "replace_text returns after the corrected patch succeeds"
mapfile[$TEST_TMP/src/no-final-newline.txt]=$'before\n'
tool_apply_patch $'--- a/src/no-final-newline.txt\n+++ b/src/no-final-newline.txt\n@@ -1 +1 @@\n-before\n+after'
assert_success "apply_patch normalizes a missing final diff newline" $?
assert_contains "${mapfile[$TEST_TMP/src/no-final-newline.txt]}" "after" "normalized patch content is applied"
assert_not_contains "$TOOL_RESULT" "\$'\\n'" "patch success output contains real newlines"

tool_apply_patch $'*** ../escape.txt\n--- ../escape.txt\n***************\n*** 1 ****\n! outside\n--- 1 ----\n! escaped\n'
assert_failure "patch fallback rejects parent traversal" $?
if [[ -e "$TEST_TMP/../escape.txt" ]]; then escape_absent=1; else escape_absent=0; fi
assert_success "patch fallback leaves outside paths untouched" "$escape_absent"
TOOL_PATCH_RETRY_REQUIRED=0

mcp_home="$TEST_TMP/mcp-home"
mcp_fixture="${PROJECT_DIR}/tests/fixtures/mcp_server.zsh"
mcp_modern_log="$mcp_home/modern.log"
mcp_legacy_log="$mcp_home/legacy.log"
zf_mkdir -p "$mcp_home"
json_quote "$mcp_fixture"; mcp_fixture_json="$REPLY"
json_quote "$mcp_modern_log"; mcp_modern_log_json="$REPLY"
json_quote "$mcp_legacy_log"; mcp_legacy_log_json="$REPLY"
mapfile[$mcp_home/mcp.json]='{"mcpServers":{"modern":{"type":"stdio","command":"zsh","args":['"${mcp_fixture_json}"',"modern"],"env":{"MCP_FIXTURE_LOG":'"${mcp_modern_log_json}"'}},"shadowed":{"type":"stdio","command":"missing-user-command","args":[]}}}'
mapfile[$TEST_TMP/.mcp.json]='{"mcpServers":{"legacy":{"type":"stdio","command":"zsh","args":['"${mcp_fixture_json}"',"legacy"],"env":{"MCP_FIXTURE_LOG":'"${mcp_legacy_log_json}"'}},"shadowed":{"type":"stdio","command":"missing-project-command","args":[],"enabled":false}}}'
ZCODER_HOME="$mcp_home"
ZCODER_WORKSPACE="$TEST_TMP"
mcp_load
assert_success "MCP configuration loads user and project scopes" $?
assert_eq "3" "${#MCP_NAMES}" "MCP configuration merges named servers"
assert_eq "project" "${MCP_SCOPE[shadowed]}" "project MCP definitions override user definitions"
assert_eq "disabled" "${MCP_STATUS[shadowed]}" "disabled MCP servers remain visible without starting"
assert_eq "0" "${#MCP_BROKER_PID}" "MCP server processes are lazy at launch"
mcp_status_text
assert_eq $'legacy    configured  stdio  project\nmodern    configured  stdio  user\nshadowed  disabled    stdio  project' "$REPLY" "MCP status aligns columns with spaces"

raw_mcp_object='{"description":"mentions \"inputSchema\" before the field and contains } ]","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"commas, braces }, and brackets ] stay inside strings"}}}}'
_mcp_raw_member "$raw_mcp_object" inputSchema
assert_success "raw MCP member scan ignores field names and delimiters inside strings" $?
assert_eq '{"type":"object","properties":{"query":{"type":"string","description":"commas, braces }, and brackets ] stay inside strings"}}}' "$REPLY" "raw MCP member scan preserves the exact nested schema"
_mcp_raw_array_items '[{"value":"one,two"}, {"nested":[1,{"text":"]}"}]}, true]'
assert_success "raw MCP array scan handles nested values and delimiters in strings" $?
assert_eq "3" "${#MCP_RAW_ITEMS}" "raw MCP array scan returns every top-level item"
_mcp_response_parse '{"jsonrpc":"2.0","id":17,"result":{"tools":[{"description":"mentions \"result\""}]}}'
assert_eq '{"tools":[{"description":"mentions \"result\""}]}' "$MCP_RESPONSE_RESULT" "MCP response parsing preserves its raw result envelope"

mcp_connect modern
assert_success "modern stdio MCP server connects" $?
assert_eq "$MCP_VERSION_MODERN" "${MCP_PROTOCOL[modern]}" "server/discover negotiates the 2026 protocol"
assert_eq "3" "${#MCP_TOOL_NAMES}" "paginated modern tool discovery loads every page"
assert_eq "read_only" "${MCP_TOOL_EFFECT[mcp__modern__find_symbol]}" "MCP read-only annotations classify inspection tools"
assert_eq "external_write" "${MCP_TOOL_EFFECT[mcp__modern__create_pull_request]}" "MCP open-world writes classify as external mutations"
_mcp_tool_effect_from_record contradictory '{"annotations":{"readOnlyHint":true,"destructiveHint":true,"openWorldHint":false}}'
assert_eq "external_write" "$REPLY" "destructive MCP metadata wins over a contradictory read-only hint"
mcp_tools_schema_json
assert_contains "$REPLY" '"name":"mcp__modern__find_symbol"' "MCP tool names are namespaced and normalized for Ollama"
assert_contains "$REPLY" '"required":["query"]' "MCP input schemas remain intact in Ollama tool definitions"
assert_contains "$REPLY" "short tool name 'find-symbol'" "MCP schemas teach models how short instruction names map to functions"
assert_contains "$REPLY" "per-call user confirmation required" "MCP schemas disclose the external-write confirmation boundary"
mcp_prompt_block
assert_contains "$REPLY" 'modern/find-symbol [read_only] -> mcp__modern__find_symbol' "MCP prompt supplies an exact short-name routing map and effect"
assert_contains "$REPLY" "mandatory tool-selection rules" "MCP prompt makes required project routing mandatory"
assert_contains "$REPLY" "applicable repository investigation" "MCP prompt scopes designated orientation to repository investigations"
assert_contains "$REPLY" "mere mention of a repository" "MCP prompt does not treat repository nouns as investigation requests"
assert_contains "$REPLY" "respond directly without calling an MCP tool" "MCP prompt preserves direct responses when no evidence is needed"
tools_schema_json
first_name_marker='"name":"'
first_exposed_tool="${REPLY#*${first_name_marker}}"; first_exposed_tool="${first_exposed_tool%%\"*}"
[[ "$first_exposed_tool" == mcp__* ]]
assert_success "connected MCP tools precede generic built-ins" $?
assert_contains "$REPLY" "only when project instructions do not designate an MCP navigation tool" "search schema defers to project-designated MCP navigation"
agent_build_payload
assert_contains "$REPLY" 'modern/find-symbol [read_only] -> mcp__modern__find_symbol' "regular Ollama payloads include connected MCP routing"
saved_tool_phase="$AGENT_TOOL_PHASE"
AGENT_TOOL_PHASE=routing
tools_schema_json
assert_eq "[]" "$REPLY" "routing phase exposes no executable tool schema"
assert_not_contains "$REPLY" '"name":"list_files"' "routing phase withholds workspace tools"
assert_not_contains "$REPLY" '"name":"run_command"' "routing phase withholds command execution"
assert_not_contains "$REPLY" '"name":"mcp__modern__find_symbol"' "routing phase withholds MCP tools"
assert_not_contains "$REPLY" '"name":"finish"' "ordinary routing completes through plain assistant content"
agent_build_payload
assert_contains "$REPLY" '"format":{"type":"object"' "routing payload requests a structured decision"
assert_contains "$REPLY" '"enum":["respond","workspace","external"]' "routing schema separates direct, workspace, and external outcomes"
assert_contains "$REPLY" '"think":false' "routing decision disables model thinking"
assert_not_contains "$REPLY" '"tools":' "routing payload omits the native tool channel"
agent_resolve_system_prompt
assert_contains "$REPLY" "routing layer with no executable tools" "routing payload uses the short phase-specific prompt"
assert_contains "$REPLY" "Classify the requested outcome, not individual words" "routing prompt avoids keyword-triggered discovery"
assert_contains "$REPLY" "context, not a delivery destination" "routing prompt separates audiences from external destinations"
assert_contains "$REPLY" "If uncertain between respond and another mode, choose respond" "routing prompt resolves ambiguity without tools"
assert_not_contains "$REPLY" 'modern/find-symbol [read_only] -> mcp__modern__find_symbol' "routing prompt withholds the MCP function map"
agent_parse_route '{"mode":"respond","response":"Hello","reason":""}'
assert_success "valid direct routing decisions parse" $?
assert_eq "Hello" "$AGENT_ROUTE_RESPONSE" "direct routing preserves the user-facing response"
agent_parse_route '{"mode":"workspace","response":"","reason":"Current README contents are required."}'
assert_success "valid workspace routing decisions parse" $?
assert_eq "workspace" "$AGENT_ROUTE_MODE" "workspace routing preserves its capability mode"
agent_parse_route '{"mode":"external","response":"","reason":"Publish an issue to the named repository."}'
assert_success "valid external routing decisions parse" $?
assert_eq "external" "$AGENT_ROUTE_MODE" "external routing preserves its capability mode"
agent_parse_route '{"mode":"maybe","response":"","reason":"uncertain"}'
assert_failure "unknown routing modes are rejected" $?
tool_dispatch run_command '{"command":"print should-not-run"}'
assert_failure "dispatcher rejects a hidden capability" $?
assert_contains "$TOOL_RESULT" "not enabled" "hidden-tool rejection identifies the exposure boundary"
AGENT_TOOL_PHASE=workspace
tools_schema_json
assert_contains "$REPLY" '"name":"mcp__modern__find_symbol"' "workspace execution exposes read-only MCP tools"
assert_not_contains "$REPLY" '"name":"mcp__modern__create_pull_request"' "workspace execution withholds external MCP mutations"
assert_not_contains "$REPLY" '"name":"send_agent_message"' "workspace execution withholds inter-agent delivery"
assert_contains "$REPLY" '"name":"list_files"' "workspace execution restores core workspace tools"
tool_dispatch mcp__modern__create_pull_request '{"repository":"example/repo"}'
assert_failure "workspace dispatcher rejects a hidden external mutation" $?
AGENT_TOOL_PHASE=external
tools_schema_json
assert_contains "$REPLY" '"name":"mcp__modern__create_pull_request"' "external execution exposes confirmed mutation tools"
AGENT_TOOL_PHASE="$saved_tool_phase"
saved_agent_messages=("${AGENT_MESSAGES[@]}")
saved_agent_user_messages=("${AGENT_USER_MESSAGES[@]}")
AGENT_MESSAGES=()
AGENT_USER_MESSAGES=("exact user request")
agent_add_context_message "runtime recovery instruction"
assert_eq "1" "${#AGENT_MESSAGES}" "harness context is added to model history"
assert_contains "${AGENT_MESSAGES[1]}" '"role":"user"' "harness context uses a template-safe user role"
assert_eq "1" "${#AGENT_USER_MESSAGES}" "harness context stays out of the exact-user ledger"
AGENT_MESSAGES+=('{"role":"system","content":"legacy retry instruction"}')
agent_build_payload
assert_not_contains "$REPLY" ',{"role":"system"' "Ollama payloads never contain a mid-conversation system role"
assert_contains "$REPLY" ',{"role":"user","content":"legacy retry instruction"}' "legacy system records are normalized at the transport boundary"
assert_contains "$REPLY" "runtime recovery instruction" "template-safe payloads retain current harness context"
AGENT_MESSAGES=("${saved_agent_messages[@]}")
AGENT_USER_MESSAGES=("${saved_agent_user_messages[@]}")
tool_dispatch mcp__modern__echo_data '{"payload":{"nested":true}}'
assert_success "nested MCP tool arguments bypass the flat built-in decoder" $?
assert_contains "$TOOL_RESULT" "fixture call completed" "MCP tool results return to the model context"
assert_contains "${mapfile[$mcp_modern_log]}" '"io.modelcontextprotocol/clientCapabilities"' "modern MCP requests carry namespaced client metadata"
assert_contains "${mapfile[$mcp_modern_log]}" '"cursor":"page-2"' "MCP tool discovery follows pagination cursors"

saved_command_policy="$ZCODER_COMMAND_POLICY"
ZCODER_COMMAND_POLICY=allow
typeset -g MOCK_EXTERNAL_APPROVAL_TEXT=""
ui_confirm_external_action() { MOCK_EXTERNAL_APPROVAL_TEXT="$1"; REPLY="n"; }
modern_log_before="${mapfile[$mcp_modern_log]}"
tool_dispatch mcp__modern__create_pull_request '{"repository":"example/repo"}'
assert_failure "external MCP mutations fail closed when confirmation is denied" $?
assert_contains "$TOOL_RESULT" "user denied external action" "external denial is reported distinctly from command denial"
assert_contains "$MOCK_EXTERNAL_APPROVAL_TEXT" "modern/create-pull-request" "external confirmation names the exact MCP capability"
assert_eq "$modern_log_before" "${mapfile[$mcp_modern_log]}" "denied external mutations never reach the MCP server"
ui_confirm_external_action() { MOCK_EXTERNAL_APPROVAL_TEXT="$1"; REPLY="y"; }
tool_dispatch mcp__modern__create_pull_request '{"repository":"example/repo"}'
assert_success "one confirmed external MCP mutation executes" $?
assert_contains "$TOOL_RESULT" "fixture call completed" "confirmed external MCP results return normally"
unfunction ui_confirm_external_action
ZCODER_COMMAND_POLICY="$saved_command_policy"

mcp_connect legacy
assert_success "legacy stdio MCP server connects after the discovery probe" $?
assert_eq "$MCP_VERSION_LEGACY" "${MCP_PROTOCOL[legacy]}" "initialize negotiates the 2025 protocol"
assert_contains "${mapfile[$mcp_legacy_log]}" '"method":"initialize"' "legacy negotiation sends initialize after unsupported discovery"
assert_contains "${mapfile[$mcp_legacy_log]}" '"method":"notifications/initialized"' "legacy negotiation completes the initialization lifecycle"
mcp_tools_schema_json
assert_contains "$REPLY" '"name":"mcp__legacy__echo_data"' "tool catalog combines connected MCP servers"
mcp_status_text
assert_contains "$REPLY" 'modern    connected  stdio  user     2026-07-28' "MCP status includes connection, transport, scope, and version"
modern_broker_pid="${MCP_BROKER_PID[modern]}"
legacy_broker_pid="${MCP_BROKER_PID[legacy]}"
mcp_shutdown_all
assert_eq "0" "${#MCP_BROKER_PID}" "MCP shutdown clears every broker process"
kill -0 "$modern_broker_pid" 2>/dev/null
assert_failure "MCP shutdown reaps the modern broker" $?
kill -0 "$legacy_broker_pid" 2>/dev/null
assert_failure "MCP shutdown reaps the legacy broker" $?
cli_output="$(mcp_cli add --scope project --env FIXTURE_MODE=cli cli-server -- zsh "$mcp_fixture" legacy)"
assert_success "MCP CLI adds a project-scoped stdio server" $?
assert_contains "$cli_output" "Added MCP server 'cli-server'" "MCP CLI reports the added server"
mcp_load
assert_contains "${MCP_ARGS[cli-server]}" '"legacy"' "MCP CLI preserves command arguments as separate JSON values"
assert_contains "${MCP_ENV[cli-server]}" '"FIXTURE_MODE":"cli"' "MCP CLI preserves explicit environment values"
cli_output="$(mcp_cli disable --scope project cli-server)"; mcp_load
assert_eq "disabled" "${MCP_STATUS[cli-server]}" "MCP CLI disables the selected scope"
cli_output="$(mcp_cli enable --scope project cli-server)"; mcp_load
assert_eq "configured" "${MCP_STATUS[cli-server]}" "MCP CLI re-enables the selected scope"
cli_output="$(mcp_cli remove --scope project cli-server)"; mcp_load
[[ -z "${MCP_RAW[cli-server]:-}" ]]
assert_success "MCP CLI removes the selected scope" $?
zf_rm -f "$mcp_home/mcp.json" "$TEST_TMP/.mcp.json" 2>/dev/null
mcp_load

ZCODER_PROFILE=sysadmin
ZCODER_COMMAND_POLICY=allow
tool_sysadmin_command_guard "sudo rm -rf -- /"
assert_failure "sysadmin guard blocks literal root deletion" $?
assert_contains "$TOOL_SAFETY_REASON" "broad deletion" "catastrophic guard explains the blocked target"
tool_sysadmin_command_guard "sh -c 'rm -rf /home'"
assert_failure "sysadmin guard inspects nested shell commands" $?
tool_sysadmin_command_guard "dd if=/dev/zero of=/dev/sda"
assert_failure "sysadmin guard blocks raw device writes" $?
tool_sysadmin_command_guard "rm -rf ${ZCODER_WORKSPACE}/*"
assert_failure "sysadmin guard blocks clearing the whole workspace" $?
tool_sysadmin_command_guard "find / -xdev -delete"
assert_failure "sysadmin guard blocks broad find deletion" $?
tool_sysadmin_command_guard "rm -rf /var/log/obsolete-service"
assert_success "sysadmin guard permits scoped maintenance targets" $?
ui_confirm_command() { REPLY="a"; }
tool_run_command "print -r -- must-still-ask" . 2
assert_failure "sysadmin profile ignores session-wide command approval" $?
assert_contains "$TOOL_RESULT" "user denied" "sysadmin commands fail closed without per-command approval"
unfunction ui_confirm_command

ZCODER_PROFILE=coding
ZCODER_COMMAND_POLICY=deny
tool_run_command "print -r -- should-not-run" . 2
assert_failure "run_command honors deny policy" $?
assert_contains "$TOOL_RESULT" "user denied" "denied command is reported"

ZCODER_COMMAND_POLICY=allow
tool_run_command "print -r -- approved" . 2
assert_success "run_command honors allow policy" $?
assert_contains "$TOOL_RESULT" "approved" "run_command captures combined output"

json_parse_ollama_response '{"message":{"content":"done","thinking":"work","tool_calls":[{"type":"function","function":{"name":"read_file_range","arguments":{"path":"a b.txt","start_line":2,"end_line":4}}}]},"done":true,"prompt_eval_count":321,"eval_count":22}'
assert_success "Ollama response JSON parses" $?
assert_eq "read_file_range" "${JSON_TOOL_NAMES[1]}" "tool name is decoded"
assert_eq '{"path":"a b.txt","start_line":2,"end_line":4}' "${JSON_TOOL_ARGS[1]}" "tool arguments are preserved as JSON"
assert_eq "321" "$JSON_RESPONSE_PROMPT_TOKENS" "Ollama prompt token usage is decoded"
assert_eq "22" "$JSON_RESPONSE_OUTPUT_TOKENS" "Ollama output token usage is decoded"

json_parse_ollama_response '{"message":{"tool_calls":[{"function":{"name":"list_files","arguments":{}}},{"function":{"name":"search","arguments":{"query":"TODO"}}}]}}'
assert_success "parallel tool-call JSON parses" $?
assert_eq "2" "${#JSON_TOOL_NAMES}" "parallel tool calls are all retained"

json_parse_ollama_response '{"message":{"content":"","thinking":"<tool_call>run_command {\"command\":\"print unsafe\"}</tool_call>"}}'
assert_success "tool-like reasoning text remains valid reasoning" $?
assert_eq "0" "${#JSON_TOOL_NAMES}" "tool-like reasoning text is never promoted to a structured call"

json_parse_ollama_response '{"message":{"content":"pair \ud83d\ude00 ok"}}'
assert_success "surrogate-pair unicode escapes parse" $?
assert_eq $'pair \U0001f600 ok' "$JSON_RESPONSE_CONTENT" "surrogate pairs decode to the astral character"
json_parse_ollama_response '{"message":{"content":"pre \ud83d post"}}'
assert_success "a lone UTF-16 surrogate escape does not abort parsing" $?
assert_eq $'pre � post' "$JSON_RESPONSE_CONTENT" "a lone surrogate decodes to the replacement character"
json_begin '"\udc00\uD800\uD800"'
assert_success "adjacent unpairable surrogate escapes decode" $?
assert_eq $'���' "$JSON_TOKEN_VALUE" "each unpairable surrogate becomes one replacement character"

json_parse_running_model_context '{"models":[{"name":"other:latest","context_length":4096},{"name":"qwen:latest","model":"qwen:latest","context_length":65536}]}' "qwen:latest"
assert_success "running Ollama model metadata parses" $?
assert_eq "65536" "$JSON_RUNNING_MODEL_CONTEXT" "allocated model context is selected by name"
json_parse_running_model_context '{"models":[{"name":"example-model:latest","context_length":65536}]}' "example-model"
assert_success "running model lookup accepts Ollama's implicit latest tag" $?
assert_eq "65536" "$JSON_RUNNING_MODEL_CONTEXT" "untagged model names match their latest allocation"

_http_dechunk $'4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n'
assert_success "chunked HTTP bodies decode" $?
assert_eq "Wikipedia" "$REPLY" "HTTP decoder joins chunks"

json_parse_models '{"models":[{"name":"model-a:12b","details":{"family":"example"},"capabilities":["tools"]},{"name":"model-b:27b","size":123}]}'
assert_success "Ollama model-list JSON parses" $?
assert_eq "2" "${#JSON_MODEL_NAMES}" "all model names are retained"
assert_eq "model-b:27b" "${JSON_MODEL_NAMES[2]}" "model order is preserved"

http_request() {
  HTTP_BODY='{"models":[{"name":"mock-tools:latest"}]}'
  return 0
}
ollama_get_models "mock.invalid:11434"
assert_eq "mock-tools:latest" "${OLLAMA_MODELS[1]}" "model discovery exposes parsed names"

http_request() {
  HTTP_BODY='{"message":{"content":"async result"}}'
  HTTP_ERROR=""
  return 0
}
http_async_start POST /api/chat '{}' "mock.invalid:11434"
assert_success "async HTTP request starts" $?
for _ in {1..100}; do
  http_async_ready && break
  zselect -t 1 2>/dev/null
done
http_async_collect
assert_success "async HTTP result collects" $?
assert_contains "$HTTP_BODY" "async result" "async HTTP preserves the response body"
assert_eq "" "$HTTP_ASYNC_PID" "async HTTP clears its worker state"

http_request() {
  while true; do zselect -t 10 2>/dev/null; done
}
http_async_start POST /api/chat '{}' "mock.invalid:11434"
assert_success "cancellable HTTP request starts" $?
cancel_pid="$HTTP_ASYNC_PID"
cancel_base="$HTTP_ASYNC_BASE"
zselect -t 2 2>/dev/null
http_async_cancel
if kill -0 "$cancel_pid" 2>/dev/null; then cancel_stopped=1; else cancel_stopped=0; fi
assert_success "HTTP cancellation reaps the request worker" "$cancel_stopped"
if [[ -e "${cancel_base}.done" || -e "${cancel_base}.body" ]]; then cancel_clean=1; else cancel_clean=0; fi
assert_success "HTTP cancellation removes request files" "$cancel_clean"
assert_contains "$HTTP_ERROR" "cancelled" "HTTP cancellation reports its reason"

typeset -ga MOCK_INHERITED_FD_CLOSES=()
ztcp() {
  [[ "$1" == -c ]] && MOCK_INHERITED_FD_CLOSES+=("$2")
  return 0
}
_http_close_inherited_fds 7 invalid 9
assert_eq "2" "${#MOCK_INHERITED_FD_CLOSES}" "descriptor cleanup ignores invalid inherited descriptors"
assert_eq "7 9" "${(j: :)MOCK_INHERITED_FD_CLOSES}" "descriptor cleanup closes every inherited server socket"
unfunction ztcp

ui_wait_for_generation() { return 130; }
ui_draw_footer() { return 0; }
UI_ACTIVE=1
agent_ollama_chat '{}' "mock.invalid:11434"
agent_cancel_status=$?
assert_eq "130" "$agent_cancel_status" "agent maps Escape polling to cancellation"
assert_eq "1" "$AGENT_CANCELLED" "agent records intentional cancellation"
assert_contains "$HTTP_ERROR" "Escape pressed" "HTTP cancellation records why the client disconnected"
UI_ACTIVE=0
unfunction ui_wait_for_generation ui_draw_footer

remote_normalize_endpoint buildbox
assert_success "remote endpoints accept a hostname" $?
assert_eq "buildbox:7337" "$REPLY" "remote endpoints receive the default port"
remote_normalize_endpoint http://buildbox.local:8123
assert_success "remote endpoints accept an explicit HTTP port" $?
assert_eq "buildbox.local:8123" "$REPLY" "remote endpoint normalization removes the HTTP scheme"
remote_normalize_endpoint https://buildbox.local
assert_failure "remote endpoints reject unsupported HTTPS" $?
assert_contains "$REMOTE_ERROR" "HTTPS is not supported" "remote HTTPS rejection explains the native transport limit"

remote_token_file="$TEST_TMP/remote-token"
mapfile[$remote_token_file]="short"
zf_chmod 600 "$remote_token_file"
remote_load_token "$remote_token_file"
assert_failure "remote authentication rejects short tokens" $?
remote_token_value="abcdefghijklmnopqrstuvwxyz0123456789ABCDEF"
mapfile[$remote_token_file]="${remote_token_value}"$'\n'
zf_chmod 644 "$remote_token_file"
remote_load_token "$remote_token_file"
assert_failure "remote authentication refuses a group- or world-accessible token file" $?
assert_contains "$REMOTE_ERROR" "chmod 600" "token permission refusal explains the required fix"
zf_chmod 640 "$remote_token_file"
remote_load_token "$remote_token_file"
assert_failure "remote authentication refuses a group-readable token file" $?
zf_chmod 400 "$remote_token_file"
remote_load_token "$remote_token_file"
assert_success "remote authentication accepts a stricter read-only private token file" $?
zf_chmod 600 "$remote_token_file"
remote_load_token "$remote_token_file"
assert_success "remote authentication loads a URL-safe token file" $?
assert_eq "$remote_token_value" "$REMOTE_TOKEN" "remote authentication trims the token file newline"

remote_runtime="$TEST_TMP/remote-runtime"
zf_mkdir -p "$remote_runtime/events" "$remote_runtime/approvals"
REMOTE_RUNTIME_DIR="$remote_runtime"
remote_server_emit_message assistant $'remote hello\nsecond line' "private thought"
assert_success "remote message events publish atomically" $?
remote_server_emit_status "Thinking 1"
assert_success "remote status events publish atomically" $?
_remote_server_next_event 0
assert_success "remote event polling returns the first unseen event" $?
json_parse_flat_object "$REPLY"
assert_success "remote event envelopes remain flat valid JSON" $?
assert_eq "1" "${JSON_OBJECT[seq]}" "remote events receive ordered sequence numbers"
assert_eq $'remote hello\nsecond line' "${JSON_OBJECT[content]}" "remote events preserve multiline content"
_remote_server_next_event 1
assert_success "remote event polling advances by cursor" $?
json_parse_flat_object "$REPLY"
assert_eq "Thinking 1" "${JSON_OBJECT[status]}" "remote status events preserve their display text"
_remote_server_next_event 2
remote_next_status=$?
assert_failure "remote event polling reports an empty tail" $remote_next_status
assert_eq '{"event":"none"}' "$REPLY" "empty remote event polls return a stable envelope"

transcript_reset
remote_server_worker_emit tool "persist this visible result" "worker reasoning"
assert_eq "tool" "${UI_ROLES[1]}" "remote workers retain emitted roles in the persistent transcript"
assert_eq "persist this visible result" "${UI_CONTENTS[1]}" "remote workers retain emitted content in the persistent transcript"

saved_remote_sessions_dir="$ZCODER_SESSIONS_DIR"
saved_remote_workspace="$ZCODER_WORKSPACE"
saved_remote_profile="$ZCODER_PROFILE"
saved_remote_session_id="$REMOTE_SESSION_ID"
saved_remote_state_enabled="$STATE_ENABLED"
saved_remote_current_session_id="$CURRENT_SESSION_ID"
saved_remote_session_ids=("${SESSION_IDS[@]}")
saved_remote_session_titles=("${SESSION_TITLES[@]}")
saved_remote_session_models=("${SESSION_MODELS[@]}")
ZCODER_SESSIONS_DIR="$remote_runtime/sessions"
ZCODER_WORKSPACE="$TEST_TMP/remote-workspace"
ZCODER_PROFILE=coding
STATE_ENABLED=0
remote_newer_id="2000000000_2"
remote_current_id="1000000000_1"
for remote_fixture_id in "$remote_newer_id" "$remote_current_id"; do
  remote_fixture_dir="$ZCODER_SESSIONS_DIR/${remote_fixture_id}.session"
  zf_mkdir -p "$remote_fixture_dir/ui_events"
  mapfile[$remote_fixture_dir/workspace]="${ZCODER_WORKSPACE:A}"
  mapfile[$remote_fixture_dir/profile]="$ZCODER_PROFILE"
  mapfile[$remote_fixture_dir/model]="remote-model"
  mapfile[$remote_fixture_dir/title]="Remote ${remote_fixture_id}"
  mapfile[$remote_fixture_dir/updated_at]="${remote_fixture_id%%_*}"
  mapfile[$remote_fixture_dir/ui_event_count]="0"
done
REMOTE_SESSION_ID="$remote_current_id"
remote_fixture_dir="$ZCODER_SESSIONS_DIR/${remote_current_id}.session"
mapfile[$remote_fixture_dir/ui_event_count]="1"
mapfile[$remote_fixture_dir/ui_events/000001.role]="assistant"
mapfile[$remote_fixture_dir/ui_events/000001.content]=$'saved remote reply\nsecond line'
mapfile[$remote_fixture_dir/ui_events/000001.thinking]="saved reasoning"
mapfile[$remote_fixture_dir/ui_events/000001.time]="21:27"
mapfile[$remote_fixture_dir/ui_events/000001.reasoning_open]="1"

_remote_server_session_summary 0
assert_success "remote session listing returns its newest session" $?
json_parse_flat_object "$REPLY"
assert_success "remote session summaries remain flat valid JSON" $?
assert_eq "$remote_newer_id" "${JSON_OBJECT[id]}" "remote session listing is ordered by recent activity"
assert_eq "0" "${JSON_OBJECT[current]}" "remote session summaries distinguish inactive jobs"
assert_eq "1" "${JSON_OBJECT[empty]}" "remote session summaries identify untouched jobs"
assert_eq "Remote ${remote_newer_id}" "${JSON_OBJECT[title]}" "remote session summaries preserve titles"
_remote_server_session_summary 1
assert_success "remote session listing advances by cursor" $?
json_parse_flat_object "$REPLY"
assert_eq "$remote_current_id" "${JSON_OBJECT[id]}" "remote session listing returns every scoped job"
assert_eq "1" "${JSON_OBJECT[current]}" "remote session summaries identify the selected job"
assert_eq "0" "${JSON_OBJECT[empty]}" "remote session summaries identify jobs with persisted events"
_remote_server_session_summary 2
assert_failure "remote session listing reports an empty tail" $?
assert_eq '{"event":"none"}' "$REPLY" "empty remote session lists return a stable envelope"

_remote_server_session_event "$remote_current_id" 0
assert_success "remote transcript loading returns a persisted event" $?
json_parse_flat_object "$REPLY"
assert_success "remote transcript events remain flat valid JSON" $?
assert_eq $'saved remote reply\nsecond line' "${JSON_OBJECT[content]}" "remote transcript loading preserves multiline content"
assert_eq "saved reasoning" "${JSON_OBJECT[thinking]}" "remote transcript loading preserves reasoning"
assert_eq "21:27" "${JSON_OBJECT[time]}" "remote transcript loading preserves display timestamps"
assert_eq "1" "${JSON_OBJECT[reasoning_open]}" "remote transcript loading preserves reasoning visibility"
_remote_server_session_event "../../escape" 0
assert_eq "2" "$?" "remote transcript loading rejects unsafe session identifiers"

ZCODER_SESSIONS_DIR="$saved_remote_sessions_dir"
ZCODER_WORKSPACE="$saved_remote_workspace"
ZCODER_PROFILE="$saved_remote_profile"
REMOTE_SESSION_ID="$saved_remote_session_id"
STATE_ENABLED="$saved_remote_state_enabled"
CURRENT_SESSION_ID="$saved_remote_current_session_id"
SESSION_IDS=("${saved_remote_session_ids[@]}")
SESSION_TITLES=("${saved_remote_session_titles[@]}")
SESSION_MODELS=("${saved_remote_session_models[@]}")

_remote_server_clear_turn_runtime
REMOTE_TURN_ID="12345_67"
REMOTE_APPROVAL_TIMEOUT=5
remote_approval_result="$remote_runtime/approval-result"
(remote_server_request_approval "print -r -- approved"; mapfile[$remote_approval_result]="$?:$REPLY") &
remote_approval_pid=$!
remote_approval_deadline=$(( EPOCHREALTIME + 2 ))
while [[ ! -f "$remote_runtime/pending_approval" ]] && (( EPOCHREALTIME < remote_approval_deadline )); do zselect -t 1; done
remote_approval_id="${mapfile[$remote_runtime/pending_approval]:-}"
[[ "$remote_approval_id" == 12345_67_<0-> ]]
assert_success "remote command approval publishes a one-use identifier" $?
_remote_server_next_event 0
assert_success "remote command approval emits an event for the client" $?
assert_contains "$REPLY" '"event":"approval_required"' "remote approval events identify their purpose"
assert_contains "$REPLY" '"kind":"command"' "remote command approval events retain their approval kind"
mapfile[$remote_runtime/approvals/${remote_approval_id}.response.tmp]="y"
zf_mv -f "$remote_runtime/approvals/${remote_approval_id}.response.tmp" "$remote_runtime/approvals/${remote_approval_id}.response"
wait "$remote_approval_pid"
assert_eq "0:y" "${mapfile[$remote_approval_result]}" "remote command approval resumes only with the matching response"

_remote_server_clear_turn_runtime
zf_mkdir -p "$ZCODER_SESSIONS_DIR/7777777777_888.session"
saved_remote_cancel_session_id="$REMOTE_SESSION_ID"
REMOTE_SESSION_ID="7777777777_888"
mapfile[$ZCODER_SESSIONS_DIR/$REMOTE_SESSION_ID.session/goal_status]="active"
(while true; do zselect -t 10; done) &
remote_cancel_pid=$!
mapfile[$remote_runtime/active.pid]="$remote_cancel_pid"
_remote_server_cancel_turn
assert_success "remote turn cancellation accepts an active worker" $?
if kill -0 "$remote_cancel_pid" 2>/dev/null; then remote_cancel_alive=1; else remote_cancel_alive=0; fi
assert_success "remote turn cancellation reaps the worker" "$remote_cancel_alive"
if [[ -f "$remote_runtime/active.pid" ]]; then remote_cancel_active=1; else remote_cancel_active=0; fi
assert_success "remote turn cancellation clears the active marker" "$remote_cancel_active"
_remote_server_next_event 1
assert_success "remote turn cancellation publishes a completion event" $?
assert_contains "$REPLY" '"exit_code":130' "remote cancellation completion carries the stopped status"
assert_eq "paused" "${mapfile[$ZCODER_SESSIONS_DIR/$REMOTE_SESSION_ID.session/goal_status]}" "remote cancellation persists an active goal as paused"
REMOTE_SESSION_ID="$saved_remote_cancel_session_id"

saved_remote_context_lookup="${functions[ollama_get_running_context]}"
saved_remote_warmup_start="${functions[_remote_server_model_start_warmup]}"
saved_remote_http_ready="${functions[http_async_ready]}"
saved_remote_http_collect="${functions[http_async_collect]}"
saved_remote_context_refresh="${functions[agent_context_refresh_after_response]}"
saved_remote_client_request="${functions[remote_client_request]}"
saved_remote_status_setter="${functions[agent_set_status]}"
saved_remote_emitter="${functions[agent_emit]}"
saved_remote_turn_start="${functions[_remote_server_start_turn]}"
saved_remote_model_poll="${functions[_remote_server_model_poll]}"
saved_remote_warmup_setting="$ZCODER_WARMUP"
saved_remote_ui_active="$UI_ACTIVE"
saved_remote_payload_builder="${functions[agent_build_warmup_payload]}"
saved_remote_async_start="${functions[http_async_start]}"
saved_remote_listen_fd="$REMOTE_LISTEN_FD"

typeset -g MOCK_REMOTE_WARMUP_FDS=""
agent_build_warmup_payload() { REPLY='{"warmup":true}'; }
http_async_start() {
  MOCK_REMOTE_WARMUP_FDS="$5:$6"
  return 0
}
REMOTE_LISTEN_FD=51
_remote_server_model_start_warmup 52
assert_success "remote warm-up starts without retaining the handshake socket" $?
assert_eq "51:52" "$MOCK_REMOTE_WARMUP_FDS" "remote warm-up detaches the inherited listener and client descriptors"
assert_eq "warming" "$REMOTE_MODEL_STATUS" "detached remote warm-up enters the warming state"
functions[agent_build_warmup_payload]="$saved_remote_payload_builder"
functions[http_async_start]="$saved_remote_async_start"
REMOTE_LISTEN_FD="$saved_remote_listen_fd"

typeset -gi MOCK_REMOTE_CONTEXT_CHECKS=0 MOCK_REMOTE_WARMUP_STARTS=0
ollama_get_running_context() {
  (( MOCK_REMOTE_CONTEXT_CHECKS++ ))
  OLLAMA_RUNNING_CONTEXT=32768
  HTTP_ERROR=""
  return 0
}
_remote_server_model_start_warmup() {
  (( MOCK_REMOTE_WARMUP_STARTS++ ))
  REMOTE_MODEL_STATUS="warming"
  return 0
}
ZCODER_WARMUP=true
REMOTE_MODEL_STATUS="unknown"
_remote_server_model_ensure 1
assert_success "remote residency checks accept an already loaded configured model" $?
assert_eq "ready" "$REMOTE_MODEL_STATUS" "resident remote models become ready without a warm-up"
assert_eq "0" "$MOCK_REMOTE_WARMUP_STARTS" "resident remote models do not start a warm-up request"
assert_eq "32768" "$AGENT_CONTEXT_WINDOW" "remote residency checks retain the loaded context allocation"

ollama_get_running_context() {
  (( MOCK_REMOTE_CONTEXT_CHECKS++ ))
  OLLAMA_RUNNING_CONTEXT=0
  HTTP_ERROR=""
  return 1
}
REMOTE_MODEL_STATUS="ready"
_remote_server_model_ensure 1
remote_missing_status=$?
assert_eq "1" "$remote_missing_status" "an evicted remote model reports warm-up in progress"
assert_eq "warming" "$REMOTE_MODEL_STATUS" "an evicted remote model enters the warming state"
assert_eq "1" "$MOCK_REMOTE_WARMUP_STARTS" "a forced pre-turn check starts warm-up after eviction"

typeset -gi MOCK_REMOTE_COLLECTS=0 MOCK_REMOTE_REFRESHES=0
http_async_ready() { return 1; }
REMOTE_MODEL_STATUS="warming"
_remote_server_model_poll
assert_eq "1" "$?" "an unfinished remote warm-up remains pending"
http_async_ready() { return 0; }
http_async_collect() {
  (( MOCK_REMOTE_COLLECTS++ ))
  HTTP_BODY='{"message":{"content":"Ready"},"done":true}'
  HTTP_ERROR=""
  return 0
}
agent_context_refresh_after_response() { (( MOCK_REMOTE_REFRESHES++ )); }
_remote_server_model_poll
assert_success "a completed remote warm-up is collected" $?
assert_eq "ready" "$REMOTE_MODEL_STATUS" "a successful remote warm-up changes model state to ready"
assert_eq "1" "$MOCK_REMOTE_COLLECTS" "remote warm-up completion collects its HTTP worker"
assert_eq "1" "$MOCK_REMOTE_REFRESHES" "remote warm-up completion refreshes context allocation"

typeset -ga MOCK_REMOTE_CLIENT_REQUESTS=()
typeset -g MOCK_REMOTE_CLIENT_STATUS=""
remote_client_request() {
  MOCK_REMOTE_CLIENT_REQUESTS+=("$1:$2")
  if [[ "$1:$2" == POST:/v1/model/ensure ]]; then
    HTTP_BODY='{"model_status":"warming","model_error":""}'
  else
    HTTP_BODY='{"model_status":"ready","model_error":""}'
  fi
  REMOTE_ERROR=""
  return 0
}
agent_set_status() { MOCK_REMOTE_CLIENT_STATUS="$1"; }
agent_emit() { return 0; }
UI_ACTIVE=0
REMOTE_MODEL_STATUS="warming"
REMOTE_CLIENT_NEXT_MODEL_POLL=0
remote_client_model_ensure
assert_success "remote clients hold a prompt until connection-triggered warm-up completes" $?
assert_contains "${(j: :)MOCK_REMOTE_CLIENT_REQUESTS}" "POST:/v1/model/ensure" "each remote prompt requests a fresh residency check"
assert_contains "${(j: :)MOCK_REMOTE_CLIENT_REQUESTS}" "GET:/v1/model" "remote clients poll an active model warm-up"
assert_eq "Ready" "$MOCK_REMOTE_CLIENT_STATUS" "remote clients become ready after warm-up"

MOCK_REMOTE_CLIENT_REQUESTS=()
REMOTE_MODEL_STATUS="unmanaged"
remote_client_model_ensure
assert_success "new clients remain compatible with servers lacking model status" $?
assert_eq "0" "${#MOCK_REMOTE_CLIENT_REQUESTS}" "legacy remote servers bypass the new readiness endpoint"

typeset -ga MOCK_REMOTE_SESSION_REQUESTS=()
typeset -g MOCK_REMOTE_SELECTED_SESSION="3000000000_3"
typeset -g MOCK_REMOTE_SELECT_PAYLOAD=""
remote_client_request() {
  local -i mock_current=0
  MOCK_REMOTE_SESSION_REQUESTS+=("$1:$2")
  case "$1:$2" in
    GET:/v1/sessions\?after=0)
      [[ "$MOCK_REMOTE_SELECTED_SESSION" == "3000000000_3" ]] && mock_current=1
      HTTP_BODY="{\"event\":\"session\",\"seq\":1,\"id\":\"3000000000_3\",\"title\":\"Current remote job\",\"model\":\"remote-model\",\"current\":${mock_current},\"empty\":0}"
      ;;
    GET:/v1/sessions\?after=1)
      [[ "$MOCK_REMOTE_SELECTED_SESSION" == "2000000000_2" ]] && mock_current=1
      HTTP_BODY="{\"event\":\"session\",\"seq\":2,\"id\":\"2000000000_2\",\"title\":\"Older remote job\",\"model\":\"remote-model\",\"current\":${mock_current},\"empty\":1}"
      ;;
    GET:/v1/sessions\?after=2) HTTP_BODY='{"event":"none"}' ;;
    GET:/v1/session\?id=3000000000_3\&after=0)
      HTTP_BODY='{"event":"message","seq":1,"role":"assistant","content":"persisted reply","thinking":"persisted thought","time":"20:15","reasoning_open":1}'
      ;;
    GET:/v1/session\?id=3000000000_3\&after=1|GET:/v1/session\?id=2000000000_2\&after=0)
      HTTP_BODY='{"event":"none"}'
      ;;
    POST:/v1/session/select)
      MOCK_REMOTE_SELECT_PAYLOAD="${3:-}"
      json_parse_flat_object "${3:-}" || return 1
      MOCK_REMOTE_SELECTED_SESSION="${JSON_OBJECT[id]:-}"
      HTTP_BODY='{"ok":true}'
      ;;
    *) REMOTE_ERROR="unexpected mock remote session request: $1 $2"; return 1 ;;
  esac
  REMOTE_ERROR=""
  return 0
}
REMOTE_SESSIONS_SUPPORTED=1
CURRENT_SESSION_ID=""
SESSION_IDS=(); SESSION_TITLES=(); SESSION_MODELS=()
remote_client_refresh_sessions
assert_success "remote clients load the server-owned session list" $?
assert_eq "2" "${#SESSION_IDS}" "remote clients retain every listed server session"
assert_eq "3000000000_3" "$CURRENT_SESSION_ID" "remote clients adopt the server-selected session"
assert_eq "Current remote job" "$SESSION_TITLE" "remote clients retain the selected session title"
assert_eq "0" "$REMOTE_SESSION_EMPTY" "remote clients detect a previously used selected session"
assert_contains "${(j: :)MOCK_REMOTE_SESSION_REQUESTS}" "GET:/v1/sessions?after=2" "remote clients paginate through the session-list tail"
remote_client_load_session "$CURRENT_SESSION_ID"
assert_success "remote clients load the selected transcript" $?
assert_eq "1" "${#UI_ROLES}" "remote clients restore every persisted transcript event"
assert_eq "assistant" "${UI_ROLES[1]}" "remote clients restore transcript roles"
assert_eq "persisted reply" "${UI_CONTENTS[1]}" "remote clients restore transcript content"
assert_eq "20:15" "${UI_TIMES[1]}" "remote clients restore transcript timestamps"
assert_eq "1" "${UI_REASONING_OPEN[1]}" "remote clients restore expanded reasoning state"
remote_client_select_session "2000000000_2"
assert_success "remote clients can select another server-owned session" $?
assert_contains "$MOCK_REMOTE_SELECT_PAYLOAD" '"id":"2000000000_2"' "remote session selection sends the exact safe identifier"
assert_eq "2000000000_2" "$CURRENT_SESSION_ID" "remote session selection updates the active client job"
assert_eq "1" "$REMOTE_SESSION_EMPTY" "remote clients detect a selected session that is still empty"

saved_remote_session_refresh="${functions[remote_client_refresh_sessions]}"
saved_remote_session_load="${functions[remote_client_load_session]}"
saved_remote_session_new="${functions[remote_client_new_session]}"
typeset -gi MOCK_REMOTE_START_LOADS=0 MOCK_REMOTE_START_NEWS=0
typeset -g MOCK_REMOTE_START_LOADED_ID=""
remote_client_refresh_sessions() { return 0; }
remote_client_load_session() { (( MOCK_REMOTE_START_LOADS++ )); MOCK_REMOTE_START_LOADED_ID="$1"; return 0; }
remote_client_new_session() { (( MOCK_REMOTE_START_NEWS++ )); return 0; }
CURRENT_SESSION_ID="3000000000_3"
REMOTE_SESSION_EMPTY=0
remote_client_start_session
assert_success "remote client startup prepares a fresh job after a used session" $?
assert_eq "1" "$MOCK_REMOTE_START_NEWS" "remote client startup does not resume a used session"
assert_eq "0" "$MOCK_REMOTE_START_LOADS" "remote client startup leaves prior transcript loading explicit"
MOCK_REMOTE_START_LOADS=0
MOCK_REMOTE_START_NEWS=0
CURRENT_SESSION_ID="2000000000_2"
REMOTE_SESSION_EMPTY=1
remote_client_start_session
assert_success "remote client startup accepts an already-empty selected job" $?
assert_eq "0" "$MOCK_REMOTE_START_NEWS" "remote client startup avoids duplicate blank sessions"
assert_eq "2000000000_2" "$MOCK_REMOTE_START_LOADED_ID" "remote client startup loads the existing empty job"
functions[remote_client_refresh_sessions]="$saved_remote_session_refresh"
functions[remote_client_load_session]="$saved_remote_session_load"
functions[remote_client_new_session]="$saved_remote_session_new"

functions[remote_client_request]="$saved_remote_client_request"
functions[agent_set_status]="$saved_remote_status_setter"
functions[agent_emit]="$saved_remote_emitter"
typeset -gi MOCK_REMOTE_TURN_STARTS=0
typeset -g MOCK_REMOTE_STARTED_PROMPT=""
_remote_server_model_poll() {
  REMOTE_MODEL_STATUS="ready"
  return 0
}
_remote_server_start_turn() {
  (( MOCK_REMOTE_TURN_STARTS++ ))
  MOCK_REMOTE_STARTED_PROMPT="$1"
  REPLY="queued-turn"
  return 0
}
_remote_server_clear_turn_runtime
REMOTE_MODEL_STATUS="warming"
_remote_server_queue_turn "queued while warming"
assert_success "remote prompts can be queued during a warm-up race" $?
[[ -f "$remote_runtime/pending_prompt" ]]
assert_success "queued remote prompts remain pending on disk" $?
assert_eq "queued while warming" "${mapfile[$remote_runtime/pending_prompt]}" "queued remote prompts preserve exact content"
_remote_server_progress_pending_turn
assert_success "a queued remote prompt starts after model warm-up" $?
assert_eq "1" "$MOCK_REMOTE_TURN_STARTS" "model readiness starts exactly one queued turn worker"
assert_eq "queued while warming" "$MOCK_REMOTE_STARTED_PROMPT" "the queued prompt reaches the turn worker unchanged"
[[ ! -f "$remote_runtime/pending_prompt" ]]
assert_success "starting a queued turn clears its pending marker" $?

_remote_server_clear_turn_runtime
REMOTE_MODEL_STATUS="warming"
_remote_server_queue_turn "cancel before ready"
_remote_server_cancel_turn
assert_success "remote cancellation accepts a prompt waiting for model warm-up" $?
[[ ! -f "$remote_runtime/pending_prompt" ]]
assert_success "cancelling a queued prompt clears its pending marker" $?
_remote_server_next_event 1
assert_success "queued-prompt cancellation publishes completion" $?
assert_contains "$REPLY" '"exit_code":130' "queued-prompt cancellation reports the stopped exit code"

functions[ollama_get_running_context]="$saved_remote_context_lookup"
functions[_remote_server_model_start_warmup]="$saved_remote_warmup_start"
functions[http_async_ready]="$saved_remote_http_ready"
functions[http_async_collect]="$saved_remote_http_collect"
functions[agent_context_refresh_after_response]="$saved_remote_context_refresh"
functions[_remote_server_start_turn]="$saved_remote_turn_start"
functions[_remote_server_model_poll]="$saved_remote_model_poll"
ZCODER_WARMUP="$saved_remote_warmup_setting"
UI_ACTIVE="$saved_remote_ui_active"
REMOTE_RUNTIME_DIR=""
REMOTE_TURN_ID=""
REMOTE_APPROVAL_TIMEOUT=300

guide_root="$TEST_TMP/instruction-repo"
guide_work="$guide_root/services/payments"
guide_home="$TEST_TMP/zcoder-home"
zf_mkdir -p "$guide_root/.git" "$guide_work" "$guide_home"
mapfile[$guide_home/AGENTS.md]="ignored global base"
mapfile[$guide_home/AGENTS.override.md]="global override rule"
mapfile[$guide_root/AGENTS.md]="root project rule"
mapfile[$guide_root/services/AGENTS.md]="ignored service base"
mapfile[$guide_root/services/AGENTS.override.md]="service override rule"
mapfile[$guide_work/TEAM_GUIDE.md]="payment fallback rule"
ZCODER_HOME="$guide_home"
ZCODER_WORKSPACE="$guide_work"
ZCODER_PROJECT_DOC_FALLBACKS="TEAM_GUIDE.md"
ZCODER_PROJECT_DOC_MAX_BYTES=32768
instructions_load "$ZCODER_WORKSPACE"
assert_success "instruction discovery succeeds" $?
assert_eq "$guide_root" "$INSTRUCTIONS_PROJECT_ROOT" "Git root bounds project discovery"
assert_eq "4" "${#INSTRUCTION_SOURCES}" "one instruction file is loaded per scope"
assert_eq "$guide_home/AGENTS.override.md" "${INSTRUCTION_SOURCES[1]}" "global override wins"
assert_eq "$guide_root/AGENTS.md" "${INSTRUCTION_SOURCES[2]}" "root AGENTS.md loads second"
assert_eq "$guide_root/services/AGENTS.override.md" "${INSTRUCTION_SOURCES[3]}" "nested override wins"
assert_eq "$guide_work/TEAM_GUIDE.md" "${INSTRUCTION_SOURCES[4]}" "configured fallback loads"
assert_contains "$INSTRUCTIONS_TEXT" "global override rule" "global instructions are merged"
assert_contains "$INSTRUCTIONS_TEXT" "root project rule" "project instructions are merged"
assert_contains "$INSTRUCTIONS_TEXT" "service override rule" "nested instructions are merged"
assert_contains "$INSTRUCTIONS_TEXT" "payment fallback rule" "fallback instructions are merged"
assert_not_contains "$INSTRUCTIONS_TEXT" "ignored global base" "global base is ignored beside override"
assert_not_contains "$INSTRUCTIONS_TEXT" "ignored service base" "scoped base is ignored beside override"
agent_build_payload
assert_contains "$REPLY" "root project rule" "resolved instructions enter the system prompt"
assert_contains "$REPLY" "mandatory requirements, not reference material" "resolved instructions are framed as mandatory"
assert_contains "$REPLY" "Before finishing, verify that every applicable project instruction" "resolved instructions add a completion check"

empty_override_root="$TEST_TMP/empty-override"
zf_mkdir -p "$empty_override_root" "$TEST_TMP/empty-zcoder-home"
mapfile[$empty_override_root/AGENTS.override.md]=$'  \n\t'
mapfile[$empty_override_root/AGENTS.md]="nonempty base rule"
ZCODER_HOME="$TEST_TMP/empty-zcoder-home"
ZCODER_WORKSPACE="$empty_override_root"
ZCODER_PROJECT_DOC_FALLBACKS=""
instructions_load "$ZCODER_WORKSPACE"
assert_eq "$empty_override_root" "$INSTRUCTIONS_PROJECT_ROOT" "non-Git discovery is limited to the workspace"
assert_eq "$empty_override_root/AGENTS.md" "${INSTRUCTION_SOURCES[1]}" "empty overrides fall through to AGENTS.md"
assert_eq "nonempty base rule" "$INSTRUCTIONS_TEXT" "the non-empty fallback content is loaded"

trunc_root="$TEST_TMP/truncated-instructions"
zf_mkdir -p "$trunc_root"
mapfile[$trunc_root/AGENTS.md]="0123456789abcdef"
ZCODER_HOME="$TEST_TMP/empty-zcoder-home"
ZCODER_WORKSPACE="$trunc_root"
ZCODER_PROJECT_DOC_FALLBACKS=""
ZCODER_PROJECT_DOC_MAX_BYTES=10
instructions_load "$ZCODER_WORKSPACE"
assert_eq "1" "$INSTRUCTIONS_TRUNCATED" "oversized instruction chains report truncation"
assert_eq "10" "$INSTRUCTIONS_BYTES" "instruction byte cap is enforced"
assert_eq "0123456789" "$INSTRUCTIONS_TEXT" "instruction content is truncated at the cap"

mapfile[$trunc_root/AGENTS.md]="ééé"
ZCODER_PROJECT_DOC_MAX_BYTES=3
instructions_load "$ZCODER_WORKSPACE"
assert_eq "é" "$INSTRUCTIONS_TEXT" "UTF-8 instructions are not split mid-character"
assert_eq "2" "$INSTRUCTIONS_BYTES" "UTF-8 byte accounting is exact"

skill_config_root="$TEST_TMP/config-agents-skills"
skill_user_root="$TEST_TMP/user-agents-skills"
skill_project_root="$TEST_TMP/skill-project"
zf_mkdir -p "$skill_config_root/config-only" "$skill_config_root/shared-skill" \
  "$skill_user_root/folded-skill/references" "$skill_user_root/shared-skill" \
  "$skill_user_root/broken-skill" "$skill_project_root/.agents/skills/shared-skill"
mapfile[$skill_config_root/config-only/SKILL.md]=$'---\nname: config-only\ndescription: "Handles config tasks: use it for quoted descriptions."\nallowed-tools: Bash(*)\n---\n\nCONFIG BODY SENTINEL'
mapfile[$skill_config_root/shared-skill/SKILL.md]=$'---\nname: shared-skill\ndescription: Config-level copy.\n---\n\nCONFIG SHARED BODY'
mapfile[$skill_user_root/folded-skill/SKILL.md]=$'---\nname: folded-skill\ndescription: >\n  Handles folded descriptions.\n  Use for parser verification.\n---\n\n# Folded Skill\n\nFOLDED BODY SENTINEL\n\nRead references/guide.md when needed.'
mapfile[$skill_user_root/folded-skill/references/guide.md]="bounded skill reference"
mapfile[$skill_user_root/shared-skill/SKILL.md]=$'---\nname: shared-skill\ndescription: User-level copy.\n---\n\nUSER SHARED BODY'
mapfile[$skill_user_root/broken-skill/SKILL.md]=$'---\nname: broken-skill\n---\n\nMissing its description.'
mapfile[$skill_project_root/.agents/skills/shared-skill/SKILL.md]=$'---\nname: shared-skill\ndescription:\n  Project copy wins over both\n  user-level locations.\n---\n\nPROJECT SHARED BODY'
mapfile[$TEST_TMP/outside-skill-secret]="outside skill root"
zf_ln -s "$TEST_TMP/outside-skill-secret" "$skill_user_root/folded-skill/references/escape.md"

ZCODER_CONFIG_SKILLS_DIR="$skill_config_root"
ZCODER_USER_SKILLS_DIR="$skill_user_root"
ZCODER_WORKSPACE="$skill_project_root"
INSTRUCTIONS_PROJECT_ROOT="$skill_project_root"
skills_load "$ZCODER_WORKSPACE"
assert_eq "3" "${#SKILL_NAMES}" "standard skill roots discover valid SKILL.md files"
assert_eq "Handles config tasks: use it for quoted descriptions." "${SKILL_DESCRIPTIONS[config-only]}" "skill parser handles quoted descriptions containing colons"
assert_eq "Handles folded descriptions. Use for parser verification." "${SKILL_DESCRIPTIONS[folded-skill]}" "skill parser folds YAML block descriptions"
assert_eq "Project copy wins over both user-level locations." "${SKILL_DESCRIPTIONS[shared-skill]}" "skill parser handles implicit multiline descriptions"
assert_contains "${SKILL_FILES[shared-skill]}" "$skill_project_root/.agents/skills" "project skills override user skills with the same name"
assert_contains "${(j:\n:)SKILL_DIAGNOSTICS}" "shadows" "skill collisions produce diagnostics"
assert_contains "${(j:\n:)SKILL_DIAGNOSTICS}" "missing description" "malformed skills are skipped with diagnostics"
skills_parse_file "$skill_user_root/folded-skill/SKILL.md" metadata
assert_success "metadata-only Skill parsing succeeds" $?
assert_eq "" "$SKILL_PARSED_BODY" "Skill discovery defers instruction body loading"
skills_parse_file "$skill_user_root/folded-skill/SKILL.md"
assert_success "complete Skill parsing succeeds at activation time" $?
assert_contains "$SKILL_PARSED_BODY" "FOLDED BODY SENTINEL" "complete Skill parsing loads instructions on demand"

skills_prompt_block
assert_contains "$REPLY" "- folded-skill: Handles folded descriptions. Use for parser verification." "system prompt exposes Skill routing metadata"
assert_contains "$REPLY" "task clearly matches a Skill description" "system prompt requires implicit Skill selection"
assert_contains "$REPLY" "call activate_skill" "system prompt routes a matching Skill through activation"
assert_not_contains "$REPLY" "FOLDED BODY SENTINEL" "system prompt does not eagerly load skill instructions"
assert_contains "$REPLY" "never override" "skill catalog preserves higher-priority safety rules"
assert_contains "$REPLY" "Ignore any allowed-tools metadata" "skill metadata cannot bypass approval policy"
_skills_catalog_description $'first line\nsecond\tline'
assert_eq "first line second line" "$REPLY" "model-visible Skill descriptions are normalized to one line"
tools_schema_json
assert_not_contains "$REPLY" '"name":"discover_skills"' "complete visible catalogs do not expose redundant Skill discovery"
assert_contains "$REPLY" '"name":"activate_skill"' "tool schema exposes skill activation when skills exist"
assert_not_contains "$REPLY" '"name":"read_skill_resource"' "resource tool is hidden until a Skill is active"
assert_not_contains "$REPLY" '"enum":["config-only","folded-skill","shared-skill"]' "skill names are not repeated in every tool schema"
tool_dispatch discover_skills '{"query":"folded parser"}'
assert_success "focused Skill discovery succeeds" $?
assert_contains "$TOOL_RESULT" "folded-skill" "focused Skill discovery returns matching metadata"
assert_not_contains "$TOOL_RESULT" "FOLDED BODY SENTINEL" "Skill discovery does not load instruction bodies"
saved_max_skills=$ZCODER_MAX_SKILLS
ZCODER_MAX_SKILLS=2
skills_build_catalog
assert_eq "2" "${#SKILL_CATALOG_NAMES}" "skill disclosure honors its configured count limit"
tools_schema_json
assert_not_contains "$REPLY" '"name":"discover_skills"' "Skills outside the discoverable count limit do not expose a misleading fallback"
assert_not_contains "$REPLY" '"shared-skill"' "deferred skill schemas omit catalog entries"
skills_prompt_block
assert_not_contains "$REPLY" "visible catalog was truncated" "count-limited undiscoverable Skills do not advertise fallback discovery"
tool_dispatch activate_skill '{"name":"shared-skill"}'
assert_failure "model activation rejects a Skill outside the discoverable catalog" $?
assert_contains "$TOOL_RESULT" "not in the model-discoverable catalog" "undiscoverable Skill rejection explains the boundary"
skills_activate "shared-skill"
assert_success "explicit activation can select a valid Skill outside the model disclosure limit" $?
tools_schema_json
assert_contains "$REPLY" '"name":"read_skill_resource"' "explicitly activated undisclosed Skills expose the resource reader"
assert_contains "$REPLY" '"enum":["shared-skill"]' "resource schemas include explicitly activated undisclosed Skills"
skills_reset_activations
assert_eq "0" "${#SKILL_ACTIVE_NAMES}" "explicit activation regression setup resets cleanly"
ZCODER_MAX_SKILLS=$saved_max_skills
skills_build_catalog

saved_catalog_max_bytes=$ZCODER_SKILL_CATALOG_MAX_BYTES
_skills_catalog_description "${SKILL_DESCRIPTIONS[config-only]}"
catalog_first_line="- config-only: $REPLY"
_instructions_byte_length "$catalog_first_line"
ZCODER_SKILL_CATALOG_MAX_BYTES=$(( REPLY + 1 ))
skills_build_catalog
assert_eq "1" "${#SKILL_CATALOG_NAMES}" "routing catalog byte limit preserves complete entries"
assert_eq "3" "${#SKILL_DISCOVERABLE_NAMES}" "byte truncation keeps omitted Skills available to fallback discovery"
tools_schema_json
assert_contains "$REPLY" '"name":"discover_skills"' "byte-truncated visible catalogs expose fallback Skill discovery"
skills_prompt_block
assert_contains "$REPLY" "visible catalog was truncated" "byte truncation tells the model when fallback discovery is appropriate"
tool_dispatch discover_skills '{"query":"project copy"}'
assert_success "fallback Skill discovery searches descriptions omitted from the visible catalog" $?
assert_contains "$TOOL_RESULT" "shared-skill" "fallback Skill discovery returns an omitted match"
ZCODER_SKILL_CATALOG_MAX_BYTES=$saved_catalog_max_bytes
skills_build_catalog

tool_dispatch read_skill_resource '{"name":"folded-skill","path":"references/guide.md"}'
assert_failure "skill resources require prior activation" $?
tool_dispatch activate_skill '{"name":"folded-skill"}'
assert_success "activate_skill loads a discovered skill" $?
assert_eq "1" "${#SKILL_ACTIVE_NAMES}" "skill activation is tracked once per conversation"
tools_schema_json
assert_not_contains "$REPLY" '"enum":["config-only","shared-skill"]' "activation schema remains independent of catalog size"
assert_contains "$REPLY" '"name":"read_skill_resource"' "resource tool appears after Skill activation"
skills_prompt_block
assert_contains "$REPLY" "FOLDED BODY SENTINEL" "activated skill instructions enter the system prompt"
tool_dispatch read_skill_resource '{"name":"folded-skill","path":"references/guide.md"}'
assert_success "activated skill resources are readable" $?
assert_eq "bounded skill reference" "$TOOL_RESULT" "skill resource reads return exact content"
tool_dispatch read_skill_resource '{"name":"folded-skill","path":"references/escape.md"}'
assert_failure "skill resource symlinks cannot escape the validated root" $?
assert_contains "$TOOL_RESULT" "escapes its read-only root" "skill resource rejection explains its boundary"

saved_active_skill_bytes=$ZCODER_ACTIVE_SKILLS_MAX_BYTES
_instructions_byte_length "${SKILL_BODIES[folded-skill]}"
ZCODER_ACTIVE_SKILLS_MAX_BYTES=$REPLY
tool_dispatch activate_skill '{"name":"shared-skill"}'
assert_failure "aggregate Skill instructions are bounded for local contexts" $?
assert_contains "$TOOL_RESULT" "aggregate limit" "aggregate Skill rejection explains the context boundary"
ZCODER_ACTIVE_SKILLS_MAX_BYTES=$saved_active_skill_bytes
skills_activate_explicit_from_text '$shared-skill apply the project workflow'
assert_success "dollar-prefixed skill names activate explicitly" $?
assert_eq "2" "${#SKILL_ACTIVE_NAMES}" "explicit activation adds the selected skill"
tool_dispatch activate_skill '{"name":"shared-skill"}'
assert_success "repeated skill activation is idempotent" $?
assert_eq "2" "${#SKILL_ACTIVE_NAMES}" "repeated activation does not duplicate instructions"
agent_build_payload
assert_contains "$REPLY" "PROJECT SHARED BODY" "active skills persist in every regular payload"
agent_compaction_replace_history "checkpoint without skill bodies"
agent_build_payload
assert_contains "$REPLY" "PROJECT SHARED BODY" "active skills survive conversation compaction"
agent_reset
assert_eq "0" "${#SKILL_ACTIVE_NAMES}" "new conversations clear active skills"

# Persistent goals force structural completion and expose a separate read-only
# verifier surface.
goal_begin "Implement and verify the requested feature" 5000
assert_success "a persistent goal starts with a concrete objective" $?
assert_eq "active" "$GOAL_STATUS" "new goals enter the active state"
assert_eq "Implement and verify the requested feature" "$GOAL_OBJECTIVE" "goal state preserves the exact objective"
agent_completion_instructions
assert_contains "$REPLY" "Turn completion is structural" "active goals require the finish control tool"
goal_prompt_block
assert_contains "$REPLY" "separate read-only verifier" "active goals explain independent candidate verification"
goal_verifier_system_prompt
assert_contains "$REPLY" "Implement and verify the requested feature" "verifier prompts retain the exact objective independently of compacted history"
GOAL_VERIFIER_ACTIVE=1
tools_schema_json
assert_contains "$REPLY" '"name":"read_file_range"' "goal verifiers receive read-only evidence tools"
assert_not_contains "$REPLY" '"name":"write_file"' "goal verifier schemas omit workspace writes"
assert_not_contains "$REPLY" '"name":"run_command"' "goal verifier schemas omit command execution"
goal_verifier_dispatch_read write_file '{"path":"verifier-escape","content":"no"}'
assert_failure "goal verifier dispatch rejects invented write calls" $?
GOAL_VERIFIER_ACTIVE=0

# The transcript exporter is UI code but does not require curses to be active.
source "${PROJECT_DIR}/lib/terminal.zsh"
source "${PROJECT_DIR}/lib/ui.zsh"
source "${PROJECT_DIR}/lib/overlays.zsh"
source "${PROJECT_DIR}/lib/commands.zsh"

ZCODER_SESSIONS_DIR="$TEST_TMP/zcoder-sessions"
STATE_ENABLED=0
CURRENT_SESSION_ID=""
ZCODER_WORKSPACE="$skill_project_root"
ZCODER_PROFILE=coding
ZCODER_MODEL="session-model"
ZCODER_MODEL_OVERRIDE=0
state_init
assert_eq "1" "$STATE_ENABLED" "session storage initializes in the standard config root"
saved_session_id="$CURRENT_SESSION_ID"
_state_valid_id "$saved_session_id"
assert_success "new sessions receive traversal-safe identifiers" $?
state_note_user $'Repair the deployment\nwithout losing context'
AGENT_MESSAGES=('{"role":"user","content":"Repair the deployment"}' '{"role":"assistant","content":"Working"}')
AGENT_USER_MESSAGES=("Repair the deployment")
UI_ROLES=(user assistant assistant)
UI_CONTENTS=("Repair the deployment" "Work completed" "")
UI_THINKINGS=("" "private reasoning" "reasoning-only tool turn")
UI_TIMES=("12:00" "12:01" "12:02")
UI_REASONING_OPEN=(0 0 0)
AGENT_COMPACTION_SUMMARY="durable resumed checkpoint"
AGENT_COMPACTION_COUNT=2
AGENT_COMPACTION_REARM_TOKENS=1234
AGENT_LAST_PROMPT_TOKENS=4321
AGENT_LAST_OUTPUT_TOKENS=55
AGENT_LAST_PAYLOAD_BYTES=9876
GOAL_STATUS="active"
GOAL_ID="123_456"
GOAL_OBJECTIVE="Persist this exact goal"
GOAL_FEEDBACK="Need a broader test"
GOAL_BLOCK_REASON="paused for restart"
GOAL_CREATED_AT=100
GOAL_UPDATED_AT=200
GOAL_ATTEMPTS=2
GOAL_REJECTIONS=1
GOAL_TOKENS_USED=321
GOAL_TOKEN_BUDGET=999
skills_activate folded-skill >/dev/null
state_save_and_refresh
assert_eq "Repair the deployment without losing conte" "$SESSION_TITLE" "first user request becomes a bounded resumable session title"
assert_contains "${(j:,:)SESSION_IDS}" "$saved_session_id" "saved sessions appear in the sidebar cache"

state_init
launch_session_id="$CURRENT_SESSION_ID"
[[ "$launch_session_id" != "$saved_session_id" ]]
assert_success "interactive startup creates a fresh session instead of resuming the latest one" $?
assert_eq "0" "${#AGENT_MESSAGES}" "fresh startup sessions begin without prior model history"
assert_contains "${(j:,:)SESSION_IDS}" "$saved_session_id" "fresh startup keeps older sessions available for selection"
state_init
assert_eq "$launch_session_id" "$CURRENT_SESSION_ID" "interactive startup reuses an untouched blank job instead of duplicating it"

foreign_profile_id="9999999999_101"
foreign_workspace_id="9999999999_102"
zf_mkdir -p "$ZCODER_SESSIONS_DIR/$foreign_profile_id.session" "$ZCODER_SESSIONS_DIR/$foreign_workspace_id.session"
mapfile[$ZCODER_SESSIONS_DIR/$foreign_profile_id.session/workspace]="${ZCODER_WORKSPACE:A}"
mapfile[$ZCODER_SESSIONS_DIR/$foreign_profile_id.session/profile]="sysadmin"
mapfile[$ZCODER_SESSIONS_DIR/$foreign_profile_id.session/updated_at]="9999999999"
mapfile[$ZCODER_SESSIONS_DIR/$foreign_workspace_id.session/workspace]="$TEST_TMP/another-project"
mapfile[$ZCODER_SESSIONS_DIR/$foreign_workspace_id.session/profile]="coding"
mapfile[$ZCODER_SESSIONS_DIR/$foreign_workspace_id.session/updated_at]="9999999999"
state_refresh_sessions_list
session_ids_joined="${(j:,:)SESSION_IDS}"
assert_not_contains "$session_ids_joined" "$foreign_profile_id" "session list isolates prompt profiles"
assert_not_contains "$session_ids_joined" "$foreign_workspace_id" "session list isolates canonical workspaces"

CURRENT_SESSION_ID=""
AGENT_MESSAGES=()
AGENT_USER_MESSAGES=()
UI_ROLES=(); UI_CONTENTS=(); UI_THINKINGS=(); UI_TIMES=(); UI_REASONING_OPEN=()
AGENT_COMPACTION_SUMMARY=""
AGENT_COMPACTION_COUNT=0
skills_reset_activations
ZCODER_MODEL="other-model"
state_load_session "$saved_session_id"
assert_eq "session-model" "$ZCODER_MODEL" "resuming restores the session model without a CLI override"
assert_eq "2" "${#AGENT_MESSAGES}" "resuming restores complete model/tool history"
assert_contains "${AGENT_MESSAGES[2]}" "Working" "resumed model history remains exact JSON"
assert_eq "Work completed" "${UI_CONTENTS[2]}" "resuming restores the visible transcript"
assert_eq "private reasoning" "${UI_THINKINGS[2]}" "resuming restores reasoning text"
assert_eq "" "${UI_CONTENTS[3]}" "resuming preserves an empty reasoning-only content field"
assert_eq "reasoning-only tool turn" "${UI_THINKINGS[3]}" "resuming restores reasoning-only tool turns"
assert_eq "durable resumed checkpoint" "$AGENT_COMPACTION_SUMMARY" "resuming restores compacted context"
assert_eq "2" "$AGENT_COMPACTION_COUNT" "resuming restores compaction metadata"
assert_eq "Repair the deployment" "${AGENT_USER_MESSAGES[1]}" "resuming restores the exact-user ledger"
assert_contains "${(j:,:)SKILL_ACTIVE_NAMES}" "folded-skill" "resuming reactivates available Skills"
assert_eq "paused" "$GOAL_STATUS" "resuming converts interrupted active goal work to an explicit pause"
assert_eq "Persist this exact goal" "$GOAL_OBJECTIVE" "resuming restores the exact goal objective"
assert_eq "321" "$GOAL_TOKENS_USED" "resuming restores cumulative goal token use"
assert_eq "999" "$GOAL_TOKEN_BUDGET" "resuming restores the goal token budget"

CURRENT_SESSION_ID=""
ZCODER_MODEL_OVERRIDE=1
ZCODER_MODEL="cli-selected-model"
state_load_session "$saved_session_id"
assert_eq "cli-selected-model" "$ZCODER_MODEL" "explicit CLI model selection wins when resuming"
ui_plain_transcript
assert_contains "$REPLY" "Work completed" "copy view exports the visible transcript as plain text"
assert_not_contains "$REPLY" "private reasoning" "copy view omits collapsed reasoning"
UI_REASONING_OPEN[2]=1
ui_plain_transcript
assert_contains "$REPLY" "private reasoning" "copy view includes expanded reasoning"
UI_REASONING_OPEN[3]=1
ui_plain_transcript
assert_contains "$REPLY" "reasoning-only tool turn" "copy view includes an expanded reasoning-only turn"

previous_session_id="$CURRENT_SESSION_ID"
ZCODER_MODEL_OVERRIDE=0
state_new_session
[[ "$CURRENT_SESSION_ID" != "$previous_session_id" ]]
assert_success "new chat creates a separate saved session" $?
assert_eq "0" "${#AGENT_MESSAGES}" "new sessions clear model history"
assert_eq "0" "${#UI_ROLES}" "new sessions clear the visible transcript"
assert_eq "none" "$GOAL_STATUS" "new sessions clear persistent goal state"
saved_remote_runtime_dir="$REMOTE_RUNTIME_DIR"
REMOTE_RUNTIME_DIR="$TEST_TMP/remote-session-create-runtime"
zf_mkdir -p "$REMOTE_RUNTIME_DIR"
_remote_server_new_session
assert_success "remote servers create a new server-owned session" $?
_state_valid_id "$REMOTE_SESSION_ID"
assert_success "new remote sessions receive traversal-safe identifiers" $?
[[ -d "$ZCODER_SESSIONS_DIR/${REMOTE_SESSION_ID}.session" ]]
assert_success "new remote sessions are persisted immediately" $?
assert_eq "$REMOTE_SESSION_ID" "${mapfile[$REMOTE_RUNTIME_DIR/selected_session]}" "new remote sessions become the selected server job"
assert_eq "0" "${#UI_ROLES}" "new remote sessions begin with an empty visible transcript"
REMOTE_RUNTIME_DIR="$saved_remote_runtime_dir"
STATE_ENABLED=0
CURRENT_SESSION_ID=""
SESSION_IDS=(); SESSION_TITLES=(); SESSION_MODELS=()

skills_reset
tools_schema_json
assert_not_contains "$REPLY" '"name":"activate_skill"' "skill tools are omitted when no Skills are disclosed"
unset ZCODER_CONFIG_SKILLS_DIR ZCODER_USER_SKILLS_DIR
ZCODER_WORKSPACE="$TEST_TMP"
INSTRUCTIONS_PROJECT_ROOT="$TEST_TMP"

agent_select_profile sysadmin
assert_success "sysadmin prompt profile is accepted" $?
assert_eq "sysadmin" "$ZCODER_PROFILE" "profile selection updates agent state"
agent_default_system_prompt
assert_contains "$REPLY" "approval for that exact command" "sysadmin prompt limits approval to one exact command"
assert_contains "$REPLY" "Never run a command capable of erasing the machine" "sysadmin prompt forbids catastrophic deletion"
assert_contains "$REPLY" "AGENTS.md files may add" "sysadmin prompt keeps AGENTS guidance subordinate to safety"
assert_contains "$REPLY" "create a timestamped backup" "sysadmin prompt requires recoverable configuration changes"
assert_contains "$REPLY" "Do not print secrets" "sysadmin prompt protects sensitive host data"
assert_contains "$REPLY" "Treat each host mutation as a small transaction" "sysadmin prompt teaches a concrete safe change sequence"
assert_contains "$REPLY" "Never place ; between a prerequisite and the mutation" "sysadmin prompt makes dependent steps fail closed"
assert_contains "$REPLY" "use set -o pipefail" "sysadmin prompt prevents hidden pipeline failures"
assert_contains "$REPLY" "Use mktemp for temporary files" "sysadmin prompt rejects predictable temporary paths"
assert_contains "$REPLY" "replace the entire stored state" "sysadmin prompt identifies replacement-style command risk"
assert_contains "$REPLY" "crontab -l > /tmp/file; append content; crontab /tmp/file" "sysadmin prompt names the unsafe crontab pattern"
assert_contains "$REPLY" "complete unified-diff contract in the apply_patch tool description" "sysadmin prompt points to the workspace patch contract"
assert_contains "$REPLY" "OBSERVE → DECIDE → ACT → CHECK" "sysadmin prompt includes the shared operating loop"
assert_contains "$REPLY" "Do not combine unrelated operations or multiple mutating steps" "sysadmin prompt keeps host mutations reviewable"
assert_contains "$REPLY" "Never claim verification that was not actually observed" "sysadmin prompt requires observed verification"
assert_contains "$REPLY" "Never bypass built-in tool workspace confinement or run_command approval" "sysadmin prompt preserves its approved host-operation boundary"
assert_not_contains "$REPLY" "Never operate outside the permitted workspace" "sysadmin prompt does not contradict approved host operations"
agent_select_profile unknown
assert_failure "unknown prompt profiles are rejected" $?
assert_eq "sysadmin" "$ZCODER_PROFILE" "invalid profile selection preserves the active profile"
agent_select_profile coding
assert_success "coding prompt profile is accepted" $?
agent_select_tool_exposure staged
assert_success "staged tool exposure is accepted" $?
assert_eq "staged" "$ZCODER_TOOL_EXPOSURE" "tool exposure selection updates agent state"
agent_select_tool_exposure invalid
assert_failure "unknown tool exposure modes are rejected" $?
assert_eq "staged" "$ZCODER_TOOL_EXPOSURE" "invalid tool exposure preserves the active mode"
agent_select_tool_exposure full
agent_default_system_prompt
assert_contains "$REPLY" "Project instructions are mandatory requirements for the entire task" "system prompt makes project instructions authoritative"
assert_contains "$REPLY" "MCP navigation tool returns a relevant source range" "system prompt routes MCP locations into bounded reads"
assert_contains "$REPLY" "Use search first" "system prompt prefers indexed search before broad reads"
assert_contains "$REPLY" "Use read_file_range" "system prompt directs large-file inspection to ranges"
assert_contains "$REPLY" "rg --files, rg -n, grep, sed -n, or awk" "system prompt names shell text-processing fallbacks"
assert_contains "$REPLY" "OBSERVE → DECIDE → ACT → CHECK" "system prompt supplies a deterministic operating loop"
assert_contains "$REPLY" "ACT does not necessarily mean calling a tool" "system prompt separates reasoning actions from tool calls"
assert_contains "$REPLY" "reason privately" "system prompt assigns planning to private reasoning"
assert_contains "$REPLY" "answer directly without tools" "system prompt routes self-contained requests to direct responses"
assert_contains "$REPLY" "does not by itself require inspecting it" "system prompt does not infer discovery from a project mention"
assert_contains "$REPLY" "Do not turn a simple response into a repository investigation" "system prompt guards against disproportionate discovery"
assert_contains "$REPLY" "Do not emit this private plan as a tool-free preamble" "system prompt prevents visible plan-only turns"
assert_contains "$REPLY" "analyze the exact error" "system prompt requires evidence-based failure recovery"
assert_contains "$REPLY" "Never repeat an unchanged failed call" "system prompt prevents unchanged retries"
assert_contains "$REPLY" "multiple tool calls in one response" "system prompt permits serialized multi-call responses"
assert_contains "$REPLY" "serializes them in emitted order" "system prompt defines deterministic tool ordering"
assert_contains "$REPLY" "smallest meaningful syntax, test, build, or read-back verification" "system prompt requires proportionate verification"
assert_contains "$REPLY" "Never claim verification that was not actually observed" "system prompt prohibits invented checks"
assert_contains "$REPLY" "If work remains, call the next appropriate work tool" "system prompt requires action instead of a preamble"
assert_contains "$REPLY" "Complete only after checking the requested outcome and verification evidence" "system prompt places a completion check near its footer"
assert_contains "$REPLY" "Do not begin by reading whole source files" "system prompt forbids full-file-first exploration"
assert_contains "$REPLY" "chunks of no more than 200 lines" "system prompt gives ranged-read budget guidance"
assert_contains "$REPLY" "Stop inspecting once you have enough evidence" "system prompt prevents unnecessary follow-up reads"
assert_contains "$REPLY" "Prefer replace_text for one exact literal replacement" "system prompt routes simple edits to structured replacement"
assert_contains "$REPLY" "do not repeat discovery with minor query variations" "system prompt prevents redundant discovery searches"
assert_contains "$REPLY" "non-empty plain assistant response is also accepted as final" "default prompt permits compatible tool-free completion"
assert_contains "$REPLY" "Never use a tool-free response as a preamble" "default prompt still requires tools while work remains"
assert_contains "$REPLY" "complete unified-diff contract in the apply_patch tool description" "coding prompt points to the canonical patch contract"
assert_not_contains "$REPLY" "GOOD (valid focused edit)" "coding prompt does not duplicate the patch example"
assert_not_contains "$REPLY" "BAD (invalid in this harness)" "coding prompt leaves invalid patch examples in the tool schema"
assert_not_contains "$REPLY" "exactly one prefix character" "coding prompt leaves line-prefix details in the tool schema"
assert_contains "$REPLY" "Never bypass a focused patch failure with write_file" "coding prompt requires patch retry instead of replacement"

saved_context_window_setting="$ZCODER_CONTEXT_WINDOW"
ZCODER_CONTEXT_WINDOW=32768
AGENT_CONTEXT_MODEL=""
AGENT_MESSAGES=('{"role":"user","content":"WARMUP HISTORY SENTINEL"}')
AGENT_USER_MESSAGES=("WARMUP USER SENTINEL")
agent_build_warmup_payload
warmup_payload="$REPLY"
assert_contains "$warmup_payload" "Project instructions are mandatory requirements for the entire task" "warm-up payload includes the resolved coding system prompt"
assert_contains "$warmup_payload" "Initialization check only" "warm-up payload asks for an isolated readiness response"
assert_contains "$warmup_payload" 'respond with exactly Ready and nothing else' "warm-up request specifies the silent readiness sentinel"
assert_contains "$warmup_payload" '"think":false' "warm-up disables model reasoning"
assert_contains "$warmup_payload" '"num_predict":8' "warm-up bounds readiness generation"
assert_not_contains "$warmup_payload" "WARMUP HISTORY SENTINEL" "warm-up excludes saved conversation history"
assert_eq "WARMUP USER SENTINEL" "${AGENT_USER_MESSAGES[1]}" "building warm-up leaves the user-message ledger unchanged"
ZCODER_TOOL_EXPOSURE=staged
agent_build_warmup_payload
assert_contains "$REPLY" '"enum":["respond","workspace","external"]' "staged warm-up caches the routing schema"
assert_not_contains "$REPLY" '"tools":' "staged warm-up does not preload hidden work schemas"
assert_contains "$REPLY" "routing layer with no executable tools" "staged warm-up caches the routing prompt"
ZCODER_TOOL_EXPOSURE=full

saved_warmup_payload_builder="${functions[agent_build_warmup_payload]}"
saved_warmup_status_setter="${functions[agent_set_status]}"
saved_warmup_async_start="${functions[http_async_start]}"
saved_warmup_async_ready="${functions[http_async_ready]}"
saved_warmup_async_collect="${functions[http_async_collect]}"
saved_warmup_async_cancel="${functions[http_async_cancel]}"
saved_warmup_context_refresh="${functions[agent_context_refresh_after_response]}"
typeset -g MOCK_WARMUP_PAYLOAD="" MOCK_WARMUP_HOST="" MOCK_WARMUP_STATUS="" MOCK_WARMUP_CANCEL_REASON=""
typeset -gi MOCK_WARMUP_REFRESHES=0
agent_build_warmup_payload() { REPLY='{"warmup":true}'; }
agent_set_status() { MOCK_WARMUP_STATUS="$1"; }
http_async_start() {
  MOCK_WARMUP_PAYLOAD="$3"
  MOCK_WARMUP_HOST="$4"
  HTTP_ASYNC_PID=4242
  HTTP_ASYNC_BASE="$TEST_TMP/mock-warmup"
  return 0
}
http_async_ready() { return 0; }
http_async_collect() {
  HTTP_BODY='{"message":{"content":"Ready"},"done":true}'
  HTTP_ERROR=""
  HTTP_ASYNC_PID=""
  HTTP_ASYNC_BASE=""
  return 0
}
http_async_cancel() {
  MOCK_WARMUP_CANCEL_REASON="$1"
  HTTP_ASYNC_PID=""
  HTTP_ASYNC_BASE=""
  return 0
}
agent_context_refresh_after_response() { (( MOCK_WARMUP_REFRESHES++ )); }
ZCODER_WARMUP=true
REMOTE_MODE=local
UI_ACTIVE=1
AGENT_WARMUP_ACTIVE=0
agent_warmup_start
assert_success "background model warm-up starts" $?
assert_eq "1" "$AGENT_WARMUP_ACTIVE" "started warm-up owns the asynchronous Ollama channel"
assert_eq '{"warmup":true}' "$MOCK_WARMUP_PAYLOAD" "warm-up submits its disposable payload"
assert_eq "$OLLAMA_HOST" "$MOCK_WARMUP_HOST" "warm-up targets the selected Ollama host"
agent_warmup_collect
assert_success "completed model warm-up collects silently" $?
assert_eq "0" "$AGENT_WARMUP_ACTIVE" "completed warm-up releases the asynchronous Ollama channel"
assert_eq "Ready" "$MOCK_WARMUP_STATUS" "successful warm-up changes the header status to Ready"
assert_eq "1" "$MOCK_WARMUP_REFRESHES" "successful warm-up refreshes automatic context sizing"
assert_eq "1" "${#AGENT_MESSAGES}" "warm-up lifecycle does not append model history"
assert_eq "1" "${#AGENT_USER_MESSAGES}" "warm-up lifecycle does not append user history"
agent_warmup_start
agent_warmup_cancel "user prompt submitted"
assert_eq "0" "$AGENT_WARMUP_ACTIVE" "superseding real work releases an active warm-up"
assert_eq "user prompt submitted" "$MOCK_WARMUP_CANCEL_REASON" "warm-up cancellation records the superseding action"
functions[agent_build_warmup_payload]="$saved_warmup_payload_builder"
functions[agent_set_status]="$saved_warmup_status_setter"
functions[http_async_start]="$saved_warmup_async_start"
functions[http_async_ready]="$saved_warmup_async_ready"
functions[http_async_collect]="$saved_warmup_async_collect"
functions[http_async_cancel]="$saved_warmup_async_cancel"
functions[agent_context_refresh_after_response]="$saved_warmup_context_refresh"
UI_ACTIVE=0
ZCODER_CONTEXT_WINDOW="$saved_context_window_setting"
agent_reset

tools_schema_json
assert_contains "$REPLY" "defaults to 100" "list_files schema advertises its conservative default"
assert_contains "$REPLY" "defaults to 50" "search schema advertises its conservative default"
assert_contains "$REPLY" "GOOD (valid focused edit)" "apply_patch schema includes the valid example"
assert_contains "$REPLY" '"name":"replace_text"' "tool schema exposes exact structured replacement"
assert_contains "$REPLY" "-enabled=false" "apply_patch example uses a realistic removed line"
assert_contains "$REPLY" "do not add words such as old or new" "apply_patch schema distinguishes prefixes from file content"
assert_contains "$REPLY" "BAD (invalid in this harness)" "apply_patch schema includes the invalid example"
assert_contains "$REPLY" "Counts describe hunk body lines" "apply_patch schema explains hunk counts"
agent_transport_error_is_retryable "Ollama closed the connection before returning an HTTP response"
assert_success "premature Ollama disconnects are retryable" $?
agent_transport_error_is_retryable "cannot connect to Ollama at mock.invalid:11434"
assert_success "Ollama connection failures are retryable" $?
agent_transport_error_is_retryable "Ollama closed the connection after 128/512 response bytes"
assert_success "truncated Ollama response bodies are retryable" $?
agent_transport_error_is_retryable "timed out waiting 900s for Ollama to begin its response"
assert_failure "long generation timeouts are not replayed" $?
agent_transport_error_is_retryable "Ollama HTTP error: HTTP/1.1 500 Internal Server Error"
assert_failure "HTTP error responses are not replayed" $?
agent_transport_error_is_retryable "Ollama request cancelled: Escape pressed"
assert_failure "intentional cancellation is not replayed" $?

agent_format_tool_ui_result read_file '{"path":"src/note.txt"}' $'one\ntwo\nthree' 1
assert_eq "Read(src/note.txt)" "$REPLY" "UI summarizes a complete file read"
assert_not_contains "$REPLY" "three" "UI hides complete file read contents"
agent_format_tool_ui_result read_file '{"path":"'"${TEST_TMP}"'/src/note.txt"}' $'one\ntwo\nthree' 1
assert_eq "Read(src/note.txt)" "$REPLY" "UI makes an absolute file path relative to the workspace"
zf_ln -s "$TEST_TMP" "$TEST_TMP/workspace-alias"
agent_format_tool_ui_result read_file '{"path":"'"${TEST_TMP}"'/workspace-alias/src/note.txt"}' $'one\ntwo\nthree' 1
assert_eq "Read(src/note.txt)" "$REPLY" "UI resolves a workspace symlink before making a path relative"
zf_rm -f "$TEST_TMP/workspace-alias"
agent_format_tool_ui_result read_file '{"path":"'"${TEST_TMP}"'"}' "directory" 0
assert_contains "$REPLY" "Read(.)" "UI displays the workspace root as a relative path"
agent_format_tool_ui_result read_file_range '{"path":"src/note.txt","start_line":2,"end_line":3}' $'2: two\n3: three' 1
assert_eq "Read File Range(src/note.txt:2-3)" "$REPLY" "UI summarizes a ranged file read"
agent_format_tool_ui_result write_file '{"path":"src/new.txt","content":"visible write body"}' "Wrote file" 1
assert_contains "$REPLY" "visible write body" "UI displays write_file content"
agent_format_tool_ui_result apply_patch '{"patch":"--- a/old.txt\n+++ b/old.txt\n@@ -1 +1 @@\n-old\n+new"}' "Patch applied" 1
assert_contains "$REPLY" "+new" "UI displays apply_patch content"
MCP_TOOL_SERVER[mcp__modern__echo_data]="modern"
MCP_TOOL_ORIGINAL[mcp__modern__echo_data]="echo.data"
agent_format_tool_ui_result mcp__modern__echo_data '{"payload":{"nested":true}}' "secret MCP output" 1
assert_eq "Calling modern.echo.data" "$REPLY" "UI identifies an MCP call by server and original tool name"
assert_not_contains "$REPLY" "secret MCP output" "UI hides successful MCP server output"
agent_format_tool_ui_result mcp__modern__echo_data '{}' "sensitive MCP failure details" 0
assert_not_contains "$REPLY" "sensitive MCP failure details" "UI hides failed MCP server output"

tools_schema_json
assert_contains "$REPLY" '"name":"finish"' "tool schema exposes structural turn completion"
agent_parse_finish '{"status":"complete","response":"Wɔawie dwumadi no."}'
assert_success "finish accepts a language-independent completion payload" $?
assert_eq "complete" "$AGENT_FINISH_STATUS" "finish retains completion status"
assert_eq "Wɔawie dwumadi no." "$AGENT_FINISH_RESPONSE" "finish retains the user-facing response"
agent_parse_finish '{"status":"maybe","response":"uncertain"}'
assert_failure "finish rejects unknown status values" $?
agent_parse_finish '{"status":"blocked","response":""}'
assert_failure "finish rejects an empty final response" $?

AGENT_LAST_PROMPT_TOKENS=1000
AGENT_LAST_PAYLOAD_BYTES=3000
agent_estimate_payload_tokens "${(l:6000::x:)}"
assert_eq "2200" "$REPLY" "token estimates calibrate against Ollama prompt usage with headroom"

assert_eq "65536" "$ZCODER_CONTEXT_FALLBACK" "unknown unloaded models default to a 64K context"
assert_eq "85" "$ZCODER_COMPACT_PERCENT" "automatic compaction defaults to 85 percent"
assert_eq "2" "$ZCODER_COMPACT_RETRY_LIMIT" "invalid compaction checkpoints receive two corrective retries by default"
saved_context_lookup="${functions[ollama_get_running_context]}"
saved_model="$ZCODER_MODEL"
ollama_get_running_context() {
  if [[ "$1" == "loaded-model:latest" ]]; then
    OLLAMA_RUNNING_CONTEXT=98304
    return 0
  fi
  return 1
}
ZCODER_CONTEXT_WINDOW=auto
ZCODER_MODEL="loaded-model:latest"
AGENT_CONTEXT_MODEL=""
agent_context_configure
assert_eq "98304" "$AGENT_CONTEXT_WINDOW" "automatic context sizing uses Ollama's loaded allocation"
ZCODER_MODEL="unloaded-model:latest"
agent_context_configure
assert_eq "65536" "$AGENT_CONTEXT_WINDOW" "automatic context sizing uses the fallback before first load"
assert_eq "1" "$AGENT_CONTEXT_DISCOVERY_PENDING" "automatic context sizing refreshes after an unloaded model responds"
agent_context_options_json
assert_eq "" "$REPLY" "automatic context does not override an unloaded model's declared window"
agent_build_payload
assert_not_contains "$REPLY" '"num_ctx"' "first automatic request leaves Ollama context selection intact"
functions[ollama_get_running_context]="$saved_context_lookup"
ZCODER_MODEL="$saved_model"
AGENT_CONTEXT_MODEL=""
ZCODER_CONTEXT_WINDOW=auto
AGENT_CONTEXT_WINDOW=131072
AGENT_CONTEXT_DISCOVERY_PENDING=0
agent_context_options_json
assert_contains "$REPLY" '"num_ctx":131072' "automatic context preserves a known loaded allocation"

typeset -g MOCK_CHECKPOINT='{"schema_version":1,"objective":"complete the requested change","constraints":["preserve project rules"],"decisions":["use focused edits because the project requires them"],"artifacts":["lib/example.zsh: inspected"],"facts":["make test is required"],"completed":["localized the change"],"active":["implementing"],"blocked":[],"next":["finish the edit"]}'
agent_parse_compaction_summary "$MOCK_CHECKPOINT"
assert_success "structured compaction checkpoints validate" $?
agent_parse_compaction_summary '{"schema_version":1,"objective":"missing the required arrays"}'
assert_failure "incomplete compaction checkpoints fail closed" $?
agent_parse_compaction_summary '{"schema_version":1,"objective":"wrong next type","constraints":[],"decisions":[],"artifacts":[],"facts":[],"completed":[],"active":[],"blocked":[],"next":"continue"}'
assert_failure "compaction checkpoints reject scalar array fields" $?
assert_eq "checkpoint field next must be an array" "$JSON_ERROR" "compaction validation identifies the mistyped field"

ZCODER_CONTEXT_WINDOW=32768
ZCODER_COMPACT_PERCENT=70
ZCODER_COMPACT_MAX_TOKENS=2048
ZCODER_COMPACT_KEEP_USER_TOKENS=4096
ZCODER_COMPACT_KEEP_RECENT_TOKENS=2048
ZCODER_COMPACT_MIN_YIELD_TOKENS=2048
agent_reset
agent_add_message user "original request"
agent_add_message assistant "old assistant detail ${(l:20000::a:)}"
agent_add_message tool "old tool output ${(l:20000::b:)}" read_file
agent_add_message assistant "superseded reasoning ${(l:20000::c:)}"
agent_add_message assistant "recent assistant detail"
agent_add_message user "current request"
typeset -g MOCK_COMPACT_PAYLOAD=""
agent_ollama_chat() {
  MOCK_COMPACT_PAYLOAD="$1"
  json_quote "$MOCK_CHECKPOINT"
  HTTP_BODY='{"message":{"content":'"$REPLY"'},"prompt_eval_count":1800,"eval_count":120}'
  HTTP_ERROR=""
  return 0
}
agent_compact_history manual >/dev/null
compact_status=$?
assert_success "manual compaction completes" "$compact_status"
assert_contains "$MOCK_COMPACT_PAYLOAD" "old tool output" "compaction request includes detailed tool history"
assert_contains "$MOCK_COMPACT_PAYLOAD" "You are zcoder" "compaction reuses the normal stable system prefix"
assert_contains "$MOCK_COMPACT_PAYLOAD" '"next":{"type":"array","items":{"type":"string"}}' "compaction payload enforces array fields with a JSON schema"
assert_contains "$MOCK_COMPACT_PAYLOAD" '"additionalProperties":false' "compaction schema rejects undeclared checkpoint fields"
assert_not_contains "$MOCK_COMPACT_PAYLOAD" '"tools":' "compaction payload does not expose a competing tool-call channel"
assert_eq "$MOCK_CHECKPOINT" "$AGENT_COMPACTION_SUMMARY" "compaction stores the validated model checkpoint"
assert_eq "1" "$AGENT_COMPACTION_COUNT" "compaction advances its checkpoint counter"
assert_eq "2" "${#AGENT_MESSAGES}" "replacement history preserves every bounded recent record"
assert_eq "2" "${#AGENT_USER_MESSAGES}" "replacement history preserves recent real user messages"
agent_build_payload
post_compaction_payload="$REPLY"
json_begin "$post_compaction_payload" && json_discard_value && [[ "$JSON_TOKEN_TYPE" == eof ]]
assert_success "post-compaction payload remains valid JSON with multiple retained records" $?
REPLY="$post_compaction_payload"
assert_contains "$REPLY" "complete the requested change" "regular prompts include the validated checkpoint"
assert_contains "$REPLY" "original request" "regular prompts pin the original user request verbatim"
assert_contains "$REPLY" "current request" "regular prompts pin the latest user correction verbatim"
assert_not_contains "$REPLY" "old tool output" "compacted prompts remove stale detailed tool output"
assert_contains "$REPLY" '"num_ctx":32768' "explicit 32K context windows are sent to Ollama"
assert_contains "$REPLY" '"num_predict":8192' "normal turns carry the configured output ceiling"
assert_success "compaction rearms above its post-checkpoint estimate" $(( AGENT_COMPACTION_REARM_TOKENS > AGENT_ESTIMATED_TOKENS ? 0 : 1 ))
agent_context_summary
assert_contains "$REPLY" "estimated next prompt:" "context status reports the current transport estimate"
assert_contains "$REPLY" "last Ollama prompt: unknown" "context status distinguishes reset usage from a measured prompt"
assert_contains "$REPLY" "Estimated context bill:" "context status attributes model-visible components"
assert_eq "${#AGENT_CONTEXT_COMPONENT_LABELS}" "${#AGENT_CONTEXT_COMPONENT_VALUES}" "context component labels align with their estimates"
assert_eq "9" "${#AGENT_CONTEXT_COMPONENT_VALUES}" "context accounting exposes all nine bill components to the inspector"
assert_contains "$REPLY" "checkpoint=${AGENT_CONTEXT_COMPONENT_VALUES[5]}" "inspector checkpoint accounting matches the context bill"

functions[_test_valid_compaction_chat]="${functions[agent_ollama_chat]}"
typeset -gi MOCK_COMPACTION_ATTEMPTS=0
agent_ollama_chat() {
  (( MOCK_COMPACTION_ATTEMPTS++ ))
  if (( MOCK_COMPACTION_ATTEMPTS == 1 )); then
    json_quote '{"schema_version":1,"objective":"retry malformed checkpoint","constraints":[],"decisions":[],"artifacts":[],"facts":[],"completed":[],"active":[],"blocked":[],"next":"continue"}'
    HTTP_BODY='{"message":{"content":'"$REPLY"'},"prompt_eval_count":1800,"eval_count":12}'
    HTTP_ERROR=""
    return 0
  fi
  _test_valid_compaction_chat "$@"
}
agent_reset
agent_add_message user "retry the malformed checkpoint"
agent_add_message assistant "discardable history ${(l:70000::r:)}"
agent_add_message user "continue after the checkpoint"
agent_compact_history manual >/dev/null
retry_compact_status=$?
assert_success "compaction recovers from an invalid checkpoint" "$retry_compact_status"
assert_eq "2" "$MOCK_COMPACTION_ATTEMPTS" "invalid checkpoints receive a fresh Ollama request"
assert_contains "$MOCK_COMPACT_PAYLOAD" "checkpoint field next must be an array" "checkpoint retries identify the validation failure to the model"
assert_eq "$MOCK_CHECKPOINT" "$AGENT_COMPACTION_SUMMARY" "a valid retry becomes the compaction checkpoint"
assert_eq "0" "$AGENT_COMPACTION_IN_PROGRESS" "successful retries clear the compaction guard"

ZCODER_COMPACT_RETRY_LIMIT=1
typeset -gi MOCK_COMPACTION_ATTEMPTS=0
typeset -ga MOCK_COMPACTION_PAYLOADS=()
agent_ollama_chat() {
  (( MOCK_COMPACTION_ATTEMPTS++ ))
  MOCK_COMPACTION_PAYLOADS+=("$1")
  json_quote '```json'
  HTTP_BODY='{"message":{"content":'"$REPLY"'},"prompt_eval_count":1800,"eval_count":4}'
  HTTP_ERROR=""
  return 0
}
agent_reset
agent_add_message user "preserve this request after failed compaction"
agent_add_message assistant "exact history ${(l:70000::e:)}"
rejected_history="${(j:\n:)AGENT_MESSAGES}"
agent_compact_history manual >/dev/null
rejected_compact_status=$?
assert_failure "compaction fails after invalid checkpoint retries are exhausted" "$rejected_compact_status"
assert_eq "2" "$MOCK_COMPACTION_ATTEMPTS" "compaction honors its corrective retry limit"
assert_contains "$HTTP_ERROR" "after 2 attempts" "exhausted compaction reports the number of attempts"
assert_eq "$rejected_history" "${(j:\n:)AGENT_MESSAGES}" "exhausted retries preserve exact history"
assert_eq "0" "$AGENT_COMPACTION_COUNT" "exhausted retries do not advance checkpoint state"
assert_eq "0" "$AGENT_COMPACTION_IN_PROGRESS" "exhausted retries clear the compaction guard"
assert_contains "${MOCK_COMPACTION_PAYLOADS[2]}" "Correction attempt 1 of 1" "deterministic correction retries carry a distinct attempt marker"

ZCODER_COMPACT_RETRY_LIMIT=2
typeset -gi MOCK_COMPACTION_ATTEMPTS=0
agent_ollama_chat() {
  (( MOCK_COMPACTION_ATTEMPTS++ ))
  if (( MOCK_COMPACTION_ATTEMPTS == 1 )); then
    HTTP_BODY=""
    HTTP_ERROR="Ollama closed the connection before returning an HTTP response"
    return 1
  fi
  _test_valid_compaction_chat "$@"
}
agent_reset
agent_add_message user "retry a disconnected compaction request"
agent_add_message assistant "discardable history ${(l:70000::t:)}"
agent_add_message user "continue after the connection recovers"
agent_compact_history manual >/dev/null
transport_compact_status=$?
assert_success "compaction recovers from a transient transport failure" "$transport_compact_status"
assert_eq "2" "$MOCK_COMPACTION_ATTEMPTS" "compaction reuses the normal transport retry policy"
functions[agent_ollama_chat]="${functions[_test_valid_compaction_chat]}"
unfunction _test_valid_compaction_chat

AGENT_MESSAGES=('{"role":"assistant","content":"call","tool_calls":[{"type":"function","function":{"name":"read_file","arguments":{"path":"x"}}}]}' '{"role":"tool","tool_name":"read_file","content":"result"}')
agent_compaction_recent_start 10
assert_eq "3" "$REPLY" "recent history drops an oversized orphan tool result"

ZCODER_COMPACT_KEEP_RECENT_TOKENS=16384
agent_reset
agent_add_message user "small request that should remain exact"
low_yield_original="${AGENT_MESSAGES[1]}"
agent_compact_history manual >/dev/null
assert_failure "low-yield compaction is rejected" $?
assert_eq "$low_yield_original" "${AGENT_MESSAGES[1]}" "low-yield rejection restores exact history"
assert_eq "0" "$AGENT_COMPACTION_COUNT" "low-yield rejection does not advance checkpoint state"
assert_contains "$HTTP_ERROR" "yielded only" "low-yield rejection explains its threshold"
ZCODER_COMPACT_KEEP_RECENT_TOKENS=2048

ZCODER_CONTEXT_WINDOW=32768
ZCODER_COMPACT_PERCENT=70
agent_reset
agent_add_message user "original request"
agent_add_message assistant "${(l:70000::x:)}"
agent_add_message user "current request"
agent_prepare_payload >/dev/null
auto_compact_status=$?
prepared_payload="$REPLY"
assert_success "oversized prompts trigger automatic compaction" "$auto_compact_status"
assert_eq "1" "$AGENT_COMPACTION_COUNT" "automatic compaction creates one checkpoint"
assert_contains "$prepared_payload" "complete the requested change" "automatic compaction rebuilds the pending prompt from its checkpoint"

functions[_test_real_compaction_builder]="${functions[agent_build_compaction_payload]}"
typeset -gi MOCK_COMPACTION_BUILDS=0
agent_build_compaction_payload() {
  (( MOCK_COMPACTION_BUILDS++ ))
  _test_real_compaction_builder "$@"
}
ZCODER_CONTEXT_WINDOW=32768
AGENT_CONTEXT_WINDOW=32768
AGENT_CONTEXT_MODEL="$ZCODER_MODEL"
agent_reset
for compact_record in {1..128}; do
  agent_add_message tool "record ${compact_record}: ${(l:240::x:)}" read_file
done
agent_compact_history manual >/dev/null
large_compact_status=$?
assert_success "large-history compaction completes" "$large_compact_status"
assert_success "large-history compaction uses a logarithmic cutoff search" $(( MOCK_COMPACTION_BUILDS <= 9 ? 0 : 1 ))
functions[agent_build_compaction_payload]="${functions[_test_real_compaction_builder]}"
unfunction _test_real_compaction_builder

# Reasoning and structured calls must survive as one assistant turn across the
# complete tool loop, including the common empty-content response shape.
functions[_test_real_agent_ollama_chat]="${functions[agent_ollama_chat]}"
functions[_test_real_tool_dispatch]="${functions[tool_dispatch]}"
functions[_test_real_agent_set_status]="${functions[agent_set_status]}"
functions[_test_real_ui_refresh_all]="${functions[ui_refresh_all]}"
agent_set_status() { return 0; }
ui_refresh_all() { return 0; }

typeset -gi MOCK_STAGED_TURNS=0 MOCK_STAGED_DISPATCHES=0
typeset -g MOCK_STAGED_FIRST_PAYLOAD="" MOCK_STAGED_SECOND_PAYLOAD=""
agent_ollama_chat() {
  (( MOCK_STAGED_TURNS++ ))
  MOCK_STAGED_FIRST_PAYLOAD="$1"
  HTTP_BODY='{"message":{"content":"{\"mode\":\"respond\",\"response\":\"Hello, zcoder.zsh visitors!\",\"reason\":\"\"}"},"prompt_eval_count":70,"eval_count":8}'
  HTTP_ERROR=""
  return 0
}
tool_dispatch() {
  (( MOCK_STAGED_DISPATCHES++ ))
  TOOL_RESULT="unexpected staged dispatch"
  TOOL_RESULT_OK=1
  return 0
}
ZCODER_TOOL_EXPOSURE=staged
ZCODER_CONTEXT_WINDOW=32768
AGENT_CONTEXT_MODEL=""
agent_reset
UI_ACTIVE=0
agent_user_turn "Say hello to visitors of the zcoder.zsh repository." >/dev/null 2>&1
staged_direct_status=$?
assert_success "staged direct response completes" "$staged_direct_status"
assert_eq "1" "$MOCK_STAGED_TURNS" "staged direct response uses one model turn"
assert_eq "0" "$MOCK_STAGED_DISPATCHES" "staged direct response executes no work tool"
assert_contains "$MOCK_STAGED_FIRST_PAYLOAD" '"enum":["respond","workspace","external"]' "staged first request exposes structured routing"
assert_not_contains "$MOCK_STAGED_FIRST_PAYLOAD" '"name":"list_files"' "staged first request withholds workspace tools"
assert_eq "Hello, zcoder.zsh visitors!" "$AGENT_LAST_RESPONSE" "staged direct response is returned unchanged"

MOCK_STAGED_TURNS=0
MOCK_STAGED_DISPATCHES=0
MOCK_STAGED_FIRST_PAYLOAD=""
MOCK_STAGED_SECOND_PAYLOAD=""
agent_ollama_chat() {
  (( MOCK_STAGED_TURNS++ ))
  if (( MOCK_STAGED_TURNS == 1 )); then
    MOCK_STAGED_FIRST_PAYLOAD="$1"
    HTTP_BODY='{"message":{"content":"{\"mode\":\"workspace\",\"response\":\"\",\"reason\":\"The requested file contents are not supplied.\"}"},"prompt_eval_count":75,"eval_count":12}'
  elif (( MOCK_STAGED_TURNS == 2 )); then
    MOCK_STAGED_SECOND_PAYLOAD="$1"
    HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"read_file","arguments":{"path":"note.txt"}}}]},"prompt_eval_count":90,"eval_count":7}'
  else
    HTTP_BODY='{"message":{"content":"The current note says staged evidence."},"prompt_eval_count":105,"eval_count":9}'
  fi
  HTTP_ERROR=""
  return 0
}
tool_dispatch() {
  (( MOCK_STAGED_DISPATCHES++ ))
  TOOL_RESULT="staged evidence"
  TOOL_RESULT_OK=1
  return 0
}
agent_reset
agent_user_turn "What does note.txt currently say?" >/dev/null 2>&1
staged_workspace_status=$?
assert_success "staged workspace request completes after routing" "$staged_workspace_status"
assert_eq "3" "$MOCK_STAGED_TURNS" "structured routing adds one bounded model turn"
assert_eq "1" "$MOCK_STAGED_DISPATCHES" "the execution-phase workspace tool runs once"
assert_not_contains "$MOCK_STAGED_FIRST_PAYLOAD" '"name":"read_file"' "workspace tool is absent before admission"
assert_contains "$MOCK_STAGED_SECOND_PAYLOAD" '"name":"read_file"' "workspace tool appears after admission"
assert_contains "$MOCK_STAGED_SECOND_PAYLOAD" '"name":"run_command"' "full execution tools appear only after admission"
assert_contains "${(j:\n:)AGENT_MESSAGES}" "Workspace tools were admitted" "routing transition is recorded in model history"
assert_eq "The current note says staged evidence." "$AGENT_LAST_RESPONSE" "staged execution returns the evidence-based response"
ZCODER_TOOL_EXPOSURE=full

typeset -gi MOCK_REASONING_TURNS=0 MOCK_REASONING_DISPATCHES=0
typeset -g MOCK_REASONING_SECOND_PAYLOAD=""
agent_ollama_chat() {
  (( MOCK_REASONING_TURNS++ ))
  if (( MOCK_REASONING_TURNS == 1 )); then
    HTTP_BODY='{"message":{"content":"","thinking":"inspect privately","tool_calls":[{"type":"function","function":{"name":"read_file","arguments":{"path":"reasoning.txt"}}}]},"prompt_eval_count":100,"eval_count":12}'
  else
    MOCK_REASONING_SECOND_PAYLOAD="$1"
    HTTP_BODY='{"message":{"content":"","thinking":"verification complete","tool_calls":[{"type":"function","function":{"name":"finish","arguments":{"status":"complete","response":"Reasoning tool turn completed."}}}]},"prompt_eval_count":130,"eval_count":10}'
  fi
  HTTP_ERROR=""
  return 0
}
tool_dispatch() {
  (( MOCK_REASONING_DISPATCHES++ ))
  TOOL_RESULT="reasoning fixture contents"
  TOOL_RESULT_OK=1
  return 0
}
ZCODER_CONTEXT_WINDOW=32768
AGENT_CONTEXT_MODEL=""
agent_reset
UI_ACTIVE=1
UI_ROLES=(); UI_CONTENTS=(); UI_THINKINGS=(); UI_TIMES=(); UI_REASONING_OPEN=()
agent_user_turn "inspect the reasoning fixture" >/dev/null 2>&1
reasoning_turn_status=$?
assert_success "reasoning and tool-call lifecycle completes" "$reasoning_turn_status"
assert_eq "2" "$MOCK_REASONING_TURNS" "tool result triggers a new reasoning turn"
assert_eq "1" "$MOCK_REASONING_DISPATCHES" "structured reasoning tool call dispatches once"
assert_contains "$MOCK_REASONING_SECOND_PAYLOAD" '"thinking":"inspect privately"' "follow-up payload preserves prior reasoning"
assert_contains "$MOCK_REASONING_SECOND_PAYLOAD" '"name":"read_file"' "follow-up payload preserves the structured tool call"
assert_contains "$MOCK_REASONING_SECOND_PAYLOAD" "reasoning fixture contents" "follow-up payload preserves the tool result"
assert_eq "assistant" "${UI_ROLES[2]}" "reasoning-only tool turn enters the UI transcript"
assert_eq "" "${UI_CONTENTS[2]}" "reasoning-only UI turn keeps empty assistant content"
assert_eq "inspect privately" "${UI_THINKINGS[2]}" "reasoning-only UI turn keeps private reasoning"

agent_ollama_chat() {
  HTTP_BODY='{"message":{"content":"relay work complete"},"prompt_eval_count":80,"eval_count":6}'
  HTTP_ERROR=""
  return 0
}
agent_reset
UI_ROLES=(); UI_CONTENTS=(); UI_THINKINGS=(); UI_TIMES=(); UI_REASONING_OPEN=()
agent_relay_turn $'<agent_relay>\nTask:\nInspect the current consumer.\n</agent_relay>' $'From peer-project (pid 4242)\nInspect the current consumer.' >/dev/null 2>&1
relay_turn_status=$?
assert_success "relayed work uses the normal agent loop" "$relay_turn_status"
assert_eq "relay" "${UI_ROLES[1]}" "relayed work has a distinct visible transcript role"
assert_contains "${UI_CONTENTS[1]}" "peer-project" "relay transcript identifies its sender"
assert_eq "0" "${#AGENT_USER_MESSAGES}" "relay context stays out of the exact-user ledger"
assert_contains "${AGENT_MESSAGES[1]}" '"role":"user"' "relay context uses a template-safe user role"
assert_contains "${AGENT_MESSAGES[1]}" "agent_relay" "relay wrapper remains visible to the receiving model"

# Known read-only batches are accepted but remain deterministically sequential.
typeset -gi MOCK_BATCH_TURNS=0 MOCK_BATCH_DISPATCHES=0
typeset -ga MOCK_BATCH_NAMES=()
typeset -g MOCK_BATCH_SECOND_PAYLOAD=""
agent_ollama_chat() {
  (( MOCK_BATCH_TURNS++ ))
  if (( MOCK_BATCH_TURNS == 1 )); then
    HTTP_BODY='{"message":{"content":"","thinking":"collect independent evidence","tool_calls":[{"type":"function","function":{"name":"list_files","arguments":{"path":"."}}},{"type":"function","function":{"name":"search","arguments":{"query":"TODO"}}}]}}'
  else
    MOCK_BATCH_SECOND_PAYLOAD="$1"
    HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"finish","arguments":{"status":"complete","response":"Read-only batch completed."}}}]}}'
  fi
  HTTP_ERROR=""
  return 0
}
tool_dispatch() {
  (( MOCK_BATCH_DISPATCHES++ ))
  MOCK_BATCH_NAMES+=("$1")
  TOOL_RESULT="batch result ${MOCK_BATCH_DISPATCHES}"
  TOOL_RESULT_OK=1
  return 0
}
agent_reset
UI_ACTIVE=0
agent_user_turn "collect independent evidence" >/dev/null 2>&1
safe_batch_status=$?
assert_success "independent read-only batch completes" "$safe_batch_status"
assert_eq "2" "$MOCK_BATCH_DISPATCHES" "every safe batched call is dispatched"
assert_eq "list_files,search" "${(j:,:)MOCK_BATCH_NAMES}" "safe batch execution preserves emitted order"
assert_contains "$MOCK_BATCH_SECOND_PAYLOAD" "batch result 1" "first safe batch result returns to the model"
assert_contains "$MOCK_BATCH_SECOND_PAYLOAD" "batch result 2" "second safe batch result returns to the model"

# run_command calls in one model response are dispatched serially. The real
# dispatcher applies validation, safety, and the command approval policy to each.
MOCK_BATCH_TURNS=0
MOCK_BATCH_DISPATCHES=0
MOCK_BATCH_NAMES=()
MOCK_BATCH_SECOND_PAYLOAD=""
agent_ollama_chat() {
  (( MOCK_BATCH_TURNS++ ))
  if (( MOCK_BATCH_TURNS == 1 )); then
    HTTP_BODY='{"message":{"content":"","thinking":"collect two diagnostics","tool_calls":[{"type":"function","function":{"name":"run_command","arguments":{"command":"print first"}}},{"type":"function","function":{"name":"run_command","arguments":{"command":"print second"}}}]}}'
  else
    MOCK_BATCH_SECOND_PAYLOAD="$1"
    HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"finish","arguments":{"status":"complete","response":"Command batch completed."}}}]}}'
  fi
  HTTP_ERROR=""
  return 0
}
agent_reset
agent_user_turn "collect two diagnostics" >/dev/null 2>&1
command_batch_status=$?
assert_success "serialized command batch completes" "$command_batch_status"
assert_eq "2" "$MOCK_BATCH_DISPATCHES" "every command in the batch is dispatched"
assert_eq "run_command,run_command" "${(j:,:)MOCK_BATCH_NAMES}" "command batch preserves emitted order"
assert_contains "$MOCK_BATCH_SECOND_PAYLOAD" "batch result 1" "first command result returns to the model"
assert_contains "$MOCK_BATCH_SECOND_PAYLOAD" "batch result 2" "second command result returns to the model"

# Ordered edit-and-verify calls are dispatched through their normal handlers.
MOCK_BATCH_TURNS=0
MOCK_BATCH_DISPATCHES=0
MOCK_BATCH_NAMES=()
MOCK_BATCH_SECOND_PAYLOAD=""
agent_ollama_chat() {
  (( MOCK_BATCH_TURNS++ ))
  if (( MOCK_BATCH_TURNS == 1 )); then
    HTTP_BODY='{"message":{"content":"","thinking":"write then verify","tool_calls":[{"type":"function","function":{"name":"write_file","arguments":{"path":"generated.py","content":"print(1)"}}},{"type":"function","function":{"name":"run_command","arguments":{"command":"python3 -m py_compile generated.py"}}}]}}'
  else
    MOCK_BATCH_SECOND_PAYLOAD="$1"
    HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"finish","arguments":{"status":"complete","response":"Edit and verification completed."}}}]}}'
  fi
  HTTP_ERROR=""
  return 0
}
agent_reset
agent_user_turn "write then verify" >/dev/null 2>&1
ordered_batch_status=$?
assert_success "ordered edit-and-verify batch completes" "$ordered_batch_status"
assert_eq "2" "$MOCK_BATCH_DISPATCHES" "edit-and-verify batch dispatches every call"
assert_eq "write_file,run_command" "${(j:,:)MOCK_BATCH_NAMES}" "edit-and-verify batch preserves dependency order"
assert_contains "$MOCK_BATCH_SECOND_PAYLOAD" "batch result 1" "edit result returns to the model"
assert_contains "$MOCK_BATCH_SECOND_PAYLOAD" "batch result 2" "verification result returns to the model"

# A disconnect before any HTTP response is retried with the unchanged payload.
typeset -gi MOCK_TRANSPORT_TURNS=0
agent_ollama_chat() {
  (( MOCK_TRANSPORT_TURNS++ ))
  if (( MOCK_TRANSPORT_TURNS == 1 )); then
    HTTP_BODY=""
    HTTP_ERROR="Ollama closed the connection before returning an HTTP response"
    return 1
  fi
  HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"finish","arguments":{"status":"complete","response":"Recovered after disconnect."}}}]}}'
  HTTP_ERROR=""
  return 0
}
agent_reset
agent_user_turn "recover a disconnected request" >/dev/null 2>&1
transport_retry_status=$?
assert_success "transient Ollama disconnect recovers" "$transport_retry_status"
assert_eq "2" "$MOCK_TRANSPORT_TURNS" "transient disconnect receives one replay"
assert_eq "Recovered after disconnect." "$AGENT_LAST_RESPONSE" "transport replay retains the completed response"
assert_contains "${mapfile[$ZCODER_DEBUG_LOG]}" "transport_retry" "transport replay is recorded in the debug log"

# A response timeout represents an expensive generation already in progress and
# must not be restarted automatically.
MOCK_TRANSPORT_TURNS=0
agent_ollama_chat() {
  (( MOCK_TRANSPORT_TURNS++ ))
  HTTP_BODY=""
  HTTP_ERROR="timed out waiting 900s for Ollama to begin its response"
  return 1
}
agent_reset
agent_user_turn "do not replay a timed-out generation" >/dev/null 2>&1
transport_timeout_status=$?
assert_failure "Ollama response timeout remains an error" "$transport_timeout_status"
assert_eq "1" "$MOCK_TRANSPORT_TURNS" "timed-out generation is not replayed"

functions[agent_ollama_chat]="${functions[_test_real_agent_ollama_chat]}"
functions[tool_dispatch]="${functions[_test_real_tool_dispatch]}"
functions[agent_set_status]="${functions[_test_real_agent_set_status]}"
functions[ui_refresh_all]="${functions[_test_real_ui_refresh_all]}"
unfunction _test_real_agent_ollama_chat _test_real_tool_dispatch _test_real_agent_set_status _test_real_ui_refresh_all
UI_ACTIVE=0

typeset -gi MOCK_INCOMPLETE_TURNS=0
agent_ollama_chat() {
  (( MOCK_INCOMPLETE_TURNS++ ))
  HTTP_BODY='{"message":{"content":"The requested explanation is complete."},"prompt_eval_count":100,"eval_count":8}'
  HTTP_ERROR=""
  return 0
}
ZCODER_CONTEXT_WINDOW=32768
AGENT_CONTEXT_MODEL=""
agent_reset
agent_user_turn "explain the result" >/dev/null 2>&1
incomplete_status=$?
assert_success "adaptive completion accepts a non-empty tool-free response" "$incomplete_status"
assert_eq "1" "$MOCK_INCOMPLETE_TURNS" "adaptive completion does not spend another model turn"
assert_eq "The requested explanation is complete." "$AGENT_LAST_RESPONSE" "adaptive completion retains the plain response"

saved_lfm_model="$ZCODER_MODEL"
ZCODER_MODEL="lfm2.5-8b-fast"
agent_resolve_system_prompt
assert_contains "$REPLY" "Use only Ollama native tool calls for actions" "LFM prompts require the native Ollama action channel"
assert_contains "$REPLY" "Never encode an action, command, tool_call, or tool_calls object as JSON" "LFM prompts reject competing content action envelopes"
assert_contains "$REPLY" "copy it verbatim from the tool result" "LFM prompts preserve exact observed values"
assert_contains "$REPLY" "search finds matching text inside files" "LFM prompts distinguish content search from file discovery"
assert_contains "$REPLY" "Before apply_patch, read the target file" "LFM prompts require edit evidence before patching"
assert_contains "$REPLY" "read that path directly" "LFM prompts avoid searching for supplied file paths"
agent_patch_failure_limit
assert_eq "2" "$REPLY" "LFM profiles bound repeated patch failures"
agent_normalize_lfm_response $'<think>private final reasoning</think>\nVisible final answer.' "" 0
assert_eq "Visible final answer." "$AGENT_NORMALIZED_CONTENT" "LFM final answers hide a leading think block"
assert_eq "private final reasoning" "$AGENT_NORMALIZED_THINKING" "LFM final-answer reasoning enters the private thinking channel"
agent_content_is_lfm_intermediate_plan '{"analysis":"inspect first","plan":"run a check","commands":[{"command":"pwd"}],"status":"working"}'
assert_success "LFM command-plan envelopes are recognized" $?
agent_content_is_lfm_intermediate_plan $'Inspect with list_files next.\n<|tool_call>'
assert_success "dangling LFM tool-call markers request a native retry" $?
agent_content_is_lfm_intermediate_plan '{"plan":"create it","instructions":"write the file","commands":[{"keystrokes":"write code"}],"check":"launch it"}'
assert_success "LFM alternate planner fields are recognized" $?
agent_content_is_lfm_intermediate_plan '{"analysis":"inspect first","plan":"explore the workspace","observations":[{"description":"nothing inspected"}],"next_steps":["list files"]}'
assert_success "LFM observation and next-step plans are recognized without commands" $?
agent_content_is_lfm_intermediate_plan '{"plan":"write it","observations":"ready to create","steps":"create then check","next actions":"write the file","tool_calls":[{"name":"write_file","arguments":{"path":"editor.py","content":"code"}}]}'
assert_success "LFM foreign tool-call envelopes are recognized" $?
agent_content_is_lfm_intermediate_plan $'{"analysis":"inspect","plan":"run it","commands":[{"command":"pwd\n"}]}'
assert_success "malformed multiline LFM plans are recognized without execution" $?
ZCODER_MODEL="qwen3-coder"
agent_content_is_lfm_intermediate_plan '{"analysis":"requested JSON","plan":"show commands","commands":[{"command":"pwd"}]}'
assert_failure "non-LFM JSON responses retain adaptive plain completion" $?
agent_content_is_lfm_false_tool_refusal "File system tools are not available in my current capabilities."
assert_failure "non-LFM tool availability answers retain adaptive plain completion" $?
ZCODER_MODEL="lfm2.5-8b-fast"
agent_content_is_lfm_false_tool_refusal "I cannot create the file because file system tools are not available in my current capabilities."
assert_success "false LFM tool-unavailable responses are recognized" $?
agent_content_is_lfm_false_tool_refusal "The requested deployment tool is not available, but here is the completed analysis."
assert_failure "specific unavailable-tool explanations are not treated as LFM protocol failures" $?
AGENT_MESSAGES=('{"role":"user","content":"find fallback.txt"}' '{"role":"tool","tool_name":"search","content":"No text matches. search examines file contents, not filenames; use list_files to discover file paths."}' '{"role":"assistant","content":"fallback.txt does not exist"}')
AGENT_USER_MESSAGES=("find fallback.txt")
agent_content_is_lfm_false_path_conclusion "fallback.txt does not exist"
assert_success "LFM filename conclusions require path evidence" $?
AGENT_MESSAGES=('{"role":"user","content":"search TODO"}' '{"role":"tool","tool_name":"search","content":"No text matches."}' '{"role":"assistant","content":"No TODO text exists"}')
AGENT_USER_MESSAGES=("search TODO")
agent_content_is_lfm_false_path_conclusion "No TODO text exists"
assert_failure "ordinary empty content searches remain valid LFM evidence" $?
agent_lfm_user_requests_plan_only "Provide a plan only; do not execute it."
assert_success "explicit plan-only requests disable LFM action recovery" $?
agent_lfm_user_requests_plan_only "Create the editor and verify it."
assert_failure "ordinary implementation requests retain LFM action recovery" $?
agent_content_is_lfm_intermediate_plan '{"analysis":"nothing to run","plan":"done","commands":[]}'
assert_failure "empty LFM command lists are not treated as stalled execution" $?
agent_content_is_lfm_intermediate_plan '{"commands":[{"command":"pwd"}]}'
assert_failure "a commands field alone does not trigger LFM recovery" $?
agent_content_is_lfm_intermediate_plan '{"First action":"List files in the workspace."}'
assert_success "single-field LFM plans are recognized without relying on their label" $?
agent_content_is_lfm_intermediate_plan '{"First action":"List files in the workspace."} trailing planner debris'
assert_success "single-field LFM plans remain recognizable inside malformed output" $?
agent_content_is_lfm_intermediate_plan '{"tool_call":{"name":"list_files","arguments":{"path":"."}}}'
assert_success "content tool-call objects request a corrected native tool call" $?
agent_content_is_lfm_intermediate_plan $'{"tool_call":{"name":"search","arguments":{"query":"literal { brace } and \\"quoted\\" text","path":"."}} trailing'
assert_success "content-envelope recognition handles braces and escaped quotes inside strings" $?
agent_content_is_lfm_intermediate_plan '{"name":"not_exposed","arguments":{"path":"."}}'
assert_success "unknown call objects request a corrected native tool call" $?
agent_content_is_lfm_intermediate_plan '{"name":"list_files"}'
assert_success "call objects missing arguments request correction" $?
agent_content_is_lfm_intermediate_plan '{"name":"list_files","arguments":"."}'
assert_success "call objects with non-object arguments request correction" $?
agent_content_is_lfm_intermediate_plan '{"plan":"inspect","analysis":"choose a native tool","actions":[{"name":"list_files","arguments":{"path":"."}},{"name":"search","arguments":{"query":"TODO"}}]}'
assert_success "ambiguous content actions request one corrected native tool call" $?

typeset -gi MOCK_LFM_TURNS=0 MOCK_LFM_DISPATCHES=0
typeset -ga MOCK_LFM_PAYLOADS=()
saved_lfm_dispatch="${functions[tool_dispatch]}"
typeset -gi MOCK_LFM_ACTION_TURNS=0
typeset -g MOCK_LFM_ACTION_NAME=""
typeset -ga MOCK_LFM_ACTION_PAYLOADS=()
agent_ollama_chat() {
  (( MOCK_LFM_ACTION_TURNS++ ))
  MOCK_LFM_ACTION_PAYLOADS+=("$1")
  if (( MOCK_LFM_ACTION_TURNS == 1 )); then
    HTTP_BODY='{"message":{"content":"{\"analysis\":\"inspect first\",\"plan\":\"search files\",\"actions\":[{\"tool_name\":\"search\",\"arguments\":{\"query\":\"TODO\"}}],\"check\":\"inspect the result\"}"}}'
  elif (( MOCK_LFM_ACTION_TURNS == 2 )); then
    HTTP_BODY='{"message":{"content":"<think>native private reasoning</think>{\"tool_call\":{\"name\":\"search\",\"arguments\":{\"query\":\"wrong channel\"}}}","tool_calls":[{"type":"function","function":{"name":"list_files","arguments":{"path":"."}}}]}}'
  else
    HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"finish","arguments":{"status":"complete","response":"Promoted action completed."}}}]}}'
  fi
  HTTP_ERROR=""
  return 0
}
tool_dispatch() {
  MOCK_LFM_ACTION_NAME="$1"
  TOOL_RESULT="native tool result"
  TOOL_RESULT_OK=1
  return 0
}
AGENT_INCOMPLETE_RETRY_LIMIT=1
AGENT_REQUIRE_FINISH_TOOL=0
agent_reset
agent_user_turn "complete an LFM action plan" >/dev/null 2>&1
assert_success "LFM native-tool recovery completes" $?
assert_eq "3" "$MOCK_LFM_ACTION_TURNS" "content JSON receives a retry before native tool execution"
assert_eq "list_files" "$MOCK_LFM_ACTION_NAME" "native tool calls override competing content JSON"
assert_contains "${MOCK_LFM_ACTION_PAYLOADS[2]}" "intermediate JSON plan" "content action envelopes receive a native-tool nudge"
assert_not_contains "${AGENT_MESSAGES[2]}" ',"tool_calls":' "content action envelopes are never promoted into executable calls"
assert_contains "${AGENT_MESSAGES[4]}" '"content":""' "mixed native tool turns suppress LFM assistant content"
assert_contains "${AGENT_MESSAGES[4]}" "native private reasoning" "native LFM think blocks remain private reasoning"
assert_contains "${AGENT_MESSAGES[4]}" "wrong channel" "competing native-turn content remains available only as reasoning"
assert_contains "${MOCK_LFM_ACTION_PAYLOADS[3]}" '"name":"list_files"' "native LFM calls are preserved in the continuation payload"
assert_contains "${MOCK_LFM_ACTION_PAYLOADS[3]}" "native tool result" "native tool results return to LFM with the tool role"

agent_ollama_chat() {
  (( MOCK_LFM_TURNS++ ))
  MOCK_LFM_PAYLOADS+=("$1")
  if (( MOCK_LFM_TURNS == 1 )); then
    HTTP_BODY='{"message":{"content":"{\"analysis\":\"inspect first\",\"plan\":\"run pwd\",\"commands\":[{\"command\":pwd}],\"status\":\"working\"}"}}'
  elif (( MOCK_LFM_TURNS == 2 )); then
    HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"list_files","arguments":{"path":"."}}}]}}'
  elif (( MOCK_LFM_TURNS == 3 )); then
    HTTP_BODY='{"message":{"content":"{\"analysis\":\"continue\",\"plan\":\"run another check\",\"commands\":[{\"command\":pwd}],\"status\":\"working\"}"}}'
  else
    HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"finish","arguments":{"status":"complete","response":"LFM recovery completed."}}}]}}'
  fi
  HTTP_ERROR=""
  return 0
}
tool_dispatch() {
  (( MOCK_LFM_DISPATCHES++ ))
  TOOL_RESULT="native tool result"
  TOOL_RESULT_OK=1
  return 0
}
AGENT_INCOMPLETE_RETRY_LIMIT=1
AGENT_REQUIRE_FINISH_TOOL=0
MOCK_LFM_TURNS=0
MOCK_LFM_DISPATCHES=0
MOCK_LFM_PAYLOADS=()
agent_reset
agent_user_turn "complete a multi-step LFM task" >/dev/null 2>&1
assert_success "adaptive completion recovers LFM command plans" $?
assert_eq "4" "$MOCK_LFM_TURNS" "LFM recovery continues through native tool use"
assert_eq "1" "$MOCK_LFM_DISPATCHES" "only native LFM tool calls reach dispatch"
assert_contains "${MOCK_LFM_PAYLOADS[2]}" "intermediate JSON plan" "first LFM plan receives a native-tool nudge"
assert_contains "${MOCK_LFM_PAYLOADS[4]}" "intermediate JSON plan" "native tool progress resets the LFM recovery budget"
assert_eq "LFM recovery completed." "$AGENT_LAST_RESPONSE" "LFM recovery retains the structured final response"
assert_contains "${(j:\n:)AGENT_MESSAGES}" 'commands' "unexecuted LFM plans remain model-visible without being dispatched"

typeset -gi MOCK_LFM_REFUSAL_TURNS=0
typeset -g MOCK_LFM_REFUSAL_PAYLOAD=""
agent_ollama_chat() {
  (( MOCK_LFM_REFUSAL_TURNS++ ))
  if (( MOCK_LFM_REFUSAL_TURNS == 1 )); then
    HTTP_BODY='{"message":{"content":"I cannot create the file because file system tools are not available in my current capabilities."}}'
  else
    MOCK_LFM_REFUSAL_PAYLOAD="$1"
    HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"finish","arguments":{"status":"complete","response":"LFM tool recovery completed."}}}]}}'
  fi
  HTTP_ERROR=""
  return 0
}
AGENT_INCOMPLETE_RETRY_LIMIT=1
MOCK_LFM_REFUSAL_TURNS=0
agent_reset
agent_user_turn "use the supplied LFM tools" >/dev/null 2>&1
assert_success "adaptive completion recovers false LFM tool refusals" $?
assert_eq "2" "$MOCK_LFM_REFUSAL_TURNS" "false LFM tool refusals receive one recovery turn"
assert_contains "$MOCK_LFM_REFUSAL_PAYLOAD" "tools in this request are available" "LFM refusal recovery corrects the protocol misunderstanding"
assert_eq "LFM tool recovery completed." "$AGENT_LAST_RESPONSE" "LFM refusal recovery accepts structured completion"

typeset -gi MOCK_LFM_PLAN_ONLY_TURNS=0 MOCK_LFM_PLAN_ONLY_DISPATCHES=0
agent_ollama_chat() {
  (( MOCK_LFM_PLAN_ONLY_TURNS++ ))
  HTTP_BODY='{"message":{"content":"{\"analysis\":\"document it\",\"plan\":\"show a command\",\"commands\":[{\"command\":\"pwd\"}]}"}}'
  HTTP_ERROR=""
  return 0
}
tool_dispatch() {
  (( MOCK_LFM_PLAN_ONLY_DISPATCHES++ ))
  TOOL_RESULT="unexpected dispatch"
  TOOL_RESULT_OK=1
  return 0
}
MOCK_LFM_PLAN_ONLY_TURNS=0
MOCK_LFM_PLAN_ONLY_DISPATCHES=0
agent_reset
agent_user_turn "Respond with JSON and provide a plan only; do not execute it." >/dev/null 2>&1
assert_success "explicit LFM plan-only turns complete as plain content" $?
assert_eq "1" "$MOCK_LFM_PLAN_ONLY_TURNS" "explicit LFM plans do not receive an action retry"
assert_eq "0" "$MOCK_LFM_PLAN_ONLY_DISPATCHES" "explicit LFM plans never enter tool dispatch"
assert_contains "$AGENT_LAST_RESPONSE" '"commands"' "explicit LFM plan JSON remains the final response"
typeset -gi MOCK_LFM_PATCH_TURNS=0 MOCK_LFM_PATCH_DISPATCHES=0
agent_ollama_chat() {
  (( MOCK_LFM_PATCH_TURNS++ ))
  HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"apply_patch","arguments":{"patch":"--- a/note.txt\\n+++ b/note.txt\\n@@ -1 +1 @@\\n-old value\\n+new value"}}}]}}'
  HTTP_ERROR=""
  return 0
}
tool_dispatch() {
  (( MOCK_LFM_PATCH_DISPATCHES++ ))
  TOOL_RESULT="Error: rejected mock patch"
  TOOL_RESULT_OK=0
  return 1
}
agent_reset
agent_user_turn "repair a file" >/dev/null 2>&1
lfm_patch_status=$?
assert_failure "LFM patch recovery stops after its model-specific budget" "$lfm_patch_status"
assert_eq "2" "$MOCK_LFM_PATCH_TURNS" "LFM patch recovery spends only two model turns"
assert_eq "2" "$MOCK_LFM_PATCH_DISPATCHES" "LFM patch recovery dispatches only two rejected patches"
assert_contains "$AGENT_LOOP_REASON" "rejected 2 times" "LFM patch stop records its exact reason"
functions[tool_dispatch]="$saved_lfm_dispatch"
ZCODER_MODEL="$saved_lfm_model"
agent_patch_failure_limit
assert_eq "0" "$REPLY" "other model profiles retain normal patch recovery"
AGENT_INCOMPLETE_RETRY_LIMIT=3

agent_ollama_chat() {
  (( MOCK_INCOMPLETE_TURNS++ ))
  if (( MOCK_INCOMPLETE_TURNS == 1 )); then
    HTTP_BODY='{"message":{"content":""},"prompt_eval_count":100,"eval_count":0}'
  else
    HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"finish","arguments":{"status":"complete","response":"Recovered from an empty response."}}}]},"prompt_eval_count":110,"eval_count":12}'
  fi
  HTTP_ERROR=""
  return 0
}
MOCK_INCOMPLETE_TURNS=0
agent_reset
agent_user_turn "recover an empty response" >/dev/null 2>&1
assert_success "adaptive completion retries an empty response" $?
assert_eq "2" "$MOCK_INCOMPLETE_TURNS" "empty response recovery uses one additional model turn"
assert_eq "Recovered from an empty response." "$AGENT_LAST_RESPONSE" "empty response recovery accepts finish"
assert_contains "${(j:\n:)AGENT_MESSAGES}" "previous response was empty" "empty response recovery is recorded in model history"

agent_ollama_chat() {
  (( MOCK_INCOMPLETE_TURNS++ ))
  if (( MOCK_INCOMPLETE_TURNS == 1 )); then
    HTTP_BODY='not valid json'
  else
    HTTP_BODY='{"message":{"content":"Recovered from malformed output."},"prompt_eval_count":110,"eval_count":12}'
  fi
  HTTP_ERROR=""
  return 0
}
MOCK_INCOMPLETE_TURNS=0
agent_reset
agent_user_turn "recover malformed output" >/dev/null 2>&1
assert_success "adaptive completion retries a malformed model response" $?
assert_eq "2" "$MOCK_INCOMPLETE_TURNS" "malformed response recovery uses one additional model turn"
assert_eq "Recovered from malformed output." "$AGENT_LAST_RESPONSE" "malformed response recovery accepts the valid retry"
assert_contains "${(j:\n:)AGENT_MESSAGES}" "could not be parsed" "malformed response recovery is recorded in model history"

agent_ollama_chat() {
  (( MOCK_INCOMPLETE_TURNS++ ))
  if (( MOCK_INCOMPLETE_TURNS == 1 )); then
    HTTP_BODY='{"message":{"content":"Merekɔyɛ nsakrae no afei."},"prompt_eval_count":100,"eval_count":8}'
  elif (( MOCK_INCOMPLETE_TURNS == 2 )); then
    HTTP_BODY='{"message":{"content":"修正を適用します。"},"prompt_eval_count":110,"eval_count":10}'
  else
    HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"finish","arguments":{"status":"complete","response":"Wɔawie dwumadi no."}}}]},"prompt_eval_count":120,"eval_count":18}'
  fi
  HTTP_ERROR=""
  return 0
}
AGENT_REQUIRE_FINISH_TOOL=1
MOCK_INCOMPLETE_TURNS=0
agent_completion_instructions
assert_contains "$REPLY" "Turn completion is structural" "strict completion remains available as an opt-in"
agent_reset
agent_user_turn "make the focused change" >/dev/null 2>&1
incomplete_status=$?
assert_success "strict completion recovers when responses omit finish" "$incomplete_status"
assert_eq "3" "$MOCK_INCOMPLETE_TURNS" "strict completion continues tool-free responses in any language"
assert_eq "Wɔawie dwumadi no." "$AGENT_LAST_RESPONSE" "strict completion returns the finish response"
assert_contains "${(j:\n:)AGENT_MESSAGES}" "call finish as the only tool" "finish protocol nudge is recorded in model history"
assert_contains "${mapfile[$ZCODER_DEBUG_LOG]}" "continuation_decision" "debug log records continuation decisions"
assert_contains "${mapfile[$ZCODER_DEBUG_LOG]}" "omitted both a work tool and the required finish tool" "debug log records the structural continuation reason"

AGENT_INCOMPLETE_RETRY_LIMIT=0
MOCK_INCOMPLETE_TURNS=0
agent_reset
agent_user_turn "leave continuation disabled" >/dev/null 2>&1
assert_success "zero disables automatic incomplete-response continuation" $?
assert_eq "1" "$MOCK_INCOMPLETE_TURNS" "disabled continuation accepts the first no-tool response"
AGENT_INCOMPLETE_RETRY_LIMIT=3
AGENT_REQUIRE_FINISH_TOOL=0

functions[_test_pre_goal_chat]="${functions[agent_ollama_chat]}"
typeset -gi MOCK_GOAL_WORKER_CALLS=0 MOCK_GOAL_VERIFIER_CALLS=0
agent_ollama_chat() {
  if (( ${GOAL_VERIFIER_ACTIVE:-0} )); then
    (( MOCK_GOAL_VERIFIER_CALLS++ ))
    HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"verify_goal","arguments":{"verdict":"accept","reason":"The transcript and workspace evidence satisfy the objective."}}}]},"prompt_eval_count":80,"eval_count":12}'
  else
    (( MOCK_GOAL_WORKER_CALLS++ ))
    HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"finish","arguments":{"status":"complete","response":"Verified feature delivered."}}}]},"prompt_eval_count":100,"eval_count":16}'
  fi
  HTTP_ERROR=""
  return 0
}
agent_reset
goal_begin "Deliver the verified feature" 0
agent_goal_turn "$GOAL_OBJECTIVE" >/dev/null 2>&1
goal_accept_status=$?
assert_success "goal completion succeeds only after an accepting verifier verdict" "$goal_accept_status"
assert_eq "complete" "$GOAL_STATUS" "an accepted candidate completes the persistent goal"
assert_eq "1" "$GOAL_ATTEMPTS" "accepted goal completion records one candidate attempt"
assert_eq "Verified feature delivered." "$AGENT_LAST_RESPONSE" "accepted goal completion returns the worker's candidate response"
assert_success "goal accounting includes worker and verifier model usage" $(( GOAL_TOKENS_USED > 0 ? 0 : 1 ))

MOCK_GOAL_WORKER_CALLS=0
MOCK_GOAL_VERIFIER_CALLS=0
agent_ollama_chat() {
  if (( ${GOAL_VERIFIER_ACTIVE:-0} )); then
    (( MOCK_GOAL_VERIFIER_CALLS++ ))
    if (( MOCK_GOAL_VERIFIER_CALLS == 1 )); then
      HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"verify_goal","arguments":{"verdict":"reject","reason":"Required verification evidence is missing.","next_action":"Run the required check and report its result.","missing_evidence":"A passing test result."}}}]},"prompt_eval_count":85,"eval_count":18}'
    else
      HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"verify_goal","arguments":{"verdict":"accept","reason":"The corrected transcript now includes the required evidence."}}}]},"prompt_eval_count":90,"eval_count":14}'
    fi
  else
    (( MOCK_GOAL_WORKER_CALLS++ ))
    if (( MOCK_GOAL_WORKER_CALLS == 1 )); then
      HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"finish","arguments":{"status":"complete","response":"First unsupported candidate."}}}]},"prompt_eval_count":100,"eval_count":15}'
    else
      HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"finish","arguments":{"status":"complete","response":"Corrected and evidenced result."}}}]},"prompt_eval_count":110,"eval_count":17}'
    fi
  fi
  HTTP_ERROR=""
  return 0
}
agent_reset
goal_begin "Require evidence before completion" 0
agent_goal_turn "$GOAL_OBJECTIVE" >/dev/null 2>&1
goal_retry_status=$?
assert_success "a rejected goal candidate automatically returns to work" "$goal_retry_status"
assert_eq "complete" "$GOAL_STATUS" "a later accepted candidate completes a rejected goal"
assert_eq "2" "$GOAL_ATTEMPTS" "verifier rejection causes a second candidate attempt"
assert_eq "1" "$GOAL_REJECTIONS" "goal state records independent verifier rejections"
assert_contains "${(j:\n:)AGENT_MESSAGES}" "finish rejected by independent goal verifier" "verifier feedback is retained in worker history"
functions[agent_ollama_chat]="${functions[_test_pre_goal_chat]}"
unfunction _test_pre_goal_chat
goal_reset

agent_loop_reset
agent_loop_record "read:a" "read:a=result"
agent_loop_record "read:a" "read:a=result"
agent_loop_detect
assert_failure "loop guard does not trigger before its repetition threshold" $?
agent_loop_record "read:a" "read:a=result"
agent_loop_detect
assert_success "loop guard detects unchanged repeated outcomes" $?
assert_contains "$AGENT_LOOP_REASON" "unchanged results" "outcome-loop reason explains the lack of progress"

agent_loop_reset
for signature in A B A B A B; do
  agent_loop_record "$signature" "${signature}=same"
done
agent_loop_detect
assert_success "loop guard detects alternating tool cycles" $?
assert_contains "$AGENT_LOOP_REASON" "2-round" "cycle-loop reason reports its period"

agent_loop_reset
agent_loop_record "command:test" "result:one"
agent_loop_record "command:test" "result:two"
agent_loop_record "command:test" "result:three"
agent_loop_detect
assert_failure "changing outcomes receive a more tolerant threshold" $?
agent_loop_record "command:test" "result:four"
agent_loop_detect
assert_success "repeated requests are eventually detected despite changing output" $?

typeset -gi MOCK_LOOP_TURNS=0 MOCK_LOOP_DISPATCHES=0
functions[_test_loop_tool_dispatch]="${functions[tool_dispatch]}"
agent_ollama_chat() {
  (( MOCK_LOOP_TURNS++ ))
  HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"read_file","arguments":{"path":"same.txt"}}}]}}'
  HTTP_ERROR=""
  return 0
}
tool_dispatch() {
  (( MOCK_LOOP_DISPATCHES++ ))
  TOOL_RESULT="unchanged mock file"
  TOOL_RESULT_OK=1
  return 0
}
ZCODER_CONTEXT_WINDOW=32768
AGENT_CONTEXT_MODEL=""
agent_user_turn "keep reading forever" >/dev/null 2>&1
mock_loop_status=$?
assert_failure "agent stops when a model ignores the loop warning" "$mock_loop_status"
assert_eq "4" "$MOCK_LOOP_TURNS" "agent gives one recovery turn before stopping"
assert_eq "3" "$MOCK_LOOP_DISPATCHES" "the violating recovery call is rejected before tool dispatch"
assert_contains "$AGENT_LOOP_NUDGE" "materially different action" "loop warning tells the model how to recover"
assert_contains "$AGENT_LOOP_NUDGE" "one and only recovery turn" "loop warning makes the final chance explicit"
assert_contains "$AGENT_LOOP_NUDGE" "rejected without execution" "loop warning explains the consequence of repetition"

typeset -gi MOCK_LOOP_RECOVERY_TURNS=0 MOCK_LOOP_RECOVERY_DISPATCHES=0
agent_ollama_chat() {
  (( MOCK_LOOP_RECOVERY_TURNS++ ))
  if (( MOCK_LOOP_RECOVERY_TURNS <= 3 )); then
    HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"read_file","arguments":{"path":"same.txt"}}}]}}'
  elif (( MOCK_LOOP_RECOVERY_TURNS == 4 )); then
    HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"read_file","arguments":{"path":"different.txt"}}}]}}'
  else
    HTTP_BODY='{"message":{"content":"Recovered with different evidence."}}'
  fi
  HTTP_ERROR=""
  return 0
}
tool_dispatch() {
  (( MOCK_LOOP_RECOVERY_DISPATCHES++ ))
  TOOL_RESULT="mock file ${MOCK_LOOP_RECOVERY_TURNS}"
  TOOL_RESULT_OK=1
  return 0
}
MOCK_LOOP_RECOVERY_TURNS=0
MOCK_LOOP_RECOVERY_DISPATCHES=0
agent_reset
agent_user_turn "recover from a repeated read" >/dev/null 2>&1
assert_success "a materially different recovery action keeps the conversation running" $?
assert_eq "5" "$MOCK_LOOP_RECOVERY_TURNS" "successful loop recovery reaches the following model turn"
assert_eq "4" "$MOCK_LOOP_RECOVERY_DISPATCHES" "successful loop recovery dispatches the different action"
assert_eq "Recovered with different evidence." "$AGENT_LAST_RESPONSE" "successful loop recovery retains the final response"
assert_eq "0" "$AGENT_LOOP_WARNING_ACTIVE" "a different action clears the active loop warning"

typeset -gi MOCK_LONG_TURNS=0
agent_prepare_payload() {
  REPLY='{}'
  return 0
}
agent_ollama_chat() {
  (( MOCK_LONG_TURNS++ ))
  if (( MOCK_LONG_TURNS <= 105 )); then
    HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"read_file","arguments":{"path":"unique-'"${MOCK_LONG_TURNS}"'.txt"}}}]},"prompt_eval_count":100,"eval_count":4}'
  else
    HTTP_BODY='{"message":{"content":"completed beyond the former ceiling"},"prompt_eval_count":100,"eval_count":6}'
  fi
  HTTP_ERROR=""
  return 0
}
tool_dispatch() {
  TOOL_RESULT="unique result ${MOCK_LONG_TURNS}"
  TOOL_RESULT_OK=1
  return 0
}
AGENT_CONTEXT_DISCOVERY_PENDING=0
agent_reset
agent_user_turn "continue while progress is being made" >/dev/null 2>&1
assert_success "agent runs have no fixed model-turn ceiling" $?
assert_eq "106" "$MOCK_LONG_TURNS" "progressing work continues beyond one hundred model turns"

AGENT_LOOP_REPEAT_LIMIT=2
AGENT_LOOP_MAX_CYCLE=2
agent_loop_reset
for round in {1..20}; do agent_loop_record "$round" "result:$round"; done
assert_eq "6" "${#AGENT_TOOL_REQUEST_HISTORY}" "loop history remains bounded"
assert_eq "15" "${AGENT_TOOL_REQUEST_HISTORY[1]}" "bounded history preserves individual array entries"
functions[tool_dispatch]="${functions[_test_loop_tool_dispatch]}"
unfunction _test_loop_tool_dispatch

# External harnesses are built and parsed independently of curses. These tests
# never invoke a paid model; the async checks use local Zsh child processes.
saved_delegate_command_available="${functions[delegate_command_available]}"
delegate_command_available() { [[ "$1" == claude || "$1" == codex ]]; }
delegate_refresh_availability
delegate_available claude
assert_success "host discovery finds an installed Claude command" $?
delegate_available codex
assert_success "host discovery finds an installed Codex command" $?
delegate_available agy
assert_failure "host discovery marks a missing Antigravity command unavailable" $?
delegate_available opencode
assert_failure "host discovery marks a missing OpenCode command unavailable" $?
delegate_available_csv
assert_eq "claude,codex" "$REPLY" "available harnesses serialize in stable provider order"
delegate_availability_summary "remote server 'test-server'"
assert_contains "$REPLY" "available /claude, /codex; unavailable /agy, /opencode" "availability summary separates installed and missing harnesses"
delegate_unavailable_message agy "remote server 'test-server'"
assert_contains "$REPLY" "/agy is unavailable on remote server 'test-server'" "missing harnesses use the standard host-specific message"
assert_contains "$REPLY" "Available external harnesses: /claude, /codex" "unavailable messages suggest installed alternatives"
delegate_require_available agy "remote server 'test-server'"
assert_failure "availability guard rejects a missing harness" $?
assert_contains "$DELEGATE_ERROR" "'agy' was not found in PATH" "availability guard retains the standard error"

saved_remote_hello_runtime="$REMOTE_RUNTIME_DIR"
REMOTE_RUNTIME_DIR="$TEST_TMP/remote-harness-hello"
zf_mkdir -p "$REMOTE_RUNTIME_DIR"
_remote_server_hello_json
remote_harness_hello="$REPLY"
json_parse_flat_object "$remote_harness_hello"
assert_success "remote hello with harness capabilities remains flat JSON" $?
assert_eq "claude,codex" "${JSON_OBJECT[harnesses]}" "remote hello advertises commands installed on the server host"
assert_eq "true" "${JSON_OBJECT[goals]}" "remote hello advertises persistent goal support"
REMOTE_RUNTIME_DIR="$saved_remote_hello_runtime"

saved_remote_handshake_load_token="${functions[remote_load_token]}"
saved_remote_handshake_request="${functions[remote_client_request]}"
saved_remote_handshake_workspace="$ZCODER_WORKSPACE"
saved_remote_handshake_model="$ZCODER_MODEL"
saved_remote_handshake_profile="$ZCODER_PROFILE"
saved_remote_handshake_name="$REMOTE_SERVER_NAME"
remote_load_token() { return 0; }
remote_client_request() {
  HTTP_BODY='{"protocol":1,"server_name":"test-server","workspace":"/srv/test-server","model":"server-model","profile":"coding","command_policy":"ask","model_status":"ready","model_error":"","harnesses":"claude,codex","sessions":false,"goals":true}'
  return 0
}
remote_client_handshake
assert_success "remote handshake accepts advertised harness capabilities" $?
assert_eq "1" "$REMOTE_HARNESS_DISCOVERY_SUPPORTED" "remote clients recognize harness-aware servers"
assert_eq "claude,codex" "$REMOTE_HARNESSES" "remote clients retain the server-authored harness list"
assert_eq "1" "$REMOTE_GOALS_SUPPORTED" "remote clients recognize goal-aware servers"
delegate_available codex
assert_success "remote availability enables a server-installed harness" $?
delegate_available agy
assert_failure "remote availability rejects a harness missing on the server" $?
remote_client_request() {
  HTTP_BODY='{"protocol":1,"server_name":"legacy","workspace":"/srv/legacy","model":"server-model","profile":"coding","command_policy":"ask","sessions":false}'
  return 0
}
remote_client_handshake
assert_success "remote handshake remains compatible with legacy capability responses" $?
assert_eq "0" "$REMOTE_HARNESS_DISCOVERY_SUPPORTED" "legacy servers leave harness availability unknown"
assert_eq "" "$REMOTE_HARNESSES" "legacy handshakes clear stale remote harness snapshots"
assert_eq "0" "$REMOTE_GOALS_SUPPORTED" "legacy handshakes leave persistent goals disabled"
functions[remote_load_token]="$saved_remote_handshake_load_token"
functions[remote_client_request]="$saved_remote_handshake_request"
functions[delegate_command_available]="$saved_delegate_command_available"
DELEGATE_AVAILABILITY_KNOWN=0
ZCODER_WORKSPACE="$saved_remote_handshake_workspace"
ZCODER_MODEL="$saved_remote_handshake_model"
ZCODER_PROFILE="$saved_remote_handshake_profile"
REMOTE_SERVER_NAME="$saved_remote_handshake_name"

delegate_build_command claude 'review $(touch should-not-run)'
assert_success "Claude consultation command builds" $?
assert_eq "claude-opus-5" "$DELEGATE_MODEL" "Claude uses the configured Opus model"
delegate_command_text="${(j: :)DELEGATE_COMMAND}"
assert_contains "$delegate_command_text" "--permission-mode plan" "Claude runs in plan mode"
assert_contains "$delegate_command_text" "--tools Read,Glob,Grep" "Claude receives only read and search tools"
assert_not_contains "$delegate_command_text" "Bash" "Claude cannot invoke its shell tool"
assert_contains "${DELEGATE_COMMAND[-1]}" '$(touch should-not-run)' "delegate prompts remain literal argv data"

delegate_execution_prompt 'implement $(touch still-literal)'
assert_contains "$REPLY" "${ZCODER_WORKSPACE:A}" "worker prompt names the canonical workspace"
assert_contains "$REPLY" "explicitly authorized" "worker prompt grants workspace edit authority"
assert_contains "$REPLY" "Do not install dependencies" "worker prompt withholds unrelated mutation authority"
assert_contains "$REPLY" 'implement $(touch still-literal)' "worker prompt preserves the literal request"
delegate_prompt unknown "request"
assert_failure "unknown delegate modes are rejected" $?
assert_contains "$DELEGATE_ERROR" "consult or execute" "delegate mode errors list the supported choices"
saved_delegate_profile="$ZCODER_PROFILE"
ZCODER_PROFILE=sysadmin
delegate_build_command codex "change the host" execute
assert_failure "sysadmin profile rejects external coding workers" $?
assert_contains "$DELEGATE_ERROR" "per-command approval" "sysadmin worker rejection preserves its approval boundary"
ZCODER_PROFILE="$saved_delegate_profile"

delegate_build_command claude "implement this" execute
assert_success "Claude worker command builds" $?
assert_eq "execute" "$DELEGATE_MODE" "worker command construction records execution mode"
delegate_command_text="${(j: :)DELEGATE_COMMAND}"
assert_contains "$delegate_command_text" "--permission-mode acceptEdits" "Claude worker accepts workspace edits"
assert_contains "$delegate_command_text" "--tools Read,Glob,Grep,Edit,Write,Bash" "Claude worker receives focused coding tools"
assert_not_contains "$delegate_command_text" "--permission-mode plan" "Claude worker does not remain in consultation mode"

delegate_build_command codex "review this"
assert_success "Codex consultation command builds" $?
delegate_command_text="${(j: :)DELEGATE_COMMAND}"
assert_contains "$delegate_command_text" "codex --ask-for-approval never exec" "Codex applies approval policy before its noninteractive exec command"
assert_contains "$delegate_command_text" "-s read-only" "Codex receives a read-only sandbox"
assert_eq "1" "$DELEGATE_STDIN_PROMPT" "Codex receives the consultation over stdin"

delegate_build_command codex "implement this" execute
assert_success "Codex worker command builds" $?
delegate_command_text="${(j: :)DELEGATE_COMMAND}"
assert_contains "$delegate_command_text" "-s workspace-write" "Codex worker receives a workspace-write sandbox"
assert_not_contains "$delegate_command_text" "-s read-only" "Codex worker does not receive the consultation sandbox"

delegate_build_command agy "review this"
assert_success "Antigravity consultation command builds" $?
delegate_command_text="${(j: :)DELEGATE_COMMAND}"
assert_contains "$delegate_command_text" "--mode plan" "Antigravity runs in plan mode"
assert_contains "$delegate_command_text" "--sandbox" "Antigravity enables its sandbox"
assert_contains "$delegate_command_text" "--model gemini-3.8-flash-high" "Antigravity uses the configured default model"

delegate_build_command agy "implement this" execute
assert_success "Antigravity worker command builds" $?
delegate_command_text="${(j: :)DELEGATE_COMMAND}"
assert_contains "$delegate_command_text" "--mode accept-edits" "Antigravity worker accepts workspace edits"
assert_contains "$delegate_command_text" "--sandbox" "Antigravity worker retains terminal restrictions"

ZCODER_OPENCODE_MODEL=""
delegate_build_command opencode "review this"
assert_failure "OpenCode requires an explicit provider/model" $?
ZCODER_OPENCODE_MODEL="anthropic/claude-sonnet-4"
delegate_build_command opencode "review this"
assert_success "OpenCode consultation command builds after model selection" $?
delegate_command_text="${(j: :)DELEGATE_COMMAND}"
assert_contains "$delegate_command_text" "--agent plan" "OpenCode uses its plan agent"
assert_contains "$delegate_command_text" "--format json" "OpenCode emits structured events"

delegate_build_command opencode "implement this" execute
assert_success "OpenCode worker command builds" $?
delegate_command_text="${(j: :)DELEGATE_COMMAND}"
assert_contains "$delegate_command_text" "--agent build" "OpenCode worker uses its build agent"
assert_not_contains "$delegate_command_text" "--auto" "OpenCode worker does not bypass its permission policy"

delegate_transcript_role codex consult
assert_eq "codex" "$REPLY" "consultations retain their provider transcript role"
delegate_transcript_role codex execute
assert_eq "codex_worker" "$REPLY" "worker runs receive a distinct transcript role"
delegate_activity codex consult
assert_eq "Codex consultation" "$REPLY" "consultation activity is labelled explicitly"
delegate_activity codex execute
assert_eq "Codex worker" "$REPLY" "worker activity is labelled explicitly"

delegate_extract_output claude '{"type":"result","subtype":"success","result":"Claude final"}'
assert_success "Claude JSON result parses" $?
assert_eq "Claude final" "$REPLY" "Claude parser selects the final result"
delegate_extract_output codex $'{"type":"thread.started","thread_id":"x"}\n{"type":"item.completed","item":{"id":"1","type":"agent_message","text":"Codex final"}}'
assert_success "Codex JSONL result parses" $?
assert_eq "Codex final" "$REPLY" "Codex parser selects completed agent messages"
delegate_extract_output agy '{"type":"result","result":"Antigravity final"}'
assert_success "Antigravity JSON result parses" $?
assert_eq "Antigravity final" "$REPLY" "Antigravity parser selects the final result"
delegate_extract_output opencode $'{"type":"text","part":{"text":"Open "}}\n{"type":"text","part":{"text":"Code"}}'
assert_success "OpenCode JSONL result parses" $?
assert_eq "Open Code" "$REPLY" "OpenCode parser joins text events without event noise"

delegate_parse_opencode_models $'anthropic/claude-sonnet-4\nopenai/gpt-5.1\nanthropic/claude-sonnet-4\n'
assert_success "OpenCode provider/model output parses" $?
assert_eq "2" "${#DELEGATE_MODELS}" "OpenCode model choices are deduplicated"
assert_eq "openai/gpt-5.1" "${DELEGATE_MODELS[2]}" "OpenCode model order is preserved"

AGENT_MESSAGES=()
ZCODER_DELEGATE_HISTORY_CHARS=12
delegate_remember claude claude-opus-5 "review this" "a deliberately long consultant result"
assert_eq "1" "${#AGENT_MESSAGES}" "successful consultations add one bounded context record"
assert_contains "${AGENT_MESSAGES[1]}" '"role":"user"' "consultant context uses a template-safe user role"
assert_contains "${AGENT_MESSAGES[1]}" "untrusted quoted reference material" "delegate context labels external output as untrusted"
delegate_remember codex gpt-5.6-sol "implement this" "changed lib/example.zsh" execute
assert_eq "2" "${#AGENT_MESSAGES}" "successful workers add one bounded context record"
assert_contains "${AGENT_MESSAGES[2]}" '"role":"user"' "worker context uses a template-safe user role"
assert_contains "${AGENT_MESSAGES[2]}" "untrusted report from an external coding worker" "worker context identifies the mutating source"
assert_contains "${AGENT_MESSAGES[2]}" "workspace may have changed" "worker context tells the main agent to inspect current state"
ZCODER_DELEGATE_HISTORY_CHARS=12000

delegate_async_start "" 0 zsh -c 'print -rn -- '\''{"result":"async delegate"}'\'''
assert_success "delegate worker starts" $?
for async_poll in {1..100}; do
  delegate_async_ready && break
  zselect -t 1 2>/dev/null
done
delegate_async_collect
assert_success "delegate worker result collects" $?
assert_eq '{"result":"async delegate"}' "$DELEGATE_OUTPUT" "delegate worker preserves structured stdout"
assert_eq "" "$DELEGATE_PID" "delegate collection clears worker state"

delegate_async_start "" 0 zsh -c 'while true; do sleep 1; done'
assert_success "cancellable delegate worker starts" $?
for async_poll in {1..100}; do
  [[ -f "${DELEGATE_BASE}.child" ]] && break
  zselect -t 1 2>/dev/null
done
delegate_child_pid="${mapfile[${DELEGATE_BASE}.child]-}"
delegate_async_cancel
kill -0 "$delegate_child_pid" 2>/dev/null
delegate_child_alive=$?
assert_failure "delegate cancellation reaps the harness process" "$delegate_child_alive"
assert_eq "" "$DELEGATE_BASE" "delegate cancellation removes worker files"

# Keep curses dispatch testable without initializing a terminal. In particular,
# delwin accepts one window per call and refresh accepts the complete frame.

UI_ROLES=(tool)
UI_CONTENTS=($'Apply Patch\n--- a/example.ts\n+++ b/example.ts\n@@ -1 +1 @@\n-old\n+new\n✓ Patch applied')
UI_THINKINGS=(""); UI_TIMES=("12:00"); UI_REASONING_OPEN=(0)
ui_render_messages 80
diff_add_attr=""; diff_remove_attr=""; diff_hunk_attr=""
for (( render_index=1; render_index<=${#UI_LINES}; render_index++ )); do
  [[ "${UI_LINES[render_index]}" == *'+new'* ]] && diff_add_attr="${UI_ATTRS[render_index]}"
  [[ "${UI_LINES[render_index]}" == *'-old'* ]] && diff_remove_attr="${UI_ATTRS[render_index]}"
  [[ "${UI_LINES[render_index]}" == *'@@ -1 +1 @@'* ]] && diff_hunk_attr="${UI_ATTRS[render_index]}"
done
assert_eq "green/black" "$diff_add_attr" "diff preview colors added lines green"
assert_eq "red/black" "$diff_remove_attr" "diff preview colors removed lines red"
assert_eq "bold magenta/black" "$diff_hunk_attr" "diff preview emphasizes hunk headers"

UI_CONTENTS=($'Write File(src/example.ts)\nconst message = "hello";\n// rendered comment\n✓ Wrote src/example.ts')
ui_render_messages 80
syntax_pairs=""
for (( render_index=1; render_index<=${#UI_SEGMENT_TEXTS}; render_index++ )); do
  syntax_pairs+="${UI_SEGMENT_TEXTS[render_index]}:${UI_SEGMENT_ATTRS[render_index]}"$'\n'
done
assert_contains "$syntax_pairs" "const:bold magenta/black" "code preview highlights language keywords"
assert_contains "$syntax_pairs" '"hello":yellow/black' "code preview highlights strings"
assert_contains "$syntax_pairs" "// rendered comment:dim green/black" "code preview highlights comments"

UI_CONTENTS=("Read(src/example.ts)")
ui_render_messages 80
read_summary_attr=""
for (( render_index=1; render_index<=${#UI_LINES}; render_index++ )); do
  [[ "${UI_LINES[render_index]}" == *'Read(src/example.ts)'* ]] && read_summary_attr="${UI_ATTRS[render_index]}"
done
assert_eq "white/black" "$read_summary_attr" "ordinary tool output no longer uses yellow body text"

UI_CONTENTS=("Calling modern.echo.data")
ui_render_messages 80
mcp_call_attr=""
for (( render_index=1; render_index<=${#UI_LINES}; render_index++ )); do
  [[ "${UI_LINES[render_index]}" == *'Calling modern.echo.data'* ]] && mcp_call_attr="${UI_ATTRS[render_index]}"
done
assert_eq "bold yellow/black" "$mcp_call_attr" "MCP call indicators use the tool header color"

UI_ROLES=(codex_worker)
UI_CONTENTS=("Implemented the requested change")
UI_THINKINGS=(""); UI_TIMES=("12:01"); UI_REASONING_OPEN=(0)
ui_render_messages 80
assert_contains "${(j:\n:)UI_LINES}" "Codex worker" "worker responses render with a distinct transcript title"
ui_plain_transcript
assert_contains "$REPLY" "=== Codex worker  12:01 ===" "plain transcript exports preserve worker identity"

UI_ROLES=(assistant)
UI_CONTENTS=("")
UI_THINKINGS=("reasoning without assistant content")
UI_TIMES=("12:01")
UI_REASONING_OPEN=(0)
ui_render_messages 80
reasoning_render="${(j:\n:)UI_LINES}"
assert_contains "$reasoning_render" "Reasoning (1 lines)" "reasoning-only turn renders a collapsible control"
reasoning_empty_body=0
for rendered_line in "${UI_LINES[@]}"; do
  [[ "$rendered_line" == "  " ]] && reasoning_empty_body=1
done
assert_eq "0" "$reasoning_empty_body" "reasoning-only turn omits an empty assistant body"
UI_REASONING_OPEN=(1)
ui_render_messages 80
assert_contains "${(j:\n:)UI_LINES}" "reasoning without assistant content" "expanded reasoning-only turn renders its reasoning"

typeset -ga MOCK_ZCURSES_CALLS=()
zcurses() {
  MOCK_ZCURSES_CALLS+=("${(j: :)@}")
  return 0
}

source "${TEST_DIR}/transcript.zsh"
source "${TEST_DIR}/overlays.zsh"

UI_ACTIVE=1
SCREEN_H=30; SCREEN_W=100; SIDE_W=0; TOP_H=3; INPUT_H=3; FOOT_H=1
UI_SCROLL=0; UI_AUTO_SCROLL=1
UI_ROLES=(tool)
UI_CONTENTS=($'Write File(src/example.ts)\nconst message = "hello";\n✓ Wrote src/example.ts')
UI_THINKINGS=(""); UI_TIMES=("12:00"); UI_REASONING_OPEN=(0)
MOCK_ZCURSES_CALLS=()
ui_draw_chat
render_calls="${(j:\n:)MOCK_ZCURSES_CALLS}"
assert_contains "$render_calls" "attr chat_win bold magenta/black" "curses renderer applies keyword attributes"
assert_contains "$render_calls" 'string chat_win "hello"' "curses renderer writes highlighted string segments"

SCREEN_H=40; SCREEN_W=120; SIDE_W=25; TOP_H=3; INPUT_H=3; FOOT_H=1
UI_FOCUS=sidebar
SESSION_IDS=(111_1 222_2)
SESSION_TITLES=("Older job" "Current job")
SESSION_MODELS=(model-a model-b)
CURRENT_SESSION_ID=222_2
MOCK_ZCURSES_CALLS=()
ui_draw_sidebar
sidebar_calls="${(j:\n:)MOCK_ZCURSES_CALLS}"
assert_contains "$sidebar_calls" "Sessions (2)" "sidebar renders the resumable session log"
assert_contains "$sidebar_calls" "Current job" "sidebar highlights the active saved job"
assert_contains "$sidebar_calls" "───────────────────────" "project details are separated from sessions by a divider"
session_call_index=0; project_call_index=0
for (( render_index=1; render_index<=${#MOCK_ZCURSES_CALLS}; render_index++ )); do
  [[ "${MOCK_ZCURSES_CALLS[render_index]}" == *"Current job"* ]] && session_call_index=$render_index
  [[ "${MOCK_ZCURSES_CALLS[render_index]}" == "string side_win Project" ]] && project_call_index=$render_index
done
assert_success "session log is rendered above the bottom Project block" $(( session_call_index > 0 && project_call_index > session_call_index ? 0 : 1 ))

MOCK_ZCURSES_CALLS=()
ui_destroy_windows
assert_eq "5" "${#MOCK_ZCURSES_CALLS}" "UI destroys each curses window separately"
assert_eq "delwin top_win" "${MOCK_ZCURSES_CALLS[1]}" "UI passes one name to each delwin call"

source "${TEST_DIR}/activity.zsh"
source "${PROJECT_DIR}/lib/stream.zsh"
source "${TEST_DIR}/stream.zsh"
source "${TEST_DIR}/terminal.zsh"
source "${TEST_DIR}/status.zsh"
source "${TEST_DIR}/process.zsh"
source "${TEST_DIR}/tool_wait.zsh"
source "${TEST_DIR}/mcp_connect_wait.zsh"
source "${TEST_DIR}/remote_wait.zsh"
source "${TEST_DIR}/remote_browse.zsh"
source "${TEST_DIR}/models_wait.zsh"
source "${TEST_DIR}/context_wait.zsh"
source "${TEST_DIR}/tui_integration.zsh"

if (( FAILURES > 0 )); then
  print -u2 -r -- "${FAILURES} test(s) failed"
  exit 1
fi
