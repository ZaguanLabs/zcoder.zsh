# Adaptive curses interface for chat, tools, and prompt editing.

typeset -gi UI_ACTIVE=0
typeset -gi SCREEN_H=24 SCREEN_W=80 TOP_H=3 SIDE_W=24 INPUT_H=3 FOOT_H=1
typeset -gr INPUT_MAX_ROWS=4
typeset -gi UI_RESIZE_PENDING=0
typeset -gF UI_NEXT_RESIZE_CHECK=0.0
typeset -grF UI_RESIZE_CHECK_INTERVAL=0.25
typeset -g UI_STATUS="Ready"
typeset -gi UI_SCROLL=0 UI_AUTO_SCROLL=1
typeset -g UI_FOCUS="input"
typeset -ga UI_ROLES=() UI_CONTENTS=() UI_THINKINGS=() UI_TIMES=() UI_REASONING_OPEN=()
# Rendering the whole transcript is linear in its size, so scrolling and tool
# events must not re-render unchanged content. Non-append mutations of the
# transcript arrays (toggles, session switches) bump the generation and force
# a full render; plain appends render only the new messages, and a matching
# generation, width, model label, and count reuses the cached render as is.
typeset -gi UI_TRANSCRIPT_GENERATION=0
typeset -g UI_RENDER_CACHE_KEY=""
typeset -gi UI_RENDER_COUNT=0
typeset -ga UI_LINES=() UI_ATTRS=()
typeset -ga UI_LINE_SEGMENT_STARTS=() UI_LINE_SEGMENT_COUNTS=()
typeset -ga UI_SEGMENT_TEXTS=() UI_SEGMENT_ATTRS=()

# Keep the signal handler minimal. Geometry is queried and curses is rebuilt
# from the normal event loop, never asynchronously in the middle of a redraw.
TRAPWINCH() { UI_RESIZE_PENDING=1; }

ui_append_message() {
  UI_ROLES+=("$1")
  UI_CONTENTS+=("$2")
  UI_THINKINGS+=("${3:-}")
  zcoder_time; UI_TIMES+=("$REPLY")
  UI_REASONING_OPEN+=(0)
  UI_AUTO_SCROLL=1
}

ui_set_status() { UI_STATUS="$1"; }

ui_destroy_windows() {
  # delwin accepts exactly one window name. Passing the whole set leaves
  # names registered, so the next addwin fails during a resize.
  zcurses delwin top_win 2>/dev/null || true
  zcurses delwin side_win 2>/dev/null || true
  zcurses delwin chat_win 2>/dev/null || true
  zcurses delwin input_win 2>/dev/null || true
  zcurses delwin foot_win 2>/dev/null || true
}

ui_input_width() {
  REPLY=$(( SCREEN_W - 6 ))
  (( REPLY < 1 )) && REPLY=1
}

ui_calculate_input_height() {
  local -i max_rows=$INPUT_MAX_ROWS
  local -i available=$(( SCREEN_H - TOP_H - FOOT_H - 5 ))
  (( available < 1 )) && available=1
  (( max_rows > available )) && max_rows=$available
  ui_input_width
  input_layout "$REPLY" "$max_rows"
  INPUT_H=$(( INPUT_VISIBLE_ROWS + 2 ))
}

ui_setup_windows() {
  ui_destroy_windows
  local -a pos=()
  zcurses position stdscr pos 2>/dev/null
  SCREEN_H=${pos[5]:-${LINES:-24}}
  SCREEN_W=${pos[6]:-${COLUMNS:-80}}
  (( SCREEN_W < 88 )) && SIDE_W=0 || SIDE_W=25
  ui_calculate_input_height
  local -i main_h=$(( SCREEN_H - TOP_H - INPUT_H - FOOT_H ))
  (( main_h < 3 )) && main_h=3
  local -i chat_w=$(( SCREEN_W - SIDE_W )) input_y=$(( TOP_H + main_h ))
  zcurses addwin top_win $TOP_H $SCREEN_W 0 0 2>/dev/null
  (( SIDE_W > 0 )) && zcurses addwin side_win $main_h $SIDE_W $TOP_H 0 2>/dev/null
  zcurses addwin chat_win $main_h $chat_w $TOP_H $SIDE_W 2>/dev/null
  zcurses addwin input_win $INPUT_H $SCREEN_W $input_y 0 2>/dev/null
  zcurses addwin foot_win $FOOT_H $SCREEN_W $(( SCREEN_H - FOOT_H )) 0 2>/dev/null
}

ui_init() {
  zcurses init || return 1
  UI_ACTIVE=1
  # Ask compatible terminals to delimit pasted text so embedded newlines are
  # inserted into the editor instead of submitting partial prompts.
  print -rn -- $'\e[?2004h' > /dev/tty 2>/dev/null
  ui_setup_windows
  ui_refresh_all
}

ui_end() {
  (( UI_ACTIVE )) || return 0
  UI_ACTIVE=0
  ui_destroy_windows
  zcurses end 2>/dev/null
  print -rn -- $'\e[?2004l' > /dev/tty 2>/dev/null
  print -rn -- "${terminfo[cnorm]}" 2>/dev/null
}

