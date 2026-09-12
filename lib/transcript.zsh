# Session transcript shared by the terminal UI and headless transports.
# Keep the existing UI_* names for the persistence and rendering interfaces.

typeset -ga UI_ROLES=() UI_CONTENTS=() UI_THINKINGS=() UI_TIMES=() UI_REASONING_OPEN=()
typeset -ga UI_IDS=() UI_BLOCK_OPEN=() UI_TOOL_NAMES=() UI_TOOL_SUMMARIES=() UI_TOOL_ARGS=() UI_TOOL_RESULTS=() UI_TOOL_STATES=()
typeset -gi UI_SELECTED_EVENT=0 UI_CURRENT_TOOL=0 UI_TRANSCRIPT_GENERATION=0
typeset -gi UI_RENDER_DIRTY_FROM=0 UI_PERSIST_DIRTY_FROM=0
typeset -gi UI_STREAM_INDEX=0

transcript_reset() {
  emulate -L zsh
  UI_ROLES=(); UI_CONTENTS=(); UI_THINKINGS=(); UI_TIMES=(); UI_REASONING_OPEN=()
  UI_IDS=(); UI_BLOCK_OPEN=(); UI_TOOL_NAMES=(); UI_TOOL_SUMMARIES=(); UI_TOOL_ARGS=(); UI_TOOL_RESULTS=(); UI_TOOL_STATES=()
  UI_SELECTED_EVENT=0; UI_CURRENT_TOOL=0
  UI_STREAM_INDEX=0
  UI_RENDER_DIRTY_FROM=0; UI_PERSIST_DIRTY_FROM=0
  (( UI_TRANSCRIPT_GENERATION++ ))
  UI_SCROLL=0; UI_AUTO_SCROLL=1
  return 0
}

# Mutating a block invalidates only that block and the layout following it.
# Persistence has a separate cursor: rendering must not consume pending saves.
transcript_changed() {
  emulate -L zsh
  local -i index=$1
  (( index > 0 && index <= ${#UI_ROLES} )) || return 1
  (( ! UI_RENDER_DIRTY_FROM || index < UI_RENDER_DIRTY_FROM )) && UI_RENDER_DIRTY_FROM=$index
  (( ! UI_PERSIST_DIRTY_FROM || index < UI_PERSIST_DIRTY_FROM )) && UI_PERSIST_DIRTY_FROM=$index
  return 0
}

transcript_default_metadata() {
  emulate -L zsh
  local -i index=$1
  UI_IDS[index]="event_${index}"
  UI_BLOCK_OPEN[index]=1
  UI_TOOL_NAMES[index]=""; UI_TOOL_ARGS[index]=""; UI_TOOL_RESULTS[index]=""; UI_TOOL_STATES[index]=""
  UI_TOOL_SUMMARIES[index]=""
}

ui_append_message() {
  emulate -L zsh
  UI_ROLES+=("$1")
  UI_CONTENTS+=("$2")
  UI_THINKINGS+=("${3:-}")
  zcoder_time; UI_TIMES+=("$REPLY")
  UI_REASONING_OPEN+=(0)
  transcript_default_metadata ${#UI_ROLES}
  if [[ "$1" == error ]] && (( ${UI_ACTIVE:-0} && $+functions[ui_status_notice] )); then
    ui_status_notice error "$2"
  fi
  # Reading older blocks must not be interrupted by incoming activity.
  [[ "$1" == user && "${UI_FOCUS:-input}" != chat ]] && UI_AUTO_SCROLL=1
  return 0
}

transcript_tool_label() {
  emulate -L zsh
  local name="$1" server='' tool='' target=''
  case "$name" in
    read_file) REPLY=Read ;;
    read_file_range) REPLY='Read File Range' ;;
    write_file) REPLY='Write File' ;;
    replace_text) REPLY='Replace Text' ;;
    list_files) REPLY='List Files' ;;
    search) REPLY=Search ;;
    run_command) REPLY='Run Command' ;;
    apply_patch) REPLY='Apply Patch' ;;
    activate_skill) REPLY=Skill ;;
    read_skill_resource) REPLY='Skill Resource' ;;
    finish) REPLY=Finish ;;
    mcp__*)
      (( ${+MCP_TOOL_SERVER} )) && server="${MCP_TOOL_SERVER[$name]:-}"
      (( ${+MCP_TOOL_ORIGINAL} )) && tool="${MCP_TOOL_ORIGINAL[$name]:-}"
      if [[ -n "$server" ]]; then
        target="${server}${tool:+.${tool}}"
      else
        target="${name#mcp__}"
        [[ "$target" == *__* ]] && target="${target%%__*}.${target#*__}"
      fi
      REPLY="Calling ${(V)target}"
      ;;
    *) REPLY="$name" ;;
  esac
}

