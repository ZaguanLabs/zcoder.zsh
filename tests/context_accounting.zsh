# Exercise retained and live context separately: the transcript may show an
# interrupted preview that must never enter the next model request.
context_accounting_tests() {
  local -a AGENT_MESSAGES=() AGENT_USER_MESSAGES=() MCP_NAMES=()
  local -a SKILL_NAMES=(accounting) SKILL_CATALOG_NAMES=(accounting) SKILL_DISCOVERABLE_NAMES=(accounting) SKILL_ACTIVE_NAMES=()
  local -A SKILL_BODIES=() SKILL_FILES=(accounting "$TEST_TMP/context-skill/SKILL.md") SKILL_DESCRIPTIONS=(accounting 'Accounting fixture')
  local -A SKILL_ROOTS=(accounting "$TEST_TMP/context-skill")
  local AGENT_SYSTEM_PROMPT='Context accounting fixture' AGENT_CONTEXT_TOOLS='' AGENT_COMPACTION_SUMMARY='' AGENT_LOOP_NUDGE=''
  local AGENT_TOOL_PHASE=full ZCODER_MODEL=fixture REMOTE_MODE=local
  local -i GOAL_VERIFIER_ACTIVE=0 UI_ACTIVE=0 SKILL_DISCOVERY_REQUIRED=0
  local -i AGENT_LAST_PROMPT_TOKENS=0 AGENT_LAST_PAYLOAD_BYTES=0 AGENT_ESTIMATED_TOKENS=0
  local -i AGENT_LAST_OUTPUT_TOKENS=0 RELAY_AVAILABLE=0
  local GOAL_STATUS=none GOAL_OBJECTIVE='' GOAL_FEEDBACK=''
  local -i baseline=0 reasoning_index=0 resources_index=0 skills_index=0 assistant_index=0 tool_index=0 whole_message=0 schema_calls=0
  local -i AGENT_STREAM_CONTEXT_BASE=0 AGENT_STREAM_CONTEXT_BYTES=0
  local saved_schema="${functions[agent_tools_schema_json]}" payload='' reasoning="${(l:9000::r:)}" body="${(l:6000::s:)}" resource="${(l:3000::f:)}"
  zf_mkdir -p "$TEST_TMP/context-skill/references"
  print -r -- $'---\nname: accounting\ndescription: Accounting fixture\n---\n'"$body" > "$TEST_TMP/context-skill/SKILL.md"
  print -rn -- "$resource" > "$TEST_TMP/context-skill/references/guide.md"
  agent_tools_schema_json() { (( schema_calls++ )); REPLY='[]'; }
  {
    agent_add_message user 'Check context'
    agent_build_payload
    payload="$REPLY"
    agent_estimate_payload_tokens "$payload"
    baseline=$AGENT_ESTIMATED_TOKENS
    agent_add_assistant_message 'Short answer' "$reasoning" '[]'
    assert_success 'retained reasoning increases the status estimate immediately' $(( AGENT_ESTIMATED_TOKENS > baseline + 2500 ? 0 : 1 ))
    assert_eq 1 "$schema_calls" 'context refresh never discovers tools or connects MCP servers'
    baseline=$AGENT_ESTIMATED_TOKENS
    agent_build_payload false "$AGENT_CONTEXT_TOOLS"
    assert_contains "$REPLY" "$reasoning" 'the estimated request includes the complete reasoning text'
    agent_estimate_payload_tokens "$REPLY"
    assert_eq "$baseline" "$AGENT_ESTIMATED_TOKENS" 'the post-answer status matches a fresh next-request estimate'

    skills_activate accounting
    assert_success 'context fixture activates a real Skill file' $?
    assert_success 'direct Skill activation refreshes context even without a tool-history entry' $(( AGENT_ESTIMATED_TOKENS > baseline + 1900 ? 0 : 1 ))
    agent_add_message tool "$TOOL_RESULT" activate_skill
    assert_success 'activated Skill instructions increase the counter before another model request' $(( AGENT_ESTIMATED_TOKENS > baseline + 1900 ? 0 : 1 ))
    baseline=$AGENT_ESTIMATED_TOKENS
    skills_read_resource accounting references/guide.md
    assert_success 'context fixture reads a real Skill resource' $?
    agent_add_message tool "$TOOL_RESULT" read_skill_resource
    assert_success 'Skill resource contents immediately increase the status estimate' $(( AGENT_ESTIMATED_TOKENS > baseline + 900 ? 0 : 1 ))

    local JSON_RESPONSE_THINKING=sentinel ZJSON_SOURCE=sentinel
    zjson_validate $'{\n"invalid":01}'
    local parser_diagnostic="$ZJSON_ERROR|$ZJSON_ERROR_CODE|$ZJSON_ERROR_OFFSET|$ZJSON_ERROR_LINE|$ZJSON_ERROR_COLUMN"
    ZJSON_SOURCE=sentinel
    agent_context_bill
    assert_eq sentinel "$JSON_RESPONSE_THINKING" 'context attribution preserves the current response reasoning'
    assert_eq sentinel "$ZJSON_SOURCE" 'context attribution preserves tokenizer state'
    assert_eq "$parser_diagnostic" "$ZJSON_ERROR|$ZJSON_ERROR_CODE|$ZJSON_ERROR_OFFSET|$ZJSON_ERROR_LINE|$ZJSON_ERROR_COLUMN" 'context attribution preserves outer parser diagnostics'
    reasoning_index=${AGENT_CONTEXT_COMPONENT_LABELS[(Ie)Reasoning]}
    resources_index=${AGENT_CONTEXT_COMPONENT_LABELS[(Ie)Skill resources]}
    skills_index=${AGENT_CONTEXT_COMPONENT_LABELS[(Ie)Skills]}
    assistant_index=${AGENT_CONTEXT_COMPONENT_LABELS[(Ie)Assistant]}
    tool_index=${AGENT_CONTEXT_COMPONENT_LABELS[(Ie)Tool results]}
    assert_success 'the inspector attributes retained reasoning explicitly' $(( reasoning_index > 0 && AGENT_CONTEXT_COMPONENT_VALUES[reasoning_index] >= 3000 ? 0 : 1 ))
    assert_success 'the Skills component includes activated instructions' $(( AGENT_CONTEXT_COMPONENT_VALUES[skills_index] >= 2000 ? 0 : 1 ))
    assert_success 'the inspector attributes Skill resources explicitly' $(( resources_index > 0 && AGENT_CONTEXT_COMPONENT_VALUES[resources_index] >= 1000 ? 0 : 1 ))
    assert_eq 0 "${AGENT_CONTEXT_COMPONENT_VALUES[tool_index]}" 'Skill reads are not also counted under generic tool results'
    agent_context_component_tokens "${AGENT_MESSAGES[2]}"; whole_message=$REPLY
    assert_eq "$whole_message" "$(( AGENT_CONTEXT_COMPONENT_VALUES[assistant_index] + AGENT_CONTEXT_COMPONENT_VALUES[reasoning_index] ))" 'splitting reasoning from assistant content does not double count it'

    # Generated text is provisional until the complete response is accepted.
    UI_ACTIVE=1
    baseline=$AGENT_ESTIMATED_TOKENS
    agent_stream_reset
    zjson_quote "$reasoning"
    agent_stream_record '{"message":{"thinking":'"$REPLY"'},"done":false}'
    assert_success 'reasoning-only streaming records update accounting' $?
    assert_success 'live reasoning increases the context estimate before visible answer text' $(( AGENT_ESTIMATED_TOKENS > baseline + 2500 ? 0 : 1 ))
    agent_stream_record '{"message":{"content":"answer"},"done":false}'
    assert_success 'later stream deltas preserve the earlier reasoning contribution' $(( AGENT_ESTIMATED_TOKENS > baseline + 2500 ? 0 : 1 ))
    local -a UI_CONTENTS=(answer) UI_THINKINGS=("$reasoning")
    local -i AGENT_STREAM_PREVIEW=1 UI_STREAM_INDEX=1
    UI_ACTIVE=0
    agent_stream_interrupt
    assert_eq "$baseline" "$AGENT_ESTIMATED_TOKENS" 'interrupted preview text is removed from next-request accounting'

    # Recalibration after Ollama reports usage must still include the answer.
    AGENT_LAST_PROMPT_TOKENS=2000
    _http_byte_length "$payload"; AGENT_LAST_PAYLOAD_BYTES=$REPLY
    agent_add_assistant_message 'Done' "$reasoning" '[]'
    baseline=$AGENT_ESTIMATED_TOKENS
    agent_build_payload false "$AGENT_CONTEXT_TOOLS"
    agent_estimate_payload_tokens "$REPLY"
    assert_eq "$baseline" "$AGENT_ESTIMATED_TOKENS" 'calibrated post-answer accounting agrees with the complete next request'

    # Responses without usage must not destroy the last measured ratio or pair
    # its count with the wrong request. The output counter remains per response.
    json_parse_ollama_response '{"message":{"content":"Done"},"prompt_eval_count":1200,"eval_count":40}'
    agent_context_record_usage "$payload"
    local -i sample_bytes=$AGENT_LAST_PAYLOAD_BYTES
    agent_estimate_payload_tokens "$payload"
    assert_eq 1320 "$REPLY" 'a reported prompt count calibrates its request with ten percent headroom'
    json_parse_ollama_response '{"message":{"content":"Done"},"eval_count":7}'
    agent_context_record_usage "${payload}${reasoning}"
    assert_eq "1200:$sample_bytes:7" "$AGENT_LAST_PROMPT_TOKENS:$AGENT_LAST_PAYLOAD_BYTES:$AGENT_LAST_OUTPUT_TOKENS" 'missing prompt usage preserves the matching sample while updating output usage'
    agent_estimate_payload_tokens "$payload"
    assert_eq 1320 "$REPLY" 'missing usage cannot make the estimate fall back to a different ratio'
    json_parse_ollama_response '{"message":{"content":"Done"},"prompt_eval_count":0}'
    agent_context_record_usage "${payload}${reasoning}"
    assert_eq "1200:$sample_bytes:0" "$AGENT_LAST_PROMPT_TOKENS:$AGENT_LAST_PAYLOAD_BYTES:$AGENT_LAST_OUTPUT_TOKENS" 'zero prompt usage is unusable calibration and missing output does not reuse an old output count'
    json_parse_ollama_response '{"message":{"content":"Done"},"prompt_eval_count":2400,"eval_count":9}'
    agent_context_record_usage "$payload"
    agent_estimate_payload_tokens "$payload"
    assert_eq 2640 "$REPLY" 'the next usable prompt count replaces the retained calibration'

    # These blocks already entered model requests but were absent from the bill.
    AGENT_LAST_PROMPT_TOKENS=0; AGENT_LAST_PAYLOAD_BYTES=0
    GOAL_STATUS=active; GOAL_OBJECTIVE="goal objective $body"; RELAY_AVAILABLE=1
    AGENT_LOOP_NUDGE='Use the evidence from the previous tool result.'
    agent_build_payload false '[]'
    assert_contains "$REPLY" 'goal objective' 'goal accounting fixture includes its objective in the actual request'
    assert_contains "$REPLY" 'Local agent relay:' 'relay accounting fixture includes guidance in the actual request'
    assert_contains "$REPLY" "$AGENT_LOOP_NUDGE" 'loop accounting fixture includes its guidance in the actual request'
    agent_context_bill
    local -i goal_index=${AGENT_CONTEXT_COMPONENT_LABELS[(Ie)Goal guidance]}
    local -i relay_index=${AGENT_CONTEXT_COMPONENT_LABELS[(Ie)Relay guidance]}
    local -i loop_index=${AGENT_CONTEXT_COMPONENT_LABELS[(Ie)Loop guidance]}
    assert_success 'the inspector attributes active goal instructions' $(( AGENT_CONTEXT_COMPONENT_VALUES[goal_index] >= 2000 ? 0 : 1 ))
    assert_success 'the inspector attributes available relay instructions' $(( AGENT_CONTEXT_COMPONENT_VALUES[relay_index] > 0 ? 0 : 1 ))
    assert_success 'the inspector attributes loop recovery instructions' $(( AGENT_CONTEXT_COMPONENT_VALUES[loop_index] > 0 ? 0 : 1 ))

    AGENT_TOOL_PHASE=routing
    agent_context_bill
    assert_eq 0 "$AGENT_CONTEXT_COMPONENT_VALUES[relay_index]" 'routing inspection excludes relay guidance that is absent from its request'
    baseline=$AGENT_CONTEXT_COMPONENT_VALUES[1]
    AGENT_SYSTEM_PROMPT+="$reasoning"
    agent_context_bill
    assert_success 'routing accounting retains custom system instructions alongside routing guidance' $(( AGENT_CONTEXT_COMPONENT_VALUES[1] >= baseline + 3000 ? 0 : 1 ))

    GOAL_VERIFIER_ACTIVE=1
    agent_context_bill
    baseline=$AGENT_CONTEXT_COMPONENT_VALUES[1]
    goal_verifier_system_prompt
    agent_context_component_tokens "$REPLY"
    assert_eq "$REPLY" "$baseline" 'verifier accounting uses its actual system prompt'
    assert_eq 0:0:0 "$AGENT_CONTEXT_COMPONENT_VALUES[goal_index]:$AGENT_CONTEXT_COMPONENT_VALUES[relay_index]:$AGENT_CONTEXT_COMPONENT_VALUES[loop_index]" 'verifier accounting excludes ordinary worker guidance and avoids counting the goal twice'
  } always {
    functions[agent_tools_schema_json]="$saved_schema"
  }
}
context_accounting_tests
unfunction context_accounting_tests