ui_poll_resize() {
  local -F now=$EPOCHREALTIME
  if (( ! UI_RESIZE_PENDING && now < UI_NEXT_RESIZE_CHECK )); then
    return 0
  fi
  UI_RESIZE_PENDING=0
  UI_NEXT_RESIZE_CHECK=$(( now + UI_RESIZE_CHECK_INTERVAL ))

  # zsh/curses keeps stdscr, LINES, COLUMNS, and zsh/terminfo at their old
  # values until curses has already been resized. Querying the controlling
  # terminal avoids both that stale state and unloading zsh/terminfo while
  # curses is painting. `stty` is the small external capability here.
  local size=""
  local -a dimensions=()
  size="$(command stty size </dev/tty 2>/dev/null)" || return 0
  dimensions=(${=size})
  (( ${#dimensions} == 2 )) || return 0
  [[ "${dimensions[1]}" == <1-> && "${dimensions[2]}" == <1-> ]] || return 0
  local -i h=${dimensions[1]} w=${dimensions[2]}
  (( h > 0 && w > 0 )) || return 0
  (( h == SCREEN_H && w == SCREEN_W )) && return 0
  zcurses resize "$h" "$w" endwin 2>/dev/null || return 0
  ui_setup_windows
  ui_refresh_all
}

ui_draw_header() {
  (( UI_ACTIVE )) || return 0
  local -i defer_refresh="${1:-0}"
  local badge="[ ${UI_STATUS} ]" workspace="${ZCODER_WORKSPACE:t}" host="$OLLAMA_HOST"
  [[ "${REMOTE_MODE:-local}" == client ]] && host="${REMOTE_SERVER_NAME:-remote}@${REMOTE_ENDPOINT}"
  local -i badge_x=$(( SCREEN_W - ${#badge} - 3 ))
  zcurses clear top_win
  zcurses attr top_win bold cyan/black
  zcurses border top_win
  zcurses move top_win 1 2
  zcurses string top_win "⚡ ${ZCODER_NAME} v${ZCODER_VERSION} │ "
  zcurses attr top_win bold yellow/black
  zcurses string top_win "${ZCODER_MODEL}"
  zcurses attr top_win dim white/black
  zcurses string top_win " @ ${host} │ ${workspace}"
  if (( badge_x > 45 )); then
    zcurses move top_win 1 $badge_x
    case "$UI_STATUS" in
      Ready) zcurses attr top_win bold green/black ;;
      Error*|Denied*) zcurses attr top_win bold red/black ;;
      *) zcurses attr top_win bold magenta/black ;;
    esac
    zcurses string top_win "$badge"
  fi
  (( defer_refresh )) || zcurses refresh top_win
}

ui_draw_sidebar() {
  (( UI_ACTIVE && SIDE_W > 0 )) || return 0
  local -i defer_refresh="${1:-0}"
  local root="${ZCODER_WORKSPACE:t}" policy="$ZCODER_COMMAND_POLICY" divider="" display=""
  local session_id="" title="" skill_name=""
  local -a names=(list_files read_file read_file_range)
  local -i inner_h=$(( SCREEN_H - TOP_H - INPUT_H - FOOT_H - 2 )) inner_w=$(( SIDE_W - 2 ))
  local -i i row current_index=1 session_start=1 session_rows divider_row bottom_needed inactive_skills=0
  [[ "$ZCODER_PROFILE" == sysadmin ]] && policy="per-command"
  (( ! ${TOOL_PATCH_RETRY_REQUIRED:-0} )) && names+=(write_file)
  names+=(apply_patch search run_command)
  for skill_name in "${SKILL_DISCOVERABLE_NAMES[@]}"; do
    if ! _skills_is_active "$skill_name"; then
      inactive_skills=1
      break
    fi
  done
  (( inactive_skills )) && names+=(activate_skill)
  (( ${#SKILL_ACTIVE_NAMES} > 0 )) && names+=(read_skill_resource)
  names+=(finish)

  bottom_needed=$(( ${#names} + 7 ))
  divider_row=$(( inner_h - bottom_needed + 1 ))
  (( divider_row < 2 )) && divider_row=2
  session_rows=$(( divider_row - 1 ))
  current_index=${SESSION_IDS[(Ie)$CURRENT_SESSION_ID]}
  (( current_index > 0 )) || current_index=1
  if (( current_index > session_rows )); then
    session_start=$(( current_index - session_rows + 1 ))
  fi

  zcurses clear side_win
  [[ "$UI_FOCUS" == sidebar ]] && zcurses attr side_win bold yellow/black || zcurses attr side_win dim white/black
  zcurses border side_win
  zcurses move side_win 0 2
  zcurses attr side_win bold cyan/black
  zcurses string side_win " Sessions (${#SESSION_IDS}) "

  row=1
  for (( i=session_start; i<=${#SESSION_IDS} && row<=session_rows; i++ )); do
    session_id="${SESSION_IDS[i]}"
    title="${SESSION_TITLES[i]:-Untitled}"
    display="${title[1,$(( inner_w - 4 ))]}"
    zcoder_pad "$display" $(( inner_w - 4 )); display="$REPLY"
    zcurses move side_win $row 1
    if [[ "$session_id" == "$CURRENT_SESSION_ID" ]]; then
      zcurses attr side_win bold green/black
      zcurses string side_win " ▶ $display"
    else
      zcurses attr side_win dim white/black
      zcurses string side_win "   $display"
    fi
    (( row++ ))
  done

  divider="${(pl:inner_w::─:)}"
  if (( divider_row <= inner_h )); then
    zcurses move side_win $divider_row 1
    zcurses attr side_win dim cyan/black
    zcurses string side_win "$divider"
  fi
  row=$(( divider_row + 1 ))
  if (( row <= inner_h )); then zcurses move side_win $row 2; zcurses attr side_win bold white/black; zcurses string side_win "Project"; fi
  (( row++ ))
  if (( row <= inner_h )); then zcurses move side_win $row 2; zcurses attr side_win green/black; zcurses string side_win "${root[1,$(( inner_w - 1 ))]}"; fi
  (( row++ ))
  if (( row <= inner_h )); then zcurses move side_win $row 2; zcurses attr side_win dim cyan/black; zcurses string side_win "${ZCODER_PROFILE} · Guides: ${#INSTRUCTION_SOURCES}"; fi
  (( row++ ))
  if (( row <= inner_h )); then zcurses move side_win $row 2; zcurses attr side_win bold white/black; zcurses string side_win "Available tools"; fi
  (( row++ ))
  for (( i=1; i<=${#names}; i++ )); do
    (( row > inner_h )) && break
    zcurses move side_win $row 2
    [[ "${names[i]}" == run_command ]] && zcurses attr side_win yellow/black || zcurses attr side_win dim white/black
    zcurses string side_win "• ${names[i]}"
    (( row++ ))
  done
  if (( row <= inner_h )); then zcurses move side_win $row 2; zcurses attr side_win bold white/black; zcurses string side_win "Shell approval"; fi
  (( row++ ))
  if (( row <= inner_h )); then zcurses move side_win $row 2; zcurses attr side_win yellow/black; zcurses string side_win "$policy"; fi
  (( defer_refresh )) || zcurses refresh side_win
}

ui_plain_transcript() {
  local output="" label="" role="" content="" thinking="" time=""
  local -i i
  for (( i=1; i<=${#UI_ROLES}; i++ )); do
    role="${UI_ROLES[i]}"
    content="${UI_CONTENTS[i]}"
    thinking="${UI_THINKINGS[i]}"
    time="${UI_TIMES[i]}"
    case "$role" in
      user) label="You" ;;
      assistant) label="Assistant (${ZCODER_MODEL})" ;;
      tool) label="Tool activity" ;;
      claude) label="Claude consultant" ;;
      codex) label="Codex consultant" ;;
      agy) label="Antigravity consultant" ;;
      opencode) label="OpenCode consultant" ;;
      claude_worker) label="Claude worker" ;;
      codex_worker) label="Codex worker" ;;
      agy_worker) label="Antigravity worker" ;;
      opencode_worker) label="OpenCode worker" ;;
      relay) label="Agent relay" ;;
      error) label="Error" ;;
      *) label="${role:u}" ;;
    esac
    [[ -n "$output" ]] && output+=$'\n'
    output+="=== ${label}${time:+  ${time}} ==="$'\n'
    if [[ -n "$thinking" ]] && (( ${UI_REASONING_OPEN[i]:-0} )); then
      output+=$'Reasoning:\n'"$thinking"$'\n\n'
    fi
    [[ -n "$content" ]] && output+="$content"$'\n'
  done
  [[ -n "$output" ]] || output="(No transcript events yet.)"$'\n'
  REPLY="$output"
}

# Leave curses temporarily and print a stable plain-text transcript. While the
# screen is not being repainted, the terminal's native mouse selection and
# clipboard shortcuts work normally without adding a clipboard dependency.
ui_copy_view() {
  local transcript="" ignored=""
  (( UI_ACTIVE )) || return 1
  (( $+functions[state_save_session] )) && state_save_session
  ui_plain_transcript
  transcript="$REPLY"
  zcoder_terminal_safe "$transcript"; transcript="$REPLY"
  ui_end
  {
    print -rn -- $'\e[2J\e[H'
    print -r -- "zcoder.zsh transcript copy view"
    print -r -- "Select text with the terminal mouse and use its normal copy shortcut. Scroll as needed."
    print -r -- "Press Enter when finished to return to zcoder."
    print -r -- ""
    print -r -- "$transcript"
    print -r -- ""
    print -rn -- "Press Enter to return: "
  } > /dev/tty
  IFS= read -r ignored < /dev/tty
  ui_init
}

_ui_add_line() {
  UI_LINES+=("$1")
  UI_ATTRS+=("${2:-white/black}")
  UI_LINE_SEGMENT_STARTS+=(0)
  UI_LINE_SEGMENT_COUNTS+=(0)
}

_ui_add_segment() {
  local text="$1" attr="${2:-white/black}"
  [[ -n "$text" ]] || return 0
  local -i line_index=${#UI_LINES}
  if (( UI_LINE_SEGMENT_COUNTS[line_index] == 0 )); then
    UI_LINE_SEGMENT_STARTS[line_index]=$(( ${#UI_SEGMENT_TEXTS} + 1 ))
  fi
  UI_SEGMENT_TEXTS+=("$text")
  UI_SEGMENT_ATTRS+=("$attr")
  (( UI_LINE_SEGMENT_COUNTS[line_index]++ ))
}

_ui_language_for_path() {
  local path="${1:l}" name="${1:t:l}" extension="${1:e:l}"
  case "$name" in
    makefile|gnumakefile) REPLY="make"; return ;;
    dockerfile|containerfile) REPLY="shell"; return ;;
  esac
  case "$extension" in
    zsh|sh|bash) REPLY="shell" ;;
    py|pyw) REPLY="python" ;;
    js|jsx|mjs|cjs) REPLY="javascript" ;;
    ts|tsx|mts|cts) REPLY="typescript" ;;
    rs) REPLY="rust" ;;
    go) REPLY="go" ;;
    c|h|cc|cpp|cxx|hpp|hxx) REPLY="c" ;;
    java|kt|kts|swift|cs) REPLY="c-like" ;;
    rb) REPLY="ruby" ;;
    lua) REPLY="lua" ;;
    sql) REPLY="sql" ;;
    json|jsonc) REPLY="json" ;;
    yaml|yml) REPLY="yaml" ;;
    toml) REPLY="toml" ;;
    html|htm|xml|svg) REPLY="markup" ;;
    css|scss|sass|less) REPLY="css" ;;
    md|markdown) REPLY="markdown" ;;
    *) REPLY="plain" ;;
  esac
}

