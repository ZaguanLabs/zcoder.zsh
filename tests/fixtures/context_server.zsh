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
  print -r -- "$REMOTE_REQUEST_TARGET" >> "$fixture_base.requests_$phase"
  record='{"models":[{"name":"fixture","context_length":98304}]}'
  if [[ "$REMOTE_REQUEST_TARGET" == /api/chat ]]; then
    record='{"message":{"content":"Ready"},"done":true}'
    _remote_http_send "$peer" 200 "$record"
  elif [[ "$phase" == cancel || "$phase" == modal || "$phase" == timeout || "$phase" == stale || "$phase" == shutdown ]]; then
    _http_byte_length "$record"
    zcoder_syswrite_all "$peer" $'HTTP/1.1 200 OK\r\nContent-Length: '"$REPLY"$'\r\n\r\n{'
    mapfile[$fixture_base.started]="$phase"
    if [[ "$phase" == modal ]]; then
      while [[ ! -e "$fixture_base.release_modal" ]]; do zselect -t 1; done
      zcoder_syswrite_all "$peer" "${record[2,-1]}"
    else
      sysread -i "$peer" -s 32 -t 15 chunk 2>/dev/null
      mapfile[$fixture_base.eof_$phase]="$?"
    fi
  else
    [[ "$phase" == malformed ]] && record='{"models":[{"name":"fixture","context_length":131072}],'
    _remote_http_send "$peer" 200 "$record"
  fi
  ztcp -c "$peer"
done
