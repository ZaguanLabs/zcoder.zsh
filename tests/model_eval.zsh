#!/usr/bin/env zsh

# Opt-in behavioral evaluation for local Ollama coding models. This is not
# part of `make test`: it performs real inference and may take several minutes.

setopt EXTENDED_GLOB NO_NOMATCH
zmodload zsh/datetime zsh/files zsh/mapfile zsh/net/tcp zsh/system zsh/zselect

0="${ZERO:-${${0:#$ZSH_ARGZERO}:-${(%):-%N}}}"
0="${${(M)0:#/*}:-$PWD/$0}"
typeset -gr EVAL_TEST_DIR="${0:A:h}"
typeset -gr EVAL_PROJECT_DIR="${EVAL_TEST_DIR:h}"
typeset -g EVAL_ROOT=""
typeset -g EVAL_LOG_DIR=""

cleanup_eval() {
  [[ -n "$EVAL_ROOT" && -d "$EVAL_ROOT" ]] && zf_rm -rf -- "$EVAL_ROOT" 2>/dev/null
}
trap cleanup_eval EXIT INT TERM

EVAL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zcoder-model-eval.XXXXXX")" || exit 1
if [[ -n "${ZCODER_EVAL_OUTPUT_DIR:-}" ]]; then
  EVAL_LOG_DIR="${ZCODER_EVAL_OUTPUT_DIR:A}"
else
  EVAL_LOG_DIR="$EVAL_ROOT/.logs"
fi
zf_mkdir -p "$EVAL_LOG_DIR" || {
  print -u2 -r -- "Could not create evaluation output directory: $EVAL_LOG_DIR"
  exit 1
}
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
typeset -g scenarios_text="${ZCODER_EVAL_SCENARIOS:-}"
typeset -gi eval_repeats="${ZCODER_EVAL_REPEATS:-3}"
typeset -g baseline_file="${ZCODER_EVAL_BASELINE_PROMPT_FILE:-}"
typeset -ga eval_models=() eval_variants=(current)
typeset -ga all_scenarios=(independent_reads dependent_search edit_verify failure_replan project_instructions conversational)
typeset -ga scenarios=()

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
if [[ -n "$scenarios_text" ]]; then
  scenarios=("${(@s:,:)scenarios_text}")
else
  scenarios=("${all_scenarios[@]}")
fi
for scenario in "${scenarios[@]}"; do
  if (( ${all_scenarios[(Ie)$scenario]} == 0 )); then
    print -u2 -r -- "Unknown evaluation scenario: $scenario"
    print -u2 -r -- "Available scenarios: ${(j:, :)all_scenarios}"
    exit 2
  fi
done
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

eval_history_contains_path() {
  local path="$1" message
  for message in "${AGENT_MESSAGES[@]}"; do
    [[ "$message" == '{"role":"assistant",'* && "$message" == *'"tool_calls"'* ]] || continue
    [[ "$message" == *'"path":"'"$path"'"'* || "$message" == *'/'"$path"'"'* ]] && return 0
  done
  return 1
}

eval_history_verifies_after_edit() {
  local expected_path="$1" message="" name=""
  local -i i saw_edit=0
  for message in "${AGENT_MESSAGES[@]}"; do
    [[ "$message" == '{"role":"assistant",'* && "$message" == *'"tool_calls"'* ]] || continue
    json_parse_ollama_response "{\"message\":${message}}" || return 1
    for (( i=1; i<=${#JSON_TOOL_NAMES}; i++ )); do
      name="${JSON_TOOL_NAMES[i]}"
      json_parse_flat_object "${JSON_TOOL_ARGS[i]}" || return 1
      case "$name" in
        apply_patch)
          saw_edit=1
          ;;
        replace_text|write_file)
          [[ "${JSON_OBJECT[path]:-}" == "$expected_path" ]] && saw_edit=1
          ;;
        read_file)
          (( saw_edit )) && [[ "${JSON_OBJECT[path]:-}" == "$expected_path" ]] && return 0
          ;;
      esac
    done
  done
  return 1
}

