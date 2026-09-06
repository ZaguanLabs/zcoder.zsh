# UI-owned external processes. Approvals, tool state, and dispatch stay in the
# parent. A zpty worker supplies a private session/process group without setsid
# or a dependency on an external timeout program. Its PTY carries only control.
typeset -g TOOL_PROCESS_NAME='' TOOL_PROCESS_BASE='' TOOL_PROCESS_PID=''
typeset -g TOOL_PROCESS_OUTPUT='' TOOL_PROCESS_ERROR=''
typeset -gi TOOL_PROCESS_STARTED=0 TOOL_PROCESS_CANCELLED=0 TOOL_PROCESS_TIMED_OUT=0
typeset -gi TOOL_PROCESS_OUTPUT_TRUNCATED=0
typeset -gF TOOL_PROCESS_DEADLINE=0.0

_tool_process_worker() {
  emulate -L zsh
  setopt no_monitor no_notify
  trap - EXIT INT TERM HUP WINCH
  # Keep the session leader alive until the parent releases it, even if the
  # command exits first. Caught signals reset normally in the executed program.
  trap ':' TERM HUP INT
  local worker_control='' worker_result=125
  UI_ACTIVE=0
  zcoder_write_text_file "${TOOL_PROCESS_BASE}.pid" "$sysparams[pid]" || return 1
  zcoder_write_text_file "${TOOL_PROCESS_BASE}.ready" ready || return 1
  read -r worker_control || return 1
  [[ "$worker_control" == start ]] || return 1
  {
    if builtin cd -- "$process_cwd"; then
      command "${process_argv[@]}" </dev/null >| "${TOOL_PROCESS_BASE}.out" 2>&1
      worker_result=$?
    else
      print -r -- 'Could not enter the approved working directory.' >| "${TOOL_PROCESS_BASE}.out"
    fi
    zcoder_write_text_file "${TOOL_PROCESS_BASE}.status" "$worker_result" &&
      zcoder_write_text_file "${TOOL_PROCESS_BASE}.done" done || return 1
    # The parent owns teardown, including any descendants still in this group.
    while true; do read -r worker_control || continue; done
  } >/dev/null 2>&1
}

