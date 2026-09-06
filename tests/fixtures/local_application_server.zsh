#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/net/tcp zsh/system zsh/files zsh/mapfile
typeset -g fixture_root="$1" fixture_base="$2"
for fixture_lib in util json http remote; do source "$fixture_root/lib/${fixture_lib}.zsh"; done
typeset -g listener='' peer='' record='' chunk=''
typeset -gi attempt=0 port=0 requests=0 chats=0
for attempt in {1..20}; do
  port=$(( 20000 + RANDOM ))
  if ztcp -l "$port" 2>/dev/null; then listener=$REPLY; break; fi
done
[[ -n "$listener" ]] || exit 1
mapfile[$fixture_base.endpoint]="127.0.0.1:$port"
while ztcp -a "$listener"; do
  peer=$REPLY
  _remote_http_read_request "$peer" || exit 2
  (( requests++ ))
  print -r -- "$REMOTE_REQUEST_TARGET" >> "$fixture_base.requests"
  if (( requests == 1 )); then
    [[ "$REMOTE_REQUEST_TARGET" == /api/ps ]] || exit 3
    zcoder_syswrite_all "$peer" $'HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{'
    mapfile[$fixture_base.started]=1
    sysread -i "$peer" -s 32 -t 15 chunk 2>/dev/null
    mapfile[$fixture_base.cancel_eof]="$?"
  elif [[ "$REMOTE_REQUEST_TARGET" == /api/ps ]]; then
    _remote_http_send "$peer" 200 '{"models":[{"name":"fixture","context_length":98304}]}'
  elif [[ "$REMOTE_REQUEST_TARGET" == /api/chat ]]; then
    (( chats++ ))
    mapfile[$fixture_base.chat_count]="$chats"
    mapfile[$fixture_base.prompt]="$REMOTE_REQUEST_BODY"
    record=$'{"message":{"content":"Integration complete."},"done":true,"prompt_eval_count":40,"eval_count":5}\n'
    _remote_http_send "$peer" 200 "$record"
  else exit 4
  fi
  ztcp -c "$peer"
done
