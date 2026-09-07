#!/usr/bin/env zsh

# Exercise real CLI loading in a fresh shell, replacing only the blocking
# transport entry points and model/approval responses. No listener or Ollama.
headless_probe() {
  local name="" session_id=""
  for name in curses ui input terminal process overlays commands stream delegate relay; do
    (( ! ${+ZCODER_LOADED_LIBS[$name]} )) || return 10
  done
  for name in ui_init input_reset ui_command_palette ui_modal_run TRAPWINCH main_tui handle_slash_command; do
    (( ! $+functions[$name] )) || return 11
  done
  for name in zsh/curses zsh/terminfo; do
    zmodload -e "$name" && return 12
  done
  [[ "$REMOTE_MODE" == server ]] || return 0

  REMOTE_RUNTIME_DIR="$ZCODER_HOME/remote/probe"
  zf_mkdir -p "$REMOTE_RUNTIME_DIR/events" "$REMOTE_RUNTIME_DIR/approvals" || return 13
  _remote_server_hello_json || return 14
  json_parse_flat_object "$REPLY" || return 15
  [[ "${JSON_OBJECT[protocol]}" == 1 && ${+JSON_OBJECT[harnesses]} == 1 ]] || return 16
  (( ${+ZCODER_LOADED_LIBS[harnesses]} && ! ${+ZCODER_LOADED_LIBS[delegate]} )) || return 17
  (( ! $+functions[delegate_async_start] )) || return 18

  ZCODER_SESSIONS_DIR="$REMOTE_RUNTIME_DIR/sessions"
  state_init || return 19
  session_id="$CURRENT_SESSION_ID"
  REMOTE_TURN_ID="${EPOCHSECONDS}_${RANDOM}"
  ZCODER_COMMAND_POLICY=ask
  typeset -gi PROBE_APPROVAL_CALLS=0
  remote_server_request_approval() {
    (( PROBE_APPROVAL_CALLS++ ))
    (( PROBE_APPROVAL_CALLS == 1 )) && REPLY=n || REPLY=y
  }
  agent_user_turn() {
    tool_approve_command 'print denied' && return 20
    tool_approve_command 'print approved' || return 21
    (( PROBE_APPROVAL_CALLS == 2 )) || return 22
    agent_add_message user "$1"
    agent_add_message assistant "headless reply"
    agent_emit assistant "headless reply" "saved reasoning"
  }
  # Worker traps and state are isolated exactly as in the server's fork.
  (_remote_server_turn_worker "headless prompt" "$session_id") || return 23
  STATE_ENABLED=0
  state_load_session "$session_id" || return 24
  [[ "${(j:,:)UI_ROLES}" == user,assistant ]] || return 25
  [[ "${UI_CONTENTS[1]}" == 'headless prompt' && "${UI_CONTENTS[2]}" == 'headless reply' ]] || return 26
  [[ "${UI_THINKINGS[2]}" == 'saved reasoning' && -n "${UI_TIMES[2]}" ]] || return 27
  [[ "${(j:,:)UI_REASONING_OPEN}" == 0,0 && ${#AGENT_MESSAGES} == 2 ]] || return 28
  _remote_server_next_event 0 || return 29
  json_parse_flat_object "$REPLY" || return 30
  [[ "${JSON_OBJECT[content]}" == 'headless reply' ]] || return 31
  return 0
}

source() {
  builtin source "$@" || return $?
  case "$1" in
    */lib/remote.zsh) remote_server_main() { headless_probe; } ;;
    */lib/acp.zsh) acp_main() { headless_probe; } ;;
  esac
  return 0
}

typeset -g probe_entrypoint="$1"
shift
builtin source "$probe_entrypoint" "$@"
