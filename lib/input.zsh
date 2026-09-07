# Native multiline editor with prompt history and terminal event decoding.

typeset -g INPUT_BUF=""
typeset -gi INPUT_POS=0
typeset -ga INPUT_HISTORY=()
typeset -gi INPUT_HISTORY_POS=0
typeset -g INPUT_DRAFT=""
typeset -g INPUT_SUBMITTED=""
typeset -ga INPUT_VISUAL_LINES=() INPUT_VISUAL_STARTS=() INPUT_VISUAL_LENGTHS=()
typeset -gi INPUT_CURSOR_ROW=1 INPUT_CURSOR_COL=0 INPUT_VIEW_TOP=1 INPUT_VISIBLE_ROWS=1
typeset -gi INPUT_GOAL_COL=-1
typeset -g INPUT_TERM_STATE="normal" INPUT_ESCAPE_BUF="" INPUT_PASTE_BUF=""
typeset -ga INPUT_PASTE_CHUNKS=()
typeset -g INPUT_LAYOUT_BUFFER=""
typeset -gi INPUT_LAYOUT_WIDTH=-1 INPUT_LAYOUT_POS=-1
typeset -g INPUT_EVENT_ACTION="" INPUT_EVENT_TEXT=""

input_reset() {
  INPUT_BUF=""
  INPUT_POS=0
  INPUT_HISTORY_POS=0
  INPUT_DRAFT=""
  INPUT_SUBMITTED=""
  INPUT_GOAL_COL=-1
  INPUT_TERM_STATE="normal"
  INPUT_ESCAPE_BUF=""
  INPUT_PASTE_BUF=""
  INPUT_PASTE_CHUNKS=()
  INPUT_LAYOUT_WIDTH=-1
  INPUT_LAYOUT_BUFFER=""
  INPUT_EVENT_ACTION=""
  INPUT_EVENT_TEXT=""
}

