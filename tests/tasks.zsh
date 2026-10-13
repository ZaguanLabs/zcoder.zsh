#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/datetime zsh/system zsh/files zsh/mapfile zsh/stat zsh/zselect zsh/zpty
typeset -g root=${${(%):-%x}:A:h:h}
for lib in util json command_safety tools process tasks; do source "$root/lib/$lib.zsh"; done
zcoder_runtime_init || exit 1
typeset -g test_base=$ZCODER_RUNTIME_DIR
typeset -g ZCODER_WORKSPACE=$test_base CURRENT_SESSION_ID=first REMOTE_MODE=local ZCODER_PROFILE=coding
typeset -gi UI_ACTIVE=1 UI_ACTIVITY_DEPTH=0 calls=0 failures=0
typeset -g received='' shown=''
ui_draw_footer() { :; }
ui_append_message() { shown=$2; }
_agent_run_turn() { (( calls++ )); received=$1; }
trap 'tasks_cleanup; zcoder_runtime_cleanup' EXIT
check() { if "$@"; then print -r -- "ok - $1"; else print -ru2 -- "FAIL - $*"; (( failures++ )); fi; }
equal() { [[ $1 == "$2" ]]; }
contains() { [[ $1 == *"$2"* ]]; }
wait_file() {
  local -F until=$(( EPOCHREALTIME + 5 ))
  while [[ ! -s $1 ]] && (( EPOCHREALTIME < until )); do zselect -t 1; done
  [[ -s $1 ]]
}
wait_task() {
  local -F until=$(( EPOCHREALTIME + 5 ))
  while [[ ${TASK_STATE[$1]} != completed ]] && (( EPOCHREALTIME < until )); do tasks_poll; zselect -t 1; done
  [[ ${TASK_STATE[$1]} == completed ]]
}
dead() {
  local -F until=$(( EPOCHREALTIME + 5 ))
  local stat_text=''
  while kill -0 "$1" 2>/dev/null && (( EPOCHREALTIME < until )); do
    # Linux can retain an orphan zombie until init reaps it; it cannot execute.
    if [[ -r /proc/$1/stat ]]; then
      stat_text=${mapfile[/proc/$1/stat]}
      [[ ${stat_text#*\) } == Z\ * ]] && return 0
    fi
    zselect -t 1
  done
  ! kill -0 "$1" 2>/dev/null
}

ZCODER_COMMAND_POLICY=deny
tool_dispatch run_command '{"command":"print forbidden > denied","background":true}'
check equal "$TOOL_RESULT_OK" 0
check equal "${#TASK_IDS}" 0
check test ! -e "$test_base/denied"
ZCODER_COMMAND_POLICY=allow
tool_dispatch run_command '{"command":"print forbidden","cwd":"..","background":true}'
check equal "$TOOL_RESULT_OK" 0
check equal "${#TASK_IDS}" 0
UI_ACTIVE=0
tool_dispatch run_command '{"command":"print forbidden","background":true}'
check contains "$TOOL_RESULT" 'local TUI'
UI_ACTIVE=1
ZCODER_PROFILE=sysadmin
ui_confirm_command() { return 1; }
tool_dispatch run_command '{"command":"print forbidden","background":true}'
check equal "${#TASK_IDS}" 0
ZCODER_PROFILE=coding

tools_schema_json
check contains "$REPLY" '"background"'
UI_ACTIVE=0
tools_schema_json
check equal "${REPLY[(I)*\"background\"*]}" 0
UI_ACTIVE=1
tool_dispatch run_command '{"command":"print invalid","background":true,"timeout_seconds":86401}'
check equal "${#TASK_IDS}" 0

tool_dispatch run_command '{"command":"zmodload zsh/zselect; print ready > started; while [[ ! -f release ]]; do zselect -t 1; done; print BG_OUTPUT; print BG_ERROR >&2; exit 7","background":true}'
check equal "$TOOL_RESULT_OK" 1
typeset -g first=${TASK_IDS[1]}
check wait_file "$test_base/started"
check equal "${TASK_STATE[$first]}" running
tasks_summary
check equal "$REPLY" '1 task running'
check equal "$calls" 0
AGENT_TURN_ACTIVE=1
TOOL_PROCESS_OUTPUT=foreground-output
TOOL_RESULT=foreground-result
print go > "$test_base/release"
check wait_task "$first"
check equal "$TOOL_PROCESS_OUTPUT" foreground-output
check equal "$TOOL_RESULT" foreground-result
tasks_summary
check equal "$REPLY" '1 awaiting follow-up'
tasks_deliver_one
check equal "$?" 1
check equal "$calls" 0
check contains "${TASK_RESULT[$first]}" 'Exit code: 7'
check contains "${TASK_RESULT[$first]}" BG_OUTPUT
check contains "${TASK_RESULT[$first]}" BG_ERROR
AGENT_TURN_ACTIVE=0
CURRENT_SESSION_ID=second
tasks_deliver_one
check equal "$calls" 0
CURRENT_SESSION_ID=first
tasks_deliver_one
check equal "$calls" 1
check contains "$received" BG_OUTPUT
tasks_deliver_one
check equal "$calls" 1
check equal "${#TASK_IDS}" 0

tool_dispatch run_command '{"command":"trap \"\" TERM; sleep 30 & print $! > timeout-child; wait","background":true,"timeout_seconds":1}'
typeset -g timed=${TASK_IDS[1]}
check wait_file "$test_base/timeout-child"
check wait_task "$timed"
check contains "${TASK_RESULT[$timed]}" 'Timed out'
check dead "${mapfile[$test_base/timeout-child]}"
task_forget "$timed"

tool_dispatch run_command '{"command":"kill -KILL $PPID","background":true}'
typeset -g crashed=${TASK_IDS[1]}
check wait_task "$crashed"
check contains "${TASK_RESULT[$crashed]}" 'without a complete result'
task_forget "$crashed"

ZCODER_MAX_TOOL_OUTPUT=120
tool_dispatch run_command '{"command":"print -rn HEAD; print -rn -- ${(pl:10000::x:)}; print -rn TAIL","background":true}'
typeset -g noisy=${TASK_IDS[1]}
check wait_task "$noisy"
check contains "${TASK_RESULT[$noisy]}" HEAD
check contains "${TASK_RESULT[$noisy]}" TAIL
check contains "${TASK_RESULT[$noisy]}" omitted
task_forget "$noisy"
ZCODER_MAX_TOOL_OUTPUT=32768

tool_dispatch run_command '{"command":"trap \"\" TERM; sleep 30 & print $! > cancel-child; wait","background":true}'
typeset -g cancelled=${TASK_IDS[1]}
check wait_file "$test_base/cancel-child"
tasks_command "/tasks cancel $cancelled"
check contains "${TASK_RESULT[$cancelled]}" 'Cancelled by user'
check dead "${mapfile[$test_base/cancel-child]}"
tasks_cleanup
tasks_cleanup
check equal "${#TASK_IDS}" 0

# Kill the actual owner with SIGKILL: EXIT traps cannot make this test pass.
zsh -df "$root/tests/fixtures/tasks_owner.zsh" "$root" "$test_base" &
typeset -g owner=$!
check wait_file "$test_base/owner-ready"
check wait_file "$test_base/orphan-child"
kill -KILL "$owner"
wait "$owner" 2>/dev/null
check dead "${mapfile[$test_base/orphan-child]}"
check dead "${mapfile[$test_base/worker-pid]}"

# Real curses/PTY and the real idle loop: chat and foreground command execution
# remain available, and completion is withheld for the entire foreground turn.
typeset -g tui_base=$test_base/tui tui_output='' tui_chunk=''
tui_wait() {
  local -F until=$(( EPOCHREALTIME + 8 ))
  while (( EPOCHREALTIME < until )); do
    while zpty -r tasks-ui tui_chunk 2>/dev/null; do tui_output+=$tui_chunk; done
    if [[ -s $1 ]]; then
      [[ -z ${2:-} || ${mapfile[$1]} == "$2" ]] && return 0
    fi
    zselect -t 1
  done
  print -ru2 -- "TUI output: ${(V)tui_output[-2000,-1]}"
  return 1
}
tui_start() { trap - EXIT INT TERM; exec zsh -df "$root/tests/fixtures/tasks_ui.zsh" "$root" "$tui_base"; }
TERM=xterm-256color zpty -b tasks-ui tui_start
zpty -w tasks-ui 'Start a background job'
check tui_wait "$tui_base.idle"
check tui_wait "$tui_base.started"
zpty -w tasks-ui 'Do the foreground work'
check tui_wait "$tui_base.foreground"
print go > "$tui_base.release-bg"
check tui_wait "$tui_base.pending"
check equal "${mapfile[$tui_base.pending]}" $'3:1\n'
check test ! -e "$tui_base.reviewed"
zpty -w -n tasks-ui 'draft preserved'
check tui_wait "$tui_base.draft" $'draft preserved\n'
print go > "$tui_base.release-fg"
check tui_wait "$tui_base.reviewed"
check contains "${mapfile[$tui_base.requests]}" $'4:user\n5:background'
check contains "${mapfile[$tui_base.payload]}" Background_result
check contains "${mapfile[$tui_base.draft]}" 'draft preserved'
zpty -w -n tasks-ui $'\x04'
check tui_wait "$tui_base.done"
zpty -d tasks-ui
print "Background task failures: $failures"
(( failures == 0 ))