_ui_keywords_for_language() {
  case "$1" in
    shell|make)
      REPLY="if then elif else fi for while until do done case esac in function select time coproc local typeset export readonly return break continue source exec command builtin"
      ;;
    python)
      REPLY="and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case"
      ;;
    javascript|typescript)
      REPLY="async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof interface let new of package private protected public return set static super switch throw try typeof var void while with yield implements enum type namespace declare readonly abstract"
      ;;
    rust)
      REPLY="as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"
      ;;
    go)
      REPLY="break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var"
      ;;
    c|c-like)
      REPLY="alignas alignof asm auto bool break case catch char class const constexpr continue default delete do double else enum explicit export extern false float for friend goto if inline int interface long namespace new nullptr operator private protected public register return short signed sizeof static struct switch template this throw true try typedef typename union unsigned using virtual void volatile while"
      ;;
    ruby)
      REPLY="alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield"
      ;;
    lua)
      REPLY="and break do else elseif end false for function goto if in local nil not or repeat return then true until while"
      ;;
    sql)
      REPLY="select from where join inner left right full on as and or not null insert into values update set delete create alter drop table index view group by order having limit offset union all distinct case when then else end"
      ;;
    *) REPLY="" ;;
  esac
}

# Lightweight, dependency-free lexer for edit previews. It intentionally
# highlights broad token classes rather than trying to parse a full language
# grammar inside the curses renderer.
_ui_add_syntax_line() {
  local line="$1" language="${2:-plain}" prefix="${3:-  }"
  _ui_add_line "${prefix}${line}" "white/black"
  _ui_add_segment "$prefix" "dim white/black"
  [[ "$language" == plain ]] && { _ui_add_segment "$line" "white/black"; return 0; }

  if [[ "$language" == markdown && "$line" == [[:space:]]#\#* ]]; then
    _ui_add_segment "$line" "bold magenta/black"
    return 0
  fi

  _ui_keywords_for_language "$language"
  local keywords=" $REPLY " token="" ch="" pair="" quote="" next=""
  local -i index=1 start length=${#line} escaped=0
  while (( index <= length )); do
    ch="${line[index]}"
    pair="${line[index,$(( index + 1 ))]}"

    if [[ "$ch" == [[:space:]] ]]; then
      start=$index
      while (( index <= length )) && [[ "${line[index]}" == [[:space:]] ]]; do (( index++ )); done
      _ui_add_segment "${line[start,$(( index - 1 ))]}" "white/black"
      continue
    fi

    case "$language" in
      shell|make|python|ruby|yaml|toml)
        if [[ "$ch" == \# ]]; then _ui_add_segment "${line[index,-1]}" "dim green/black"; break; fi
        ;;
      javascript|typescript|rust|go|c|c-like|css)
        if [[ "$pair" == "//" || "$pair" == "/*" ]]; then _ui_add_segment "${line[index,-1]}" "dim green/black"; break; fi
        ;;
      lua|sql)
        if [[ "$pair" == "--" ]]; then _ui_add_segment "${line[index,-1]}" "dim green/black"; break; fi
        ;;
      markup)
        if [[ "${line[index,$(( index + 3 ))]}" == "<!--" ]]; then _ui_add_segment "${line[index,-1]}" "dim green/black"; break; fi
        ;;
    esac

    if [[ "$ch" == \" || "$ch" == "'" || "$ch" == \` ]]; then
      quote="$ch"; start=$index; (( index++ )); escaped=0
      while (( index <= length )); do
        ch="${line[index]}"
        if (( escaped )); then
          escaped=0
        elif [[ "$ch" == \\ ]]; then
          escaped=1
        elif [[ "$ch" == "$quote" ]]; then
          (( index++ ))
          break
        fi
        (( index++ ))
      done
      _ui_add_segment "${line[start,$(( index - 1 ))]}" "yellow/black"
      continue
    fi

    if [[ "$ch" == \$ ]]; then
      start=$index; (( index++ ))
      if (( index <= length )) && [[ "${line[index]}" == \{ ]]; then
        while (( index <= length )) && [[ "${line[index]}" != \} ]]; do (( index++ )); done
        (( index <= length )) && (( index++ ))
      else
        while (( index <= length )) && [[ "${line[index]}" == [[:alnum:]_] ]]; do (( index++ )); done
      fi
      _ui_add_segment "${line[start,$(( index - 1 ))]}" "bold cyan/black"
      continue
    fi

    if [[ "$ch" == [[:digit:]] ]]; then
      start=$index
      while (( index <= length )) && [[ "${line[index]}" == [[:alnum:]_.] ]]; do (( index++ )); done
      _ui_add_segment "${line[start,$(( index - 1 ))]}" "cyan/black"
      continue
    fi

    if [[ "$ch" == [[:alpha:]_] ]]; then
      start=$index
      while (( index <= length )) && [[ "${line[index]}" == [[:alnum:]_] ]]; do (( index++ )); done
      token="${line[start,$(( index - 1 ))]}"
      next="${line[index]:-}"
      if [[ "$keywords" == *" $token "* ]]; then
        _ui_add_segment "$token" "bold magenta/black"
      elif [[ "$token" == true || "$token" == false || "$token" == null || "$token" == nil || "$token" == None ]]; then
        _ui_add_segment "$token" "bold cyan/black"
      elif [[ "$next" == "(" ]]; then
        _ui_add_segment "$token" "bold cyan/black"
      else
        _ui_add_segment "$token" "white/black"
      fi
      continue
    fi

    if [[ "$ch" == [\{\}\[\]\(\):\;,\.\=\+\-\*\/\%\<\>\!\&\|] ]]; then
      _ui_add_segment "$ch" "cyan/black"
    else
      _ui_add_segment "$ch" "white/black"
    fi
    (( index++ ))
  done
}

# Both hard wrappers chunk via a character array and index arithmetic;
# repeatedly re-slicing the shrinking remainder is quadratic in Zsh.
_ui_add_hard_wrapped() {
  local content="$1" width="$2" prefix="${3:-  }" attr="${4:-white/black}"
  local -a content_chars=()
  local -i available=$(( width - ${#prefix} )) pos=1 total
  (( available < 1 )) && available=1
  if [[ -z "$content" ]]; then _ui_add_line "$prefix" "$attr"; return 0; fi
  content_chars=("${(@s::)content}")
  total=${#content_chars}
  while (( total - pos + 1 > available )); do
    _ui_add_line "${prefix}${(j::)content_chars[pos,pos+available-1]}" "$attr"
    (( pos += available ))
  done
  _ui_add_line "${prefix}${(j::)content_chars[pos,total]}" "$attr"
}

_ui_add_syntax_wrapped() {
  local content="$1" width="$2" prefix="${3:-  }" language="${4:-plain}"
  local -a content_chars=()
  local -i available=$(( width - ${#prefix} )) pos=1 total
  (( available < 1 )) && available=1
  if [[ -z "$content" ]]; then _ui_add_line "$prefix" "white/black"; return 0; fi
  content_chars=("${(@s::)content}")
  total=${#content_chars}
  while (( total - pos + 1 > available )); do
    _ui_add_syntax_line "${(j::)content_chars[pos,pos+available-1]}" "$language" "$prefix"
    (( pos += available ))
  done
  _ui_add_syntax_line "${(j::)content_chars[pos,total]}" "$language" "$prefix"
}

_ui_diff_attr() {
  case "$1" in
    'diff --git '*|'index '*) REPLY="bold cyan/black" ;;
    '--- '*|'+++ '*) REPLY="bold cyan/black" ;;
    '@@'*) REPLY="bold magenta/black" ;;
    '+'*) REPLY="green/black" ;;
    '-'*) REPLY="red/black" ;;
    '!'*) REPLY="yellow/black" ;;
    *) REPLY="dim white/black" ;;
  esac
}

_ui_add_tool_content() {
  local content="$1" width="$2" path="" language="plain" attr=""
  local -a lines=("${(@f)content}")
  local -i count=${#lines} index
  (( count > 0 )) || return 0

  if [[ "${lines[1]}" == "Write File("* && "${lines[1]}" == *")" ]]; then
    path="${lines[1][12,-2]}"
    _ui_language_for_path "$path"; language="$REPLY"
    _ui_add_hard_wrapped "${lines[1]}" "$width" "  " "bold cyan/black"
    for (( index=2; index<count; index++ )); do
      _ui_add_syntax_wrapped "${lines[index]}" "$width" "  " "$language"
    done
  elif [[ "${lines[1]}" == "Apply Patch" ]]; then
    _ui_add_hard_wrapped "${lines[1]}" "$width" "  " "bold cyan/black"
    for (( index=2; index<count; index++ )); do
      _ui_diff_attr "${lines[index]}"; attr="$REPLY"
      _ui_add_hard_wrapped "${lines[index]}" "$width" "  " "$attr"
    done
  elif [[ "${lines[1]}" == "Calling "* ]]; then
    _ui_add_hard_wrapped "${lines[1]}" "$width" "  " "bold yellow/black"
    return 0
  else
    _ui_add_wrapped "$content" "$width" "  " "white/black"
    return 0
  fi

  if (( count > 1 )); then
    [[ "${lines[count]}" == '✓'* ]] && attr="bold green/black" || attr="bold red/black"
    _ui_add_hard_wrapped "${lines[count]}" "$width" "  " "$attr"
  fi
}

_ui_add_wrapped() {
  local content="$1" width="$2" prefix="${3:-  }" attr="${4:-white/black}" line wrapped
  local -a raw=("${(@f)content}")
  [[ -z "$content" ]] && { _ui_add_line "$prefix" "$attr"; return 0; }
  for line in "${raw[@]}"; do
    if [[ -z "$line" ]]; then
      _ui_add_line "" default/default
      continue
    fi
    zcoder_wrap "$line" $(( width - ${#prefix} ))
    for wrapped in "${ZCODER_WRAPPED[@]}"; do
      _ui_add_line "${prefix}${wrapped}" "$attr"
    done
  done
}

_ui_render_one_message() {
  local -i i=$1 width=$2 think_lines
  local role content thinking time attr title
  local -a thinking_lines=()
  role="${UI_ROLES[i]}"; content="${UI_CONTENTS[i]}"; thinking="${UI_THINKINGS[i]}"; time="${UI_TIMES[i]}"
  case "$role" in
    user) title="🧑 You  ${time}"; attr="green/black" ;;
    assistant) title="🤖 Assistant (${ZCODER_MODEL})  ${time}"; attr="white/black" ;;
    tool) title="⚙ Tool activity  ${time}"; attr="white/black" ;;
    claude) title="◇ Claude consultant  ${time}"; attr="cyan/black" ;;
    codex) title="◇ Codex consultant  ${time}"; attr="cyan/black" ;;
    agy) title="◇ Antigravity consultant  ${time}"; attr="cyan/black" ;;
    opencode) title="◇ OpenCode consultant  ${time}"; attr="cyan/black" ;;
    claude_worker) title="◆ Claude worker  ${time}"; attr="green/black" ;;
    codex_worker) title="◆ Codex worker  ${time}"; attr="green/black" ;;
    agy_worker) title="◆ Antigravity worker  ${time}"; attr="green/black" ;;
    opencode_worker) title="◆ OpenCode worker  ${time}"; attr="green/black" ;;
    relay) title="↪ Agent relay  ${time}"; attr="magenta/black" ;;
    error) title="⚠ Error  ${time}"; attr="red/black" ;;
    *) title="ℹ ${role}  ${time}"; attr="magenta/black" ;;
  esac
  [[ "$role" == tool ]] && _ui_add_line "$title" "bold yellow/black" || _ui_add_line "$title" "bold $attr"
  if [[ -n "$thinking" ]]; then
    thinking_lines=("${(@f)thinking}")
    think_lines=${#thinking_lines}
    if (( ${UI_REASONING_OPEN[i]:-0} )); then
      _ui_add_line "  ▼ Reasoning (${think_lines} lines)" "bold magenta/black"
      _ui_add_wrapped "$thinking" "$width" "    " "dim magenta/black"
    else
      _ui_add_line "  ▶ Reasoning (${think_lines} lines) [^R to expand]" "dim magenta/black"
    fi
  fi
  if [[ "$role" == tool ]]; then
    _ui_add_tool_content "$content" "$width"
  elif [[ -n "$content" ]]; then
    _ui_add_wrapped "$content" "$width" "  " "$attr"
  fi
  _ui_add_line "" default/default
}

