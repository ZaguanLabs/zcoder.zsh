#!/usr/bin/env zsh

# Opt-in behavioral evaluation for local Ollama coding models. This is not
# part of `make test`: it performs real inference and may take several minutes.

setopt EXTENDED_GLOB NO_NOMATCH
zmodload zsh/datetime zsh/files zsh/mapfile zsh/zselect

0="${ZERO:-${${0:#$ZSH_ARGZERO}:-${(%):-%N}}}"
0="${${(M)0:#/*}:-$PWD/$0}"
typeset -gr EVAL_TEST_DIR="${0:A:h}"
typeset -gr EVAL_PROJECT_DIR="${EVAL_TEST_DIR:h}"
typeset -g EVAL_ROOT=""

cleanup_eval() {
  [[ -n "$EVAL_ROOT" && -d "$EVAL_ROOT" ]] && zf_rm -rf -- "$EVAL_ROOT" 2>/dev/null
}
trap cleanup_eval EXIT INT TERM

EVAL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zcoder-model-eval.XXXXXX")" || exit 1
typeset -g ZCODER_WORKSPACE="$EVAL_ROOT"
typeset -g ZCODER_COMMAND_POLICY=deny
typeset -g ZCODER_CONTEXT_WINDOW="${ZCODER_EVAL_CONTEXT_WINDOW:-65536}"
typeset -g ZCODER_THINK="${ZCODER_EVAL_THINK:-true}"

source "${EVAL_PROJECT_DIR}/lib/util.zsh"
source "${EVAL_PROJECT_DIR}/lib/json.zsh"
source "${EVAL_PROJECT_DIR}/lib/mcp.zsh"
source "${EVAL_PROJECT_DIR}/lib/http.zsh"
source "${EVAL_PROJECT_DIR}/lib/instructions.zsh"
source "${EVAL_PROJECT_DIR}/lib/skills.zsh"
source "${EVAL_PROJECT_DIR}/lib/tools.zsh"
source "${EVAL_PROJECT_DIR}/lib/compact.zsh"
source "${EVAL_PROJECT_DIR}/lib/agent.zsh"

typeset -g models_text="${ZCODER_EVAL_MODELS:-}"
typeset -gi eval_repeats="${ZCODER_EVAL_REPEATS:-3}"
typeset -g baseline_file="${ZCODER_EVAL_BASELINE_PROMPT_FILE:-}"
typeset -ga eval_models=() eval_variants=(current)

if [[ -z "$models_text" ]]; then
  print -u2 -r -- "Set ZCODER_EVAL_MODELS to a comma-separated list, for example:"
  print -u2 -r -- "  ZCODER_EVAL_MODELS='ornith-1.5:9b,laguna-xs-2.1' make model-eval"
  exit 2
fi
(( eval_repeats >= 1 && eval_repeats <= 20 )) || {
  print -u2 -r -- "ZCODER_EVAL_REPEATS must be between 1 and 20"
  exit 2
}
eval_models=("${(@s:,:)models_text}")
if [[ -n "$baseline_file" ]]; then
  baseline_file="${baseline_file:A}"
  [[ -f "$baseline_file" ]] || {
    print -u2 -r -- "Baseline prompt does not exist: $baseline_file"
    exit 2
  }
  eval_variants+=(baseline)
fi

eval_count_calls() {
  local message
  local -i calls=0
  for message in "${AGENT_MESSAGES[@]}"; do
    [[ "$message" == *'"tool_calls"'* ]] && (( calls++ ))
  done
  REPLY="$calls"
}

eval_history_contains() {
  local needle="$1"
  [[ "${(j:\n:)AGENT_MESSAGES}" == *"$needle"* ]]
}

eval_prepare_fixture() {
  local scenario="$1" run_dir="$2"
  zf_mkdir -p "$run_dir/src" || return 1
  mapfile[$run_dir/alpha.txt]=$'alpha exact value\n'
  mapfile[$run_dir/beta.txt]=$'beta exact value\n'
  mapfile[$run_dir/fallback.txt]=$'fallback recovered value\n'
  mapfile[$run_dir/src/app.zsh]=$'#!/usr/bin/env zsh\n# target_marker: bounded evidence\nprint -r -- ready\n'
  mapfile[$run_dir/note.txt]=$'status: old\n'
  case "$scenario" in
    independent_reads)
      REPLY="Read alpha.txt and beta.txt. They are independent; use one read-only batch if supported. Report both exact values."
      ;;
    dependent_search)
      REPLY="Find target_marker with search, then use read_file_range to read only its relevant source range. Report the matching line."
      ;;
    edit_verify)
      REPLY="Change note.txt from 'status: old' to 'status: new' with apply_patch, then verify it by reading the file back. Do not run a shell command."
      ;;
    failure_replan)
      REPLY="First try to read missing.txt. After that expected failure, inspect the workspace, find fallback.txt, and report its exact value without repeating the failed call."
      ;;
    conversational)
      REPLY="Reply with exactly: evaluation ready"
      ;;
  esac
}

