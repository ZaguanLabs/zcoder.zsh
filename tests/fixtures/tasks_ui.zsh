#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/curses zsh/terminfo zsh/datetime zsh/mapfile zsh/files zsh/system zsh/zselect
typeset -g fixture_root=$1 fixture_base=$2
for lib in util json mcp http instructions skills transcript command_safety tools compact goal agent agent_prompts agent_lfm state input_queue agent_loop input terminal process tasks ui overlays commands command_dispatch tui; do
  source "$fixture_root/lib/$lib.zsh"
done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset -g ZCODER_WORKSPACE=${fixture_base:h} ZCODER_COMMAND_POLICY=allow ZCODER_SYNC_OUTPUT=false ZCODER_WARMUP=false CURRENT_SESSION_ID=fixture
typeset -gi STATE_ENABLED=0 RUNNING=1 REMOTE_HANDSHAKE_PENDING=0 AGENT_REQUIRE_FINISH_TOOL=0 fixture_requests=0
zcoder_require() { :; }
state_init() { :; }
zcoder_refresh_sessions() { :; }
agent_warmup_start() { return 1; }
relay_start() { :; }
agent_ollama_chat() {
  (( fixture_requests++ ))
  print -r -- "$fixture_requests:$AGENT_TURN_ORIGIN" >> "$fixture_base.requests"
  local command_text='' background=false
  case $fixture_requests in
    1)
      command_text="zmodload zsh/zselect; print started > ${(q)fixture_base}.started; while [[ ! -f ${(q)fixture_base}.release-bg ]]; do zselect -t 1; done; print Background_result"
      background=true
      ;;
    2)
      HTTP_BODY='{"message":{"content":"Background job started. We can keep working."}}'
      print ready > "$fixture_base.idle"
      return 0
      ;;
    3)
      command_text="zmodload zsh/zselect; print started > ${(q)fixture_base}.foreground; while [[ ! -f ${(q)fixture_base}.release-fg ]]; do zselect -t 1; done; print Foreground_result"
      ;;
    4)
      HTTP_BODY='{"message":{"content":"Foreground task finished."}}'
      print finished > "$fixture_base.foreground-done"
      return 0
      ;;
    5)
      print -r -- "$1" > "$fixture_base.payload"
      HTTP_BODY='{"message":{"content":"Background result reviewed."}}'
      print reviewed > "$fixture_base.reviewed"
      return 0
      ;;
    *) HTTP_BODY='{"message":{"content":"Unexpected model request."}}'; return 0 ;;
  esac
  zjson_quote "$command_text"
  HTTP_BODY='{"message":{"content":"","tool_calls":[{"function":{"name":"run_command","arguments":{"command":'"$REPLY"',"background":'"$background"'}}}]}}'
  return 0
}
functions[_fixture_tasks_poll]=$functions[tasks_poll]
tasks_poll() {
  _fixture_tasks_poll
  if [[ ${TASK_STATE[task-1]:-} == completed ]]; then
    print -r -- "$fixture_requests:${AGENT_TURN_ACTIVE:-0}" > "$fixture_base.pending"
  fi
}
functions[_fixture_editor]=$functions[ui_editor_input]
ui_editor_input() {
  _fixture_editor "$@"
  print -r -- "$INPUT_BUF" > "$fixture_base.draft"
}
command stty rows 28 cols 100 < /dev/tty
trap 'tasks_cleanup; tool_process_cleanup; ui_end; zcoder_runtime_cleanup' EXIT
main_tui
print done > "$fixture_base.done"
