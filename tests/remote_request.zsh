# Exercise request admission over real sockets without curses or Ollama.
remote_request_tests() {
  local REMOTE_TOKEN=fixture_request_token REMOTE_ERROR=''
  local REMOTE_REQUEST_METHOD='' REMOTE_REQUEST_TARGET='' REMOTE_REQUEST_BODY='' REMOTE_REQUEST_AUTHORIZATION=''
  local -F REMOTE_SERVER_READ_TIMEOUT=0.6 started=0 elapsed=0
  local -i REMOTE_MAX_REQUEST_BYTES=1024 attempt=0 port=0 result=0 i=0
  local listener='' client_fd='' server_fd='' writer_pid='' scenario='' response='' header='' body='世界'
  zmodload zsh/net/tcp
  for scenario in missing_auth wrong_auth header_trickle body_trickle shared_budget valid empty oversized; do
    listener=''; client_fd=''; server_fd=''; writer_pid=''
    {
      for attempt in {1..20}; do
        port=$(( 20000 + RANDOM ))
        if ztcp -l "$port" 2>/dev/null; then listener=$REPLY; break; fi
      done
      [[ -n "$listener" ]] && ztcp 127.0.0.1 "$port" || {
        assert_failure 'remote request fixture opens a loopback connection' 0
        return
      }
      client_fd=$REPLY
      ztcp -a "$listener" || return 1
      server_fd=$REPLY
      ztcp -c "$listener"; listener=''
      header=$'POST /v1/turn HTTP/1.1\r\nAuthorization: Bearer fixture_request_token\r\nContent-Length: '
      case "$scenario" in
        missing_auth|wrong_auth)
          if [[ "$scenario" == missing_auth ]]; then
            header=$'POST /v1/turn HTTP/1.1\r\nContent-Length: '
          else
            header=${header/fixture_request_token/wrong_token}
          fi
          # Keep the peer open and never send the declared body. Admission must
          # return 401 immediately, before a body timeout can produce 400.
          zcoder_syswrite_all "$client_fd" "${header}100"$'\r\n\r\n'
          _remote_server_handle_connection "$server_fd"
          response=''
          sysread -i "$client_fd" -s 32768 -t 1 response
          assert_contains "$response" 'HTTP/1.1 401 Unauthorized' "$scenario rejects a stalled body before reading it"
          assert_eq '' "$REMOTE_REQUEST_BODY" "$scenario never publishes request body data"
          continue
          ;;
        empty) zcoder_syswrite_all "$client_fd" "${header}0"$'\r\n\r\n' ;;
        oversized) zcoder_syswrite_all "$client_fd" "${header}1025"$'\r\n\r\n' ;;
        *)
          (
            trap - EXIT INT TERM HUP
            ztcp -c "$server_fd"
            case "$scenario" in
              header_trickle|body_trickle)
                if [[ "$scenario" == body_trickle ]]; then
                  zcoder_syswrite_all "$client_fd" "${header}100"$'\r\n\r\n' || exit 1
                fi
                for i in {1..10}; do
                  zcoder_syswrite_all "$client_fd" x || exit 1
                  zselect -t 15
                done
                ;;
              shared_budget)
                zcoder_syswrite_all "$client_fd" 'POST /' || exit 1
                zselect -t 40
                zcoder_syswrite_all "$client_fd" "${header#POST /}3"$'\r\n\r\n' || exit 1
                zselect -t 40
                zcoder_syswrite_all "$client_fd" abc
                ;;
              valid)
                _http_byte_length "$body"
                zcoder_syswrite_all "$client_fd" "${header}${REPLY}"$'\r\n\r\n' || exit 1
                zselect -t 2
                zcoder_syswrite_all "$client_fd" "$body"
                ;;
            esac
          ) &
          writer_pid=$!
          ;;
      esac
      started=$EPOCHREALTIME
      _remote_http_read_request "$server_fd" "Bearer ${REMOTE_TOKEN}"
      result=$?
      elapsed=$(( EPOCHREALTIME - started ))
      case "$scenario" in
        header_trickle|body_trickle|shared_budget)
          assert_failure "$scenario cannot extend the total request deadline" "$result"
          assert_contains "$REMOTE_ERROR" 'timed out' "$scenario reports deadline exhaustion"
          (( elapsed < 1.5 ))
          assert_success "$scenario releases the reader within the shared budget and scheduling tolerance" $?
          assert_eq '' "$REMOTE_REQUEST_BODY" "$scenario never publishes an incomplete body"
          ;;
        valid|empty)
          assert_success "$scenario authenticated request completes within the deadline" "$result"
          [[ "$scenario" == empty ]] && body=''
          assert_eq "$body" "$REMOTE_REQUEST_BODY" "$scenario preserves the exact byte-framed body"
          ;;
        oversized)
          assert_eq 2 "$result" 'oversized authenticated requests retain the payload-limit rejection'
          ;;
      esac
    } always {
      if [[ -n "$writer_pid" ]]; then
        kill -TERM "$writer_pid" 2>/dev/null || true
        wait "$writer_pid" 2>/dev/null || true
      fi
      [[ -z "$server_fd" ]] || ztcp -c "$server_fd" 2>/dev/null
      [[ -z "$client_fd" ]] || ztcp -c "$client_fd" 2>/dev/null
      [[ -z "$listener" ]] || ztcp -c "$listener" 2>/dev/null
    }
  done
}
remote_request_tests
unfunction remote_request_tests

remote_request_length_tests() {
  local -i REMOTE_MAX_REQUEST_BYTES=1024 REMOTE_REQUEST_LENGTH=0
  local REMOTE_REQUEST_METHOD='' REMOTE_REQUEST_TARGET='' REMOTE_REQUEST_BODY='' REMOTE_REQUEST_AUTHORIZATION='' REMOTE_ERROR=''
  local length='' header=$'POST / HTTP/1.1\r\nContent-Length: '
  for length in 1025 18446744073709551616 999999999999999999999999999999999999; do
    _remote_http_parse_headers "${header}${length}"
    assert_eq 2 "$?" 'oversized decimal lengths are rejected before integer conversion'
  done
  _remote_http_parse_headers "${header}0001024"
  assert_success 'leading zeros do not change the decimal request limit' $?
  assert_eq 1024 "$REMOTE_REQUEST_LENGTH" 'the exact request limit remains admissible'
  _remote_http_parse_headers "${header}0000"
  assert_success 'an all-zero length remains a valid empty body' $?
  assert_eq 0 "$REMOTE_REQUEST_LENGTH" 'zero lengths normalize without octal interpretation'
}
remote_request_length_tests
unfunction remote_request_length_tests
