#!/usr/bin/env zsh

setopt EXTENDED_GLOB NO_NOMATCH
zmodload zsh/datetime zsh/files zsh/mapfile zsh/zselect

0="${ZERO:-${${0:#$ZSH_ARGZERO}:-${(%):-%N}}}"
0="${${(M)0:#/*}:-$PWD/$0}"
typeset -gr TEST_DIR="${0:A:h}"
typeset -gr PROJECT_DIR="${TEST_DIR:h}"

source "${PROJECT_DIR}/lib/util.zsh"
source "${PROJECT_DIR}/lib/json.zsh"
source "${PROJECT_DIR}/lib/mcp.zsh"
source "${PROJECT_DIR}/lib/http.zsh"
source "${PROJECT_DIR}/lib/instructions.zsh"
source "${PROJECT_DIR}/lib/skills.zsh"
source "${PROJECT_DIR}/lib/input.zsh"
source "${PROJECT_DIR}/lib/tools.zsh"
source "${PROJECT_DIR}/lib/compact.zsh"
source "${PROJECT_DIR}/lib/agent.zsh"
source "${PROJECT_DIR}/lib/state.zsh"
source "${PROJECT_DIR}/lib/delegate.zsh"

typeset -gi TESTS=0 FAILURES=0
typeset -g TEST_TMP=""

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
  [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]] && zf_rm -rf -- "$TEST_TMP" 2>/dev/null
}
trap cleanup_tests EXIT INT TERM

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/zcoder-tests.XXXXXX")" || exit 1
ZCODER_WORKSPACE="$TEST_TMP"
ZCODER_MAX_TOOL_OUTPUT=32768

print -r -- "1..387"

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
  assert_eq "No matches." "$TOOL_RESULT" "search excludes gitignored results outside Git"
else
  (( TESTS += 4 ))
  pass "search unavailable (rg not installed)"
  pass "search output unavailable (rg not installed)"
  pass "ignore-aware search unavailable (rg not installed)"
  pass "ignored search output unavailable (rg not installed)"
fi

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
assert_contains "$TOOL_RESULT" "complete standard unified diff" "patch errors teach the model the accepted format"
tools_schema_json
assert_not_contains "$REPLY" '"name":"write_file"' "write_file is hidden after a rejected patch"
tool_write_file "src/note.txt" "destructive fallback"
assert_failure "write_file cannot bypass a rejected focused patch" $?
assert_contains "$TOOL_RESULT" "corrected apply_patch" "blocked write_file directs the model back to patching"
assert_contains "${mapfile[$TEST_TMP/src/note.txt]}" "TWO" "blocked write_file leaves the target unchanged"
tool_apply_patch $'--- a/src/note.txt\n+++ b/src/note.txt\n@@ -1,3 +1,3 @@\n one\n-TWO\n+two\n three\n'
assert_success "a corrected apply_patch releases patch recovery" $?
tools_schema_json
assert_contains "$REPLY" '"name":"write_file"' "write_file returns after the corrected patch succeeds"
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
assert_eq "2" "${#MCP_TOOL_NAMES}" "paginated modern tool discovery loads every page"
mcp_tools_schema_json
assert_contains "$REPLY" '"name":"mcp__modern__find_symbol"' "MCP tool names are namespaced and normalized for Ollama"
assert_contains "$REPLY" '"required":["query"]' "MCP input schemas remain intact in Ollama tool definitions"
assert_contains "$REPLY" "short tool name 'find-symbol'" "MCP schemas teach models how short instruction names map to functions"
mcp_prompt_block
assert_contains "$REPLY" 'modern/find-symbol -> mcp__modern__find_symbol' "MCP prompt supplies an exact short-name routing map"
assert_contains "$REPLY" "mandatory tool-selection rules" "MCP prompt makes required project routing mandatory"
assert_contains "$REPLY" "On the first model turn of each user request" "MCP prompt requires designated orientation before built-ins"
tools_schema_json
first_name_marker='"name":"'
first_exposed_tool="${REPLY#*${first_name_marker}}"; first_exposed_tool="${first_exposed_tool%%\"*}"
[[ "$first_exposed_tool" == mcp__* ]]
assert_success "connected MCP tools precede generic built-ins" $?
assert_contains "$REPLY" "only when project instructions do not designate an MCP navigation tool" "search schema defers to project-designated MCP navigation"
agent_build_payload
assert_contains "$REPLY" 'modern/find-symbol -> mcp__modern__find_symbol' "regular Ollama payloads include connected MCP routing"
tool_dispatch mcp__modern__echo_data '{"payload":{"nested":true}}'
assert_success "nested MCP tool arguments bypass the flat built-in decoder" $?
assert_contains "$TOOL_RESULT" "fixture call completed" "MCP tool results return to the model context"
assert_contains "${mapfile[$mcp_modern_log]}" '"io.modelcontextprotocol/clientCapabilities"' "modern MCP requests carry namespaced client metadata"
assert_contains "${mapfile[$mcp_modern_log]}" '"cursor":"page-2"' "MCP tool discovery follows pagination cursors"

