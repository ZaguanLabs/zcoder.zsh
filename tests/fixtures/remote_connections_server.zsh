#!/usr/bin/env zsh
# Real socket admission, dispatch, response writers and turn workers. Only the
# model and session persistence are fixtures; no Ollama or curses is involved.
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/files zsh/mapfile zsh/datetime zsh/system zsh/net/tcp zsh/zselect
typeset root="$1" base="$2" library='' port=0 attempt=0
for library in util json http remote; do source "$root/lib/$library.zsh"; done
typeset -gi RUNNING=1 STATE_ENABLED=0
REMOTE_TOKEN=fixture_connection_token
REMOTE_RUNTIME_DIR="$base.runtime"
REMOTE_SESSION_ID=1000000000_1
REMOTE_SERVER_READ_TIMEOUT=1.0
REMOTE_SERVER_WRITE_TIMEOUT=2.0
REMOTE_SERVER_MAX_CONNECTIONS=4
typeset ZCODER_PROFILE=coding ZCODER_COMMAND_POLICY=ask
zf_mkdir -p "$REMOTE_RUNTIME_DIR/events" "$REMOTE_RUNTIME_DIR/approvals"
print -rn -- "$sysparams[pid]" > "$REMOTE_RUNTIME_DIR/server.pid"

functions[fixture_model_ensure]="${functions[_remote_server_model_ensure]}"
_remote_server_model_ensure() {
  if [[ -f "$base.ollama" ]]; then
    OLLAMA_HOST="${mapfile[$base.ollama]}"
    REMOTE_SERVER_MODEL_CHECK_TIMEOUT=0.6
    fixture_model_ensure "$@"
  else
    REMOTE_MODEL_STATUS=ready
  fi
}
_remote_server_hello_json() { REPLY="{\"pid\":$sysparams[pid],\"session\":\"$REMOTE_SESSION_ID\"}"; }
_remote_server_select_session() { REMOTE_SESSION_ID="$1"; }
_remote_server_session_event() {
  # Bigger than the loopback send buffer: a peer that stops reading holds the
  # real syswrite until disconnected or killed by the listener's deadline.
  REPLY='{"data":"'"${(pl:8388608::x:)}"'"}'
}
input_queue_open() { return 0; }
input_queue_close() { return 0; }
state_load_session() { return 0; }
state_note_user() { return 0; }
state_save_session() { return 0; }
state_pause_saved_goal() { return 0; }
ui_append_message() { return 0; }
agent_user_turn() {
  print -r -- "$sysparams[pid]" > "$base.turn"
  while true; do zselect -t 20; done
}

for attempt in {1..20}; do
  port=$(( 20000 + RANDOM ))
  if ztcp -l "$port" 2>/dev/null; then REMOTE_LISTEN_FD=$REPLY; break; fi
done
[[ -n "$REMOTE_LISTEN_FD" ]] || exit 1
print -r -- "127.0.0.1:$port" > "$base.endpoint"
trap 'RUNNING=0' INT TERM HUP
{
  while (( RUNNING )); do
    if [[ -f "$base.pause" ]]; then zselect -t 1; continue; fi
    _remote_server_io_poll
    print -rn -- "${#REMOTE_CONNECTION_PHASE}" > "$base.pool.tmp"
    zf_mv -f "$base.pool.tmp" "$base.pool"
    print -rn -- "${(j: :)${(v)REMOTE_CONNECTION_WRITER}}" > "$base.writers.tmp"
    zf_mv -f "$base.writers.tmp" "$base.writers"
  done
} always {
  remote_server_stop
  zcoder_runtime_cleanup
}
print -r -- stopped > "$base.stopped"
