# Command groups use stubbed presentation/services, never terminal or model IO.
command_dispatch_tests() {
  emulate -L zsh
  source "${PROJECT_DIR}/lib/command_dispatch.zsh"
  local -A saved=() present=()
  local name='' REMOTE_MODE=local ZCODER_MODEL=before ZCODER_WORKSPACE=fixture OLLAMA_HOST=before
  local opened='' help='' DELEGATE_ERROR=unavailable TOOL_RESULT='' HTTP_ERROR=''
  local -i RUNNING=1 UI_ACTIVE=1 refreshes=0 session_refreshes=0 warmups=0 availability=0 DELEGATE_ERROR_REPORTED=0
  local -a emitted=() loaded=() calls=()
  for name in ui_append_message ui_refresh_all zcoder_refresh_sessions agent_warmup_start ui_document_open ui_show_help zcoder_require zcoder_delegate_require_available zcoder_delegate_availability_summary state_new_session input_queue_command delegate_run; do
    present[$name]=${+functions[$name]}; saved[$name]="${functions[$name]:-}"
  done
  ui_append_message() { emitted+=("$1:$2"); }
  ui_refresh_all() { (( refreshes++ )); return 0; }
  zcoder_refresh_sessions() { (( session_refreshes++ )); return 0; }
  agent_warmup_start() { (( warmups++ )); return 0; }
  ui_document_open() { opened="$1"; }
  ui_show_help() { help="$1"; }
  zcoder_require() { loaded+=("$@"); }
  zcoder_delegate_require_available() { (( availability == 0 )); }
  zcoder_delegate_availability_summary() { REPLY=available; }
  state_new_session() { calls+=(new); }
  input_queue_command() { calls+=("$1" "$2"); }
  delegate_run() { calls+=("$@"); }
  {
    handle_slash_command '/model   selected'
    assert_success 'model command is handled' $?
    assert_eq selected "$ZCODER_MODEL" 'model handler trims command arguments'
    assert_eq '1:1:1' "$refreshes:$session_refreshes:$warmups" 'model handler retains the common refresh and warmup'
    handle_slash_command '/open "literal $(false) * 世界.md"'
    assert_eq 'literal $(false) * 世界.md' "$opened" 'open handler keeps paths literal'
    assert_eq 1 "$refreshes" 'open handler does not duplicate its own refresh'
    handle_slash_command /new
    assert_eq new "$calls[1]" 'session handler routes new jobs'
    handle_slash_command '/queue drop receipt'
    assert_eq 'drop:receipt' "$calls[-2]:$calls[-1]" 'queue handler preserves its subcommand and ID'
    handle_slash_command /help
    assert_eq available "$help" 'help retains harness availability information'
    assert_eq 'harnesses,delegate' "${(j:,:)loaded}" 'help loads only its required delegate libraries'
    calls=(); loaded=()
    handle_slash_command '/codex! literal request'
    assert_eq 'codex,literal request,execute' "${(j:,:)calls}" 'delegate handler preserves worker execution mode'
    availability=1; calls=()
    handle_slash_command '/codex request'
    assert_success 'unavailable delegates remain recognized commands' $?
    assert_eq 0 "${#calls}" 'unavailable delegates cannot execute'
    assert_contains "$emitted[-1]" unavailable 'unavailable delegates report their reason'

    REMOTE_MODE=client
    local -i before_refreshes=$refreshes
    handle_slash_command '/model forbidden'
    assert_success 'remote model restriction remains handled' $?
    assert_eq selected "$ZCODER_MODEL" 'remote model restriction preserves the selected model'
    assert_eq "$before_refreshes" "$refreshes" 'remote model rejection does not trigger shared refresh'
    handle_slash_command '/skills reload'
    assert_success 'remote skill reload rejection remains handled' $?
    assert_contains "$emitted[-1]" 'controlled by the remote server' 'remote skill rejection retains its explanation'
    handle_slash_command '/agents pause'
    assert_success 'remote relay rejection remains handled' $?
    assert_contains "$emitted[-1]" 'local to the machine' 'relay group preserves remote restrictions'
    handle_slash_command '/skills unsupported'
    assert_eq 1 "$?" 'unsupported arguments retain model fallback'
    handle_slash_command /unknown
    assert_eq 1 "$?" 'unknown commands retain model fallback'
    handle_slash_command '/quit extra'
    assert_eq 1 "$?" 'exit aliases require an exact command'
    assert_eq 1 "$RUNNING" 'an invalid exit command cannot stop the UI'
    before_refreshes=$refreshes
    handle_slash_command /q
    assert_eq '0:0' "$?:$RUNNING" 'exit aliases stop the UI successfully'
    assert_eq "$before_refreshes" "$refreshes" 'exit does not repaint'
  } always {
    for name in "${(@k)saved}"; do
      if (( present[$name] )); then functions[$name]="${saved[$name]}"; else unfunction "$name"; fi
    done
  }
}
command_dispatch_tests
unfunction command_dispatch_tests