mcp_connect legacy
assert_success "legacy stdio MCP server connects after the discovery probe" $?
assert_eq "$MCP_VERSION_LEGACY" "${MCP_PROTOCOL[legacy]}" "initialize negotiates the 2025 protocol"
assert_contains "${mapfile[$mcp_legacy_log]}" '"method":"initialize"' "legacy negotiation sends initialize after unsupported discovery"
assert_contains "${mapfile[$mcp_legacy_log]}" '"method":"notifications/initialized"' "legacy negotiation completes the initialization lifecycle"
mcp_tools_schema_json
assert_contains "$REPLY" '"name":"mcp__legacy__echo_data"' "tool catalog combines connected MCP servers"
mcp_status_text
assert_contains "$REPLY" $'modern\tconnected\tstdio\tuser\t2026-07-28' "MCP status includes connection, transport, scope, and version"
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
assert_contains "$REPLY" '"name":"folded-skill"' "system prompt discloses skill metadata"
assert_not_contains "$REPLY" "FOLDED BODY SENTINEL" "system prompt does not eagerly load skill instructions"
assert_contains "$REPLY" "never override" "skill catalog preserves higher-priority safety rules"
assert_contains "$REPLY" "Ignore any allowed-tools metadata" "skill metadata cannot bypass approval policy"
tools_schema_json
assert_contains "$REPLY" '"name":"activate_skill"' "tool schema exposes skill activation when skills exist"
assert_not_contains "$REPLY" '"name":"read_skill_resource"' "resource tool is hidden until a Skill is active"
assert_contains "$REPLY" '"enum":["config-only","folded-skill","shared-skill"]' "skill tool names are constrained to discovered values"
saved_max_skills=$ZCODER_MAX_SKILLS
ZCODER_MAX_SKILLS=2
skills_build_catalog
assert_eq "2" "${#SKILL_CATALOG_NAMES}" "skill disclosure honors its configured count limit"
tools_schema_json
assert_not_contains "$REPLY" '"shared-skill"' "skill tool enums omit undisclosed catalog entries"
skills_prompt_block
assert_contains "$REPLY" "Skill catalog truncated" "bounded skill catalogs report truncation"
ZCODER_MAX_SKILLS=$saved_max_skills
skills_build_catalog

tool_dispatch read_skill_resource '{"name":"folded-skill","path":"references/guide.md"}'
assert_failure "skill resources require prior activation" $?
tool_dispatch activate_skill '{"name":"folded-skill"}'
assert_success "activate_skill loads a discovered skill" $?
assert_eq "1" "${#SKILL_ACTIVE_NAMES}" "skill activation is tracked once per conversation"
tools_schema_json
assert_contains "$REPLY" '"enum":["config-only","shared-skill"]' "active Skills leave the activation enum"
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

# The transcript exporter is UI code but does not require curses to be active.
source "${PROJECT_DIR}/lib/ui.zsh"

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
UI_ROLES=(user assistant)
UI_CONTENTS=("Repair the deployment" "Work completed")
UI_THINKINGS=("" "private reasoning")
UI_TIMES=("12:00" "12:01")
UI_REASONING_OPEN=(0 0)
AGENT_COMPACTION_SUMMARY="durable resumed checkpoint"
AGENT_COMPACTION_COUNT=2
AGENT_COMPACTION_REARM_TOKENS=1234
AGENT_LAST_PROMPT_TOKENS=4321
AGENT_LAST_OUTPUT_TOKENS=55
AGENT_LAST_PAYLOAD_BYTES=9876
skills_activate folded-skill >/dev/null
state_save_and_refresh
assert_eq "Repair the deployment without losing conte" "$SESSION_TITLE" "first user request becomes a bounded resumable session title"
assert_contains "${(j:,:)SESSION_IDS}" "$saved_session_id" "saved sessions appear in the sidebar cache"

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
assert_eq "durable resumed checkpoint" "$AGENT_COMPACTION_SUMMARY" "resuming restores compacted context"
assert_eq "2" "$AGENT_COMPACTION_COUNT" "resuming restores compaction metadata"
assert_eq "Repair the deployment" "${AGENT_USER_MESSAGES[1]}" "resuming restores the exact-user ledger"
assert_contains "${(j:,:)SKILL_ACTIVE_NAMES}" "folded-skill" "resuming reactivates available Skills"

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

