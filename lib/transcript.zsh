# Session transcript shared by the terminal UI and headless transports.
# Keep the existing UI_* names for the persistence and rendering interfaces.

typeset -ga UI_ROLES=() UI_CONTENTS=() UI_THINKINGS=() UI_TIMES=() UI_REASONING_OPEN=()
typeset -ga UI_IDS=() UI_BLOCK_OPEN=() UI_TOOL_NAMES=() UI_TOOL_SUMMARIES=() UI_TOOL_ARGS=() UI_TOOL_RESULTS=() UI_TOOL_STATES=()
typeset -gi UI_SELECTED_EVENT=0 UI_CURRENT_TOOL=0 UI_TRANSCRIPT_GENERATION=0
typeset -gi UI_RENDER_DIRTY_FROM=0 UI_PERSIST_DIRTY_FROM=0

transcript_reset() {
  emulate -L zsh
  UI_ROLES=(); UI_CONTENTS=(); UI_THINKINGS=(); UI_TIMES=(); UI_REASONING_OPEN=()
  UI_IDS=(); UI_BLOCK_OPEN=(); UI_TOOL_NAMES=(); UI_TOOL_SUMMARIES=(); UI_TOOL_ARGS=(); UI_TOOL_RESULTS=(); UI_TOOL_STATES=()
  UI_SELECTED_EVENT=0; UI_CURRENT_TOOL=0
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
  # Reading older blocks must not be interrupted by incoming activity.
  [[ "$1" == user && "${UI_FOCUS:-input}" != chat ]] && UI_AUTO_SCROLL=1
  return 0
}

# Called by the local UI and by the remote worker. No terminal dependency.
# An optional transport ID identifies updates independently of row positions.
transcript_tool_event() {
  emulate -L zsh
  setopt extendedglob
  local phase="$1" name="$2" args="${3:-}" result="${4:-}" succeeded="${5:-0}" id="${6:-}"
  local -i index=$UI_CURRENT_TOOL
  local -A JSON_OBJECT=()
  local target=""
  if [[ "$phase" == begin ]]; then
    if [[ -n "$id" ]] && (( ${UI_IDS[(Ie)$id]} )); then return 0; fi
    ui_append_message tool "$name"
    index=${#UI_ROLES}
    UI_CURRENT_TOOL=$index
    [[ -n "$id" ]] && UI_IDS[index]="$id"
    UI_BLOCK_OPEN[index]=0
    UI_TOOL_NAMES[index]="$name"
    if json_parse_flat_object "$args"; then
      target="${JSON_OBJECT[path]:-${JSON_OBJECT[command]:-${JSON_OBJECT[query]:-${JSON_OBJECT[name]:-}}}}"
      target="${target//$'\n'/ }"
      (( ${#target} > 120 )) && target="${target[1,117]}..."
    fi
    UI_TOOL_SUMMARIES[index]="${name}${target:+ (${target})}"
    UI_TOOL_ARGS[index]="$args"
    UI_TOOL_STATES[index]=pending
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
    json_quote "$value"
    output+="${output:+,}\"${key}\":${REPLY}"
  done
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
  if (( interrupted )) && [[ "${UI_TOOL_STATES[index]}" == pending || "${UI_TOOL_STATES[index]}" == running ]]; then
    UI_TOOL_STATES[index]=interrupted
    transcript_changed "$index"
  fi
  return 0
}
