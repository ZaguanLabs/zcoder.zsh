#!/usr/bin/env zsh
emulate -R zsh
setopt no_monitor no_notify
zmodload zsh/datetime zsh/system zsh/files zsh/mapfile zsh/stat zsh/zselect
typeset -g root=$1 test_base=$2
for lib in util json command_safety tools process tasks; do source "$root/lib/$lib.zsh"; done
typeset -g ZCODER_WORKSPACE=$test_base CURRENT_SESSION_ID=crash REMOTE_MODE=local ZCODER_PROFILE=coding ZCODER_COMMAND_POLICY=allow
typeset -gi UI_ACTIVE=1
# Keep crash-test scratch inside the harness's owned directory.
ZCODER_RUNTIME_DIR=$test_base
tool_run_command 'trap "" TERM; sleep 30 & print $! > orphan-child; wait' . '' true || exit 1
print -r -- "${TASK_PID[${TASK_IDS[1]}]}" > "$test_base/worker-pid"
print ready > "$test_base/owner-ready"
while true; do zselect -t 10; done
