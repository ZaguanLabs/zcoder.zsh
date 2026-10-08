# Exercise selected reusable boundaries under foreign caller options. Each
# invocation must establish its own semantics and leave the caller intact.
option_contract_tests() {
  emulate -L zsh
  local -a AGENT_MESSAGES=('{"role":"system","content":"legacy"}' '{"role":"user","content":"two words","input_id":"receipt"}')
  local result='' REPLY='' HTTP_ERROR='' endpoint='' bytes='' history='' truncated=''
  local -i normalized=0 counted=0 serialized=0
  {
    setopt ksharrays shwordsplit noextendedglob nomultibyte
    ollama_normalize_host '  http://example.test:11434/  '
    normalized=$?; endpoint="$REPLY"
    _http_byte_length '世界'
    counted=$?; bytes="$REPLY"
    agent_history_payload_json
    serialized=$?; history="$REPLY"
    zcoder_truncate_head_tail "BEGIN-${(l:120::é:)}-END" 60
    truncated="$REPLY"
    result="${options[ksharrays]}:${options[shwordsplit]}:${options[extendedglob]}:${options[multibyte]}"
  } always {
    # Assertions themselves use the ordinary native test environment.
    emulate -L zsh
  }
  assert_eq 'on:on:off:off' "$result" 'reusable boundaries preserve foreign caller options'
  assert_eq 0 "$normalized" 'host normalization works without inherited extended globbing'
  assert_eq example.test:11434 "$endpoint" 'host normalization trims whitespace under foreign options'
  assert_eq '0:6' "$counted:$bytes" 'HTTP byte counts are independent of caller options'
  assert_eq 0 "$serialized" 'history serialization works under zero-based caller arrays'
  assert_eq '{"role":"user","content":"legacy"},{"role":"user","content":"two words"}' "$history" 'history normalization and receipt removal survive foreign options'
  assert_eq 60 "${#truncated}" 'truncation retains its character contract under a byte-mode caller'
}
option_contract_tests
unfunction option_contract_tests
