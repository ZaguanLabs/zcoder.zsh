#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/curses zsh/terminfo zsh/datetime zsh/mapfile zsh/files zsh/system zsh/zselect zsh/net/tcp
typeset -g fixture_root="$1" fixture_base="$2"
for fixture_lib in util json mcp http instructions skills transcript tools compact goal agent state input terminal ui overlays remote; do source "$fixture_root/lib/${fixture_lib}.zsh"; done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture ZCODER_PROFILE=coding REMOTE_MODE=client
typeset -g ZCODER_WORKSPACE="${fixture_base:h}" ZCODER_SYNC_OUTPUT=false
typeset -g REMOTE_TOKEN=fixture_token_012345678901234567890
typeset -gi STATE_ENABLED=0 REMOTE_SESSIONS_SUPPORTED=0 REMOTE_REQUEST_TIMEOUT=5
typeset -g fixture_listener='' fixture_server_pid='' fixture_phase=''
typeset -gi fixture_port=0 fixture_attempt=0
for fixture_attempt in {1..20}; do
  fixture_port=$(( 20000 + RANDOM ))
  if ztcp -l "$fixture_port" 2>/dev/null; then fixture_listener=$REPLY; break; fi
done
[[ -n "$fixture_listener" ]] || exit 1
REMOTE_ENDPOINT="127.0.0.1:$fixture_port"
(
  trap - EXIT INT TERM HUP WINCH
  local peer='' phase='' target='' record='' chunk='' previous_phase=''
  local -i sequence=0 stall=0
  while ztcp -a "$fixture_listener"; do
    peer=$REPLY
    _remote_http_read_request "$peer" || exit 2
    phase="${mapfile[$fixture_base.phase]}"; target="$REMOTE_REQUEST_TARGET"
    [[ "$phase" == "$previous_phase" ]] || { sequence=0; previous_phase="$phase"; }
    [[ "$REMOTE_REQUEST_AUTHORIZATION" == "Bearer $REMOTE_TOKEN" ]] || { mapfile[$fixture_base.auth_failed]=1; exit 3; }
    print -r -- "$REMOTE_REQUEST_METHOD:$target" >> "$fixture_base.requests_$phase"
    stall=0
    case "$target" in
      /v1/turn)
        record='{"turn_id":"fixture-turn"}'
        [[ "$phase" == submit_cancel ]] && stall=1
        ;;
      /v1/events\?*)
        (( sequence++ ))
        if [[ "$phase" == approval_* ]]; then
          record='{"event":"approval_required","seq":1,"id":"exact-approval","kind":"external","command":"Publish fixture message"}'
        elif [[ "$phase" == success && sequence -gt 1 ]]; then
          record='{"event":"complete","seq":2,"exit_code":0}'
        else
          record='{"event":"message","seq":1,"role":"assistant","content":"Remote reply 世界"}'
          stall=1
        fi
        ;;
      /v1/approval)
        mapfile[$fixture_base.approval_$phase]="$REMOTE_REQUEST_BODY"
        record='{"ok":true}'; stall=1
        ;;
      /v1/cancel)
        record='{"ok":true}'
        [[ "$phase" == cancel_unconfirmed ]] && stall=1
        ;;
      /v1/model/ensure)
        record='{"model_status":"warming"}'
        [[ "$phase" == warmup_cancel ]] && stall=1
        ;;
      /v1/model) record='{"model_status":"ready"}'; stall=1 ;;
      *) exit 4 ;;
    esac
    if (( stall )); then
      _http_byte_length "$record"
      zcoder_syswrite_all "$peer" $'HTTP/1.1 200 OK\r\nContent-Length: '"$REPLY"$'\r\n\r\n{'
      mapfile[$fixture_base.started]="$phase:$target"
      if [[ "$phase" == success ]]; then
        while [[ ! -f "$fixture_base.release" ]]; do zselect -t 1; done
        zcoder_syswrite_all "$peer" "${record[2,-1]}"
      else
        sysread -i "$peer" -s 32 -t 8 chunk 2>/dev/null
        mapfile[$fixture_base.eof_$phase]="$?"
      fi
    else _remote_http_send "$peer" 200 "$record"
    fi
    ztcp -c "$peer"
  done
) </dev/null >/dev/null 2>&1 &
fixture_server_pid=$!
ztcp -c "$fixture_listener"
fixture_cleanup() {
  ui_end
  kill -TERM "$fixture_server_pid" 2>/dev/null || true
  wait "$fixture_server_pid" 2>/dev/null || true
  zcoder_runtime_cleanup
}
trap fixture_cleanup EXIT
functions[_fixture_input]="${functions[ui_activity_input]}"
ui_activity_input() {
  _fixture_input "$@"
  local -i input_status=$?
  mapfile[$fixture_base.draft]="$INPUT_BUF"
  mapfile[$fixture_base.state]="${SCREEN_W}:${UI_FOCUS}:${UI_BLOCK_OPEN[1]}"
  return "$input_status"
}
functions[_fixture_approval_draw]="${functions[_ui_approval_draw]}"
_ui_approval_draw() { _fixture_approval_draw; mapfile[$fixture_base.approval_ready]="$fixture_phase"; }
command stty rows 24 cols 80 < /dev/tty
ui_append_message assistant 'Fold this stable entry.'
ui_init || exit 1
mapfile[$fixture_base.tty]="$TTY"
# A live PID in unrelated HTTP ownership must survive every remote request.
HTTP_ASYNC_PID="$fixture_server_pid"; HTTP_ASYNC_BASE="$fixture_base.unrelated"
for fixture_phase in success events_cancel submit_cancel approval_deny approval_allow cancel_unconfirmed warmup_cancel poll_cancel timeout; do
  mapfile[$fixture_base.phase]="$fixture_phase"
  REMOTE_MODEL_STATUS=unmanaged
  [[ "$fixture_phase" == warmup_cancel || "$fixture_phase" == poll_cancel ]] && REMOTE_MODEL_STATUS=unknown
  [[ "$fixture_phase" == timeout ]] && REMOTE_REQUEST_TIMEOUT=1
  remote_client_user_turn "Exercise $fixture_phase"
  fixture_result=$?
  mapfile[$fixture_base.result_$fixture_phase]="${fixture_result}:${UI_ACTIVITY_DEPTH}:${UI_STATUS}:${AGENT_LAST_RESPONSE}"
  mapfile[$fixture_base.message_$fixture_phase]="${UI_CONTENTS[-1]}"
done
mapfile[$fixture_base.isolated]="$(( HTTP_ASYNC_PID == fixture_server_pid )):$HTTP_ASYNC_BASE"
HTTP_ASYNC_PID=''; HTTP_ASYNC_BASE=''
typeset -a fixture_scratch=("$ZCODER_RUNTIME_DIR"/http.*(N))
mapfile[$fixture_base.scratch]="${#fixture_scratch}"
ui_end
mapfile[$fixture_base.done]=1
