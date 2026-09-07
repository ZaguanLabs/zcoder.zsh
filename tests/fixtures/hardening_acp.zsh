#!/usr/bin/env zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/datetime zsh/system zsh/zselect
local root="${0:A:h:h:h}" mode="$1" barrier="$2"
source "$root/lib/json.zsh"
source "$root/lib/mcp.zsh"
source "$root/lib/acp.zsh"
_acp_close_input_queue() { :; }
ACP_INITIALIZED=1
ACP_SESSION_ID=demo
ACP_PROMPT_ID_RAW=1
coproc {
  trap 'exit 130' TERM
  if [[ "$mode" == input ]]; then
    while [[ ! -f "$barrier" ]]; do zselect -t 1; done
    print -r -- '{"jsonrpc":"2.0","method":"session/update","params":{"marker":"worker-progress"}}'
  else
    print -rn -- '{"jsonrpc":'
    : > "$barrier"
  fi
  while true; do zselect -t 10; done
}
ACP_WORKER_PID=$!
exec {ACP_WORKER_FD}<&p
ACP_WORKER_RUNNING=1
trap 'acp_shutdown' EXIT
trap 'acp_shutdown; exit 130' INT TERM HUP
acp_main
