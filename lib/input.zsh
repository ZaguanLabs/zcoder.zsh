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
typeset -gF INPUT_ESCAPE_AT=0.0
typeset -ga INPUT_PASTE_CHUNKS=()
typeset -g INPUT_LAYOUT_BUFFER=""
typeset -gi INPUT_LAYOUT_WIDTH=-1 INPUT_LAYOUT_POS=-1
typeset -g INPUT_EVENT_ACTION="" INPUT_EVENT_TEXT=""
typeset -gi INPUT_GRAPHEME=0

# Headless-safe discovery: only an already selected drawing backend can opt in.
input_detect_boundaries() {
  INPUT_GRAPHEME=0
  [[ -o multibyte ]] || return 0
  local -a reply=()
  local -A input_probe=()
  if (( $+functions[zcoder_curses_features] )) && zcoder_curses_features &&
     (( ${reply[(Ie)grapheme_boundaries]} )) &&
     zcoder_curses textpos input_probe x byte 0 grapheme 2>/dev/null; then
    INPUT_GRAPHEME=1
  fi
  return 0
}

# Return the containing unit as character offsets, even though the native API
# uses bytes. Query only the logical line: newlines remain individual units.
_input_grapheme_bounds() {
  (( INPUT_GRAPHEME )) && [[ -o multibyte ]] || return 1
  emulate -L zsh
  local -i at=$1 line_start byte_offset unit_start unit_end
  (( at >= 0 && at < ${#INPUT_BUF} )) || return 1
  [[ ${INPUT_BUF[at+1]} != $'\n' ]] || return 1
  if [[ ${INPUT_BUF[at+1]} == [\ -~] ]] &&
     { (( at == 0 )) || [[ ${INPUT_BUF[at]} == [\ -~] ]]; } &&
     { (( at+1 == ${#INPUT_BUF} )) || [[ ${INPUT_BUF[at+2]} == [\ -~] ]]; }; then
    return 1
  fi
  local prefix="${INPUT_BUF[1,at]}" suffix="${INPUT_BUF[at+1,-1]}" line
  prefix=${prefix##*$'\n'}
  line_start=$(( at - ${#prefix} ))
  line="$prefix${suffix%%$'\n'*}"
  # ASCII keystrokes need no native query. A space sentinel gives leading
  # combining marks a printable base without changing the original buffer.
  [[ $line == *[^\ -~]* ]] || return 1
  prefix=" $prefix"; line=" $line"
  setopt nomultibyte
  byte_offset=${#prefix}
  setopt multibyte
  local -A input_hit=()
  zcoder_curses textpos input_hit "$line" byte "$byte_offset" grapheme 2>/dev/null || return 1
  unit_start=$(( line_start + ${#input_hit[prefix]} - 1 ))
  unit_end=$(( unit_start + ${#input_hit[text]} ))
  (( unit_start < line_start )) && unit_start=$line_start
  reply=("$unit_start" "$unit_end")
  return 0
}

# A splice can join units across the caret (for example, removing a newline
# between a letter and a combining mark). Keep the caret after the joined unit.
_input_snap_forward() {
  local -a reply=()
  if _input_grapheme_bounds "$INPUT_POS" && (( reply[1] < INPUT_POS )); then
    INPUT_POS=$reply[2]
  fi
  return 0
}

_input_remove_range() {
  local -i first=$1 last=$2
  INPUT_BUF="${INPUT_BUF[1,first]}${INPUT_BUF[last+1,-1]}"
  INPUT_POS=$first
  _input_snap_forward
  INPUT_GOAL_COL=-1
}

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
  _input_snap_forward
  INPUT_GOAL_COL=-1
}

input_backspace() {
  (( INPUT_POS > 0 )) || return 0
  local -a reply=()
  if _input_grapheme_bounds "$(( INPUT_POS-1 ))"; then
    _input_remove_range "$reply[1]" "$reply[2]"
  else
    _input_remove_range "$(( INPUT_POS-1 ))" "$INPUT_POS"
  fi
}

input_delete() {
  (( INPUT_POS < ${#INPUT_BUF} )) || return 0
  local -a reply=()
  if _input_grapheme_bounds "$INPUT_POS"; then
    _input_remove_range "$reply[1]" "$reply[2]"
  else
    _input_remove_range "$INPUT_POS" "$(( INPUT_POS+1 ))"
  fi
}

input_left() {
  local -a reply=()
  if (( INPUT_POS > 0 )); then
    if _input_grapheme_bounds "$(( INPUT_POS-1 ))"; then INPUT_POS=$reply[1]
    else (( INPUT_POS-- )); fi
  fi
  INPUT_GOAL_COL=-1
  return 0
}
input_right() {
  local -a reply=()
  if (( INPUT_POS < ${#INPUT_BUF} )); then
    if _input_grapheme_bounds "$INPUT_POS"; then INPUT_POS=$reply[2]
    else (( INPUT_POS++ )); fi
  fi
  INPUT_GOAL_COL=-1
  return 0
}
input_home() { INPUT_POS=0; INPUT_GOAL_COL=-1; }
input_end() { INPUT_POS=${#INPUT_BUF}; INPUT_GOAL_COL=-1; }
input_clear() { INPUT_BUF=""; INPUT_POS=0; INPUT_GOAL_COL=-1; }

input_kill_word() {
  emulate -L zsh
  setopt extendedglob
  local left
  local -a reply=()
  local -i first last=$INPUT_POS
  (( INPUT_POS > 0 )) || return 0
  left="${INPUT_BUF[1,INPUT_POS]}"
  left="${left%%[[:space:]]#}"
  left="${left%%[^[:space:]]#}"
  first=${#left}
  if _input_grapheme_bounds "$first"; then first=$reply[1]; fi
  if _input_grapheme_bounds "$(( last-1 ))"; then last=$reply[2]; fi
  _input_remove_range "$first" "$last"
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
  # Cell-based layout may hit the middle of a joined emoji. Choose its start
  # while retaining the requested column for the next vertical move.
  local -a reply=()
  if _input_grapheme_bounds "$INPUT_POS"; then INPUT_POS=$reply[1]; fi
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

  case "$key" in
    PASTE_BEGIN|PASTE_PENDING|PASTE_REJECTED|PASTE)
      INPUT_TERM_STATE=normal; INPUT_ESCAPE_BUF=''
      if [[ $key == PASTE ]]; then
        zjson_utf8_repair "${TERMINAL_EVENT_TEXT:-}"
        INPUT_EVENT_TEXT=${REPLY//$'\r\n'/$'\n'}
        INPUT_EVENT_TEXT=${INPUT_EVENT_TEXT//$'\r'/$'\n'}
        INPUT_EVENT_TEXT=${INPUT_EVENT_TEXT//$'\t'/    }
        # Prompt text may contain newlines, but no other terminal controls.
        INPUT_EVENT_TEXT=${INPUT_EVENT_TEXT//[$'\x00'-$'\x09'$'\x0b'-$'\x1f'$'\x7f']/}
        INPUT_EVENT_ACTION=paste
      elif [[ $key == PASTE_REJECTED ]]; then
        INPUT_EVENT_ACTION=paste_rejected
        INPUT_EVENT_TEXT='Paste exceeds the 1 MiB limit; nothing was inserted.'
      fi
      return 0
      ;;
  esac

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
    # A digit typed after a separate, older Escape remains ordinary input.
    if [[ $INPUT_ESCAPE_BUF == $'\e' && $ch == (1|2) ]] &&
       (( EPOCHREALTIME - INPUT_ESCAPE_AT > 0.2 )); then
      INPUT_TERM_STATE=normal; INPUT_ESCAPE_BUF=''
      return 1
    fi
    INPUT_ESCAPE_BUF+="$ch"
    case "$INPUT_ESCAPE_BUF" in
      $'\e1'|$'\e[49;3u'|$'\e[27;3;49~')
        INPUT_TERM_STATE=normal; INPUT_ESCAPE_BUF=''
        INPUT_EVENT_ACTION=focus_sessions
        ;;
      $'\e2'|$'\e[50;3u'|$'\e[27;3;50~')
        INPUT_TERM_STATE=normal; INPUT_ESCAPE_BUF=''
        INPUT_EVENT_ACTION=focus_prompt
        ;;
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
          $'\e1' $'\e2' $'\e[49;3u' $'\e[50;3u'
          $'\e[27;3;49~' $'\e[27;3;50~'
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
    INPUT_ESCAPE_AT=$EPOCHREALTIME
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
