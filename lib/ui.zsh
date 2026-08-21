# Adaptive curses interface for chat, tools, and prompt editing.

typeset -gi UI_ACTIVE=0
typeset -gi SCREEN_H=24 SCREEN_W=80 TOP_H=3 SIDE_W=24 INPUT_H=3 FOOT_H=1
typeset -gr INPUT_MAX_ROWS=4
typeset -gi UI_RESIZE_PENDING=0
typeset -gF UI_NEXT_RESIZE_CHECK=0.0
typeset -grF UI_RESIZE_CHECK_INTERVAL=0.25
typeset -g UI_STATUS="Ready"
typeset -gi UI_SCROLL=0 UI_AUTO_SCROLL=1
typeset -ga UI_ROLES=() UI_CONTENTS=() UI_THINKINGS=() UI_TIMES=() UI_REASONING_OPEN=()
typeset -ga UI_LINES=() UI_ATTRS=()

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
  local root="${ZCODER_WORKSPACE:t}" policy="$ZCODER_COMMAND_POLICY"
  zcurses clear side_win
  zcurses attr side_win dim white/black
  zcurses border side_win
  zcurses move side_win 0 2
  zcurses attr side_win bold cyan/black
  zcurses string side_win " Agent Workspace "
  zcurses move side_win 2 2; zcurses attr side_win bold white/black; zcurses string side_win "Project"
  zcurses move side_win 3 2; zcurses attr side_win green/black; zcurses string side_win "${root[1,20]}"
  zcurses move side_win 4 2; zcurses attr side_win dim cyan/black; zcurses string side_win "Instructions: ${#INSTRUCTION_SOURCES}"
  zcurses move side_win 5 2; zcurses attr side_win bold white/black; zcurses string side_win "Available tools"
  local -a names=(list_files read_file read_file_range write_file apply_patch search run_command finish)
  local -i row=6 i
  for (( i=1; i<=${#names}; i++ )); do
    zcurses move side_win $row 2
    [[ "${names[i]}" == run_command ]] && zcurses attr side_win yellow/black || zcurses attr side_win dim white/black
    zcurses string side_win "• ${names[i]}"
    (( row++ ))
  done
  zcurses move side_win $(( row + 1 )) 2; zcurses attr side_win bold white/black; zcurses string side_win "Shell approval"
  zcurses move side_win $(( row + 2 )) 2; zcurses attr side_win yellow/black; zcurses string side_win "$policy"
  (( defer_refresh )) || zcurses refresh side_win
}

_ui_add_line() { UI_LINES+=("$1"); UI_ATTRS+=("${2:-white/black}"); }

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

ui_render_messages() {
  local -i width=$1 count=${#UI_ROLES} i think_lines
  local role content thinking time attr title
  UI_LINES=(); UI_ATTRS=()
  if (( count == 0 )); then
    _ui_add_line "" default/default
    _ui_add_line "  👋 Welcome to zcoder.zsh" "bold cyan/black"
    _ui_add_line "" default/default
    _ui_add_line "  Ask for a change, investigation, or build. The model can inspect and edit" "dim white/black"
    _ui_add_line "  the workspace with tools. Shell commands always require your approval." "dim white/black"
    _ui_add_line "" default/default
    _ui_add_line "  /model NAME   switch model       /host HOST   switch Ollama server" "dim cyan/black"
    _ui_add_line "  /new          clear chat         /help        show shortcuts" "dim cyan/black"
    return 0
  fi
  for (( i=1; i<=count; i++ )); do
    role="${UI_ROLES[i]}"; content="${UI_CONTENTS[i]}"; thinking="${UI_THINKINGS[i]}"; time="${UI_TIMES[i]}"
    case "$role" in
      user) title="🧑 You  ${time}"; attr="green/black" ;;
      assistant) title="🤖 Assistant (${ZCODER_MODEL})  ${time}"; attr="white/black" ;;
      tool) title="⚙ Tool activity  ${time}"; attr="dim yellow/black" ;;
      error) title="⚠ Error  ${time}"; attr="red/black" ;;
      *) title="ℹ ${role}  ${time}"; attr="magenta/black" ;;
    esac
    _ui_add_line "$title" "bold $attr"
    if [[ -n "$thinking" ]]; then
      think_lines=${#${(f)thinking}}
      if (( ${UI_REASONING_OPEN[i]:-0} )); then
        _ui_add_line "  ▼ Reasoning (${think_lines} lines)" "bold magenta/black"
        _ui_add_wrapped "$thinking" "$width" "    " "dim magenta/black"
      else
        _ui_add_line "  ▶ Reasoning (${think_lines} lines) [^R to expand]" "dim magenta/black"
      fi
    fi
    _ui_add_wrapped "$content" "$width" "  " "$attr"
    _ui_add_line "" default/default
  done
}

