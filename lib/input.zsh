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
  local left right
  (( INPUT_POS > 0 )) || return 0
  left="${INPUT_BUF[1,INPUT_POS]}"
  right="${INPUT_BUF[INPUT_POS+1,-1]}"
  left="${left%# }"
  left="${left%#* }"
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

  INPUT_VISUAL_LINES=()
  INPUT_VISUAL_STARTS=()
  INPUT_VISUAL_LENGTHS=()
  INPUT_CURSOR_ROW=1
  INPUT_CURSOR_COL=0

  # Lay out per logical line with arithmetic instead of walking the buffer one
  # character at a time, which is quadratic per keystroke on pasted prompts.
  # Quoted (@ps) splitting keeps the empty fields that represent blank lines.
  local -a logical_lines=("${(@ps:\n:)INPUT_BUF}") line_chars=()
  local line=""
  local -i line_count=${#logical_lines} length=${#INPUT_BUF}
  local -i row=0 offset=0 rows j i n k first_row segment_start segment_length

  for (( j=1; j<=line_count; j++ )); do
    line="${logical_lines[j]}"
    n=${#line}
    rows=1
    (( n > width )) && rows=$(( (n + width - 1) / width ))
    first_row=$(( row + 1 ))
    if (( n <= width )); then
      (( row++ ))
      INPUT_VISUAL_LINES+=("$line")
      INPUT_VISUAL_STARTS+=("$offset")
      INPUT_VISUAL_LENGTHS+=("$n")
    else
      line_chars=("${(@s::)line}")
      for (( i=1; i<=rows; i++ )); do
        segment_start=$(( (i - 1) * width ))
        segment_length=$(( n - segment_start ))
        (( segment_length > width )) && segment_length=width
        (( row++ ))
        INPUT_VISUAL_LINES+=("${(j::)line_chars[segment_start+1,segment_start+segment_length]}")
        INPUT_VISUAL_STARTS+=($(( offset + segment_start )))
        INPUT_VISUAL_LENGTHS+=("$segment_length")
      done
    fi

    if (( INPUT_POS >= offset && INPUT_POS <= offset + n )); then
      k=$(( INPUT_POS - offset ))
      if (( k == 0 )); then
        # Only a row that begins a fresh logical line owns a cursor at its
        # very start; the buffer start keeps the default position.
        if (( j > 1 )); then
          INPUT_CURSOR_ROW=$first_row
          INPUT_CURSOR_COL=0
        fi
      elif (( k % width == 0 && k < n )); then
        # A cursor on a wrapped-row boundary belongs at the start of the next
        # visual row; before a newline it stays at the end of its own row.
        INPUT_CURSOR_ROW=$(( first_row + k / width ))
        INPUT_CURSOR_COL=0
      else
        i=$(( (k - 1) / width + 1 ))
        INPUT_CURSOR_ROW=$(( first_row + i - 1 ))
        INPUT_CURSOR_COL=$(( k - (i - 1) * width ))
      fi
    fi
    offset=$(( offset + n + 1 ))
  done

  # A cursor immediately after a full final row belongs at the start of a new
  # visual row; placing it on the border would make it disappear.
  n=${#logical_lines[line_count]}
  if (( length > 0 && INPUT_POS == length && n > 0 && n % width == 0 )); then
    INPUT_VISUAL_LINES+=("")
    INPUT_VISUAL_STARTS+=("$length")
    INPUT_VISUAL_LENGTHS+=(0)
    (( row++ ))
    INPUT_CURSOR_ROW=$row
    INPUT_CURSOR_COL=0
  fi

  local -i total=$row
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
  local -i target_col=$INPUT_GOAL_COL target_length=${INPUT_VISUAL_LENGTHS[target]}
  (( target_col > target_length )) && target_col=$target_length
  INPUT_POS=$(( INPUT_VISUAL_STARTS[target] + target_col ))
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
    if [[ "$INPUT_PASTE_BUF" == *$'\e[201~' ]]; then
      INPUT_EVENT_TEXT="${INPUT_PASTE_BUF%$'\e[201~'}"
      local newline=$'\n' carriage_return=$'\r' crlf=$'\r\n'
      INPUT_EVENT_TEXT="${INPUT_EVENT_TEXT//$crlf/$newline}"
      INPUT_EVENT_TEXT="${INPUT_EVENT_TEXT//$carriage_return/$newline}"
      INPUT_PASTE_BUF=""
      INPUT_TERM_STATE="normal"
      INPUT_EVENT_ACTION="paste"
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
