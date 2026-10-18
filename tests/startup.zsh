#!/usr/bin/env zsh
# Also an opt-in first-frame / first-input benchmark, without model requests.
emulate -R zsh
setopt extendedglob
zmodload zsh/zpty zsh/zselect zsh/datetime zsh/mapfile zsh/files || exit 1
typeset -g startup_root=${0:A:h:h} startup_base startup_chunk startup_output=''
typeset -g startup_tmp=$(mktemp -d "${TMPDIR:-/tmp}/zcoder-startup.XXXXXXXX")
[[ -d $startup_tmp ]] || exit 1
trap 'zpty -d startup-ui 2>/dev/null; zf_rm -rf -- "$startup_tmp"' EXIT
typeset -gi startup_benchmark=0 startup_samples=1 startup_iteration
if [[ ${1:-} == --benchmark ]]; then
  startup_benchmark=1
  startup_samples=${2:-7}
  (( startup_samples >= 3 && startup_samples % 2 )) || {
    print -ru2 -- 'Use an odd sample count of at least three.'; exit 2
  }
  print -r -- "Zsh $ZSH_VERSION; $MACHTYPE; locale=${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}"
  print -r -- "One warmup, $startup_samples samples; fixture-shell startup excludes model work and runtime selection."
fi
startup_fail() {
  print -ru2 -- "FAIL: $*" "${(V)startup_output[-1500,-1]}"
  exit 1
}
startup_wait() {
  local suffix=$1 expected=${2:-} actual=''
  local -F deadline=$(( EPOCHREALTIME + 8.0 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r startup-ui startup_chunk 2>/dev/null; do
      [[ -n $startup_chunk ]] || break
      startup_output+=$startup_chunk
    done
    if [[ -f $startup_base.$suffix ]]; then
      actual=${${mapfile[$startup_base.$suffix]}%$'\n'}
      [[ -z $expected || $actual == "$expected" ]] && return 0
    fi
    zselect -t 1
  done
  startup_fail "waiting for $suffix=$expected (got $actual)"
}
startup_run() {
  trap - EXIT INT TERM
  export TERM=xterm-256color
  exec zsh -df "$startup_root/tests/fixtures/tui_startup.zsh" "$startup_root" "$startup_base" "$startup_backend"
}
typeset startup_backend startup_action
typeset -F startup_deadline
typeset -a startup_frames startup_inputs
typeset -i startup_frame_us startup_input_us
for startup_backend in stock auto; do
  startup_frames=(); startup_inputs=()
  # Benchmark discards one warmup per backend; correctness uses a disk barrier.
  for (( startup_iteration=0; startup_iteration<=startup_samples; startup_iteration++ )); do
    (( ! startup_benchmark && startup_iteration == 0 )) && continue
    startup_base="$startup_tmp/$startup_backend-$startup_iteration"
    startup_output=''
    zf_mkdir -p "$startup_base.workspace/.agents/skills/startup" "$startup_base.home"
    print -r -- STARTUP_INSTRUCTION > "$startup_base.workspace/AGENTS.md"
    print -r -- $'---\nname: startup\ndescription: Startup skill.\n---\nSkill body.' > "$startup_base.workspace/.agents/skills/startup/SKILL.md"
    print -r -- '{"mcpServers":{"startup":{"command":"startup-command"}}}' > "$startup_base.home/mcp.json"
    (( startup_benchmark )) || print -r -- 1 > "$startup_base.block"
    zpty -b startup-ui startup_run || startup_fail 'starting PTY'
    startup_wait frame
    if (( ! startup_benchmark )); then
      startup_wait preparing
      # Queue text before instructions, skills, MCP and sessions are ready.
      zpty -w -n startup-ui 'queued startup text'
      print -r -- 1 > "$startup_base.release"
    fi
    startup_wait idle
    startup_frame_us=${mapfile[$startup_base.frame]}
    startup_input_us=${mapfile[$startup_base.idle]}
    if (( startup_iteration > 0 )); then
      startup_frames+=("$startup_frame_us"); startup_inputs+=("$startup_input_us")
    fi
    if (( ! startup_benchmark )); then
      startup_wait draft 'queued startup text'
      zpty -w -n startup-ui $'\r'
      startup_wait turn 'queued startup text'
      # First use and repeat use exercise both deferred component families.
      for startup_action in document picker document picker; do
        zf_rm -f -- "$startup_base.modal" "$startup_base.helpers"
        zpty -w -n startup-ui "$startup_action"$'\r'
        startup_wait modal Startup
        zpty -w -n startup-ui q
        startup_wait helpers
      done
      [[ ${${mapfile[$startup_base.helpers]}%$'\n'} == 1:1 ]] || startup_fail 'helpers must load exactly once'
    fi
    zpty -w -n startup-ui $'/quit\r'
    # Drain until the shell has exited, so cleanup errors cannot pass silently.
    startup_deadline=$(( EPOCHREALTIME + 8.0 ))
    while zpty -t startup-ui && (( EPOCHREALTIME < startup_deadline )); do
      while zpty -r startup-ui startup_chunk 2>/dev/null; do
        [[ -n $startup_chunk ]] || break
        startup_output+=$startup_chunk
      done
      zselect -t 1
    done
    zpty -t startup-ui && startup_fail 'quitting the TUI'
    [[ ${${mapfile[$startup_base.exit]:-}%$'\n'} == 0 ]] || startup_fail 'application exit status'
    kill -0 "${${mapfile[$startup_base.listener]}%$'\n'}" 2>/dev/null && startup_fail 'relay listener survived application exit'
    [[ $startup_output != *'not found'* && $startup_output != *'Error:'* ]] || startup_fail 'startup or cleanup error'
    zpty -d startup-ui
  done
  if (( startup_benchmark )); then
    # Sort integer microseconds: Zsh's numeric sort compares digit runs, not
    # floating-point fractions. Convert only when displaying milliseconds.
    startup_frames=("${(@on)startup_frames}"); startup_inputs=("${(@on)startup_inputs}")
    printf '%s first frame ms median/min/max: %.3f / %.3f / %.3f\n' "$startup_backend" \
      "$(( startup_frames[(startup_samples+1)/2] / 1000.0 ))" "$(( startup_frames[1] / 1000.0 ))" "$(( startup_frames[-1] / 1000.0 ))"
    printf '%s first input ms median/min/max: %.3f / %.3f / %.3f\n' "$startup_backend" \
      "$(( startup_inputs[(startup_samples+1)/2] / 1000.0 ))" "$(( startup_inputs[1] / 1000.0 ))" "$(( startup_inputs[-1] / 1000.0 ))"
  else
    print -r -- "PASS: $startup_backend paints before preparation, preserves queued input, enforces approval and loads dialog helpers once"
  fi
done