ui_draw_chat() {
  (( UI_ACTIVE )) || return 0
  local -i defer_refresh="${1:-0}"
  local -i inner_w=$(( SCREEN_W - SIDE_W - 2 )) inner_h=$(( SCREEN_H - TOP_H - INPUT_H - FOOT_H - 2 ))
  local -i total row idx max_scroll
  local attr=""
  ui_render_messages "$inner_w"
  total=${#UI_LINES}; max_scroll=$(( total - inner_h )); (( max_scroll < 0 )) && max_scroll=0
  (( UI_AUTO_SCROLL )) && UI_SCROLL=$max_scroll
  (( UI_SCROLL > max_scroll )) && UI_SCROLL=$max_scroll
  (( UI_SCROLL < 0 )) && UI_SCROLL=0
  zcurses clear chat_win
  zcurses attr chat_win dim white/black
  zcurses border chat_win
  zcurses move chat_win 0 2; zcurses attr chat_win bold cyan/black; zcurses string chat_win " Agent Transcript (${#UI_ROLES} events) "
  for (( row=1; row<=inner_h; row++ )); do
    idx=$(( UI_SCROLL + row ))
    (( idx <= total )) || continue
    zcurses move chat_win $row 1
    zcurses attr chat_win -bold -dim -reverse -underline default/default
    attr="${UI_ATTRS[idx]}"
    zcurses attr chat_win $=attr
    zcoder_pad "${UI_LINES[idx][1,$inner_w]}" "$inner_w"
    zcurses string chat_win "$REPLY"
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
  zcurses attr input_win bold green/black; zcurses border input_win
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
  local text=" Enter Send  S/M-Enter Newline  Esc Stop  ^O Model  ^R Reason  ^N New  PgUp/Dn Scroll  ^Q Quit"
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

ui_toggle_reasoning() {
  local -i i
  for (( i=${#UI_ROLES}; i>=1; i-- )); do
    if [[ "${UI_ROLES[i]}" == assistant && -n "${UI_THINKINGS[i]}" ]]; then
      UI_REASONING_OPEN[i]=$(( ! ${UI_REASONING_OPEN[i]:-0} ))
      break
    fi
  done
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

ui_confirm_command() {
  local command_text="$1" ch="" key="" mouse="" answer="n" line=""
  local -a wrapped=()
  if (( ! UI_ACTIVE )); then
    if [[ -r /dev/tty && -w /dev/tty ]]; then
      print -r -- $'\n'"Command approval requested:" > /dev/tty
      print -r -- "  $command_text" > /dev/tty
      print -rn -- "Allow? [y] once / [a] session / [N] deny: " > /dev/tty
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
  zcurses move approval_win 0 2; zcurses attr approval_win bold white/black; zcurses string approval_win " Shell command approval "
  zcurses move approval_win 2 2; zcurses attr approval_win dim white/black; zcurses string approval_win "The model wants to run:"
  zcoder_wrap "$command_text" $(( w - 6 )); wrapped=("${ZCODER_WRAPPED[@]}")
  for line in "${wrapped[@]}"; do
    (( row >= h - 3 )) && break
    zcurses move approval_win $row 3; zcurses attr approval_win bold yellow/black; zcurses string approval_win "${line[1,$(( w - 6 ))]}"
    (( row++ ))
  done
  zcurses move approval_win $(( h - 2 )) 2; zcurses attr approval_win bold white/black
  zcurses string approval_win "[y] Allow once   [a] Allow session   [n/Esc] Deny"
  zcurses refresh approval_win
  while true; do
    ch=""; key=""; mouse=""
    zcurses timeout approval_win -1
    zcurses input approval_win ch key mouse
    case "${(L)ch}" in
      y) answer="y"; break ;;
      a) answer="a"; break ;;
      n|q|$'\x1b'|$'\x03') answer="n"; break ;;
    esac
  done
  zcurses delwin approval_win 2>/dev/null
  ui_refresh_all
  REPLY="$answer"
}