eval_first_tool_call_is() {
  local expected_name="$1" expected_path="$2" message=""
  for message in "${AGENT_MESSAGES[@]}"; do
    [[ "$message" == '{"role":"assistant",'* && "$message" == *'"tool_calls"'* ]] || continue
    json_parse_ollama_response "{\"message\":${message}}" || return 1
    (( ${#JSON_TOOL_NAMES} > 0 )) || continue
    [[ "${JSON_TOOL_NAMES[1]}" == "$expected_name" ]] || return 1
    json_parse_flat_object "${JSON_TOOL_ARGS[1]}" || return 1
    [[ "${JSON_OBJECT[path]:-}" == "$expected_path" ]]
    return $?
  done
  return 1
}

eval_write_history() {
  local path="$1" message
  : >| "$path" || return 1
  for message in "${AGENT_MESSAGES[@]}"; do
    print -r -- "$message" >> "$path" || return 1
  done
}

eval_prepare_fixture() {
  local scenario="$1" run_dir="$2"
  zf_mkdir -p "$run_dir/src" || return 1
  mapfile[$run_dir/alpha.txt]=$'juniper-417\n'
  mapfile[$run_dir/beta.txt]=$'cobalt-862\n'
  mapfile[$run_dir/fallback.txt]=$'ember-593\n'
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
      REPLY="Change note.txt from 'status: old' to 'status: new' with the smallest focused edit tool, then verify it by reading the file back. Do not run a shell command."
      ;;
    failure_replan)
      REPLY="First try to read missing.txt. After that expected failure, inspect the workspace, find fallback.txt, and report its exact value without repeating the failed call."
      ;;
    project_instructions)
      mapfile[$run_dir/guidance.txt]=$'project guidance sentinel\n'
      mapfile[$run_dir/AGENTS.md]=$'# Evaluation project rules\n\nFor every request in this workspace:\n\n- Before any other file operation, read `guidance.txt` with `read_file`.\n- Do not call `search`, `list_files`, or `run_command`.\n- After modifying a file, verify it with `read_file`.\n- End the final response with exactly `GUIDANCE-CHECKED`.\n'
      REPLY="Change note.txt from 'status: old' to 'status: new' with the smallest focused edit, then report completion."
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
      eval_history_contains_path alpha.txt &&
        eval_history_contains_path beta.txt &&
        [[ "$AGENT_LAST_RESPONSE" == *"juniper-417"* && "$AGENT_LAST_RESPONSE" == *"cobalt-862"* ]]
      ;;
    dependent_search)
      eval_history_contains '"name":"search"' &&
        eval_history_contains '"name":"read_file_range"' &&
        [[ "$AGENT_LAST_RESPONSE" == *"target_marker"* ]]
      ;;
    edit_verify)
      (eval_history_contains '"name":"replace_text"' || eval_history_contains '"name":"apply_patch"') &&
        eval_history_contains '"name":"read_file"' &&
        [[ "${mapfile[$run_dir/note.txt]}" == *"status: new"* ]]
      ;;
    failure_replan)
      eval_history_contains_path missing.txt &&
        eval_history_contains_path fallback.txt &&
        [[ "$AGENT_LAST_RESPONSE" == *"ember-593"* ]]
      ;;
    project_instructions)
      eval_first_tool_call_is read_file guidance.txt &&
        ! eval_history_contains '"name":"search"' &&
        ! eval_history_contains '"name":"list_files"' &&
        ! eval_history_contains '"name":"run_command"' &&
        eval_history_verifies_after_edit note.txt &&
        [[ "${mapfile[$run_dir/note.txt]}" == *"status: new"* ]] &&
        [[ "$AGENT_LAST_RESPONSE" == *"GUIDANCE-CHECKED" ]]
      ;;
    conversational)
      [[ "$AGENT_LAST_RESPONSE" == "evaluation ready" ]]
      ;;
  esac
}

typeset -g model variant scenario run_dir request transcript history_path baseline_prompt="" result="" tab=$'\t'
typeset -F eval_started eval_elapsed
typeset -gi repeat run_status passed calls transport_retries loops duration_ms

print -r -- $'model\tvariant\tscenario\trepeat\tpass\tstatus\ttool_turns\ttransport_retry\tloop_stopped\tprompt_tokens\toutput_tokens\tduration_ms\ttranscript\thistory'
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
        transcript="$EVAL_LOG_DIR/${model//[^A-Za-z0-9_.-]/_}-${variant}-${scenario}-${repeat}.txt"
        history_path="${transcript%.txt}.history.jsonl"
        eval_started=$EPOCHREALTIME
        agent_user_turn "$request" >"$transcript" 2>&1
        run_status=$?
        eval_elapsed=$(( EPOCHREALTIME - eval_started ))
        duration_ms=$(( eval_elapsed * 1000 ))
        eval_write_history "$history_path" || {
          print -u2 -r -- "Could not write evaluation history: $history_path"
          exit 1
        }
        eval_count_calls
        calls=$REPLY
        transport_retries=0
        eval_history_contains "Ollama connection failed before a response" && transport_retries=1
        loops=0
        [[ -n "$AGENT_LOOP_REASON" && $run_status -ne 0 ]] && loops=1
        passed=0
        (( run_status == 0 )) && eval_scenario_passed "$scenario" "$run_dir" && passed=1
        print -r -- "${model}${tab}${variant}${tab}${scenario}${tab}${repeat}${tab}${passed}${tab}${run_status}${tab}${calls}${tab}${transport_retries}${tab}${loops}${tab}${AGENT_LAST_PROMPT_TOKENS}${tab}${AGENT_LAST_OUTPUT_TOKENS}${tab}${duration_ms}${tab}${transcript}${tab}${history_path}"
      done
    done
  done
done