eval_scenario_passed() {
  local scenario="$1" run_dir="$2"
  case "$scenario" in
    independent_reads)
      eval_history_contains '"path":"alpha.txt"' &&
        eval_history_contains '"path":"beta.txt"' &&
        [[ "$AGENT_LAST_RESPONSE" == *"alpha exact value"* && "$AGENT_LAST_RESPONSE" == *"beta exact value"* ]]
      ;;
    dependent_search)
      eval_history_contains '"name":"search"' &&
        eval_history_contains '"name":"read_file_range"' &&
        [[ "$AGENT_LAST_RESPONSE" == *"target_marker"* ]]
      ;;
    edit_verify)
      eval_history_contains '"name":"apply_patch"' &&
        eval_history_contains '"name":"read_file"' &&
        [[ "${mapfile[$run_dir/note.txt]}" == *"status: new"* ]]
      ;;
    failure_replan)
      eval_history_contains '"path":"missing.txt"' &&
        eval_history_contains '"path":"fallback.txt"' &&
        [[ "$AGENT_LAST_RESPONSE" == *"fallback recovered value"* ]]
      ;;
    conversational)
      [[ "$AGENT_LAST_RESPONSE" == "evaluation ready" ]]
      ;;
  esac
}

typeset -ga scenarios=(independent_reads dependent_search edit_verify failure_replan conversational)
typeset -g model variant scenario run_dir request transcript baseline_prompt="" result="" tab=$'\t'
typeset -gi repeat status passed calls unsafe_batches loops

print -r -- $'model\tvariant\tscenario\trepeat\tpass\tstatus\ttool_turns\tunsafe_batches\tloop_stopped\tprompt_tokens\toutput_tokens'
for model in "${eval_models[@]}"; do
  for variant in "${eval_variants[@]}"; do
    for scenario in "${scenarios[@]}"; do
      for (( repeat=1; repeat<=eval_repeats; repeat++ )); do
        run_dir="$EVAL_ROOT/${model//[^A-Za-z0-9_.-]/_}/${variant}/${scenario}/${repeat}"
        eval_prepare_fixture "$scenario" "$run_dir" || exit 1
        request="$REPLY"
        ZCODER_WORKSPACE="$run_dir"
        ZCODER_MODEL="$model"
        AGENT_SYSTEM_PROMPT=""
        if [[ "$variant" == baseline ]]; then
          baseline_prompt="${mapfile[$baseline_file]}"
          AGENT_SYSTEM_PROMPT="${baseline_prompt//\{\{WORKSPACE\}\}/$run_dir}"
        fi
        instructions_load "$run_dir" >/dev/null
        skills_load "$run_dir" >/dev/null
        agent_reset
        zf_mkdir -p "$EVAL_ROOT/.logs"
        transcript="$EVAL_ROOT/.logs/${model//[^A-Za-z0-9_.-]/_}-${variant}-${scenario}-${repeat}.txt"
        agent_user_turn "$request" >"$transcript" 2>&1
        status=$?
        eval_count_calls
        calls=$REPLY
        unsafe_batches=0
        eval_history_contains "Unsafe tool batch" && unsafe_batches=1
        loops=0
        [[ -n "$AGENT_LOOP_REASON" && $status -ne 0 ]] && loops=1
        passed=0
        (( status == 0 )) && eval_scenario_passed "$scenario" "$run_dir" && passed=1
        print -r -- "${model}${tab}${variant}${tab}${scenario}${tab}${repeat}${tab}${passed}${tab}${status}${tab}${calls}${tab}${unsafe_batches}${tab}${loops}${tab}${AGENT_LAST_PROMPT_TOKENS}${tab}${AGENT_LAST_OUTPUT_TOKENS}"
      done
    done
  done
done
