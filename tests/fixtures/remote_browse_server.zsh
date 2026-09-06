#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/net/tcp zsh/system zsh/files zsh/mapfile zsh/zselect
typeset -g fixture_root="$1" fixture_base="$2"
for fixture_lib in util json http remote; do source "$fixture_root/lib/${fixture_lib}.zsh"; done
typeset -g listener='' peer='' phase='' target='' record='' chunk='' current=1000000000_1
typeset -gi attempt=0 port=0 created=2 stall=0
for attempt in {1..20}; do
  port=$(( 20000 + RANDOM ))
  if ztcp -l "$port" 2>/dev/null; then listener=$REPLY; break; fi
done
[[ -n "$listener" ]] || exit 1
mapfile[$fixture_base.endpoint]="127.0.0.1:$port"
while ztcp -a "$listener"; do
  peer=$REPLY
  _remote_http_read_request "$peer" || exit 2
  phase="${mapfile[$fixture_base.phase]}"; target="$REMOTE_REQUEST_TARGET"
  [[ "$REMOTE_REQUEST_AUTHORIZATION" == 'Bearer fixture_token_012345678901234567890' ]] || { mapfile[$fixture_base.auth_failed]=1; exit 3; }
  print -r -- "$REMOTE_REQUEST_METHOD:$target" >> "$fixture_base.requests_$phase"
  stall=0
  case "$target" in
    /v1/hello)
      record='{"protocol":1,"server_name":"Fixture","workspace":"remote","model":"fixture","profile":"coding","command_policy":"ask","sessions":false,"model_status":"warming"}'
      stall=1
      ;;
    /v1/session/select)
      json_parse_flat_object "$REMOTE_REQUEST_BODY" || exit 4
      current="${JSON_OBJECT[id]}"; record='{"ok":true}'
      ;;
    /v1/session/new)
      (( created++ )); current="1000000000_$created"
      record='{"id":"'"$current"'"}'
      [[ "$phase" == new_cancel ]] && stall=1
      ;;
    /v1/sessions\?after=0)
      record='{"event":"session","seq":1,"id":"'"$current"'","title":"Remote job","model":"fixture","current":1,"empty":0}'
      ;;
    /v1/sessions\?*)
      record='{"event":"none"}'
      [[ "$phase" == list_cancel ]] && stall=1
      ;;
    /v1/session\?*after=0)
      record='{"event":"message","seq":1,"role":"assistant","content":"Conversation '"$current"'","thinking":"Saved reasoning","time":"12:34","reasoning_open":1,"metadata":"{\"id\":\"saved-entry\",\"open\":\"0\"}"}'
      [[ "$phase" == load_failure ]] && record='not JSON'
      ;;
    /v1/session\?*)
      record='{"event":"none"}'
      [[ "$phase" == select_cancel || "$phase" == reconcile_cancel ]] && stall=1
      ;;
    /v1/model)
      record='{"model_status":"ready"}'
      [[ "$phase" == idle_cancel || "$phase" == idle_timeout || "$phase" == startup_success ]] && stall=1
      ;;
    /v1/model/ensure) record='{"model_status":"ready"}' ;;
    /v1/turn)
      mapfile[$fixture_base.turn_$phase]="$REMOTE_REQUEST_BODY"
      record='{"turn_id":"fixture-turn"}'
      ;;
    /v1/events\?*) record='{"event":"complete","seq":1,"exit_code":0}' ;;
    *) exit 5 ;;
  esac
  if (( stall )); then
    _http_byte_length "$record"
    zcoder_syswrite_all "$peer" $'HTTP/1.1 200 OK\r\nContent-Length: '"$REPLY"$'\r\n\r\n{'
    mapfile[$fixture_base.started]="$phase:$target"
    if [[ "$phase:$target" == startup_success:/v1/hello ]]; then
      while [[ ! -e "$fixture_base.release_hello" ]]; do zselect -t 1; done
      zcoder_syswrite_all "$peer" "${record[2,-1]}"
    else
      sysread -i "$peer" -s 32 -t 30 chunk 2>/dev/null
      mapfile[$fixture_base.eof_$phase]="$?"
    fi
  else _remote_http_send "$peer" 200 "$record"
  fi
  ztcp -c "$peer"
done
