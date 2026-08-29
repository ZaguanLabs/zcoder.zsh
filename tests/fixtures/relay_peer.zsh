#!/usr/bin/env zsh

setopt EXTENDED_GLOB NO_NOMATCH NO_MONITOR NO_NOTIFY NO_CHECK_JOBS NO_HUP
zmodload zsh/datetime zsh/files zsh/mapfile zsh/system zsh/zselect || exit 1

typeset -gr FIXTURE_DIR="${0:A:h}"
typeset -gr PROJECT_DIR="${FIXTURE_DIR:h:h}"
typeset -g peer_relay_dir="$1" peer_runtime_parent="$2" peer_workspace="$3"
typeset -g peer_ready_file="$4" peer_stop_file="$5" peer_received_file="$6"
typeset -gi peer_running=1

source "${PROJECT_DIR}/lib/util.zsh"
source "${PROJECT_DIR}/lib/json.zsh"
source "${PROJECT_DIR}/lib/relay.zsh"

TRAPTERM() { peer_running=0; return 0; }
TRAPINT() { peer_running=0; return 0; }
TRAPHUP() { peer_running=0; return 0; }

ZCODER_RELAY_DIR="$peer_relay_dir"
TMPDIR="$peer_runtime_parent"
ZCODER_WORKSPACE="$peer_workspace"
ZCODER_MODEL="fixture-model"
ZCODER_PROFILE="coding"
CURRENT_SESSION_ID="1_1"
zf_mkdir -p -- "$peer_runtime_parent" "$peer_workspace" || exit 1
relay_start || exit 1
mapfile[$peer_ready_file]="$RELAY_INSTANCE_ID" || { relay_stop; exit 1; }

while (( peer_running )) && [[ ! -f "$peer_stop_file" ]]; do
  if relay_claim_one; then
    mapfile[$peer_received_file]="$RELAY_CLAIM_SENDER_PROJECT"$'\n'"$RELAY_CLAIM_BODY"
    relay_complete_claim || true
  fi
  zselect -t 2 2>/dev/null
done

relay_stop
zcoder_runtime_cleanup
