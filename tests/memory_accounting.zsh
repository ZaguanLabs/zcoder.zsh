# Bounded exact accounting caches must not retain whole conversations.
memory_accounting_tests() {
  local -a AGENT_MESSAGES=() AGENT_ACCOUNTING_MESSAGES=() AGENT_ACCOUNTING_BYTES=() AGENT_ACCOUNTING_REASONING_BYTES=()
  local -i AGENT_ACCOUNTING_CACHE_BYTES=0 AGENT_ACCOUNTING_MAX_RECORD_BYTES=4096 AGENT_ACCOUNTING_MAX_CACHE_BYTES=1048576 AGENT_ACCOUNTING_MAX_RECORDS=1024
  local AGENT_SYSTEM_PROMPT=fixture AGENT_CONTEXT_TOOLS='[]' AGENT_COMPACTION_SUMMARY='' ZCODER_MODEL=fixture
  local -i GOAL_VERIFIER_ACTIVE=0 parser_calls=0 i
  local saved_parser="${functions[json_parse_ollama_response]}" text='' original_bill='' changed_bill=''
  functions[_memory_real_parser]="$saved_parser"
  json_parse_ollama_response() { (( parser_calls++ )); _memory_real_parser "$@"; }
  {
    AGENT_MESSAGES=('{"role":"assistant","content":"abc","thinking":"x"}')
    agent_context_bill; original_bill="$REPLY"
    agent_context_bill
    assert_eq 1 "$parser_calls" 'small unchanged reasoning uses cached accounting'
    AGENT_MESSAGES[1]='{"role":"assistant","content":"a","thinking":"xyz"}'
    agent_context_bill; changed_bill="$REPLY"
    assert_eq 2 "$parser_calls" 'same-length reasoning edits invalidate bounded cache'
    assert_not_contains "$changed_bill" 'reasoning=1;' 'same-length edit recalculates reasoning share'
    # Replacing a cached record with an oversized one must release its slot.
    text="${(pl:4096::x:)}"
    AGENT_MESSAGES[1]='{"role":"assistant","content":"'"$text"'","thinking":"xyz"}'
    agent_context_bill; original_bill="$REPLY"
    assert_eq '' "${AGENT_ACCOUNTING_MESSAGES[1]}" 'oversized replacement releases previously cached text'
    assert_eq 0 "$AGENT_ACCOUNTING_CACHE_BYTES" 'oversized replacement releases its previous budget charge'
    agent_context_bill
    assert_eq "$original_bill" "$REPLY" 'oversized reasoning is recomputed consistently without retention'
    assert_eq 4 "$parser_calls" 'oversized reasoning bypasses the cache on each inspection'
    agent_accounting_reset
    # Byte bounds must include UTF-8 bytes rather than just character count.
    text="${(pl:2500::é:)}"
    AGENT_MESSAGES=('{"role":"user","content":"'"$text"'"}')
    agent_context_bill
    assert_eq 0 "${#AGENT_ACCOUNTING_MESSAGES}" 'multibyte records obey the byte retention limit'
    agent_accounting_reset
    text="${(pl:131072::x:)}"
    AGENT_MESSAGES=('{"role":"user","content":"'"$text"'"}')
    agent_context_bill
    assert_eq 0 "${#AGENT_ACCOUNTING_MESSAGES}" 'large user record is never retained in accounting cache'
    assert_eq 0 "$AGENT_ACCOUNTING_CACHE_BYTES" 'large record leaves cache payload budget unused'
    AGENT_MESSAGES=()
    AGENT_CONTEXT_TOOLS=''
    agent_add_assistant_message "$text" '' '[]'
    assert_eq 0 "${#AGENT_ACCOUNTING_MESSAGES}" 'large assistant creation avoids eager duplicate'
    AGENT_CONTEXT_TOOLS='[]'
    AGENT_MESSAGES=()
    text="${(pl:2048::x:)}"
    AGENT_ACCOUNTING_MAX_CACHE_BYTES=4096
    for i in {1..4}; do AGENT_MESSAGES+=('{"role":"assistant","content":"'"$text"'"}'); done
    agent_context_bill
    assert_eq 1 "${#AGENT_ACCOUNTING_MESSAGES}" 'aggregate cache budget prevents additional record copies'
    (( AGENT_ACCOUNTING_CACHE_BYTES <= AGENT_ACCOUNTING_MAX_CACHE_BYTES ))
    assert_success 'cache serialized payload remains within its total budget' $?
    original_bill="$REPLY"
    agent_accounting_reset; AGENT_ACCOUNTING_MAX_CACHE_BYTES=0
    agent_context_bill
    assert_eq "$original_bill" "$REPLY" 'uncached history produces the same complete context bill'
    agent_accounting_reset; AGENT_ACCOUNTING_MAX_CACHE_BYTES=1048576; AGENT_ACCOUNTING_MAX_RECORDS=2
    AGENT_MESSAGES=('{"role":"user","content":"a"}' '{"role":"user","content":"b"}' '{"role":"user","content":"c"}')
    agent_context_bill
    assert_eq 2 "${#AGENT_ACCOUNTING_MESSAGES}" 'cache slot count is bounded for many tiny messages'
    AGENT_MESSAGES=()
    agent_context_bill
    assert_eq 0 "$AGENT_ACCOUNTING_CACHE_BYTES" 'history shrink releases removed records from byte budget'
    AGENT_MESSAGES=('{"role":"user","content":"a"}')
    agent_context_bill
    agent_compaction_replace_history 'memory fixture checkpoint'
    assert_eq 0 "${#AGENT_ACCOUNTING_MESSAGES}" 'compaction releases cached records before retaining recent history'
    agent_context_bill
    agent_reset
    assert_eq 0 "${#AGENT_ACCOUNTING_MESSAGES}" 'new job clears cached message copies'
    assert_eq 0 "${#AGENT_ACCOUNTING_BYTES}" 'new job clears cached byte counts'
    assert_eq 0 "${#AGENT_ACCOUNTING_REASONING_BYTES}" 'new job clears cached reasoning counts'
    assert_eq 0 "$AGENT_ACCOUNTING_CACHE_BYTES" 'new job restores the full cache budget'
  } always {
    functions[json_parse_ollama_response]="$saved_parser"
    unfunction _memory_real_parser
  }
}
memory_accounting_tests
unfunction memory_accounting_tests