previous_session_id="$CURRENT_SESSION_ID"
ZCODER_MODEL_OVERRIDE=0
state_new_session
[[ "$CURRENT_SESSION_ID" != "$previous_session_id" ]]
assert_success "new chat creates a separate saved session" $?
assert_eq "0" "${#AGENT_MESSAGES}" "new sessions clear model history"
assert_eq "0" "${#UI_ROLES}" "new sessions clear the visible transcript"
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
assert_contains "$REPLY" "Good example:" "sysadmin prompt also teaches the workspace patch protocol"
agent_select_profile unknown
assert_failure "unknown prompt profiles are rejected" $?
assert_eq "sysadmin" "$ZCODER_PROFILE" "invalid profile selection preserves the active profile"
agent_select_profile coding
assert_success "coding prompt profile is accepted" $?
agent_default_system_prompt
assert_contains "$REPLY" "Project instructions override the default inspection order" "system prompt makes project inspection routing authoritative"
assert_contains "$REPLY" "MCP navigation tool returns a relevant source range" "system prompt routes MCP locations into bounded reads"
assert_contains "$REPLY" "Use search first" "system prompt prefers indexed search before broad reads"
assert_contains "$REPLY" "Use read_file_range" "system prompt directs large-file inspection to ranges"
assert_contains "$REPLY" "rg --files, rg -n, grep, sed -n, or awk" "system prompt names shell text-processing fallbacks"
assert_contains "$REPLY" "if more work remains, call the appropriate work tool" "system prompt requires action instead of a preamble"
assert_contains "$REPLY" "Do not begin by reading whole source files" "system prompt forbids full-file-first exploration"
assert_contains "$REPLY" "chunks of no more than 200 lines" "system prompt gives ranged-read budget guidance"
assert_contains "$REPLY" "Stop inspecting once you have enough evidence" "system prompt prevents unnecessary follow-up reads"
assert_contains "$REPLY" "do not repeat discovery with minor query variations" "system prompt prevents redundant discovery searches"
assert_contains "$REPLY" "non-empty plain assistant response is also accepted as final" "default prompt permits compatible tool-free completion"
assert_contains "$REPLY" "Never use a tool-free response as a preamble" "default prompt still requires tools while work remains"
assert_contains "$REPLY" "Good example:" "coding prompt includes a valid unified-diff example"
assert_contains "$REPLY" "@@ -10,3 +10,3 @@" "valid patch example includes concrete hunk ranges"
assert_contains "$REPLY" "Bad example" "coding prompt contrasts an unsupported patch envelope"
assert_contains "$REPLY" "Never bypass a focused patch failure with write_file" "coding prompt requires patch retry instead of replacement"
tools_schema_json
assert_contains "$REPLY" "defaults to 100" "list_files schema advertises its conservative default"
assert_contains "$REPLY" "defaults to 50" "search schema advertises its conservative default"

agent_format_tool_ui_result read_file '{"path":"src/note.txt"}' $'one\ntwo\nthree' 1
assert_eq "Read(src/note.txt)" "$REPLY" "UI summarizes a complete file read"
assert_not_contains "$REPLY" "three" "UI hides complete file read contents"
agent_format_tool_ui_result read_file_range '{"path":"src/note.txt","start_line":2,"end_line":3}' $'2: two\n3: three' 1
assert_eq "Read File Range(src/note.txt:2-3)" "$REPLY" "UI summarizes a ranged file read"
agent_format_tool_ui_result write_file '{"path":"src/new.txt","content":"visible write body"}' "Wrote file" 1
assert_contains "$REPLY" "visible write body" "UI displays write_file content"
agent_format_tool_ui_result apply_patch '{"patch":"--- a/old.txt\n+++ b/old.txt\n@@ -1 +1 @@\n-old\n+new"}' "Patch applied" 1
assert_contains "$REPLY" "+new" "UI displays apply_patch content"

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