transcript_tool_summary() {
  emulate -L zsh
  local name="$1" args="$2" target='' label=''
  local -A JSON_OBJECT=()
  transcript_tool_label "$name"; label="$REPLY"
  json_parse_flat_object "$args" || { REPLY="$label"; return 1; }
  if [[ -n "${JSON_OBJECT[path]:-}" ]]; then
    zcoder_display_path "${JSON_OBJECT[path]}"; target="$REPLY"
  else
    target="${JSON_OBJECT[command]:-${JSON_OBJECT[query]:-${JSON_OBJECT[name]:-}}}"
  fi
  case "$name" in
    read_file_range) target="${target:-?}:${JSON_OBJECT[start_line]:-?}-${JSON_OBJECT[end_line]:-?}" ;;
    read_skill_resource) target="${JSON_OBJECT[name]:-?}:${target:-?}" ;;
  esac
  target="${target//$'\n'/ }"
  (( ${#target} > 120 )) && target="${target[1,117]}..."
  REPLY="${label}${target:+(${target})}"
}

# Called by the local UI and by the remote worker. No terminal dependency.
# An optional transport ID identifies updates independently of row positions.
transcript_tool_event() {
  emulate -L zsh
  setopt extendedglob
  local phase="$1" name="$2" args="${3:-}" result="${4:-}" succeeded="${5:-0}" id="${6:-}"
  local -i index=$UI_CURRENT_TOOL
  if [[ "$phase" == begin ]]; then
    if [[ -n "$id" ]] && (( ${UI_IDS[(Ie)$id]} )); then return 0; fi
    ui_append_message tool "$name"
    index=${#UI_ROLES}
    UI_CURRENT_TOOL=$index
    [[ -n "$id" ]] && UI_IDS[index]="$id"
    UI_BLOCK_OPEN[index]=0
    UI_TOOL_NAMES[index]="$name"
    transcript_tool_summary "$name" "$args" || true
    UI_TOOL_SUMMARIES[index]="$REPLY"
    UI_TOOL_ARGS[index]="$args"
    UI_TOOL_STATES[index]=pending
    # User shell output opens immediately, including on remote clients and
    # when the transcript is later restored from a saved session.
    if [[ "$name" == run_command ]]; then
      local -A JSON_OBJECT=()
      if json_parse_flat_object "$args" && [[ "${JSON_OBJECT[user_initiated]:-}" == true ]]; then
        UI_BLOCK_OPEN[index]=1
      fi
    fi
    return 0
  fi
  [[ -n "$id" ]] && index=${UI_IDS[(Ie)$id]}
  (( index > 0 && index <= ${#UI_ROLES} )) || return 1
  [[ "${UI_TOOL_NAMES[index]}" == "$name" ]] || return 1
  [[ "${UI_TOOL_STATES[index]}" == pending || "${UI_TOOL_STATES[index]}" == running ]] || return 1
  case "$phase" in
    running) UI_TOOL_STATES[index]=running ;;
    complete)
      UI_TOOL_RESULTS[index]="$result"
      [[ "$succeeded" == 1 ]] && UI_TOOL_STATES[index]=completed || UI_TOOL_STATES[index]=failed
      if (( $+functions[agent_format_tool_ui_result] )); then
        agent_format_tool_ui_result "$name" "${UI_TOOL_ARGS[index]}" "$result" "$succeeded"
        UI_CONTENTS[index]="$REPLY"
      fi
      (( UI_CURRENT_TOOL == index )) && UI_CURRENT_TOOL=0
      ;;
    *) return 1 ;;
  esac
  transcript_changed "$index"
}

transcript_metadata_json() {
  emulate -L zsh
  local -i index=$1
  local output="" key="" value=""
  local -a values=("${UI_IDS[index]:-event_${index}}" "${UI_BLOCK_OPEN[index]:-1}"
    "${UI_TOOL_NAMES[index]}" "${UI_TOOL_ARGS[index]}" "${UI_TOOL_RESULTS[index]}" "${UI_TOOL_STATES[index]}" "${UI_TOOL_SUMMARIES[index]}")
  for key in id open name args result state summary; do
    value="${values[1]}"; shift values
    zjson_quote "$value"
    output+="${output:+,}\"${key}\":${REPLY}"
  done
  output+=",\"streaming\":$(( index == UI_STREAM_INDEX ? 1 : 0 ))"
  REPLY="{${output}}"
}

transcript_interrupt_tool() {
  emulate -L zsh
  local -i index=$UI_CURRENT_TOOL
  UI_CURRENT_TOOL=0
  (( index > 0 && index <= ${#UI_ROLES} )) || return 1
  [[ "${UI_TOOL_STATES[index]}" == pending || "${UI_TOOL_STATES[index]}" == running ]] || return 1
  UI_TOOL_STATES[index]=interrupted
  transcript_changed "$index"
}

transcript_restore_metadata() {
  emulate -L zsh
  setopt extendedglob
  local -i index=$1 interrupted=${3:-1}
  local metadata="$2" id=""
  local -A JSON_OBJECT=()
  transcript_default_metadata "$index"
  [[ -n "$metadata" ]] || return 0
  json_parse_flat_object "$metadata" || return 0
  id="${JSON_OBJECT[id]:-}"
  # IDs are data, never paths or arithmetic expressions. Reject duplicates.
  if [[ -n "$id" ]] && (( ! ${UI_IDS[(Ie)$id]} || ${UI_IDS[(Ie)$id]} == index )); then
    UI_IDS[index]="$id"
  fi
  [[ "${JSON_OBJECT[open]:-1}" == 0 ]] && UI_BLOCK_OPEN[index]=0
  if [[ "${UI_ROLES[index]}" == assistant && "${JSON_OBJECT[streaming]:-0}" == 1 ]]; then
    UI_CONTENTS[index]+=$'\n\n[Interrupted response restored from disk; partial text only.]'
    transcript_changed "$index"
  fi
  [[ "${UI_ROLES[index]}" == tool && -n "${JSON_OBJECT[name]:-}" ]] || return 0
  case "${JSON_OBJECT[state]:-}" in
    pending|running|completed|failed|interrupted) ;;
    *) return 0 ;;
  esac
  UI_TOOL_NAMES[index]="${JSON_OBJECT[name]}"
  UI_TOOL_SUMMARIES[index]="${JSON_OBJECT[summary]:-${JSON_OBJECT[name]}}"
  UI_TOOL_ARGS[index]="${JSON_OBJECT[args]:-}"
  UI_TOOL_RESULTS[index]="${JSON_OBJECT[result]:-}"
  UI_TOOL_STATES[index]="${JSON_OBJECT[state]}"
  if transcript_tool_summary "${UI_TOOL_NAMES[index]}" "${UI_TOOL_ARGS[index]}"; then
    UI_TOOL_SUMMARIES[index]="$REPLY"
  fi
  if (( interrupted )) && [[ "${UI_TOOL_STATES[index]}" == pending || "${UI_TOOL_STATES[index]}" == running ]]; then
    UI_TOOL_STATES[index]=interrupted
    transcript_changed "$index"
  fi
  return 0
}
