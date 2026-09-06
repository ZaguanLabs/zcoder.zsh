#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_monitor no_notify
zmodload zsh/curses zsh/terminfo zsh/datetime zsh/mapfile zsh/files zsh/system zsh/zselect
typeset -g fixture_root="$1" fixture_base="$2"
for fixture_lib in util json transcript tools input terminal process ui; do source "$fixture_root/lib/${fixture_lib}.zsh"; done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture ZCODER_PROFILE=coding REMOTE_MODE=local ZCODER_SYNC_OUTPUT=false
typeset -g ZCODER_WORKSPACE="${fixture_base}.workspace" fixture_phase=check
typeset -gi fixture_calls=0
zf_mkdir -p "$ZCODER_WORKSPACE"
mapfile[$ZCODER_WORKSPACE/note]=$'before\n'
typeset -g fixture_patch=$'--- a/note\n+++ b/note\n@@ -1 +1 @@\n-before\n+after\n'
functions[_fixture_process]="${functions[tool_process_run]}"
tool_process_run() {
  (( fixture_calls++ ))
  local process_cwd="$1" process_timeout="$2"
  shift 2
  if [[ "$fixture_phase" == check ]]; then
    _fixture_process "$process_cwd" "$process_timeout" zsh -fc 'zmodload zsh/mapfile zsh/zselect; mapfile[$1]=check; while true; do zselect -t 5; done' worker "${fixture_base}.started"
  elif [[ "$fixture_phase" == apply && " $* " != *' --check '* ]]; then
    # Apply a real patch, then delay completion publication so cancellation
    # exercises a mutation whose effects have already reached disk.
    _fixture_process "$process_cwd" "$process_timeout" zsh -fc 'zmodload zsh/mapfile zsh/zselect; marker=$1; shift; command "$@" || exit $?; mapfile[$marker]=apply; while true; do zselect -t 5; done' worker "${fixture_base}.started" "$@"
  else _fixture_process "$process_cwd" "$process_timeout" "$@"
  fi
}
functions[_fixture_input]="${functions[ui_activity_input]}"
ui_activity_input() { _fixture_input "$@"; local -i input_result=$?; mapfile[${fixture_base}.draft]="$INPUT_BUF"; return "$input_result"; }
command stty rows 24 cols 80 < /dev/tty
trap 'tool_process_cleanup; ui_end' EXIT
ui_init || exit 1
ui_set_status 'Tool: apply_patch'
tool_apply_patch "$fixture_patch"
mapfile[${fixture_base}.check_cancelled]="$?:${TOOL_CANCELLED}:${TOOL_PATCH_RETRY_REQUIRED}:${fixture_calls}:${mapfile[$ZCODER_WORKSPACE/note]}"
fixture_phase=apply; fixture_calls=0
tool_apply_patch "$fixture_patch"
mapfile[${fixture_base}.apply_cancelled]="$?:${TOOL_CANCELLED}:${TOOL_PATCH_RETRY_REQUIRED}:${fixture_calls}:$TOOL_RESULT"
mapfile[${fixture_base}.changed]="${mapfile[$ZCODER_WORKSPACE/note]}"
tool_write_file other 'must remain blocked'
mapfile[${fixture_base}.write_guard]="$TOOL_RESULT_OK"
fixture_phase=normal; fixture_calls=0
mapfile[$ZCODER_WORKSPACE/note]=$'before\n'
tool_apply_patch "$fixture_patch"
mapfile[${fixture_base}.success]="${TOOL_RESULT_OK}:${TOOL_PATCH_RETRY_REQUIRED}:${fixture_calls}:${mapfile[$ZCODER_WORKSPACE/note]}"
fixture_calls=0
tool_apply_patch $'*** note\n--- note\n***************\n*** 1 ****\n! after\n--- 1 ----\n! AFTER\n'
mapfile[${fixture_base}.fallback]="${TOOL_RESULT_OK}:${TOOL_PATCH_RETRY_REQUIRED}:${fixture_calls}:${mapfile[$ZCODER_WORKSPACE/note]}"
fixture_calls=0
mapfile[${fixture_base}.outside]=$'outside\n'
tool_apply_patch $'--- a/../patch-wait.outside\n+++ b/../patch-wait.outside\n@@ -1 +1 @@\n-outside\n+escaped\n'
mapfile[${fixture_base}.confined]="${TOOL_RESULT_OK}:${fixture_calls}:${mapfile[${fixture_base}.outside]}"
typeset -a scratch=("$ZCODER_RUNTIME_DIR"/patch.*(N))
mapfile[${fixture_base}.scratch]="${#scratch}"
ui_end
mapfile[${fixture_base}.done]=1