ZCODER_CONTEXT_WINDOW=8192
ZCODER_COMPACT_PERCENT=70
ZCODER_COMPACT_MAX_TOKENS=2048
ZCODER_COMPACT_KEEP_USER_TOKENS=4096
agent_reset
agent_add_message user "original request"
agent_add_message assistant "old assistant detail"
agent_add_message tool "old tool output" read_file
agent_add_message user "current request"
typeset -g MOCK_COMPACT_PAYLOAD=""
agent_ollama_chat() {
  MOCK_COMPACT_PAYLOAD="$1"
  HTTP_BODY='{"message":{"content":"checkpoint summary with exact state"},"prompt_eval_count":1800,"eval_count":120}'
  HTTP_ERROR=""
  return 0
}
agent_compact_history manual >/dev/null
compact_status=$?
assert_success "manual compaction completes" "$compact_status"
assert_contains "$MOCK_COMPACT_PAYLOAD" "old tool output" "compaction request includes detailed tool history"
assert_eq "checkpoint summary with exact state" "$AGENT_COMPACTION_SUMMARY" "compaction stores the model checkpoint"
assert_eq "1" "$AGENT_COMPACTION_COUNT" "compaction advances its checkpoint counter"
assert_eq "4" "${#AGENT_MESSAGES}" "replacement history retains the recent raw exchange"
assert_eq "2" "${#AGENT_USER_MESSAGES}" "replacement history preserves recent real user messages"
agent_build_payload
assert_contains "$REPLY" "checkpoint summary with exact state" "regular prompts include the compacted checkpoint"
assert_contains "$REPLY" "old tool output" "compacted prompts retain recent tool results to prevent repeated work"
assert_contains "$REPLY" '"num_ctx":8192' "explicit context windows are sent to Ollama"
assert_success "compaction rearms above its post-checkpoint estimate" $(( AGENT_COMPACTION_REARM_TOKENS > AGENT_ESTIMATED_TOKENS ? 0 : 1 ))
agent_context_summary
assert_contains "$REPLY" "estimated next prompt:" "context status reports the current transport estimate"
assert_contains "$REPLY" "last Ollama prompt: unknown" "context status distinguishes reset usage from a measured prompt"

ZCODER_CONTEXT_WINDOW=4096
ZCODER_COMPACT_PERCENT=70
agent_reset
agent_add_message user "${(l:12000::x:)}"
agent_prepare_payload >/dev/null
auto_compact_status=$?
prepared_payload="$REPLY"
assert_success "oversized prompts trigger automatic compaction" "$auto_compact_status"
assert_eq "1" "$AGENT_COMPACTION_COUNT" "automatic compaction creates one checkpoint"
assert_contains "$prepared_payload" "checkpoint summary with exact state" "automatic compaction rebuilds the pending prompt from its checkpoint"

functions[_test_real_compaction_builder]="${functions[agent_build_compaction_payload]}"
typeset -gi MOCK_COMPACTION_BUILDS=0
agent_build_compaction_payload() {
  (( MOCK_COMPACTION_BUILDS++ ))
  _test_real_compaction_builder "$@"
}
ZCODER_CONTEXT_WINDOW=4096
AGENT_CONTEXT_WINDOW=4096
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

typeset -gi MOCK_INCOMPLETE_TURNS=0
agent_ollama_chat() {
  (( MOCK_INCOMPLETE_TURNS++ ))
  HTTP_BODY='{"message":{"content":"The requested explanation is complete."},"prompt_eval_count":100,"eval_count":8}'
  HTTP_ERROR=""
  return 0
}
ZCODER_CONTEXT_WINDOW=16384
AGENT_CONTEXT_MODEL=""
agent_reset
agent_user_turn "explain the result" >/dev/null 2>&1
incomplete_status=$?
assert_success "adaptive completion accepts a non-empty tool-free response" "$incomplete_status"
assert_eq "1" "$MOCK_INCOMPLETE_TURNS" "adaptive completion does not spend another model turn"
assert_eq "The requested explanation is complete." "$AGENT_LAST_RESPONSE" "adaptive completion retains the plain response"

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