tool_process_ready() {
  local worker_pid=''
  [[ -n "$TOOL_PROCESS_NAME" ]] || return 0
  (( ! TOOL_PROCESS_STARTED && EPOCHREALTIME >= TOOL_PROCESS_DEADLINE )) && return 1
  if (( ! TOOL_PROCESS_STARTED )) && [[ -f "${TOOL_PROCESS_BASE}.ready" ]]; then
    worker_pid="${mapfile[${TOOL_PROCESS_BASE}.pid]}"
    if [[ "$worker_pid" != <1-> || ${#worker_pid} -gt 12 || "$worker_pid" == "$sysparams[pid]" ]]; then
      TOOL_PROCESS_ERROR='Invalid worker handshake.'; return 0
    fi
    # This file is produced before the command is allowed to run. Cache the ID
    # once; never accept a replacement PID from files the command could modify.
    TOOL_PROCESS_PID="$worker_pid"
    zpty -w "$TOOL_PROCESS_NAME" start || { TOOL_PROCESS_ERROR='Worker startup failed.'; return 0; }
    TOOL_PROCESS_STARTED=1
  fi
  [[ -f "${TOOL_PROCESS_BASE}.done" ]] && return 0
  zpty -t "$TOOL_PROCESS_NAME" 2>/dev/null && return 1
  TOOL_PROCESS_ERROR='Command worker exited without a complete result.'
  return 0
}

tool_process_expired() { (( EPOCHREALTIME >= TOOL_PROCESS_DEADLINE )); }

tool_process_cleanup() {
  emulate -L zsh
  local name="$TOOL_PROCESS_NAME" base="$TOOL_PROCESS_BASE" worker_pid="$TOOL_PROCESS_PID"
  TOOL_PROCESS_NAME=''; TOOL_PROCESS_BASE=''; TOOL_PROCESS_PID=''; TOOL_PROCESS_STARTED=0
  # The worker's session leader remains alive through result collection, so the
  # group ID cannot be recycled between collecting and releasing this request.
  [[ -n "$worker_pid" ]] && kill -KILL -- "-${worker_pid}" 2>/dev/null
  [[ -n "$name" ]] && zpty -d "$name" 2>/dev/null
  [[ -n "$base" ]] && zf_rm -f -- "${base}.pid" "${base}.ready" "${base}.out" "${base}.status" "${base}.done" 2>/dev/null
  return 0
}

# Read bounded head/tail byte windows, then apply the existing character limit.
# Output remains in a file while the process runs, so a noisy command cannot
# starve input by keeping a pipe permanently readable.
_tool_process_output() {
  emulate -L zsh
  local output_fd='' head='' tail='' chunk=''
  local -A output_stat=()
  local -i budget=$(( ZCODER_MAX_TOOL_OUTPUT * 4 )) remaining=0 received=0
  (( budget < 256 )) && budget=256
  (( budget > 1048576 )) && budget=1048576
  [[ -f "${TOOL_PROCESS_BASE}.out" ]] || return 0
  sysopen -r -o cloexec,nofollow -u output_fd "${TOOL_PROCESS_BASE}.out" || return 1
  {
    zstat -H output_stat -f "$output_fd" || return 1
    remaining=$budget
    while (( remaining > 0 )); do
      chunk=''; received=0
      sysread -i "$output_fd" -s "$remaining" -c received chunk 2>/dev/null
      (( received > 0 )) || break
      head+="$chunk"; (( remaining -= received ))
    done
    if (( output_stat[size] > 2 * budget )); then
      # Keep both sides even for output much larger than the display budget.
      sysseek -u "$output_fd" -w end -- "-$budget" || return 1
      remaining=$budget
      while (( remaining > 0 )); do
        chunk=''; received=0
        sysread -i "$output_fd" -s "$remaining" -c received chunk 2>/dev/null
        (( received > 0 )) || break
        tail+="$chunk"; (( remaining -= received ))
      done
      head+=$'\n[... output omitted ...]\n'"$tail"
    elif (( output_stat[size] > budget )); then
      remaining=$(( output_stat[size] - budget ))
      while (( remaining > 0 )); do
        chunk=''; received=0
        sysread -i "$output_fd" -s "$remaining" -c received chunk 2>/dev/null
        (( received > 0 )) || break
        head+="$chunk"; (( remaining -= received ))
      done
    fi
    zcoder_truncate_head_tail "$head" "$ZCODER_MAX_TOOL_OUTPUT"
    TOOL_PROCESS_OUTPUT="$REPLY"
    (( output_stat[size] > 2 * budget || ${#head} > ZCODER_MAX_TOOL_OUTPUT )) && TOOL_PROCESS_OUTPUT_TRUNCATED=1
    if (( output_stat[size] > 2 * budget )); then
      TOOL_PROCESS_OUTPUT="${TOOL_PROCESS_OUTPUT//\[... <-> characters omitted ...\]/[... output omitted ...]}"
    fi
  } always { exec {output_fd}<&-; }
}

# Arguments are trusted executable argv already prepared by a tool. Only
# run_command deliberately passes approved shell source to zsh -c.
tool_process_run() {
  emulate -L zsh
  local process_cwd="$1" process_timeout="$2"
  shift 2
  local -a process_argv=("$@")
  local -i wait_result=0 command_result=1
  local result_text=''
  [[ -z "$TOOL_PROCESS_NAME" ]] || { TOOL_PROCESS_ERROR='Another tool process is active.'; return 1; }
  TOOL_PROCESS_OUTPUT=''; TOOL_PROCESS_ERROR=''; TOOL_PROCESS_CANCELLED=0; TOOL_PROCESS_TIMED_OUT=0; TOOL_PROCESS_OUTPUT_TRUNCATED=0
  [[ "$process_timeout" == <1-3600> && ${#process_argv} -gt 0 ]] || return 1
  zmodload zsh/zpty zsh/system zsh/stat || { TOOL_PROCESS_ERROR='Required native process modules are unavailable.'; return 1; }
  zcoder_temp_path process || { TOOL_PROCESS_ERROR='Could not create private process storage.'; return 1; }
  TOOL_PROCESS_BASE="$REPLY"
  TOOL_PROCESS_NAME="zcoder-process-${ZCODER_RUNTIME_SEQUENCE}"
  TOOL_PROCESS_DEADLINE=$(( EPOCHREALTIME + process_timeout ))
  {
    # The command text is never interpolated into zpty's evaluated command.
    zpty -b "$TOOL_PROCESS_NAME" _tool_process_worker || { TOOL_PROCESS_ERROR='Could not start command worker.'; return 1; }
    ui_wait_for_tool_process
    wait_result=$?
    if (( wait_result == 130 || wait_result == 124 )); then
      (( wait_result == 130 )) && TOOL_PROCESS_CANCELLED=1 || TOOL_PROCESS_TIMED_OUT=1
      [[ -n "$TOOL_PROCESS_PID" ]] && kill -TERM -- "-${TOOL_PROCESS_PID}" 2>/dev/null
      # Give normal commands a brief chance to stop, while continuing to admit
      # UI input. Final cleanup kills the owned group even if TERM is ignored.
      local -F stop_deadline=$(( EPOCHREALTIME + 0.2 ))
      while (( EPOCHREALTIME < stop_deadline )); do ui_poll_activity 20 || true; done
      _tool_process_output || true
      return "$wait_result"
    fi
    (( wait_result == 0 )) || { TOOL_PROCESS_ERROR='Tool input wait failed.'; return 1; }
    [[ -z "$TOOL_PROCESS_ERROR" && -f "${TOOL_PROCESS_BASE}.done" ]] || return 1
    result_text="${mapfile[${TOOL_PROCESS_BASE}.status]}"
    [[ "$result_text" == <0-255> ]] || { TOOL_PROCESS_ERROR='Invalid command completion status.'; return 1; }
    command_result=$result_text
    _tool_process_output || { TOOL_PROCESS_ERROR='Could not read command output.'; return 1; }
    return "$command_result"
  } always { tool_process_cleanup; }
}
