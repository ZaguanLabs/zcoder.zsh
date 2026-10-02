#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/system zsh/stat zsh/datetime zsh/mapfile zsh/net/tcp zsh/zselect zsh/files
typeset root=$1 base=$2 ZCODER_WORKSPACE=$3
for library in util json http remote; do source "$root/lib/$library.zsh"; done
REMOTE_TOKEN=fixture-document-token
REMOTE_RUNTIME_DIR="$base/runtime"
_remote_server_reap_worker() { return 0; }
typeset -gi RUNNING=1 port attempt
for attempt in {1..20}; do
  port=$(( 20000+RANDOM ))
  if ztcp -l "$port" 2>/dev/null; then REMOTE_LISTEN_FD=$REPLY; break; fi
done
[[ -n $REMOTE_LISTEN_FD ]] || exit 1
print -rn -- "127.0.0.1:$port" > "$base/endpoint"
trap 'RUNNING=0' TERM INT HUP
while (( RUNNING )); do _remote_server_io_poll; done
remote_server_stop
