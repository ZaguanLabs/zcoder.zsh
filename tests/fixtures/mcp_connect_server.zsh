#!/usr/bin/env zsh
emulate -R zsh
zmodload zsh/mapfile zsh/zselect
typeset -g fixture_base="$1" fixture_phase="${mapfile[$1.phase]}" line='' method='' id='' result=''
typeset -g method_pattern='"method":"([^"]+)"' id_pattern='"id":([0-9]+)'
while IFS= read -r line; do
  [[ "$line" =~ "$method_pattern" ]] || continue
  method="$match[1]"
  print -r -- "$method" >> "$fixture_base.methods"
  [[ "$line" =~ "$id_pattern" ]] || continue
  id="$match[1]"
  if [[ "$method" == server/discover && "$fixture_phase" == legacy* ]]; then
    print -r -- '{"jsonrpc":"2.0","id":'"$id"',"error":{"code":-32601,"message":"legacy only"}}'
    continue
  fi
  if [[ ( "$method" == server/discover && "$fixture_phase" == discover* ) ||
        ( "$method" == initialize && "$fixture_phase" == legacy_cancel ) ||
        ( "$method" == tools/list && "$line" == *'"cursor"'* && "$fixture_phase" == pages_cancel ) ]]; then
    print -rn -- '{"jsonrpc":"2.0","id":'"$id"',"result":'
    mapfile[$fixture_base.started]="$fixture_phase"
    while true; do zselect -t 5; done
  fi
  case "$method" in
    server/discover) result='{"supportedVersions":["2026-07-28"]}' ;;
    initialize) result='{"protocolVersion":"2025-11-25"}' ;;
    tools/list)
      if [[ "$line" == *'"cursor"'* ]]; then
        result='{"tools":[{"name":"read_second","inputSchema":{"type":"object"}}]}'
      else
        result='{"tools":[{"name":"read_first","inputSchema":{"type":"object"}}],"nextCursor":"page-two"}'
      fi
      ;;
    *) continue ;;
  esac
  print -r -- '{"jsonrpc":"2.0","id":'"$id"',"result":'"$result"'}'
done
