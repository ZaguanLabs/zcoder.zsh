#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/net/tcp zsh/system zsh/files zsh/mapfile zsh/zselect
typeset -g fixture_root="$1" fixture_base="$2"
for fixture_lib in util json http remote; do source "$fixture_root/lib/${fixture_lib}.zsh"; done
typeset -g listener='' peer='' phase='' record='' chunk=''
typeset -gi attempt=0 port=0
for attempt in {1..20}; do
  port=$(( 20000 + RANDOM ))
  if ztcp -l "$port" 2>/dev/null; then listener=$REPLY; break; fi
done
[[ -n "$listener" ]] || exit 1
mapfile[$fixture_base.endpoint]="127.0.0.1:$port"
while ztcp -a "$listener"; do
  peer=$REPLY
  _remote_http_read_request "$peer" || exit 2
  phase="${mapfile[$fixture_base.phase]}"
  record='{"models":[{"name":"alpha"},{"name":"beta"}]}'
  [[ "$REMOTE_REQUEST_TARGET" == /warmup ]] && phase=warmup
  case "$phase" in
    cancel|timeout)
      _http_byte_length "$record"
      zcoder_syswrite_all "$peer" $'HTTP/1.1 200 OK\r\nContent-Length: '"$REPLY"$'\r\n\r\n{'
      mapfile[$fixture_base.started]="$phase"
      sysread -i "$peer" -s 32 -t 15 chunk 2>/dev/null
      mapfile[$fixture_base.eof_$phase]="$?"
      ;;
    *)
      [[ "$phase" == malformed ]] && record='invalid JSON'
      [[ "$phase" == warmup ]] && record='{"warmup":true}'
      _remote_http_send "$peer" 200 "$record"
      ;;
  esac
  ztcp -c "$peer"
done