typeset -gi MOCK_LOOP_TURNS=0
agent_ollama_chat() {
  (( MOCK_LOOP_TURNS++ ))
  HTTP_BODY='{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"read_file","arguments":{"path":"same.txt"}}}]}}'
  HTTP_ERROR=""
  return 0
}
tool_dispatch() {
  TOOL_RESULT="unchanged mock file"
  TOOL_RESULT_OK=1
  return 0
}
ZCODER_CONTEXT_WINDOW=16384
AGENT_CONTEXT_MODEL=""
agent_user_turn "keep reading forever" >/dev/null 2>&1
mock_loop_status=$?
assert_failure "agent stops when a model ignores the loop warning" "$mock_loop_status"
assert_eq "4" "$MOCK_LOOP_TURNS" "agent gives one recovery turn before stopping"
assert_contains "$AGENT_LOOP_NUDGE" "materially different action" "loop warning tells the model how to recover"

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

# External harnesses are built and parsed independently of curses. These tests
# never invoke a paid model; the async checks use local Zsh child processes.
delegate_build_command claude 'review $(touch should-not-run)'
assert_success "Claude consultation command builds" $?
assert_eq "claude-opus-5" "$DELEGATE_MODEL" "Claude uses the configured Opus model"
delegate_command_text="${(j: :)DELEGATE_COMMAND}"
assert_contains "$delegate_command_text" "--permission-mode plan" "Claude runs in plan mode"
assert_contains "$delegate_command_text" "--tools Read,Glob,Grep" "Claude receives only read and search tools"
assert_not_contains "$delegate_command_text" "Bash" "Claude cannot invoke its shell tool"
assert_contains "${DELEGATE_COMMAND[-1]}" '$(touch should-not-run)' "delegate prompts remain literal argv data"

delegate_build_command codex "review this"
assert_success "Codex consultation command builds" $?
delegate_command_text="${(j: :)DELEGATE_COMMAND}"
assert_contains "$delegate_command_text" "codex exec" "Codex uses its noninteractive exec command"
assert_contains "$delegate_command_text" "-s read-only" "Codex receives a read-only sandbox"
assert_eq "1" "$DELEGATE_STDIN_PROMPT" "Codex receives the consultation over stdin"

delegate_build_command agy "review this"
assert_success "Antigravity consultation command builds" $?
delegate_command_text="${(j: :)DELEGATE_COMMAND}"
assert_contains "$delegate_command_text" "--mode plan" "Antigravity runs in plan mode"
assert_contains "$delegate_command_text" "--sandbox" "Antigravity enables its sandbox"

ZCODER_OPENCODE_MODEL=""
delegate_build_command opencode "review this"
assert_failure "OpenCode requires an explicit provider/model" $?
ZCODER_OPENCODE_MODEL="anthropic/claude-sonnet-4"
delegate_build_command opencode "review this"
assert_success "OpenCode consultation command builds after model selection" $?
delegate_command_text="${(j: :)DELEGATE_COMMAND}"
assert_contains "$delegate_command_text" "--agent plan" "OpenCode uses its plan agent"
assert_contains "$delegate_command_text" "--format json" "OpenCode emits structured events"

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
assert_contains "${AGENT_MESSAGES[1]}" "untrusted quoted reference material" "delegate context labels external output as untrusted"
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

typeset -ga MOCK_ZCURSES_CALLS=()
zcurses() {
  MOCK_ZCURSES_CALLS+=("${(j: :)@}")
  return 0
}

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

ui_draw_header() { return 0; }
ui_draw_sidebar() { return 0; }
ui_draw_chat() { return 0; }
ui_draw_input() { return 0; }
ui_draw_footer() { return 0; }
MOCK_ZCURSES_CALLS=()
UI_ACTIVE=1
SIDE_W=25
ui_refresh_all
assert_eq "1" "${#MOCK_ZCURSES_CALLS}" "full UI redraw performs one curses refresh"
assert_eq "refresh top_win side_win chat_win input_win foot_win" "${MOCK_ZCURSES_CALLS[1]}" "full UI redraw batches every visible window"

if (( FAILURES > 0 )); then
  print -u2 -r -- "${FAILURES} test(s) failed"
  exit 1
fi
