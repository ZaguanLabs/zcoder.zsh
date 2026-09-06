#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/curses zsh/terminfo zsh/datetime zsh/mapfile zsh/files zsh/system zsh/zselect zsh/net/tcp
typeset -g fixture_root="$1" fixture_base="$2"
for fixture_lib in util json mcp http instructions skills transcript tools compact goal agent state input terminal process ui overlays commands; do
  source "$fixture_root/lib/${fixture_lib}.zsh"
done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset -g ZCODER_WORKSPACE="${fixture_base:h}" ZCODER_SYNC_OUTPUT=false ZCODER_CONTEXT_WINDOW=auto ZCODER_WARMUP=true
typeset -gi STATE_ENABLED=0
OLLAMA_HOST="${mapfile[$fixture_base.endpoint]}"
trap 'agent_context_discovery_cancel; http_async_cancel fixture; ui_end; zcoder_runtime_cleanup' EXIT
functions[_fixture_input]="${functions[ui_activity_input]}"
ui_activity_input() {
  _fixture_input "$@"
  local -i result=$?
  mapfile[$fixture_base.draft]="$INPUT_BUF"
  mapfile[$fixture_base.view]="${UI_FOCUS}:${UI_BLOCK_OPEN[1]}:${SCREEN_W}"
  return "$result"
}
functions[_fixture_modal]="${functions[_ui_modal_view_draw]}"
_ui_modal_view_draw() {
  _fixture_modal
  mapfile[$fixture_base.modal]="${SCREEN_W}:${UI_MODAL_ACTIVE}:${UI_ACTIVITY_DEPTH}"
}
fixture_wait_context() {
  while [[ -n "$AGENT_CONTEXT_PID" ]]; do ui_poll_activity 10 || true; done
}
command stty rows 24 cols 80 < /dev/tty
ui_append_message assistant 'Original conversation'
ui_init || exit 1
mapfile[$fixture_base.tty]="$TTY"
mapfile[$fixture_base.phase]=cancel
agent_warmup_start
mapfile[$fixture_base.cancelled]="$?:${AGENT_WARMUP_ACTIVE}:${AGENT_CANCELLED}:${UI_ACTIVITY_DEPTH}:${AGENT_CONTEXT_PID}"
mapfile[$fixture_base.phase]=success
AGENT_CANCELLED=0
agent_context_configure
mapfile[$fixture_base.success]="$?:${AGENT_CONTEXT_WINDOW}:${AGENT_CONTEXT_DISCOVERY_PENDING}"

# A real warm-up completes underneath a modal, then /api/ps stalls. The modal
# must keep its own keyboard handling while the independent lookup is pending.
mapfile[$fixture_base.phase]=modal
AGENT_CONTEXT_DISCOVERY_PENDING=1
http_async_start POST /api/chat '{}' "$OLLAMA_HOST" || exit 3
AGENT_WARMUP_ACTIVE=1; AGENT_WARMUP_MODEL="$ZCODER_MODEL"; AGENT_WARMUP_HOST="$OLLAMA_HOST"
typeset -a modal_lines=('Keep this inspector open while warm-up completes.')
ui_modal_run 'Context fixture' _ui_modal_view_draw _ui_modal_view_input 16 72
mapfile[$fixture_base.modal_closed]="${UI_MODAL_ACTIVE}:${UI_ACTIVITY_DEPTH}:$(( ${#AGENT_CONTEXT_PID} > 0 )):${AGENT_WARMUP_ACTIVE}"
# Collection must leave an in-progress JSON parse and generation result intact.
HTTP_BODY='generation body'; HTTP_ERROR='generation error'
JSON_RESPONSE_CONTENT='assistant response'; JSON_TOOL_NAMES=(read_file)
json_begin '{"sentinel":42}'
typeset -g expected_parser="$JSON_SOURCE:$JSON_POS:$JSON_TOKEN_TYPE:$JSON_TOKEN_VALUE"
REPLY=sentinel
fixture_wait_context
mapfile[$fixture_base.modal_result]="${AGENT_CONTEXT_WINDOW}:${AGENT_CONTEXT_DISCOVERY_PENDING}:${HTTP_BODY}:${HTTP_ERROR}:${JSON_RESPONSE_CONTENT}:${JSON_TOOL_NAMES[1]}"
mapfile[$fixture_base.parser_preserved]="$([[ "$JSON_SOURCE:$JSON_POS:$JSON_TOKEN_TYPE:$JSON_TOKEN_VALUE" == "$expected_parser" ]] && print 1)"

for phase in malformed timeout stale shutdown; do
  mapfile[$fixture_base.phase]="$phase"
  AGENT_CONTEXT_DISCOVERY_PENDING=1
  agent_context_refresh_after_response
  if [[ "$phase" == timeout ]]; then
    AGENT_CONTEXT_DEADLINE=$(( EPOCHREALTIME + 1.0 ))
  elif [[ "$phase" == stale || "$phase" == shutdown ]]; then
    while [[ "${mapfile[$fixture_base.started]}" != "$phase" ]]; do ui_poll_activity 10 || true; done
    if [[ "$phase" == stale ]]; then
      OLLAMA_HOST=127.0.0.1:1
    else ui_end
    fi
  fi
  fixture_wait_context
  mapfile[$fixture_base.result_$phase]="${AGENT_CONTEXT_WINDOW}:${AGENT_CONTEXT_DISCOVERY_PENDING}:${AGENT_CONTEXT_PID}"
  OLLAMA_HOST="${mapfile[$fixture_base.endpoint]}"
done
typeset -a scratch=("$ZCODER_RUNTIME_DIR"/http.*(N))
mapfile[$fixture_base.scratch]="${#scratch}"
mapfile[$fixture_base.done]=1
