# Standards-aligned AGENTS.md discovery and prompt assembly.

typeset -g ZCODER_HOME="${ZCODER_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/zcoder}"
typeset -gi ZCODER_PROJECT_DOC_MAX_BYTES="${ZCODER_PROJECT_DOC_MAX_BYTES:-32768}"
typeset -g ZCODER_PROJECT_DOC_FALLBACKS="${ZCODER_PROJECT_DOC_FALLBACKS:-}"

typeset -g INSTRUCTIONS_PROJECT_ROOT=""
typeset -g INSTRUCTIONS_TEXT=""
typeset -gi INSTRUCTIONS_BYTES=0
typeset -gi INSTRUCTIONS_TRUNCATED=0
typeset -ga INSTRUCTION_SOURCES=()
typeset -ga INSTRUCTION_CONTENTS=()

_instructions_byte_length() {
  setopt localoptions nomultibyte
  REPLY=${#1}
}

_instructions_prefix_bytes() {
  local input="$1"
  local -i limit="$2" low=0 high=${#1} midpoint bytes
  while (( low < high )); do
    midpoint=$(( (low + high + 1) / 2 ))
    _instructions_byte_length "${input[1,midpoint]}"
    bytes=$REPLY
    if (( bytes <= limit )); then
      low=$midpoint
    else
      high=$(( midpoint - 1 ))
    fi
  done
  if (( low > 0 )); then
    REPLY="${input[1,low]}"
  else
    REPLY=""
  fi
}

_instructions_nonempty_file() {
  local candidate="$1" content=""
  [[ -f "$candidate" ]] || return 1
  content="${mapfile[$candidate]}"
  [[ -n "${content//[[:space:]]/}" ]] || return 1
  REPLY="$candidate"
}

_instructions_select_file() {
  local directory="$1" fallback=""
  local -a fallbacks=()
  _instructions_nonempty_file "$directory/AGENTS.override.md" && return 0
  _instructions_nonempty_file "$directory/AGENTS.md" && return 0

  [[ -n "$ZCODER_PROJECT_DOC_FALLBACKS" ]] || return 1
  fallbacks=("${(@s.:.)ZCODER_PROJECT_DOC_FALLBACKS}")
  for fallback in "${fallbacks[@]}"; do
    [[ -n "$fallback" && "$fallback" != */* && "$fallback" != . && "$fallback" != .. ]] || continue
    _instructions_nonempty_file "$directory/$fallback" && return 0
  done
  return 1
}

instructions_find_project_root() {
  local directory="${1:A}" parent=""
  while true; do
    if [[ -e "$directory/.git" ]]; then
      REPLY="$directory"
      return 0
    fi
    parent="${directory:h}"
    [[ "$parent" == "$directory" ]] && break
    directory="$parent"
  done
  REPLY="${1:A}"
}

_instructions_add_file() {
  local source_file="$1" content="" separator=""
  local -i content_bytes remaining separator_bytes=0
  content="${mapfile[$source_file]}"
  (( ${#INSTRUCTION_SOURCES} > 0 )) && separator=$'\n\n'
  _instructions_byte_length "$separator"; separator_bytes=$REPLY
  _instructions_byte_length "$content"; content_bytes=$REPLY
  remaining=$(( ZCODER_PROJECT_DOC_MAX_BYTES - INSTRUCTIONS_BYTES - separator_bytes ))
  if (( remaining <= 0 )); then
    INSTRUCTIONS_TRUNCATED=1
    return 1
  fi
  if (( content_bytes > remaining )); then
    _instructions_prefix_bytes "$content" "$remaining"
    content="$REPLY"
    _instructions_byte_length "$content"; content_bytes=$REPLY
    INSTRUCTIONS_TRUNCATED=1
  fi
  INSTRUCTION_SOURCES+=("$source_file")
  INSTRUCTION_CONTENTS+=("$content")
  INSTRUCTIONS_TEXT+="${separator}${content}"
  (( INSTRUCTIONS_BYTES += separator_bytes + content_bytes ))
  (( INSTRUCTIONS_TRUNCATED == 0 ))
}

instructions_load() {
  local workspace="${1:-$ZCODER_WORKSPACE}" global_file="" directory="" selected=""
  local -a directories=()
  INSTRUCTION_SOURCES=()
  INSTRUCTION_CONTENTS=()
  INSTRUCTIONS_TEXT=""
  INSTRUCTIONS_BYTES=0
  INSTRUCTIONS_TRUNCATED=0

  [[ "$ZCODER_PROJECT_DOC_MAX_BYTES" == <1-> ]] || ZCODER_PROJECT_DOC_MAX_BYTES=32768
  instructions_find_project_root "$workspace"
  INSTRUCTIONS_PROJECT_ROOT="$REPLY"

  if _instructions_nonempty_file "${ZCODER_HOME:A}/AGENTS.override.md"; then
    global_file="$REPLY"
  elif _instructions_nonempty_file "${ZCODER_HOME:A}/AGENTS.md"; then
    global_file="$REPLY"
  fi
  if [[ -n "$global_file" ]]; then
    _instructions_add_file "$global_file" || return 0
  fi

  directory="${workspace:A}"
  while true; do
    directories=("$directory" "${directories[@]}")
    [[ "$directory" == "$INSTRUCTIONS_PROJECT_ROOT" ]] && break
    directory="${directory:h}"
  done

  for directory in "${directories[@]}"; do
    selected=""
    if _instructions_select_file "$directory"; then
      selected="$REPLY"
    fi
    [[ -n "$selected" ]] || continue
    _instructions_add_file "$selected" || break
  done
  return 0
}

instructions_prompt_block() {
  local output="" source="" content="" display=""
  local -i i
  [[ -n "$INSTRUCTIONS_TEXT" ]] || { REPLY=""; return 0; }
  output=$'\n\nThe project instructions below are mandatory requirements, not reference material. Before acting, identify and follow every applicable instruction. Do not omit a requirement because the user did not repeat it. Each file governs its directory and descendants; later, more specific files override earlier guidance. Workspace, approval, and safety restrictions remain authoritative. Before changing files in a deeper directory, check for a closer AGENTS.override.md or AGENTS.md.\n<mandatory_project_instructions>'
  for (( i=1; i<=${#INSTRUCTION_SOURCES}; i++ )); do
    source="${INSTRUCTION_SOURCES[i]}"
    content="${INSTRUCTION_CONTENTS[i]}"
    if [[ "$source" == "$ZCODER_WORKSPACE"/* ]]; then
      display="${source#$ZCODER_WORKSPACE/}"
    elif [[ "$source" == "$INSTRUCTIONS_PROJECT_ROOT"/* ]]; then
      display="${source#$INSTRUCTIONS_PROJECT_ROOT/}"
    else
      display="$source"
    fi
    output+=$'\n\n'"### Instructions from ${display}"$'\n'"${content}"
  done
  (( INSTRUCTIONS_TRUNCATED )) && output+=$'\n\n[Instruction chain truncated at configured byte limit.]'
  output+=$'\n</mandatory_project_instructions>'
  REPLY="$output"
}

instructions_completion_block() {
  if [[ -n "$INSTRUCTIONS_TEXT" ]]; then
    REPLY=$'\n\n<project_instruction_check>\nBefore finishing, verify that every applicable project instruction, including required checks, was satisfied. If not, the task is incomplete.\n</project_instruction_check>'
  else
    REPLY=""
  fi
}

instructions_summary() {
  local output="" source="" display=""
  local -i i
  if (( ${#INSTRUCTION_SOURCES} == 0 )); then
    REPLY="No AGENTS.md instructions loaded."
    return 0
  fi
  output="Loaded ${#INSTRUCTION_SOURCES} instruction file(s), ${INSTRUCTIONS_BYTES}/${ZCODER_PROJECT_DOC_MAX_BYTES} bytes:"
  for (( i=1; i<=${#INSTRUCTION_SOURCES}; i++ )); do
    source="${INSTRUCTION_SOURCES[i]}"
    if [[ "$source" == "$INSTRUCTIONS_PROJECT_ROOT"/* ]]; then
      display="${source#$INSTRUCTIONS_PROJECT_ROOT/}"
    else
      display="$source"
    fi
    output+=$'\n'"  ${i}. ${display}"
  done
  (( INSTRUCTIONS_TRUNCATED )) && output+=$'\n'"  Warning: instruction chain was truncated."
  REPLY="$output"
}
