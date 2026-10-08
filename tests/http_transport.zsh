# Exercise the real buffered request with deterministic short socket reads.
# Native sysread's output assignment is represented by the caller's chunk local.
http_transport_tests() {
  emulate -L zsh
  local -A saved=() present=()
  local name='' HTTP_BODY='' HTTP_ERROR='' HTTP_ACTIVE_FD='' HTTP_NET_HOST='' HTTP_NET_PORT=''
  local sample='{"text":"世界","escaped":"\n"}' REPLY=''
  local -i HTTP_READ_TIMEOUT=1 read_index=0 closes=0 body_bytes=0
  local -a fragments=() requests=()
  for name in ztcp sysread zcoder_syswrite_all _http_close_active; do
    present[$name]=${+functions[$name]}; saved[$name]="${functions[$name]:-}"
  done
  ztcp() { REPLY=7; }
  sysread() {
    (( read_index++ ))
    (( read_index <= ${#fragments} )) || return 5
    chunk="${fragments[read_index]}"
    return 0
  }
  zcoder_syswrite_all() { requests+=("$2"); }
  _http_close_active() { (( closes++ )); HTTP_ACTIVE_FD=''; return 0; }
  {
    _http_byte_length "$sample"; body_bytes=$REPLY
    fragments=($'HTTP/1.1 2' $'00 OK\r\nContent-Len' "gth: $body_bytes"$'\r\n\r\n{"text":"\xe4' $'\xb8' $'\x96' '界","escaped":"\n"}')
    http_request POST /api/chat '世界' fixture:11434
    assert_success 'buffered HTTP assembles fragmented headers and body bytes' $?
    assert_eq "$sample" "$HTTP_BODY" 'response assembly preserves split UTF-8 and literal JSON escapes'
    assert_contains "$requests[1]" 'Content-Length: 6' 'request payload length remains a byte count'
    assert_eq '1:' "$closes:$HTTP_ACTIVE_FD" 'buffered requests release their descriptor after collection'

    read_index=0
    fragments=($'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWi' $'ki\r\n5\r\npedia\r\n0\r\n\r\n')
    http_request GET /api/tags '' fixture:11434
    assert_success 'buffered HTTP still decodes chunked transfers' $?
    assert_eq Wikipedia "$HTTP_BODY" 'joined socket fragments preserve HTTP chunk boundaries'

    read_index=0
    fragments=($'HTTP/1.1 500 Error\r\n\r\nserver ' 'failure')
    http_request GET /api/tags '' fixture:11434
    assert_failure 'buffered HTTP retains server error status' $?
    assert_eq 'server failure' "$HTTP_BODY" 'buffered HTTP retains fragmented error bodies'
    read_index=0
    fragments=($'HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nshort')
    http_request GET /api/tags '' fixture:11434
    assert_failure 'buffered HTTP rejects a truncated body' $?
    assert_contains "$HTTP_ERROR" '5/8 response bytes' 'buffered HTTP retains incomplete-response diagnostics'
    assert_eq '4:' "$closes:$HTTP_ACTIVE_FD" 'successful and failed requests all close their descriptors'
  } always {
    for name in "${(@k)saved}"; do
      if (( present[$name] )); then functions[$name]="${saved[$name]}"; else unfunction "$name"; fi
    done
  }
}
http_transport_tests
unfunction http_transport_tests