input_insert() {
  local ch="$1"
  [[ -n "$ch" ]] || return 0
  if (( INPUT_POS == 0 )); then
    INPUT_BUF="${ch}${INPUT_BUF}"
  elif (( INPUT_POS >= ${#INPUT_BUF} )); then
    INPUT_BUF+="$ch"
  else
    INPUT_BUF="${INPUT_BUF[1,INPUT_POS]}${ch}${INPUT_BUF[INPUT_POS+1,-1]}"
  fi
  (( INPUT_POS += ${#ch} ))
  INPUT_GOAL_COL=-1
}

input_backspace() {
  (( INPUT_POS > 0 )) || return 0
  if (( INPUT_POS == 1 )); then
    INPUT_BUF="${INPUT_BUF[2,-1]}"
  elif (( INPUT_POS >= ${#INPUT_BUF} )); then
    INPUT_BUF="${INPUT_BUF[1,-2]}"
  else
    INPUT_BUF="${INPUT_BUF[1,INPUT_POS-1]}${INPUT_BUF[INPUT_POS+1,-1]}"
  fi
  (( INPUT_POS-- ))
  INPUT_GOAL_COL=-1
}

input_delete() {
  (( INPUT_POS < ${#INPUT_BUF} )) || return 0
  if (( INPUT_POS == 0 )); then
    INPUT_BUF="${INPUT_BUF[2,-1]}"
  else
    INPUT_BUF="${INPUT_BUF[1,INPUT_POS]}${INPUT_BUF[INPUT_POS+2,-1]}"
  fi
  INPUT_GOAL_COL=-1
}

input_left() { (( INPUT_POS > 0 )) && (( INPUT_POS-- )); INPUT_GOAL_COL=-1; return 0; }
input_right() { (( INPUT_POS < ${#INPUT_BUF} )) && (( INPUT_POS++ )); INPUT_GOAL_COL=-1; return 0; }
input_home() { INPUT_POS=0; INPUT_GOAL_COL=-1; }
input_end() { INPUT_POS=${#INPUT_BUF}; INPUT_GOAL_COL=-1; }
input_clear() { INPUT_BUF=""; INPUT_POS=0; INPUT_GOAL_COL=-1; }

input_kill_word() {
  emulate -L zsh
  setopt extendedglob
  local left right
  (( INPUT_POS > 0 )) || return 0
  left="${INPUT_BUF[1,INPUT_POS]}"
  right="${INPUT_BUF[INPUT_POS+1,-1]}"
  left="${left%%[[:space:]]#}"
  left="${left%%[^[:space:]]#}"
  INPUT_BUF="${left}${right}"
  INPUT_POS=${#left}
  INPUT_GOAL_COL=-1
}

# Split the buffer into terminal-width visual rows. Starts are zero-based
# character offsets, matching INPUT_POS, so cursor movement stays independent
# of curses and can be tested without a terminal.
input_layout() {
  local -i width=${1:-1} max_rows=${2:-4}
  (( width < 1 )) && width=1
  (( max_rows < 1 )) && max_rows=1

  if (( width == INPUT_LAYOUT_WIDTH && INPUT_POS == INPUT_LAYOUT_POS )) &&
     [[ "$INPUT_BUF" == "$INPUT_LAYOUT_BUFFER" ]]; then
    _input_layout_viewport "$max_rows"
    return 0
  fi
  INPUT_LAYOUT_BUFFER="$INPUT_BUF"; INPUT_LAYOUT_WIDTH=$width
  INPUT_LAYOUT_POS=$INPUT_POS
  INPUT_VISUAL_LINES=(); INPUT_VISUAL_STARTS=(); INPUT_VISUAL_LENGTHS=()
  INPUT_CURSOR_ROW=1; INPUT_CURSOR_COL=0
  local -a logical_lines=("${(@ps:\n:)INPUT_BUF}")
  local line="" segment="" prefix=""
  local -i length=${#INPUT_BUF} row=0 offset=0 i segment_length k
  for line in "${logical_lines[@]}"; do
    zcoder_hard_wrap "$line" "$width"
    for (( i=1; i<=${#ZCODER_WRAPPED}; i++ )); do
      segment="${ZCODER_WRAPPED[i]}"; segment_length=${ZCODER_WRAPPED_LENGTHS[i]}
      (( row++ ))
      INPUT_VISUAL_LINES+=("$segment"); INPUT_VISUAL_STARTS+=("$offset")
      INPUT_VISUAL_LENGTHS+=("$segment_length")
      if (( INPUT_POS >= offset && INPUT_POS <= offset + segment_length )); then
        k=$(( INPUT_POS - offset ))
        prefix="${segment[1,k]}"
        INPUT_CURSOR_ROW=$row; INPUT_CURSOR_COL=${(m)#prefix}
      fi
      (( offset += segment_length ))
    done
    (( offset++ )) # A logical newline occupies one original character.
  done
  # Keep an end cursor off the border after a completely filled final row.
  if (( length > 0 && INPUT_POS == length && INPUT_CURSOR_COL == width )); then
    INPUT_VISUAL_LINES+=(""); INPUT_VISUAL_STARTS+=("$length"); INPUT_VISUAL_LENGTHS+=(0)
    (( row++ )); INPUT_CURSOR_ROW=$row; INPUT_CURSOR_COL=0
  fi

  _input_layout_viewport "$max_rows"
}

# A height-only change reuses wrapping and cursor geometry.
_input_layout_viewport() {
  local -i max_rows=$1 total=${#INPUT_VISUAL_LINES}
  INPUT_VISIBLE_ROWS=$total
  (( INPUT_VISIBLE_ROWS > max_rows )) && INPUT_VISIBLE_ROWS=$max_rows
  INPUT_VIEW_TOP=1
  if (( INPUT_CURSOR_ROW > max_rows )); then
    INPUT_VIEW_TOP=$(( INPUT_CURSOR_ROW - max_rows + 1 ))
  fi
  if (( INPUT_VIEW_TOP + INPUT_VISIBLE_ROWS - 1 > total )); then
    INPUT_VIEW_TOP=$(( total - INPUT_VISIBLE_ROWS + 1 ))
  fi
  (( INPUT_VIEW_TOP < 1 )) && INPUT_VIEW_TOP=1
}

input_move_vertical() {
  local -i direction=$1 width=${2:-1} max_rows=${3:-4}
  input_layout "$width" "$max_rows"
  local -i target=$(( INPUT_CURSOR_ROW + direction ))
  (( target >= 1 && target <= ${#INPUT_VISUAL_LINES} )) || return 1
  (( INPUT_GOAL_COL < 0 )) && INPUT_GOAL_COL=$INPUT_CURSOR_COL
  local -i target_col=$INPUT_GOAL_COL
  zcoder_clip "${INPUT_VISUAL_LINES[target]}" "$target_col"
  INPUT_POS=$(( INPUT_VISUAL_STARTS[target] + ${#REPLY} ))
  return 0
}

# Consume terminal sequences which curses does not identify as named keys.
# Shift-Return has no distinct encoding in traditional terminal mode, but the
# two common extended-key protocols are recognized. Alt-Return is a portable
# fallback. Bracketed paste keeps embedded newlines in the prompt.
input_decode_terminal_event() {
  local ch="${1:-}" key="${2:-}"
  INPUT_EVENT_ACTION=""
  INPUT_EVENT_TEXT=""

  if [[ "$key" == SENTER ]]; then
    INPUT_EVENT_ACTION="newline"
    return 0
  fi

  if [[ "$INPUT_TERM_STATE" != normal && -z "$ch" && ( "$key" == ENTER || "$key" == PADENTER ) ]]; then
    ch=$'\n'
  fi

  if [[ "$INPUT_TERM_STATE" == paste ]]; then
    INPUT_PASTE_BUF+="$ch"
    if [[ "${INPUT_PASTE_BUF[-6,-1]}" == $'\e[201~' ]]; then
      INPUT_EVENT_TEXT="${(j::)INPUT_PASTE_CHUNKS}${INPUT_PASTE_BUF%$'\e[201~'}"
      INPUT_PASTE_CHUNKS=()
      INPUT_EVENT_TEXT="${(pj:\n:)${(@ps:\r\n:)INPUT_EVENT_TEXT}}"
      INPUT_EVENT_TEXT="${(pj:\n:)${(@ps:\r:)INPUT_EVENT_TEXT}}"
      INPUT_PASTE_BUF=""
      INPUT_TERM_STATE="normal"
      INPUT_EVENT_ACTION="paste"
    elif (( ${#INPUT_PASTE_BUF} >= 262 )); then
      # Keep the delimiter tail together across chunk boundaries.
      INPUT_PASTE_CHUNKS+=("${INPUT_PASTE_BUF[1,-7]}")
      INPUT_PASTE_BUF="${INPUT_PASTE_BUF[-6,-1]}"
    fi
    return 0
  fi

  if [[ "$INPUT_TERM_STATE" == escape ]]; then
    INPUT_ESCAPE_BUF+="$ch"
    case "$INPUT_ESCAPE_BUF" in
      $'\e[200~')
        INPUT_TERM_STATE="paste"
        INPUT_ESCAPE_BUF=""
        INPUT_PASTE_BUF=""
        INPUT_PASTE_CHUNKS=()
        ;;
      $'\e[13;2u'|$'\e[13;2~'|$'\e[27;2;13~'|$'\e\n'|$'\e\r')
        INPUT_TERM_STATE="normal"
        INPUT_ESCAPE_BUF=""
        INPUT_EVENT_ACTION="newline"
        ;;
      *)
        local -a known=(
          $'\e[200~' $'\e[13;2u' $'\e[13;2~' $'\e[27;2;13~'
          $'\e\n' $'\e\r'
        )
        local candidate=""
        local -i is_prefix=0
        for candidate in "${known[@]}"; do
          [[ "$candidate" == "$INPUT_ESCAPE_BUF"* ]] && { is_prefix=1; break; }
        done
        if (( ! is_prefix )); then
          INPUT_TERM_STATE="normal"
          INPUT_ESCAPE_BUF=""
        fi
        ;;
    esac
    return 0
  fi

  if [[ "$ch" == $'\e' ]]; then
    INPUT_TERM_STATE="escape"
    INPUT_ESCAPE_BUF="$ch"
    return 0
  fi
  return 1
}

input_history_previous() {
  local -i total=${#INPUT_HISTORY}
  (( total > 0 )) || return 0
  if (( INPUT_HISTORY_POS == 0 )); then
    INPUT_DRAFT="$INPUT_BUF"
    INPUT_HISTORY_POS=$total
  elif (( INPUT_HISTORY_POS > 1 )); then
    (( INPUT_HISTORY_POS-- ))
  fi
  INPUT_BUF="${INPUT_HISTORY[INPUT_HISTORY_POS]}"
  INPUT_POS=${#INPUT_BUF}
  INPUT_GOAL_COL=-1
}

input_history_next() {
  local -i total=${#INPUT_HISTORY}
  (( total > 0 && INPUT_HISTORY_POS > 0 )) || return 0
  if (( INPUT_HISTORY_POS < total )); then
    (( INPUT_HISTORY_POS++ ))
    INPUT_BUF="${INPUT_HISTORY[INPUT_HISTORY_POS]}"
  else
    INPUT_HISTORY_POS=0
    INPUT_BUF="$INPUT_DRAFT"
  fi
  INPUT_POS=${#INPUT_BUF}
  INPUT_GOAL_COL=-1
}

input_submit() {
  INPUT_SUBMITTED="$INPUT_BUF"
  [[ -n "$INPUT_SUBMITTED" ]] && INPUT_HISTORY+=("$INPUT_SUBMITTED")
  INPUT_BUF=""
  INPUT_POS=0
  INPUT_HISTORY_POS=0
  INPUT_DRAFT=""
  INPUT_GOAL_COL=-1
}
