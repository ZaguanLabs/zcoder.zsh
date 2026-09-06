#!/usr/bin/env zsh
# Independent wire fixture: delay full or partial replies until released.
emulate -R zsh
zmodload zsh/mapfile zsh/zselect
typeset base="$1" line='' rpc_id='' method='' phase=''
typeset id_pattern='"id":([0-9]+)' method_pattern='"method":"([^\"]+)"' phase_pattern='"phase":"([^\"]+)"'
typeset -i calls=0 partial=0
while IFS= read -r line; do
  rpc_id=''; method=''; phase='plain'; partial=0
  [[ "$line" =~ "$id_pattern" ]] && rpc_id="${match[1]}"
  [[ "$line" =~ "$method_pattern" ]] && method="${match[1]}"
  [[ "$line" =~ "$phase_pattern" ]] && phase="${match[1]}"
  case "$method" in
    server/discover)
      print -r -- '{"jsonrpc":"2.0","id":'"$rpc_id"',"result":{"supportedVersions":["2026-07-28"]}}' ;;
    tools/list)
      print -r -- '{"jsonrpc":"2.0","id":'"$rpc_id"',"result":{"tools":[{"name":"read","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true,"openWorldHint":false}},{"name":"write","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":false,"openWorldHint":true}}]}}' ;;
    tools/call)
      (( calls++ )); mapfile[${base}.calls]="$calls"
      [[ "$phase" == write ]] && mapfile[${base}.external_effect]=applied
      if [[ "$line" == *'"partial":true'* ]]; then
        print -rn -- '{"jsonrpc":"2.0","id":'"$rpc_id"',"result":'
        partial=1
      fi
      mapfile[${base}.started]="$phase"
      if [[ "$line" == *'"wait":true'* ]]; then
        while [[ ! -f "${base}.release-${phase}" ]]; do zselect -t 5 2>/dev/null; done
      fi
      (( partial )) || print -rn -- '{"jsonrpc":"2.0","id":'"$rpc_id"',"result":'
      print -r -- '{"content":[{"type":"text","text":"reply-'"$phase"'"}],"isError":false}}' ;;
  esac
done
