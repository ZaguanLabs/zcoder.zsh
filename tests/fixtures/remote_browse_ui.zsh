#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/curses zsh/terminfo zsh/datetime zsh/mapfile zsh/files zsh/system zsh/zselect zsh/net/tcp
typeset -g fixture_root="$1" fixture_base="$2"
for fixture_lib in util json mcp http instructions skills transcript tools compact goal agent state input terminal ui overlays remote; do source "$fixture_root/lib/${fixture_lib}.zsh"; done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture ZCODER_PROFILE=coding REMOTE_MODE=client
typeset -g ZCODER_WORKSPACE="${fixture_base:h}" ZCODER_SYNC_OUTPUT=false REMOTE_TOKEN=fixture_token_012345678901234567890
typeset -gi STATE_ENABLED=0 REMOTE_SESSIONS_SUPPORTED=1 REMOTE_REQUEST_TIMEOUT=10
REMOTE_ENDPOINT="${mapfile[$fixture_base.endpoint]}"
CURRENT_SESSION_ID=1000000000_1; SESSION_TITLE='Original job'
SESSION_IDS=(1000000000_1); SESSION_TITLES=('Original job'); SESSION_MODELS=(fixture)
trap 'remote_client_idle_cancel; ui_end; zcoder_runtime_cleanup' EXIT
functions[_fixture_input]="${functions[ui_activity_input]}"
ui_activity_input() {
  _fixture_input "$@"
  local -i input_status=$?
  mapfile[$fixture_base.draft]="$INPUT_BUF"
  mapfile[$fixture_base.view]="${CURRENT_SESSION_ID}:${UI_CONTENTS[1]}:${UI_BLOCK_OPEN[1]}:${SCREEN_W}"
  return "$input_status"
}
functions[_fixture_request]="${functions[remote_client_request]}"
remote_client_request() {
  [[ "$2" == /v1/turn ]] && mapfile[$fixture_base.submitted_view]="${CURRENT_SESSION_ID}:${UI_CONTENTS[1]}:${REMOTE_SESSION_SYNC_REQUIRED}"
  _fixture_request "$@"
}
command stty rows 24 cols 80 < /dev/tty
ui_append_message assistant 'Original conversation'
ui_init || exit 1
mapfile[$fixture_base.tty]="$TTY"
mapfile[$fixture_base.phase]=list_cancel
remote_client_refresh_sessions
mapfile[$fixture_base.list_cancelled]="$?:${(j: :)SESSION_IDS}:${CURRENT_SESSION_ID}"
mapfile[$fixture_base.phase]=select_cancel
remote_client_select_session 1000000000_2
mapfile[$fixture_base.select_cancelled]="$?:${CURRENT_SESSION_ID}:${UI_CONTENTS[1]}:${REMOTE_SESSION_SYNC_REQUIRED}"
mapfile[$fixture_base.phase]=reconcile_cancel
remote_client_user_turn 'Do not send this cancelled prompt'
mapfile[$fixture_base.reconcile_cancelled]="$?:${CURRENT_SESSION_ID}:${UI_CONTENTS[1]}:${REMOTE_SESSION_SYNC_REQUIRED}"
mapfile[$fixture_base.phase]=reconcile_success
REMOTE_MODEL_STATUS=unmanaged
remote_client_user_turn 'Send after reconciliation'
mapfile[$fixture_base.reconciled]="$?:${CURRENT_SESSION_ID}:${UI_CONTENTS[1]}:${REMOTE_SESSION_SYNC_REQUIRED}:${UI_IDS[1]}:${UI_REASONING_OPEN[1]}"
mapfile[$fixture_base.phase]=new_cancel
remote_client_new_session
mapfile[$fixture_base.new_cancelled]="$?:${CURRENT_SESSION_ID}:${UI_CONTENTS[1]}:${REMOTE_SESSION_SYNC_REQUIRED}"
mapfile[$fixture_base.phase]=load_failure
remote_client_user_turn 'Do not send after a malformed transcript'
mapfile[$fixture_base.failed]="$?:${CURRENT_SESSION_ID}:${UI_CONTENTS[1]}:${REMOTE_SESSION_SYNC_REQUIRED}"
mapfile[$fixture_base.phase]=new_success
remote_client_new_session
mapfile[$fixture_base.new_success]="$?:${CURRENT_SESSION_ID}:${UI_CONTENTS[1]}:${REMOTE_SESSION_SYNC_REQUIRED}"
mapfile[$fixture_base.phase]=idle_cancel
REMOTE_MODEL_STATUS=warming; REMOTE_CLIENT_NEXT_MODEL_POLL=0
typeset -F fixture_before=$EPOCHREALTIME
remote_client_model_poll
mapfile[$fixture_base.idle_started]="$(( EPOCHREALTIME - fixture_before < 0.5 )):${UI_ACTIVITY_DEPTH}:$(( ${#REMOTE_IDLE_PID} > 0 ))"
while [[ ! -e "$fixture_base.submit_idle" ]]; do remote_client_model_poll || true; ui_poll_activity 10 || true; done
mapfile[$fixture_base.phase]=idle_foreground
remote_client_user_turn 'Supersede the idle request'
mapfile[$fixture_base.idle_superseded]="$?:${REMOTE_MODEL_STATUS}:${REMOTE_IDLE_PID}:${UI_ACTIVITY_DEPTH}"
mapfile[$fixture_base.phase]=idle_timeout
REMOTE_MODEL_STATUS=warming; REMOTE_CLIENT_NEXT_MODEL_POLL=0; REMOTE_REQUEST_TIMEOUT=1
while [[ "$REMOTE_MODEL_STATUS" == warming ]]; do remote_client_model_poll || true; ui_poll_activity 10 || true; done
mapfile[$fixture_base.idle_timeout]="${REMOTE_MODEL_STATUS}:${REMOTE_IDLE_PID}:${UI_ACTIVITY_DEPTH}:$REMOTE_MODEL_ERROR"
mapfile[$fixture_base.phase]=idle_success
REMOTE_MODEL_STATUS=warming; REMOTE_CLIENT_NEXT_MODEL_POLL=0
while [[ "$REMOTE_MODEL_STATUS" == warming ]]; do remote_client_model_poll || true; ui_poll_activity 10 || true; done
mapfile[$fixture_base.idle_success]="${REMOTE_MODEL_STATUS}:${REMOTE_IDLE_PID}:${UI_ACTIVITY_DEPTH}"
typeset -a fixture_scratch=("$ZCODER_RUNTIME_DIR"/http.*(N))
mapfile[$fixture_base.scratch]="${#fixture_scratch}"
ui_end
mapfile[$fixture_base.done]=1