ui_render_messages() {
  local -i width=$1 count=${#UI_ROLES} i
  UI_LINES=(); UI_ATTRS=()
  UI_LINE_SEGMENT_STARTS=(); UI_LINE_SEGMENT_COUNTS=()
  UI_SEGMENT_TEXTS=(); UI_SEGMENT_ATTRS=()
  if (( count == 0 )); then
    _ui_add_line "" default/default
    _ui_add_line "  👋 Welcome to zcoder.zsh" "bold cyan/black"
    _ui_add_line "" default/default
    _ui_add_line "  Ask for a change, investigation, or build. The model can inspect and edit" "dim white/black"
    _ui_add_line "  the workspace with tools. Shell commands always require your approval." "dim white/black"
    _ui_add_line "" default/default
    _ui_add_line "  /model NAME   switch model       /host HOST   switch Ollama server" "dim cyan/black"
    _ui_add_line "  /new          start saved job    /help        show shortcuts" "dim cyan/black"
    return 0
  fi
  for (( i=1; i<=count; i++ )); do
    _ui_render_one_message "$i" "$width"
  done
  UI_RENDER_CACHE_KEY="${UI_TRANSCRIPT_GENERATION}:${width}:${ZCODER_MODEL}"
  UI_RENDER_COUNT=$count
}

ui_draw_chat() {
  (( UI_ACTIVE )) || return 0
  local -i defer_refresh="${1:-0}"
  local -i inner_w=$(( SCREEN_W - SIDE_W - 2 )) inner_h=$(( SCREEN_H - TOP_H - INPUT_H - FOOT_H - 2 ))
  local -i total row idx max_scroll segment_start segment_count segment_index remaining
  local attr="" segment="" cache_key="${UI_TRANSCRIPT_GENERATION}:${inner_w}:${ZCODER_MODEL}"
  local -i message_count=${#UI_ROLES} render_index
  if [[ "$cache_key" != "$UI_RENDER_CACHE_KEY" ]] || \
     (( message_count < UI_RENDER_COUNT )) || (( UI_RENDER_COUNT == 0 && message_count > 0 )); then
    ui_render_messages "$inner_w"
  elif (( message_count > UI_RENDER_COUNT )); then
    for (( render_index=UI_RENDER_COUNT+1; render_index<=message_count; render_index++ )); do
      _ui_render_one_message "$render_index" "$inner_w"
    done
    UI_RENDER_COUNT=$message_count
  fi
  total=${#UI_LINES}; max_scroll=$(( total - inner_h )); (( max_scroll < 0 )) && max_scroll=0
  (( UI_AUTO_SCROLL )) && UI_SCROLL=$max_scroll
  (( UI_SCROLL > max_scroll )) && UI_SCROLL=$max_scroll
  (( UI_SCROLL < 0 )) && UI_SCROLL=0
  zcurses clear chat_win
  [[ "$UI_FOCUS" == chat ]] && zcurses attr chat_win bold yellow/black || zcurses attr chat_win dim white/black
  zcurses border chat_win
  zcurses move chat_win 0 2; zcurses attr chat_win bold cyan/black; zcurses string chat_win " Agent Transcript (${#UI_ROLES} events) "
  for (( row=1; row<=inner_h; row++ )); do
    idx=$(( UI_SCROLL + row ))
    (( idx <= total )) || continue
    zcurses move chat_win $row 1
    zcurses attr chat_win -bold -dim -reverse -underline default/default
    segment_count=${UI_LINE_SEGMENT_COUNTS[idx]:-0}
    if (( segment_count > 0 )); then
      segment_start=${UI_LINE_SEGMENT_STARTS[idx]}
      remaining=$inner_w
      for (( segment_index=segment_start; segment_index<segment_start+segment_count && remaining>0; segment_index++ )); do
        segment="${UI_SEGMENT_TEXTS[segment_index][1,$remaining]}"
        attr="${UI_SEGMENT_ATTRS[segment_index]}"
        zcurses attr chat_win -bold -dim -reverse -underline default/default
        zcurses attr chat_win $=attr
        zcurses string chat_win "$segment"
        (( remaining -= ${#segment} ))
      done
      if (( remaining > 0 )); then
        zcurses attr chat_win -bold -dim -reverse -underline default/default
        zcoder_pad "" "$remaining"
        zcurses string chat_win "$REPLY"
      fi
    else
      attr="${UI_ATTRS[idx]}"
      zcurses attr chat_win $=attr
      zcoder_pad "${UI_LINES[idx][1,$inner_w]}" "$inner_w"
      zcurses string chat_win "$REPLY"
    fi
  done
  (( UI_SCROLL > 0 )) && { zcurses move chat_win 0 $(( inner_w - 12 )); zcurses attr chat_win dim yellow/black; zcurses string chat_win " [PgUp/PgDn] "; }
  (( defer_refresh )) || zcurses refresh chat_win
}

ui_draw_input() {
  (( UI_ACTIVE )) || return 0
  local -i defer_refresh="${1:-0}"
  local -i max_rows=$(( INPUT_H - 2 )) row visual_row cursor_y cursor_x total
  local visible="" marker="" title=" Prompt (Enter sends · Shift-Enter newline) "
  ui_input_width
  input_layout "$REPLY" "$max_rows"
  total=${#INPUT_VISUAL_LINES}
  zcurses clear input_win
  [[ "$UI_FOCUS" == input ]] && zcurses attr input_win bold green/black || zcurses attr input_win dim white/black
  zcurses border input_win
  if (( total > INPUT_VISIBLE_ROWS )); then
    title=" Prompt (Enter sends · Shift-Enter newline · ${INPUT_VIEW_TOP}-$(( INPUT_VIEW_TOP + INPUT_VISIBLE_ROWS - 1 ))/${total}) "
  fi
  zcurses move input_win 0 2
  zcurses attr input_win bold white/black
  zcurses string input_win "${title[1,$(( SCREEN_W - 4 ))]}"
  for (( row=1; row<=INPUT_VISIBLE_ROWS; row++ )); do
    visual_row=$(( INPUT_VIEW_TOP + row - 1 ))
    visible="${INPUT_VISUAL_LINES[visual_row]}"
    marker="│"
    (( visual_row == 1 )) && marker="❯"
    (( row == 1 && INPUT_VIEW_TOP > 1 )) && marker="↑"
    (( row == INPUT_VISIBLE_ROWS && visual_row < total )) && marker="↓"
    zcurses move input_win $row 2
    zcurses attr input_win bold green/black
    zcurses string input_win "$marker "
    zcurses attr input_win white/black
    zcurses string input_win "$visible"
  done
  cursor_y=$(( INPUT_CURSOR_ROW - INPUT_VIEW_TOP + 1 ))
  cursor_x=$(( 4 + INPUT_CURSOR_COL ))
  (( cursor_y < 1 )) && cursor_y=1
  (( cursor_y > INPUT_VISIBLE_ROWS )) && cursor_y=$INPUT_VISIBLE_ROWS
  (( cursor_x < 4 )) && cursor_x=4
  (( cursor_x > SCREEN_W - 2 )) && cursor_x=$(( SCREEN_W - 2 ))
  zcurses move input_win $cursor_y $cursor_x
  (( defer_refresh )) || zcurses refresh input_win
}

# Rebuild only when the editor crosses a visual-row boundary. Keeping the
# footer anchored at the bottom makes each added prompt row grow upward.
ui_input_changed() {
  (( UI_ACTIVE )) || return 0
  local -i previous_height=$INPUT_H
  ui_calculate_input_height
  if (( INPUT_H != previous_height )); then
    ui_setup_windows
    ui_refresh_all
  else
    ui_draw_input
  fi
}

ui_draw_footer() {
  (( UI_ACTIVE )) || return 0
  local -i defer_refresh="${1:-0}"
  local text=" Enter Send  S/M-Enter Newline  ^Q Quit  Tab Sessions  ^Y Copy  Esc Stop  ^O Model  ^R Reason  ^N New  PgUp/Dn Scroll"
  text="${text[1,$SCREEN_W]}"
  zcurses clear foot_win; zcurses attr foot_win reverse dim white/black
  zcoder_pad "$text" "$SCREEN_W"; zcurses move foot_win 0 0; zcurses string foot_win "$REPLY"
  (( defer_refresh )) || zcurses refresh foot_win
}

ui_refresh_all() {
  (( UI_ACTIVE )) || return 0
  local -a windows=(top_win)
  ui_draw_header 1
  if (( SIDE_W > 0 )); then
    ui_draw_sidebar 1
    windows+=(side_win)
  fi
  ui_draw_chat 1
  ui_draw_input 1
  ui_draw_footer 1
  windows+=(chat_win input_win foot_win)
  # zcurses batches multiple windows into one physical terminal update. This
  # prevents users from seeing half-painted frames between tool events.
  zcurses refresh "${windows[@]}"
}

# Keep the terminal responsive while the Ollama request runs in its worker.
# Other editing keys are intentionally left alone; Escape is the generation
# cancellation key and scrolling remains available for the transcript.
ui_wait_for_generation() {
  local ch="" key="" mouse=""
  while ! http_async_ready; do
    ui_poll_resize
    ch=""; key=""; mouse=""
    zcurses timeout input_win 50
    zcurses input input_win ch key mouse
    if [[ "$key" == RESIZE ]]; then
      UI_RESIZE_PENDING=1
      ui_poll_resize
    elif [[ "$ch" == $'\x1b' ]]; then
      return 130
    elif [[ "$key" == PPAGE ]]; then
      UI_AUTO_SCROLL=0
      (( UI_SCROLL -= 6 )); (( UI_SCROLL < 0 )) && UI_SCROLL=0
      ui_draw_chat
    elif [[ "$key" == NPAGE ]]; then
      (( UI_SCROLL += 6 ))
      ui_draw_chat
    fi
  done
  return 0
}

# Poll one input event between short remote-event HTTP requests. Keeping this
# in the UI module preserves the remote transport's independence from curses.
ui_poll_remote_turn() {
  local ch="" key="" mouse=""
  ui_poll_resize
  zcurses timeout input_win 50
  zcurses input input_win ch key mouse
  if [[ "$key" == RESIZE ]]; then
    UI_RESIZE_PENDING=1
    ui_poll_resize
  elif [[ "$ch" == $'\x1b' ]]; then
    return 130
  elif [[ "$key" == PPAGE ]]; then
    UI_AUTO_SCROLL=0
    (( UI_SCROLL -= 6 )); (( UI_SCROLL < 0 )) && UI_SCROLL=0
    ui_draw_chat
  elif [[ "$key" == NPAGE ]]; then
    (( UI_SCROLL += 6 ))
    ui_draw_chat
  fi
  return 0
}

ui_wait_for_delegate() {
  local ch="" key="" mouse=""
  while ! delegate_async_ready; do
    delegate_async_timed_out && return 124
    ui_poll_resize
    ch=""; key=""; mouse=""
    zcurses timeout input_win 50
    zcurses input input_win ch key mouse
    if [[ "$key" == RESIZE ]]; then
      UI_RESIZE_PENDING=1
      ui_poll_resize
    elif [[ "$ch" == $'\x1b' ]]; then
      return 130
    elif [[ "$key" == PPAGE ]]; then
      UI_AUTO_SCROLL=0
      (( UI_SCROLL -= 6 )); (( UI_SCROLL < 0 )) && UI_SCROLL=0
      ui_draw_chat
    elif [[ "$key" == NPAGE ]]; then
      (( UI_SCROLL += 6 ))
      ui_draw_chat
    fi
  done
  return 0
}

ui_toggle_reasoning() {
  local -i i
  for (( i=${#UI_ROLES}; i>=1; i-- )); do
    if [[ "${UI_ROLES[i]}" == assistant && -n "${UI_THINKINGS[i]}" ]]; then
      UI_REASONING_OPEN[i]=$(( ! ${UI_REASONING_OPEN[i]:-0} ))
      (( UI_TRANSCRIPT_GENERATION++ ))
      break
    fi
  done
  (( $+functions[state_save_and_refresh] )) && state_save_and_refresh
  ui_draw_chat
}

_ui_modal_frame() {
  local window="$1" title="$2" color="${3:-cyan/black}"
  zcurses clear "$window"
  zcurses attr "$window" bold $=color
  zcurses border "$window"
  zcurses move "$window" 0 2
  zcurses attr "$window" bold white/black
  zcurses string "$window" " ${title} "
  zcurses attr "$window" default/default
}

ui_select_model() {
  local previous_status="$UI_STATUS" fetch_error=""
  local -a models=()
  ui_set_status "Loading models"
  ui_draw_header
  if ollama_get_models "$OLLAMA_HOST"; then
    models=("${OLLAMA_MODELS[@]}")
  else
    fetch_error="${HTTP_ERROR:-could not load models}"
  fi

  if (( ${#models} == 0 )); then
    ui_set_status "Error"
    ui_append_message error "Could not load Ollama models from ${OLLAMA_HOST}: ${fetch_error:-the server returned no models}"
    ui_refresh_all
    return 1
  fi

  local -i total=${#models} selected=1 i
  for (( i=1; i<=total; i++ )); do
    [[ "${models[i]}" == "$ZCODER_MODEL" ]] && { selected=$i; break; }
  done

  local -i modal_h=18 modal_w=72
  (( modal_h > SCREEN_H - 4 )) && modal_h=$(( SCREEN_H - 4 ))
  (( modal_w > SCREEN_W - 4 )) && modal_w=$(( SCREEN_W - 4 ))
  local -i modal_y=$(( (SCREEN_H - modal_h) / 2 )) modal_x=$(( (SCREEN_W - modal_w) / 2 ))
  local -i max_visible=$(( modal_h - 4 )) scroll_top=1 row
  (( max_visible < 1 )) && max_visible=1
  zcurses addwin model_win $modal_h $modal_w $modal_y $modal_x 2>/dev/null || {
    ui_set_status "$previous_status"
    return 1
  }

  local ch="" key="" mouse="" model="" display="" padded=""
  while true; do
    _ui_modal_frame model_win "Select Ollama Model (↑/↓, Enter, Esc)" "cyan/black"
    if (( selected < scroll_top )); then
      scroll_top=$selected
    elif (( selected >= scroll_top + max_visible )); then
      scroll_top=$(( selected - max_visible + 1 ))
    fi

    row=2
    for (( i=scroll_top; i<=total && i<scroll_top+max_visible; i++ )); do
      model="${models[i]}"
      display="  $model"
      [[ "$model" == "$ZCODER_MODEL" ]] && display="★ $model"
      display="${display[1,$(( modal_w - 4 ))]}"
      zcoder_pad "$display" $(( modal_w - 4 )); padded="$REPLY"
      zcurses move model_win $row 2
      if (( i == selected )); then
        zcurses attr model_win reverse bold cyan/black
        zcurses string model_win "$padded"
        zcurses attr model_win -reverse default/default
      else
        zcurses attr model_win white/black
        zcurses string model_win "$padded"
      fi
      (( row++ ))
    done

    zcurses move model_win $(( modal_h - 2 )) 2
    zcurses attr model_win dim white/black
    display="Model ${selected}/${total}  [${OLLAMA_HOST}]"
    zcurses string model_win "${display[1,$(( modal_w - 4 ))]}"
    zcurses refresh model_win

    ch=""; key=""; mouse=""
    zcurses timeout model_win -1
    zcurses input model_win ch key mouse
    if [[ "$key" == UP || "$ch" == k ]]; then
      (( selected > 1 )) && (( selected-- ))
    elif [[ "$key" == DOWN || "$ch" == j ]]; then
      (( selected < total )) && (( selected++ ))
    elif [[ "$key" == PPAGE ]]; then
      (( selected -= max_visible )); (( selected < 1 )) && selected=1
    elif [[ "$key" == NPAGE ]]; then
      (( selected += max_visible )); (( selected > total )) && selected=$total
    elif [[ "$ch" == $'\n' || "$ch" == $'\r' || "$key" == ENTER || "$key" == PADENTER ]]; then
      ZCODER_MODEL="${models[selected]}"
      ui_set_status "Ready"
      break
    elif [[ "$ch" == $'\x1b' || "$ch" == q || "$ch" == $'\x03' ]]; then
      ui_set_status "$previous_status"
      break
    fi
  done

  zcurses delwin model_win 2>/dev/null
  ui_refresh_all
  return 0
}

ui_mcp_servers() {
  local previous_status="$UI_STATUS" ch="" key="" mouse="" name="" display="" detail="" marker=""
  local -i selected=1 total=${#MCP_NAMES} i row modal_h=18 modal_w=82 max_visible scroll_top=1
  ui_set_status "Connecting MCP"
  ui_draw_header
  mcp_connect_all >/dev/null 2>&1 || true
  total=${#MCP_NAMES}
  (( modal_h > SCREEN_H - 4 )) && modal_h=$(( SCREEN_H - 4 ))
  (( modal_w > SCREEN_W - 4 )) && modal_w=$(( SCREEN_W - 4 ))
  (( modal_h < 8 )) && modal_h=8
  (( modal_w < 44 )) && modal_w=44
  local -i modal_y=$(( (SCREEN_H - modal_h) / 2 )) modal_x=$(( (SCREEN_W - modal_w) / 2 ))
  max_visible=$(( modal_h - 5 )); (( max_visible < 1 )) && max_visible=1
  zcurses addwin mcp_win $modal_h $modal_w $modal_y $modal_x 2>/dev/null || { ui_set_status "$previous_status"; return 1; }
  while true; do
    _ui_modal_frame mcp_win "MCP Servers (↑/↓, r Restart, Esc)" "cyan/black"
    if (( total == 0 )); then
      zcurses move mcp_win 3 3; zcurses attr mcp_win dim white/black
      zcurses string mcp_win "No MCP servers configured. Use: zcoder.zsh mcp add ..."
    else
      (( selected < scroll_top )) && scroll_top=$selected
      (( selected >= scroll_top + max_visible )) && scroll_top=$(( selected - max_visible + 1 ))
      row=2
      for (( i=scroll_top; i<=total && i<scroll_top+max_visible; i++ )); do
        name="${MCP_NAMES[i]}"
        case "${MCP_STATUS[$name]}" in connected) marker="●" ;; disabled) marker="○" ;; *) marker="!" ;; esac
        display="${marker} ${name} · ${MCP_STATUS[$name]} · ${MCP_TYPE[$name]} · ${MCP_SCOPE[$name]}"
        [[ -n "${MCP_PROTOCOL[$name]:-}" ]] && display+=" · ${MCP_PROTOCOL[$name]}"
        zcoder_pad "${display[1,$(( modal_w - 4 ))]}" $(( modal_w - 4 )); display="$REPLY"
        zcurses move mcp_win $row 2
        if (( i == selected )); then
          zcurses attr mcp_win reverse bold cyan/black; zcurses string mcp_win "$display"; zcurses attr mcp_win -reverse default/default
        else
          [[ "${MCP_STATUS[$name]}" == connected ]] && zcurses attr mcp_win green/black || zcurses attr mcp_win white/black
          zcurses string mcp_win "$display"
        fi
        (( row++ ))
      done
      name="${MCP_NAMES[selected]}"; detail="${MCP_DETAIL[$name]:-Ready to connect on first use}"
      zcurses move mcp_win $(( modal_h - 2 )) 2; zcurses attr mcp_win dim white/black
      zcurses string mcp_win "${detail[1,$(( modal_w - 4 ))]}"
    fi
    zcurses refresh mcp_win
    ch=""; key=""; mouse=""; zcurses timeout mcp_win -1; zcurses input mcp_win ch key mouse
    if [[ "$key" == UP || "$ch" == k ]]; then (( selected > 1 )) && (( selected-- ))
    elif [[ "$key" == DOWN || "$ch" == j ]]; then (( selected < total )) && (( selected++ ))
    elif [[ "$ch" == r && total -gt 0 ]]; then
      name="${MCP_NAMES[selected]}"; mcp_broker_stop "$name"; MCP_PROTOCOL[$name]=""; MCP_SERVER_TOOLS[$name]=""
      if (( ${MCP_ENABLED[$name]:-0} )); then
        MCP_STATUS[$name]="configured"
        if ! mcp_connect "$name"; then MCP_DETAIL[$name]="$MCP_ERROR"; fi
      else
        MCP_STATUS[$name]="disabled"; MCP_DETAIL[$name]=""
      fi
    elif [[ "$ch" == $'\x1b' || "$ch" == q || "$ch" == $'\x03' ]]; then break
    fi
  done
  zcurses delwin mcp_win 2>/dev/null
  ui_set_status "$previous_status"
  ui_refresh_all
}

ui_select_opencode_model() {
  local previous_status="$UI_STATUS" fetch_error=""
  local -a models=()
  local -i accepted=0
  ui_set_status "Loading OpenCode models"
  ui_draw_header
  if delegate_discover_opencode_models; then
    models=("${DELEGATE_MODELS[@]}")
  else
    fetch_error="${DELEGATE_ERROR:-could not load models}"
  fi

  if (( ${#models} == 0 )); then
    ui_set_status "Error"
    ui_append_message error "Could not load OpenCode models: ${fetch_error}"
    ui_refresh_all
    return 1
  fi

  local -i total=${#models} selected=1 i
  for (( i=1; i<=total; i++ )); do
    [[ "${models[i]}" == "$ZCODER_OPENCODE_MODEL" ]] && { selected=$i; break; }
  done

  local -i modal_h=18 modal_w=72
  (( modal_h > SCREEN_H - 4 )) && modal_h=$(( SCREEN_H - 4 ))
  (( modal_w > SCREEN_W - 4 )) && modal_w=$(( SCREEN_W - 4 ))
  local -i modal_y=$(( (SCREEN_H - modal_h) / 2 )) modal_x=$(( (SCREEN_W - modal_w) / 2 ))
  local -i max_visible=$(( modal_h - 4 )) scroll_top=1 row
  (( max_visible < 1 )) && max_visible=1
  zcurses addwin opencode_model_win $modal_h $modal_w $modal_y $modal_x 2>/dev/null || {
    ui_set_status "$previous_status"
    return 1
  }

  local ch="" key="" mouse="" model="" display="" padded=""
  while true; do
    _ui_modal_frame opencode_model_win "Select OpenCode Model (↑/↓, Enter, Esc)" "cyan/black"
    if (( selected < scroll_top )); then
      scroll_top=$selected
    elif (( selected >= scroll_top + max_visible )); then
      scroll_top=$(( selected - max_visible + 1 ))
    fi

    row=2
    for (( i=scroll_top; i<=total && i<scroll_top+max_visible; i++ )); do
      model="${models[i]}"
      display="  $model"
      [[ "$model" == "$ZCODER_OPENCODE_MODEL" ]] && display="★ $model"
      display="${display[1,$(( modal_w - 4 ))]}"
      zcoder_pad "$display" $(( modal_w - 4 )); padded="$REPLY"
      zcurses move opencode_model_win $row 2
      if (( i == selected )); then
        zcurses attr opencode_model_win reverse bold cyan/black
        zcurses string opencode_model_win "$padded"
        zcurses attr opencode_model_win -reverse default/default
      else
        zcurses attr opencode_model_win white/black
        zcurses string opencode_model_win "$padded"
      fi
      (( row++ ))
    done

    zcurses move opencode_model_win $(( modal_h - 2 )) 2
    zcurses attr opencode_model_win dim white/black
    display="Model ${selected}/${total}"
    zcurses string opencode_model_win "${display[1,$(( modal_w - 4 ))]}"
    zcurses refresh opencode_model_win

    ch=""; key=""; mouse=""
    zcurses timeout opencode_model_win -1
    zcurses input opencode_model_win ch key mouse
    if [[ "$key" == UP || "$ch" == k ]]; then
      (( selected > 1 )) && (( selected-- ))
    elif [[ "$key" == DOWN || "$ch" == j ]]; then
      (( selected < total )) && (( selected++ ))
    elif [[ "$key" == PPAGE ]]; then
      (( selected -= max_visible )); (( selected < 1 )) && selected=1
    elif [[ "$key" == NPAGE ]]; then
      (( selected += max_visible )); (( selected > total )) && selected=$total
    elif [[ "$ch" == $'\n' || "$ch" == $'\r' || "$key" == ENTER || "$key" == PADENTER ]]; then
      ZCODER_OPENCODE_MODEL="${models[selected]}"
      accepted=1
      ui_set_status "Ready"
      break
    elif [[ "$ch" == $'\x1b' || "$ch" == q || "$ch" == $'\x03' ]]; then
      ui_set_status "$previous_status"
      break
    fi
  done

  zcurses delwin opencode_model_win 2>/dev/null
  ui_refresh_all
  (( accepted ))
}

ui_confirm_command() {
  local command_text="$1" ch="" key="" mouse="" answer="n" line="" display_command=""
  local -a wrapped=()
  local -i per_command=0
  [[ "$ZCODER_PROFILE" == sysadmin ]] && per_command=1
  if (( ! UI_ACTIVE )); then
    if [[ -r /dev/tty && -w /dev/tty ]]; then
      zcoder_terminal_safe "$command_text"; display_command="$REPLY"
      print -r -- $'\n'"Command approval requested:" > /dev/tty
      print -r -- "  $display_command" > /dev/tty
      if (( per_command )); then
        print -rn -- "Allow this exact command once? [y/N]: " > /dev/tty
      else
        print -rn -- "Allow? [y] once / [a] session / [N] deny: " > /dev/tty
      fi
      read -r answer < /dev/tty
    fi
    REPLY="$answer"
    return 0
  fi

  local -i h=10 w=$(( SCREEN_W - 8 )) y x row=3
  (( w > 86 )) && w=86; (( w < 40 )) && w=$(( SCREEN_W - 2 ))
  (( h > SCREEN_H - 2 )) && h=$(( SCREEN_H - 2 ))
  y=$(( (SCREEN_H - h) / 2 )); x=$(( (SCREEN_W - w) / 2 ))
  zcurses addwin approval_win $h $w $y $x 2>/dev/null || { REPLY="n"; return 1; }
  zcurses clear approval_win; zcurses attr approval_win bold yellow/black; zcurses border approval_win
  zcurses move approval_win 0 2; zcurses attr approval_win bold white/black
  (( per_command )) && zcurses string approval_win " Sysadmin command approval " || zcurses string approval_win " Shell command approval "
  zcurses move approval_win 2 2; zcurses attr approval_win dim white/black; zcurses string approval_win "The model wants to run:"
  zcoder_wrap "$command_text" $(( w - 6 )); wrapped=("${ZCODER_WRAPPED[@]}")
  for line in "${wrapped[@]}"; do
    (( row >= h - 3 )) && break
    zcurses move approval_win $row 3; zcurses attr approval_win bold yellow/black; zcurses string approval_win "${line[1,$(( w - 6 ))]}"
    (( row++ ))
  done
  zcurses move approval_win $(( h - 2 )) 2; zcurses attr approval_win bold white/black
  if (( per_command )); then
    zcurses string approval_win "[y] Allow this exact command once   [n/Esc] Deny"
  else
    zcurses string approval_win "[y] Allow once   [a] Allow session   [n/Esc] Deny"
  fi
  zcurses refresh approval_win
  while true; do
    ch=""; key=""; mouse=""
    zcurses timeout approval_win -1
    zcurses input approval_win ch key mouse
    case "${(L)ch}" in
      y) answer="y"; break ;;
      a) (( per_command )) || { answer="a"; break; } ;;
      n|q|$'\x1b'|$'\x03') answer="n"; break ;;
    esac
  done
  zcurses delwin approval_win 2>/dev/null
  ui_refresh_all
  REPLY="$answer"
}
