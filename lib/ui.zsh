# Adaptive curses interface for chat, tools, and prompt editing.
(( ${+functions[zcoder_curses]} )) || source "${${(%):-%x}:A:h}/curses.zsh"
source "${${(%):-%x}:A:h}/drawing.zsh"
source "${${(%):-%x}:A:h}/ui_preferences.zsh"

typeset -gi UI_ACTIVE=0 UI_ACTIVITY_DEPTH=0
# 0: ordinary lifecycle; 1: retained zdraw session; 2: ended fallback session.
typeset -gi UI_SUSPENDED=0
typeset -gF UI_ACTIVITY_ESCAPE_AT=0.0
typeset -gi SCREEN_H=24 SCREEN_W=80 TOP_H=3 SIDE_W=24 INPUT_H=3 FOOT_H=1
typeset -gr INPUT_MAX_ROWS=4
typeset -gi UI_RESIZE_PENDING=0
# Keep the user's preference separate from automatic hiding on narrow terminals.
typeset -gi UI_SIDEBAR_HIDDEN=0
typeset -gi UI_SLASH_ROWS=0 UI_SLASH_SELECTED=1
# -1 probes older modules once, 0 uses stty, 1 uses native geometry.
typeset -gi UI_NATIVE_GEOMETRY=-1
typeset -gF UI_NEXT_RESIZE_CHECK=0.0
typeset -grF UI_RESIZE_CHECK_INTERVAL=0.25
typeset -g UI_STATUS="Ready"
typeset -g UI_STATUS_KIND=success UI_STATUS_DISPLAY='' UI_STATUS_ATTR='bold green/black'
typeset -g UI_NOTICE_TEXT='' UI_NOTICE_KIND=''
typeset -gF UI_STATUS_SINCE=0.0 UI_NOTICE_UNTIL=0.0
typeset -gi UI_NOTICE_GENERATION=0
typeset -g UI_GIT_DISPLAY='' UI_GIT_WORKSPACE=''
typeset -gF UI_NEXT_GIT_CHECK=0.0
typeset -gi UI_SCROLL=0 UI_AUTO_SCROLL=1
typeset -g UI_FOCUS="input"
# Rendering the whole transcript is linear in its size, so scrolling and tool
# events must not re-render unchanged content. Session switches bump the
# generation; block changes invalidate the layout from their position onward.
# Plain appends render only new messages. Selection reuses the cached layout.
typeset -g UI_RENDER_CACHE_KEY=""
typeset -gi UI_RENDER_COUNT=0
typeset -gi UI_REVEAL_SELECTED=0
typeset -ga UI_MESSAGE_STARTS=() UI_MESSAGE_SEGMENT_STARTS=()
typeset -ga UI_ASSISTANT_GROUPS=()
typeset -ga UI_LINES=() UI_ATTRS=()
typeset -ga UI_LINE_SEGMENT_STARTS=() UI_LINE_SEGMENT_COUNTS=()
typeset -ga UI_SEGMENT_TEXTS=() UI_SEGMENT_ATTRS=()
typeset -gA UI_WINDOW_KEYS=() UI_DIRTY_WINDOWS=() UI_PENDING_WINDOWS=()

# Cache each window's small input state, never a second terminal cell buffer.
# Transcript content is tracked by its existing generation/count/dirty cursor.
ui_invalidate() {
  local name=""
  local -a names=("$@")
  (( ${#names} )) || names=(header sidebar chat input footer)
  for name in "${names[@]}"; do UI_DIRTY_WINDOWS[$name]=1; done
}

_ui_window_key() {
  local -a fields=("$SCREEN_H" "$SCREEN_W" "$SIDE_W" "$INPUT_H" "$TOP_H" "$FOOT_H")
  case "$1" in
    header) fields+=("$UI_STATUS_DISPLAY" "$UI_STATUS_ATTR" "$UI_GIT_DISPLAY" "$ZCODER_NAME" "$ZCODER_VERSION" "$ZCODER_MODEL" "$OLLAMA_HOST" "$ZCODER_WORKSPACE" "${REMOTE_MODE:-local}" "$REMOTE_SERVER_NAME" "$REMOTE_ENDPOINT") ;;
    sidebar) fields+=("$UI_FOCUS" "$ZCODER_WORKSPACE" "$ZCODER_PROFILE" "$ZCODER_COMMAND_POLICY" "${TOOL_PATCH_RETRY_REQUIRED:-0}" "${#INSTRUCTION_SOURCES}" "$CURRENT_SESSION_ID"
      "${(j: :)${(@q)SESSION_IDS}}" "${(j: :)${(@q)SESSION_TITLES}}" "${(j: :)${(@q)SKILL_DISCOVERABLE_NAMES}}" "${(j: :)${(@q)SKILL_ACTIVE_NAMES}}") ;;
    chat) fields+=("$UI_FOCUS" "$UI_TRANSCRIPT_GENERATION" "${#UI_ROLES}" "$UI_RENDER_CACHE_KEY" "$ZCODER_MODEL" "$UI_SELECTED_EVENT" "$UI_SCROLL" "$UI_AUTO_SCROLL") ;;
    input) fields+=("$UI_FOCUS" "$INPUT_BUF" "$INPUT_POS" "$INPUT_VIEW_TOP" "$(( UI_ACTIVITY_DEPTH > 0 ))" "$UI_SLASH_ROWS" "$UI_SLASH_SELECTED" "${UI_SLASH_CACHE_KEY:-}") ;;
    footer) fields+=("$UI_FOCUS" "$(( UI_ACTIVITY_DEPTH > 0 ))") ;;
  esac
  # Quoting each field preserves boundaries even in multiline drafts/titles.
  REPLY="${(j: :)${(@q)fields}}"
}

_ui_draw_window() {
  local name="$1"
  local -i defer_refresh=${2:-0} dirty=${UI_DIRTY_WINDOWS[$1]:-0}
  (( UI_ACTIVE )) || return 0
  [[ "$name" == header ]] && ui_status_update
  [[ "$name" == sidebar ]] && (( SIDE_W == 0 )) && return 0
  # Background status changes must not paint over the active modal.
  (( ${UI_MODAL_ACTIVE:-0} )) && { UI_DIRTY_WINDOWS[$name]=1; return 0; }
  [[ "$name" == chat ]] && (( UI_RENDER_DIRTY_FROM > 0 || UI_REVEAL_SELECTED )) && dirty=1
  _ui_window_key "$name"
  if (( dirty )) || [[ "${UI_WINDOW_KEYS[$name]:-}" != "$REPLY" ]]; then
    "_ui_paint_${name}" 1
    _ui_window_key "$name"
    UI_WINDOW_KEYS[$name]="$REPLY"
    UI_DIRTY_WINDOWS[$name]=0
    UI_PENDING_WINDOWS[$name]=1
  fi
  (( defer_refresh )) || ui_flush
  return 0
}

ui_flush() {
  (( UI_ACTIVE && ! ${UI_MODAL_ACTIVE:-0} && ${#UI_PENDING_WINDOWS} )) || return 0
  local -a windows=()
  (( ${UI_PENDING_WINDOWS[header]:-0} )) && windows+=(top_win)
  (( ${UI_PENDING_WINDOWS[sidebar]:-0} && SIDE_W > 0 )) && windows+=(side_win)
  (( ${UI_PENDING_WINDOWS[chat]:-0} )) && windows+=(chat_win)
  (( ${UI_PENDING_WINDOWS[footer]:-0} )) && windows+=(foot_win)
  # Refreshing an unchanged input window restores its cursor without repainting
  # its contents. Keep it last in the one physical update.
  windows+=(input_win)
  terminal_refresh "${windows[@]}" || return $?
  UI_PENDING_WINDOWS=()
}

ui_draw_header() { _ui_draw_window header "${1:-0}"; }
ui_draw_sidebar() { _ui_draw_window sidebar "${1:-0}"; }
ui_draw_chat() { _ui_draw_window chat "${1:-0}"; }
ui_draw_input() { _ui_draw_window input "${1:-0}"; }
ui_draw_footer() { _ui_draw_window footer "${1:-0}"; }

# Keep the signal handler minimal. Geometry is queried and curses is rebuilt
# from the normal event loop, never asynchronously in the middle of a redraw.
TRAPWINCH() { UI_RESIZE_PENDING=1; }

# Existing local and remote status events share this presentation adapter.
# Only known activity states animate; arbitrary remote text remains plain data.
ui_set_status() {
  emulate -L zsh
  local kind=info value="$1"
  zcoder_terminal_safe "${value[1,256]}"; value="${REPLY//$'\n'/ }"
  case "${value:l}" in
    ready|'goal complete') kind=success ;;
    *error*|*failed*|denied*) kind=error ;;
    stopped|incomplete|*blocked*|*budget*|*paused*|*stopped*) kind=warning ;;
    thinking*|warming*|compacting*|'goal verifying'*|tool:*|connecting*|checking*|loading*|*' working'|*' consulting') kind=busy ;;
  esac
  [[ "$value" != "$UI_STATUS" || "$kind" != "$UI_STATUS_KIND" ]] && UI_STATUS_SINCE=$EPOCHREALTIME
  UI_STATUS="$value"; UI_STATUS_KIND="$kind"
  [[ "$kind" == error || "$kind" == warning ]] && ui_status_notice "$kind" "$value" 0
  return 0
}

# One bounded notice, with errors taking precedence over warnings. A brief
# generic status must not replace the detailed error already in the transcript.
ui_status_notice() {
  emulate -L zsh
  local kind="$1" value="$2"
  [[ "$kind" == error || "$kind" == warning ]] || return 1
  if (( EPOCHREALTIME < UI_NOTICE_UNTIL && UI_NOTICE_GENERATION == UI_TRANSCRIPT_GENERATION )); then
    [[ "$UI_NOTICE_KIND" == error && "$kind" == warning ]] && return 0
    [[ "$UI_NOTICE_KIND" == "$kind" && ${3:-1} == 0 ]] && return 0
  fi
  zcoder_terminal_safe "${value[1,256]}"
  UI_NOTICE_TEXT="${REPLY%%$'\n'*}"; UI_NOTICE_KIND="$kind"
  UI_NOTICE_UNTIL=$(( EPOCHREALTIME + 6.0 ))
  UI_NOTICE_GENERATION=$UI_TRANSCRIPT_GENERATION
}

ui_status_update() {
  emulate -L zsh
  ui_git_update
  local text="$UI_STATUS" kind="$UI_STATUS_KIND" extra=''
  local -i elapsed=0 frame=1 percent=0 ticks=0
  local -a frames=('|' '/' '-' $'\\')
  if (( EPOCHREALTIME >= UI_NOTICE_UNTIL || UI_NOTICE_GENERATION != UI_TRANSCRIPT_GENERATION )); then
    UI_NOTICE_TEXT=''; UI_NOTICE_KIND=''
  fi
  if [[ -n "$UI_NOTICE_TEXT" ]]; then
    text="$UI_NOTICE_TEXT"; kind="$UI_NOTICE_KIND"
  elif [[ "$kind" == busy ]]; then
    (( UI_STATUS_SINCE > 0 )) || UI_STATUS_SINCE=$EPOCHREALTIME
    elapsed=$(( EPOCHREALTIME - UI_STATUS_SINCE ))
    (( elapsed < 0 )) && elapsed=0
    if [[ ${ZCODER_ANIMATE:-true} != false ]]; then
      ticks=$(( (EPOCHREALTIME - UI_STATUS_SINCE) * 4 ))
      frame=$(( ticks % 4 + 1 ))
      (( frame < 1 )) && frame=1
      text="${frames[frame]} ${text} ${elapsed}s"
    else
      text="${text} ${elapsed}s"
    fi
  fi
  case "$kind" in
    error)
      [[ "$text" == Error || "$text" == Error:* ]] || text="Error: ${text}"
      UI_STATUS_ATTR='bold red/black' ;;
    warning)
      [[ "$text" == Warning:* ]] || text="Warning: ${text}"
      UI_STATUS_ATTR='bold yellow/black' ;;
    success) UI_STATUS_ATTR='bold green/black' ;;
    busy) UI_STATUS_ATTR='bold magenta/black' ;;
    *) UI_STATUS_ATTR='bold white/black' ;;
  esac
  # Display only local accounting here; remote servers do not expose these
  # counters. Add whole metadata fields only when there is room for them.
  if [[ "$kind" != error && "$kind" != warning && ${REMOTE_MODE:-local} != client ]] && (( SCREEN_W >= 100 )); then
    if (( ${AGENT_CONTEXT_WINDOW:-0} > 0 )); then
      percent=$(( 100.0 * ${AGENT_ESTIMATED_TOKENS:-0} / AGENT_CONTEXT_WINDOW ))
      extra=" ~${percent}% ctx"
      (( ${#text} + ${#extra} <= SCREEN_W / 2 - 6 )) && text+="$extra"
    fi
    case "${GOAL_STATUS:-none}" in
      active|verifying|paused|blocked|complete)
        extra=" goal:${GOAL_STATUS}"
        (( ${#text} + ${#extra} <= SCREEN_W / 2 - 6 )) && text+="$extra" ;;
    esac
  fi
  UI_STATUS_DISPLAY="$text"
}

# Poll only the tiny repository metadata once a second; the window key prevents
# unchanged results from repainting. Workspace switches bypass the timer.
ui_git_update() {
  emulate -L zsh
  if [[ "${REMOTE_MODE:-local}" == client ]]; then
    UI_GIT_DISPLAY="${REMOTE_GIT_STATUS:-Git: unavailable}"
    UI_GIT_WORKSPACE=''
  elif [[ "$UI_GIT_WORKSPACE" != "$ZCODER_WORKSPACE" ]] || (( EPOCHREALTIME >= UI_NEXT_GIT_CHECK )); then
    zcoder_git_status "$ZCODER_WORKSPACE"
    UI_GIT_DISPLAY="$REPLY"
    UI_GIT_WORKSPACE="$ZCODER_WORKSPACE"
    UI_NEXT_GIT_CHECK=$(( EPOCHREALTIME + 1.0 ))
  fi
}

ui_destroy_windows() {
  # delwin accepts exactly one window name. Passing the whole set leaves
  # names registered, so the next addwin fails during a resize.
  zcoder_curses delwin top_win 2>/dev/null || true
  zcoder_curses delwin side_win 2>/dev/null || true
  zcoder_curses delwin chat_win 2>/dev/null || true
  zcoder_curses delwin input_win 2>/dev/null || true
  zcoder_curses delwin foot_win 2>/dev/null || true
}

ui_input_width() {
  REPLY=$(( SCREEN_W - 6 ))
  (( REPLY < 1 )) && REPLY=1
}

ui_calculate_input_height() {
  (( $+functions[ui_slash_update] )) && ui_slash_update
  local -i max_rows=$INPUT_MAX_ROWS
  local -i available=$(( SCREEN_H - TOP_H - FOOT_H - 5 - UI_SLASH_ROWS ))
  (( available < 1 )) && available=1
  (( max_rows > available )) && max_rows=$available
  ui_input_width
  input_layout "$REPLY" "$max_rows"
  INPUT_H=$(( INPUT_VISIBLE_ROWS + UI_SLASH_ROWS + 2 ))
}

ui_setup_windows() {
  ui_destroy_windows
  UI_PENDING_WINDOWS=()
  ui_invalidate
  [[ "$UI_FOCUS" == chat ]] && UI_REVEAL_SELECTED=1
  local -a pos=()
  zcoder_curses position stdscr pos 2>/dev/null
  SCREEN_H=${pos[5]:-${LINES:-24}}
  SCREEN_W=${pos[6]:-${COLUMNS:-80}}
  (( UI_SIDEBAR_HIDDEN || SCREEN_W < 88 )) && SIDE_W=0 || SIDE_W=25
  (( SIDE_W == 0 )) && [[ "$UI_FOCUS" == sidebar ]] && UI_FOCUS=input
  ui_calculate_input_height
  local -i main_h=$(( SCREEN_H - TOP_H - INPUT_H - FOOT_H ))
  (( main_h < 3 )) && main_h=3
  local -i chat_w=$(( SCREEN_W - SIDE_W )) input_y=$(( TOP_H + main_h ))
  zcoder_curses addwin top_win $TOP_H $SCREEN_W 0 0 2>/dev/null
  (( SIDE_W > 0 )) && zcoder_curses addwin side_win $main_h $SIDE_W $TOP_H 0 2>/dev/null
  zcoder_curses addwin chat_win $main_h $chat_w $TOP_H $SIDE_W 2>/dev/null
  zcoder_curses addwin input_win $INPUT_H $SCREEN_W $input_y 0 2>/dev/null
  zcoder_curses addwin foot_win $FOOT_H $SCREEN_W $(( SCREEN_H - FOOT_H )) 0 2>/dev/null
  local window
  for window in top_win chat_win input_win foot_win; do ui_window_background "$window"; done
  (( SIDE_W > 0 )) && ui_window_background side_win
  return 0
}

ui_toggle_sidebar() {
  emulate -L zsh
  (( UI_ACTIVE && ! ${UI_MODAL_ACTIVE:-0} )) || return 0
  UI_SIDEBAR_HIDDEN=$(( ! UI_SIDEBAR_HIDDEN ))
  ui_setup_windows
  ui_preferences_save || ui_status_notice warning 'Could not save the sidebar preference.'
  ui_refresh_all
}

ui_detect_geometry() {
  emulate -L zsh
  # An enabled discovery parameter distinguishes compiled support from a
  # transient terminal-query failure. Older modules retain the one-time probe.
  UI_NATIVE_GEOMETRY=-1
  local -a reply=()
  if zcoder_curses_features; then
    UI_NATIVE_GEOMETRY=0
    (( ${reply[(Ie)geometry]} )) && UI_NATIVE_GEOMETRY=1
  fi
  return 0
}

ui_init() {
  # Curses otherwise waits about a second to distinguish Escape from a key
  # sequence. Scope the default to initialization; honor a user's longer wait
  # for slow terminal links without changing their shell environment.
  ESCDELAY=${ESCDELAY:-100} zcoder_curses init || return 1
  ui_preferences_load
  ui_detect_geometry
  ui_theme_init
  UI_ACTIVE=1
  terminal_start
  ui_setup_windows
  ui_refresh_all
}

ui_end() {
  (( UI_ACTIVE || UI_SUSPENDED )) || return 0
  (( $+functions[agent_context_discovery_cancel] )) && agent_context_discovery_cancel
  UI_ACTIVE=0
  # Suspended zdraw accepts end but rejects individual window mutations.
  (( UI_SUSPENDED )) || ui_destroy_windows
  UI_SUSPENDED=0
  terminal_end
  zcoder_curses end 2>/dev/null
  print -rn -- "${terminfo[cnorm]}" 2>/dev/null
}

ui_suspend() {
  emulate -L zsh
  local -i suspend_result
  (( UI_ACTIVE && ! UI_SUSPENDED && ! ${UI_MODAL_ACTIVE:-0} )) || return 1
  if terminal_suspend; then
    UI_SUSPENDED=1
    UI_ACTIVE=0
  else
    suspend_result=$?
    (( suspend_result == 2 )) || return "$suspend_result"
    ui_end
    UI_SUSPENDED=2
  fi
  return 0
}

ui_resume() {
  emulate -L zsh
  local -i rebuild_notice=0
  local -a dimensions=()
  (( UI_SUSPENDED )) || return 1
  if (( UI_SUSPENDED == 1 )); then
    if terminal_resume; then
      UI_SUSPENDED=0; UI_ACTIVE=1
      # zdraw already updated stdscr and repainted its retained frame. Rebuild
      # layout only if the dimensions changed; keep prepared rows and styles.
      if zcoder_curses position stdscr dimensions &&
         (( dimensions[5] != SCREEN_H || dimensions[6] != SCREEN_W )); then
        ui_setup_windows
      fi
      UI_RESIZE_PENDING=1
      ui_refresh_all
      return 0
    fi
    # A failed native restoration must not leave the event loop using a
    # suspended session. Release it and attempt the ordinary initialization path.
    ui_end
    rebuild_notice=1
  else
    UI_SUSPENDED=0
  fi
  if ! ui_init; then
    ui_end
    print -u2 -r -- 'Error: could not restore the terminal UI after copy view.'
    return 1
  fi
  UI_RESIZE_PENDING=1
  ui_poll_resize
  (( rebuild_notice )) && ui_status_notice warning 'Could not resume the retained UI; rebuilt the screen.'
  return 0
}

ui_poll_resize() {
  (( ${UI_ACTIVE:-0} && $+functions[agent_context_discovery_poll] )) && agent_context_discovery_poll
  # The existing idle/activity/modal loops drive notices and animation. Cached
  # header keys cap repainting at four frames per second during activity; an
  # idle screen stays still. Modal ownership continues to suppress underlays.
  (( UI_ACTIVE )) && ui_draw_header
  local -F now=$EPOCHREALTIME
  if (( ! UI_RESIZE_PENDING && now < UI_NEXT_RESIZE_CHECK )); then
    return 0
  fi
  UI_RESIZE_PENDING=0
  UI_NEXT_RESIZE_CHECK=$(( now + UI_RESIZE_CHECK_INTERVAL ))

  # Query the controlling terminal, not curses' cached window dimensions.
  # Advertised native support survives even a failed first query; retry on the
  # next poll. With older modules, a successful query selects the native path,
  # while an unsuccessful first probe selects stty until the next ui_init.
  local size=""
  local -a dimensions=()
  if (( UI_NATIVE_GEOMETRY != 0 )); then
    if zcoder_curses geometry dimensions 2>/dev/null; then
      UI_NATIVE_GEOMETRY=1
    elif (( UI_NATIVE_GEOMETRY == 1 )); then
      return 0
    else
      UI_NATIVE_GEOMETRY=0
    fi
  fi
  if (( UI_NATIVE_GEOMETRY == 0 )); then
    size="$(command stty size </dev/tty 2>/dev/null)" || return 0
    dimensions=(${=size})
  fi
  (( ${#dimensions} == 2 )) || return 0
  [[ "${dimensions[1]}" == <1-> && "${dimensions[2]}" == <1-> ]] || return 0
  local -i h=${dimensions[1]} w=${dimensions[2]}
  (( h > 0 && w > 0 )) || return 0
  (( h == SCREEN_H && w == SCREEN_W )) && return 0
  zcoder_curses resize "$h" "$w" endwin 2>/dev/null || return 0
  ui_setup_windows
  ui_refresh_all
}

_ui_paint_header() {
  (( UI_ACTIVE )) || return 0
  local -i defer_refresh="${1:-0}"
  local badge='' identity='' workspace="${ZCODER_WORKSPACE:t}" host="$OLLAMA_HOST"
  [[ "${REMOTE_MODE:-local}" == client ]] && host="${REMOTE_SERVER_NAME:-remote}@${REMOTE_ENDPOINT}"
  local -i badge_limit=$(( SCREEN_W / 2 - 4 ))
  (( badge_limit < 1 )) && badge_limit=1
  zcoder_clip "$UI_STATUS_DISPLAY" "$badge_limit"; badge="$REPLY"
  if (( ${(m)#UI_STATUS_DISPLAY} > badge_limit )); then
    zcoder_clip "$badge" $(( badge_limit - 1 )); badge="${REPLY}…"
  fi
  badge="[ ${badge} ]"
  local -i badge_x=$(( SCREEN_W - ${(m)#badge} - 2 ))
  local -i identity_limit=$(( badge_x - 3 ))
  local -i section=1
  local -a identities=("⚡ ${ZCODER_NAME} v${ZCODER_VERSION} │ " "$ZCODER_MODEL" " @ ${host} │ ${workspace}")
  local -a identity_attrs=('bold cyan/black' 'bold yellow/black' 'dim white/black')
  zcoder_curses clear top_win
  ui_attr top_win -dim -bold border/surface
  ui_border top_win
  zcoder_curses move top_win 1 2
  for identity in "${identities[@]}"; do
    (( identity_limit > 0 )) || break
    zcoder_terminal_safe "$identity"; identity="${REPLY//$'\n'/ }"
    zcoder_clip "$identity" "$identity_limit"; identity="$REPLY"
    ui_attr top_win -bold -dim $=identity_attrs[section]
    zcoder_curses string top_win "$identity"
    (( identity_limit -= ${(m)#identity}, section++ ))
  done
  if (( badge_x >= 2 )); then
    zcoder_curses move top_win 1 $badge_x
    ui_attr top_win -bold -dim $=UI_STATUS_ATTR
    zcoder_curses string top_win "$badge"
  fi
  # The lower border keeps workspace context visible without taking a chat row
  # or competing with the model identity and foreground activity above it.
  local git_label='' git_attr='bold green/black'
  local -i git_limit=$(( SCREEN_W - 6 ))
  if (( git_limit > 0 )); then
    [[ "$UI_GIT_DISPLAY" == 'No Git' || "$UI_GIT_DISPLAY" == 'Git: unavailable' ]] && git_attr='dim white/black'
    [[ "$UI_GIT_DISPLAY" == 'Git: detached '* ]] && git_attr='bold yellow/black'
    zcoder_terminal_safe "$UI_GIT_DISPLAY"; git_label="${REPLY//$'\n'/ }"
    if (( ${(m)#git_label} > git_limit )); then
      zcoder_clip "$git_label" $(( git_limit - 1 )); git_label="${REPLY}…"
    fi
    zcoder_curses move top_win 2 2
    ui_attr top_win -bold -dim $=git_attr
    zcoder_curses string top_win " ${git_label} "
  fi
  (( defer_refresh )) || terminal_refresh top_win
}

_ui_paint_sidebar() {
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

  zcoder_curses clear side_win
  [[ "$UI_FOCUS" == sidebar ]] && ui_attr side_win -dim bold accent/surface || ui_attr side_win -dim -bold border/surface
  ui_border side_win
  zcoder_curses move side_win 0 2
  ui_attr side_win bold cyan/black
  zcoder_curses string side_win " Sessions (${#SESSION_IDS}) "

  row=1
  for (( i=session_start; i<=${#SESSION_IDS} && row<=session_rows; i++ )); do
    session_id="${SESSION_IDS[i]}"
    title="${SESSION_TITLES[i]:-Untitled}"
    display="$title"
    zcoder_pad "$display" $(( inner_w - 4 )); display="$REPLY"
    zcoder_curses move side_win $row 1
    if [[ "$session_id" == "$CURRENT_SESSION_ID" ]]; then
      ui_attr side_win bold green/black
      zcoder_curses string side_win " ▶ $display"
    else
      ui_attr side_win dim white/black
      zcoder_curses string side_win "   $display"
    fi
    (( row++ ))
  done

  divider="${(pl:inner_w::─:)}"
  if (( divider_row <= inner_h )); then
    zcoder_curses move side_win $divider_row 1
    ui_attr side_win dim cyan/black
    zcoder_curses string side_win "$divider"
  fi
  row=$(( divider_row + 1 ))
  if (( row <= inner_h )); then zcoder_curses move side_win $row 2; ui_attr side_win bold white/black; zcoder_curses string side_win "Project"; fi
  (( row++ ))
  if (( row <= inner_h )); then zcoder_curses move side_win $row 2; ui_attr side_win green/black; zcoder_clip "$root" $(( inner_w - 1 )); zcoder_curses string side_win "$REPLY"; fi
  (( row++ ))
  if (( row <= inner_h )); then zcoder_curses move side_win $row 2; ui_attr side_win dim cyan/black; zcoder_curses string side_win "${ZCODER_PROFILE} · Guides: ${#INSTRUCTION_SOURCES}"; fi
  (( row++ ))
  if (( row <= inner_h )); then zcoder_curses move side_win $row 2; ui_attr side_win bold white/black; zcoder_curses string side_win "Available tools"; fi
  (( row++ ))
  for (( i=1; i<=${#names}; i++ )); do
    (( row > inner_h )) && break
    zcoder_curses move side_win $row 2
    [[ "${names[i]}" == run_command ]] && ui_attr side_win yellow/black || ui_attr side_win dim white/black
    zcoder_curses string side_win "• ${names[i]}"
    (( row++ ))
  done
  if (( row <= inner_h )); then zcoder_curses move side_win $row 2; ui_attr side_win bold white/black; zcoder_curses string side_win "Shell approval"; fi
  (( row++ ))
  if (( row <= inner_h )); then zcoder_curses move side_win $row 2; ui_attr side_win yellow/black; zcoder_curses string side_win "$policy"; fi
  (( defer_refresh )) || terminal_refresh side_win
}

# Consecutive assistant responses and their tools share a visual conversation
# block. Keep event IDs and storage intact for streaming, replay, and selection.
# The previous owner is passed in so full and incremental rendering stay linear.
_ui_assistant_group() {
  emulate -L zsh
  local -i index=$1 previous=${2:-0}
  case "${UI_ROLES[index]}" in
    assistant) REPLY=$(( previous > 0 ? previous : index )) ;;
    tool) REPLY=$previous ;;
    *) REPLY=0 ;;
  esac
}

ui_plain_transcript() {
  local output="" label="" role="" content="" thinking="" time=""
  local -i i group=0 continuation=0
  for (( i=1; i<=${#UI_ROLES}; i++ )); do
    _ui_assistant_group "$i" "$group"; group=$REPLY
    continuation=$(( group > 0 && group != i ))
    (( continuation && ! ${UI_BLOCK_OPEN[group]:-1} )) && continue
    role="${UI_ROLES[i]}"
    content="${UI_CONTENTS[i]}"
    thinking="${UI_THINKINGS[i]}"
    time="${UI_TIMES[i]}"
    case "$role" in
      user) label="You" ;;
      assistant) label="Assistant" ;;
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
    if [[ "$role" == tool && -n "${UI_TOOL_NAMES[i]:-}" ]]; then
      label+=" · ${UI_TOOL_SUMMARIES[i]:-${UI_TOOL_NAMES[i]}} · ${UI_TOOL_STATES[i]}"
      if [[ "${UI_BLOCK_OPEN[i]:-1}" == 1 ]]; then
        if [[ ( "${UI_TOOL_NAMES[i]}" == write_file || "${UI_TOOL_NAMES[i]}" == apply_patch ) &&
              ( "${UI_TOOL_STATES[i]}" == completed || "${UI_TOOL_STATES[i]}" == failed ) ]]; then
          : # The stored preview includes the edit and its outcome.
        else
          content=$'Arguments:\n'"${UI_TOOL_ARGS[i]}"$'\n\nResult:\n'"${UI_TOOL_RESULTS[i]:-(No result yet.)}"
        fi
      fi
    fi
    [[ -n "$output" ]] && output+=$'\n'
    if [[ "$role" != assistant ]] || (( ! continuation )); then
      output+="=== ${label}${time:+  ${time}} ==="$'\n'
    fi
    if (( group == i && ! ${UI_BLOCK_OPEN[i]:-1} )); then
      output+=$'[collapsed]\n'
      continue
    fi
    if [[ -n "$thinking" ]] && (( ${UI_REASONING_OPEN[i]:-0} )); then
      output+=$'Reasoning:\n'"$thinking"$'\n\n'
    fi
    if [[ "$role" != assistant && "${UI_BLOCK_OPEN[i]:-1}" == 0 ]]; then
      output+=$'[collapsed]\n'
    elif [[ -n "$content" ]]; then
      output+="$content"$'\n'
    fi
  done
  [[ -n "$output" ]] || output="(No transcript events yet.)"$'\n'
  REPLY="$output"
}

# Leave curses temporarily and print a stable plain-text transcript. While the
# screen is not being repainted, the terminal's native mouse selection and
# clipboard shortcuts work normally without adding a clipboard dependency.
ui_copy_view() {
  emulate -L zsh
  setopt localtraps
  local transcript=""
  local -i copy_result=0 restore_result=0 copy_interrupted=0
  # Zsh can run always before EXIT cleanup. Release ownership first on exit
  # signals so restoration cannot briefly reopen the screen during shutdown.
  # The foreground helper temporarily replaces INT with its return-to-UI trap.
  trap 'ui_end; exit 130' INT
  trap 'ui_end; exit 143' TERM
  trap 'ui_end; exit 129' HUP
  (( UI_ACTIVE )) || return 1
  (( $+functions[state_save_session] )) && state_save_session
  ui_plain_transcript
  transcript="$REPLY"
  zcoder_terminal_safe "$transcript"; transcript="$REPLY"
  if ! ui_suspend; then
    ui_status_notice warning 'Could not release the terminal for copy view.'
    return 1
  fi
  {
    _ui_copy_transcript "$transcript"
    copy_result=$?
    (( copy_interrupted )) && copy_result=130
  } always {
    # Exit cleanup clears UI_SUSPENDED: never reopen a terminating session.
    if (( UI_SUSPENDED )); then
      ui_resume || restore_result=$?
    fi
  }
  (( restore_result == 0 )) || return "$restore_result"
  return "$copy_result"
}

# A fixed internal foreground action; no command string or model tool is run.
_ui_copy_transcript() {
  emulate -L zsh
  setopt localtraps
  local ignored=''
  local -i read_result=0
  # The caller owns this flag: an interrupted read can return 1 even when the
  # trap returns 130, and can leave this helper before its following commands.
  trap 'copy_interrupted=1; return 130' INT
  {
    print -rn -- $'\e[2J\e[H'
    print -r -- "zcoder.zsh transcript copy view"
    print -r -- "Select text with the terminal mouse and use its normal copy shortcut. Scroll as needed."
    print -r -- "Press Enter or Ctrl-C when finished to return to zcoder."
    print -r -- ""
    print -r -- "$1"
    print -r -- ""
    print -rn -- "Press Enter to return: "
  } > /dev/tty || return 1
  (( copy_interrupted )) && return 130
  IFS= read -r ignored < /dev/tty
  read_result=$?
  (( copy_interrupted )) && return 130
  return "$read_result"
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

# Both preview renderers use the same cell boundaries as the editor.
_ui_add_hard_wrapped() {
  local content="$1" prefix="${3:-  }" attr="${4:-white/black}" line=""
  local -i available=$(( $2 - ${(m)#prefix} ))
  (( available < 1 )) && available=1
  zcoder_hard_wrap "$content" "$available"
  local -a lines=("${ZCODER_WRAPPED[@]}")
  for line in "${lines[@]}"; do _ui_add_line "${prefix}${line}" "$attr"; done
}

_ui_add_syntax_wrapped() {
  local content="$1" prefix="${3:-  }" language="${4:-plain}" line=""
  local -i available=$(( $2 - ${(m)#prefix} ))
  (( available < 1 )) && available=1
  zcoder_hard_wrap "$content" "$available"
  local -a lines=("${ZCODER_WRAPPED[@]}")
  for line in "${lines[@]}"; do _ui_add_syntax_line "$line" "$language" "$prefix"; done
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
    zcoder_wrap "$line" $(( width - ${(m)#prefix} ))
    for wrapped in "${ZCODER_WRAPPED[@]}"; do
      _ui_add_line "${prefix}${wrapped}" "$attr"
    done
  done
}

_ui_render_one_message() {
  local -i i=$1 width=$2 think_lines group continuation
  local role content thinking time attr title tool_attr="bold yellow/black"
  local -a thinking_lines=()
  UI_MESSAGE_STARTS[i]=$(( ${#UI_LINES} + 1 ))
  UI_MESSAGE_SEGMENT_STARTS[i]=$(( ${#UI_SEGMENT_TEXTS} + 1 ))
  _ui_assistant_group "$i" "${UI_ASSISTANT_GROUPS[i-1]:-0}"
  group=$REPLY; UI_ASSISTANT_GROUPS[i]=$group
  continuation=$(( group > 0 && group != i ))
  (( continuation && ! ${UI_BLOCK_OPEN[group]:-1} )) && return 0
  role="${UI_ROLES[i]}"; content="${UI_CONTENTS[i]}"; thinking="${UI_THINKINGS[i]}"; time="${UI_TIMES[i]}"
  case "$role" in
    user) title="🧑 You  ${time}"; attr="green/black" ;;
    assistant) title="🤖 Assistant  ${time}"; attr="white/black" ;;
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
  (( i == UI_STREAM_INDEX )) && title+=" · receiving"
  if [[ "$role" == tool && -n "${UI_TOOL_NAMES[i]:-}" ]]; then
    title="${UI_TOOL_SUMMARIES[i]:-${UI_TOOL_NAMES[i]}} · ${UI_TOOL_STATES[i]}  ${time}"
    zcoder_terminal_safe "$title"; title="$REPLY"
    case "${UI_TOOL_STATES[i]}" in
      completed) tool_attr="bold green/black" ;;
      failed) tool_attr="bold red/black" ;;
      running) tool_attr="bold cyan/black" ;;
    esac
  fi
  if [[ -n "$content" || "$role" == assistant ]]; then
    [[ "${UI_BLOCK_OPEN[i]:-1}" == 0 ]] && title="▶ ${title}" || title="▼ ${title}"
  fi
  if [[ "$role" == tool ]]; then
    (( continuation )) && title="  ${title}"
    _ui_add_line "$title" "$tool_attr"
  elif (( ! continuation )); then
    _ui_add_line "$title" "bold $attr"
  elif (( i == UI_STREAM_INDEX )); then
    _ui_add_line "  receiving · ${time}" "dim $attr"
  fi
  if (( group == i && ! ${UI_BLOCK_OPEN[i]:-1} )); then
    _ui_add_line "" default/default
    return 0
  fi
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
  if [[ "$role" != assistant && "${UI_BLOCK_OPEN[i]:-1}" == 0 ]]; then
    : # Keep the role and independently foldable reasoning visible.
  elif [[ "$role" == tool && -n "${UI_TOOL_NAMES[i]:-}" ]]; then
    if [[ ( "${UI_TOOL_NAMES[i]}" == write_file || "${UI_TOOL_NAMES[i]}" == apply_patch ) &&
          ( "${UI_TOOL_STATES[i]}" == completed || "${UI_TOOL_STATES[i]}" == failed ) ]]; then
      zcoder_terminal_safe "$content"
      _ui_add_tool_content "$REPLY" "$width"
    else
      _ui_add_line "  Arguments" "dim cyan/black"
      zcoder_terminal_safe "${UI_TOOL_ARGS[i]}"
      _ui_add_wrapped "$REPLY" "$width" "    " "dim white/black"
      _ui_add_line "  Result" "dim cyan/black"
      zcoder_terminal_safe "${UI_TOOL_RESULTS[i]:-(No result yet.)}"
      _ui_add_wrapped "$REPLY" "$width" "    " "white/black"
    fi
  elif [[ "$role" == tool ]]; then
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
  UI_MESSAGE_STARTS=(); UI_MESSAGE_SEGMENT_STARTS=()
  UI_ASSISTANT_GROUPS=()
  UI_RENDER_DIRTY_FROM=0
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

_ui_paint_chat() {
  (( UI_ACTIVE )) || return 0
  local -i defer_refresh="${1:-0}"
  local -i inner_w=$(( SCREEN_W - SIDE_W - 2 )) inner_h=$(( SCREEN_H - TOP_H - INPUT_H - FOOT_H - 2 ))
  local -i total row idx max_scroll segment_start segment_count segment_index
  local attr="" padding="${(pl:inner_w:: :)}" cache_key="${UI_TRANSCRIPT_GENERATION}:${inner_w}:${ZCODER_MODEL}"
  local -a row_spans=()
  local -i message_count=${#UI_ROLES} render_index
  if [[ "$cache_key" != "$UI_RENDER_CACHE_KEY" ]] || \
     (( message_count < UI_RENDER_COUNT )) || (( UI_RENDER_COUNT == 0 && message_count > 0 )); then
    ui_render_messages "$inner_w"
  else
    if (( UI_RENDER_DIRTY_FROM > 0 && UI_RENDER_DIRTY_FROM <= UI_RENDER_COUNT )); then
      local -i keep_lines=$(( UI_MESSAGE_STARTS[UI_RENDER_DIRTY_FROM] - 1 ))
      local -i keep_segments=$(( UI_MESSAGE_SEGMENT_STARTS[UI_RENDER_DIRTY_FROM] - 1 ))
      UI_LINES=("${(@)UI_LINES[1,keep_lines]}"); UI_ATTRS=("${(@)UI_ATTRS[1,keep_lines]}")
      UI_LINE_SEGMENT_STARTS=("${(@)UI_LINE_SEGMENT_STARTS[1,keep_lines]}")
      UI_LINE_SEGMENT_COUNTS=("${(@)UI_LINE_SEGMENT_COUNTS[1,keep_lines]}")
      UI_SEGMENT_TEXTS=("${(@)UI_SEGMENT_TEXTS[1,keep_segments]}")
      UI_SEGMENT_ATTRS=("${(@)UI_SEGMENT_ATTRS[1,keep_segments]}")
      UI_RENDER_COUNT=$(( UI_RENDER_DIRTY_FROM - 1 ))
    fi
    for (( render_index=UI_RENDER_COUNT+1; render_index<=message_count; render_index++ )); do
      _ui_render_one_message "$render_index" "$inner_w"
    done
    UI_RENDER_COUNT=$message_count
    UI_RENDER_DIRTY_FROM=0
  fi
  UI_RENDER_DIRTY_FROM=0
  total=${#UI_LINES}; max_scroll=$(( total - inner_h )); (( max_scroll < 0 )) && max_scroll=0
  (( UI_AUTO_SCROLL )) && UI_SCROLL=$max_scroll
  if [[ "$UI_FOCUS" == chat ]] && (( message_count > 0 )); then
    (( UI_SELECTED_EVENT > 0 && UI_SELECTED_EVENT <= message_count )) || UI_SELECTED_EVENT=$message_count
    local -i selected_group=${UI_ASSISTANT_GROUPS[UI_SELECTED_EVENT]:-0}
    if (( selected_group > 0 && ! ${UI_BLOCK_OPEN[selected_group]:-1} )); then
      UI_SELECTED_EVENT=$selected_group
    fi
    if (( UI_REVEAL_SELECTED )); then
      local -i selected_line=${UI_MESSAGE_STARTS[UI_SELECTED_EVENT]:-1}
      if (( selected_line <= UI_SCROLL )); then
        UI_SCROLL=$(( selected_line - 1 ))
      elif (( selected_line > UI_SCROLL + inner_h )); then
        UI_SCROLL=$(( selected_line - inner_h ))
      fi
    fi
  fi
  UI_REVEAL_SELECTED=0
  (( UI_SCROLL > max_scroll )) && UI_SCROLL=$max_scroll
  (( UI_SCROLL < 0 )) && UI_SCROLL=0
  zcoder_curses clear chat_win
  [[ "$UI_FOCUS" == chat ]] && ui_attr chat_win -dim bold accent/surface || ui_attr chat_win -dim -bold border/surface
  ui_border chat_win
  zcoder_curses move chat_win 0 2; ui_attr chat_win bold cyan/black; zcoder_curses string chat_win " Agent Transcript (${#UI_ROLES} events) "
  for (( row=1; row<=inner_h; row++ )); do
    idx=$(( UI_SCROLL + row ))
    (( idx <= total )) || continue
    row_spans=()
    segment_count=${UI_LINE_SEGMENT_COUNTS[idx]:-0}
    if (( segment_count > 0 )); then
      segment_start=${UI_LINE_SEGMENT_STARTS[idx]}
      for (( segment_index=segment_start; segment_index<segment_start+segment_count; segment_index++ )); do
        row_spans+=("${UI_SEGMENT_ATTRS[segment_index]}" "${UI_SEGMENT_TEXTS[segment_index]}")
      done
      row_spans+=("default/default" "$padding")
    else
      attr="${UI_ATTRS[idx]}"
      if [[ "$UI_FOCUS" == chat ]] && (( UI_SELECTED_EVENT > 0 && idx == ${UI_MESSAGE_STARTS[UI_SELECTED_EVENT]:-0} )); then
        attr="${attr} reverse bold"
      fi
      row_spans+=("$attr" "${UI_LINES[idx]}$padding")
    fi
    (( ${#row_spans} )) && ui_draw_row chat_win "$row" 1 "$inner_w" "${row_spans[@]}"
  done
  (( UI_SCROLL > 0 )) && { zcoder_curses move chat_win 0 $(( inner_w - 12 )); ui_attr chat_win dim yellow/black; zcoder_curses string chat_win " [PgUp/PgDn] "; }
  (( defer_refresh )) || terminal_refresh chat_win
}

_ui_paint_input() {
  (( UI_ACTIVE )) || return 0
  local -i defer_refresh="${1:-0}"
  local -i max_rows=$(( INPUT_H - UI_SLASH_ROWS - 2 )) row visual_row cursor_y cursor_x total
  local visible="" marker="" title=" Prompt (Enter sends · Shift-Enter newline) "
  ui_input_width
  input_layout "$REPLY" "$max_rows"
  if (( UI_ACTIVITY_DEPTH > 0 )); then
    title=" Draft (send after activity finishes) "
    [[ -n "${INPUT_QUEUE_TURN_ID:-}${REMOTE_INPUT_TURN_ID:-}" ]] && title=" Prompt (Enter: steer · Ctrl+G: follow-up) "
  fi
  total=${#INPUT_VISUAL_LINES}
  zcoder_curses clear input_win
  [[ "$UI_FOCUS" == input ]] && ui_attr input_win -dim bold accent/surface || ui_attr input_win -dim -bold border/surface
  ui_border input_win
  if (( total > INPUT_VISIBLE_ROWS && UI_ACTIVITY_DEPTH == 0 )); then
    title=" Prompt (Enter sends · Shift-Enter newline · ${INPUT_VIEW_TOP}-$(( INPUT_VIEW_TOP + INPUT_VISIBLE_ROWS - 1 ))/${total}) "
  fi
  (( UI_SLASH_ROWS > 0 )) && title=" Prompt (slash commands) "
  zcoder_curses move input_win 0 2
  ui_attr input_win bold white/black
  zcoder_clip "$title" $(( SCREEN_W - 4 )); zcoder_curses string input_win "$REPLY"
  for (( row=1; row<=INPUT_VISIBLE_ROWS; row++ )); do
    visual_row=$(( INPUT_VIEW_TOP + row - 1 ))
    visible="${INPUT_VISUAL_LINES[visual_row]}"
    marker="│"
    (( visual_row == 1 )) && marker="❯"
    (( row == 1 && INPUT_VIEW_TOP > 1 )) && marker="↑"
    (( row == INPUT_VISIBLE_ROWS && visual_row < total )) && marker="↓"
    zcoder_curses move input_win $row 2
    ui_attr input_win bold green/black
    zcoder_curses string input_win "$marker "
    ui_attr input_win white/black
    zcoder_curses string input_win "$visible"
  done
  (( UI_SLASH_ROWS > 0 )) && ui_slash_draw
  cursor_y=$(( INPUT_CURSOR_ROW - INPUT_VIEW_TOP + 1 ))
  cursor_x=$(( 4 + INPUT_CURSOR_COL ))
  (( cursor_y < 1 )) && cursor_y=1
  (( cursor_y > INPUT_VISIBLE_ROWS )) && cursor_y=$INPUT_VISIBLE_ROWS
  (( cursor_x < 4 )) && cursor_x=4
  (( cursor_x > SCREEN_W - 2 )) && cursor_x=$(( SCREEN_W - 2 ))
  zcoder_curses move input_win $cursor_y $cursor_x
  (( defer_refresh )) || terminal_refresh input_win
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

_ui_paint_footer() {
  (( UI_ACTIVE )) || return 0
  local -i defer_refresh="${1:-0}"
  local text=" ^P Commands  ^B Sidebar  Enter Send  S/M-Enter Newline  ^Q Quit  Tab Focus  ^Y Copy  Esc Stop  ^O Model  ^R Reason  PgUp/Dn Scroll"
  [[ "$UI_FOCUS" == chat ]] && text=" ^P Commands  ^B Sidebar  ↑/↓ Select  Enter/Space Fold  ^R Reasoning  Home/End First/Last  PgUp/Dn Scroll  Tab Prompt  ^Y Copy"
  (( UI_ACTIVITY_DEPTH > 0 )) && text=" Esc Stop  ^B Sidebar  Tab Prompt/Transcript  ↑/↓ Navigate  Enter Fold in Transcript  ^R Reasoning  PgUp/Dn Scroll"
  zcoder_clip "$text" "$SCREEN_W"; text="$REPLY"
  zcoder_curses clear foot_win; ui_attr foot_win reverse dim white/black
  zcoder_pad "$text" "$SCREEN_W"; zcoder_curses move foot_win 0 0; zcoder_curses string foot_win "$REPLY"
  (( defer_refresh )) || terminal_refresh foot_win
}

ui_refresh_all() {
  (( UI_ACTIVE )) || return 0
  # Focus and activity transitions can open/close inline completion too.
  if (( ! ${UI_MODAL_ACTIVE:-0} && $+functions[ui_slash_update] )); then
    local -i previous_slash_rows=$UI_SLASH_ROWS
    ui_slash_update
    (( UI_SLASH_ROWS != previous_slash_rows )) && ui_setup_windows
  fi
  ui_draw_header 1
  (( SIDE_W > 0 )) && ui_draw_sidebar 1
  ui_draw_chat 1
  ui_draw_input 1
  ui_draw_footer 1
  ui_flush
}

# Editing is shared by the idle loop and activity polling. Sending a prompt,
# changing sessions/models, and running slash commands stay with the idle loop.
ui_editor_input() {
  local ch="$1" key="$2"
  if [[ "$key" == BACKSPACE || "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then input_backspace
  elif [[ "$key" == DC || "$key" == DELETE ]]; then input_delete
  elif [[ "$key" == LEFT ]]; then input_left
  elif [[ "$key" == RIGHT ]]; then input_right
  elif [[ "$key" == HOME || "$ch" == $'\x01' ]]; then input_home
  elif [[ "$key" == END || "$ch" == $'\x05' ]]; then input_end
  elif [[ "$ch" == $'\x15' || "$ch" == $'\x03' ]]; then input_clear
  elif [[ "$ch" == $'\x17' ]]; then input_kill_word
  elif [[ "$key" == UP ]]; then
    ui_input_width
    input_move_vertical -1 "$REPLY" $(( INPUT_H - 2 )) || input_history_previous
  elif [[ "$key" == DOWN ]]; then
    ui_input_width
    input_move_vertical 1 "$REPLY" $(( INPUT_H - 2 )) || input_history_next
  elif [[ -n "$ch" && "$ch" == [[:print:]] ]]; then input_insert "$ch"
  else return 1
  fi
  ui_input_changed
  return 0
}

ui_activity_begin() {
  (( UI_ACTIVITY_DEPTH++ ))
  [[ "$UI_FOCUS" == sidebar ]] && UI_FOCUS=input
  ui_refresh_all
}

ui_activity_end() {
  (( UI_ACTIVITY_DEPTH > 0 )) && (( UI_ACTIVITY_DEPTH-- ))
  ui_refresh_all
}

ui_activity_input() {
  local ch="$1" key="$2"
  if [[ "$key" == RESIZE ]]; then
    UI_RESIZE_PENDING=1; ui_poll_resize; return 0
  fi
  # Distinguish a bare Escape from bracketed paste and enhanced newline keys.
  if [[ -z "$ch" && -z "$key" ]]; then
    if [[ "$INPUT_TERM_STATE" == escape && "$INPUT_ESCAPE_BUF" == $'\e' ]] && (( EPOCHREALTIME - UI_ACTIVITY_ESCAPE_AT >= 0.05 )); then
      INPUT_TERM_STATE=normal; INPUT_ESCAPE_BUF=""
      return 130
    fi
    return 0
  fi
  if [[ "$INPUT_TERM_STATE" == normal && "$ch" == $'\e' ]]; then UI_ACTIVITY_ESCAPE_AT=$EPOCHREALTIME; fi
  if input_decode_terminal_event "$ch" "$key"; then
    if [[ "$INPUT_EVENT_ACTION" == newline ]]; then input_insert $'\n'; ui_input_changed
    elif [[ "$INPUT_EVENT_ACTION" == paste && -n "$INPUT_EVENT_TEXT" ]]; then input_insert "$INPUT_EVENT_TEXT"; ui_input_changed
    elif [[ "$INPUT_EVENT_ACTION" == paste_rejected ]]; then ui_status_notice warning "$INPUT_EVENT_TEXT"
    fi
  elif [[ "$ch" == $'\x02' ]]; then ui_toggle_sidebar
  elif [[ "$UI_FOCUS" == input && -n "${INPUT_QUEUE_TURN_ID:-}${REMOTE_INPUT_TURN_ID:-}" &&
          ( "$ch" == $'\r' || "$ch" == $'\n' || "$key" == ENTER || "$key" == PADENTER || "$ch" == $'\x07' ) ]] && (( $+functions[input_queue_ui_submit] )); then
    if [[ "$ch" == $'\x07' ]]; then input_queue_ui_submit follow_up || return $?
    else input_queue_ui_submit steer || return $?
    fi
  elif [[ "$ch" == $'\t' || "$key" == TAB ]]; then
    [[ "$UI_FOCUS" == input ]] && UI_FOCUS=chat || UI_FOCUS=input
    [[ "$UI_FOCUS" == chat ]] && { UI_AUTO_SCROLL=0; UI_REVEAL_SELECTED=1; }
    ui_refresh_all
  elif [[ "$ch" == $'\x12' ]]; then ui_toggle_reasoning
  elif [[ "$key" == PPAGE ]]; then
    UI_AUTO_SCROLL=0; (( UI_SCROLL-=6 )); (( UI_SCROLL < 0 )) && UI_SCROLL=0
    ui_draw_chat
  elif [[ "$key" == NPAGE ]]; then
    (( UI_SCROLL+=6 )); ui_draw_chat
  elif [[ "$UI_FOCUS" == chat ]]; then ui_chat_input "$ch" "$key" || true
  else ui_editor_input "$ch" "$key" || true
  fi
  return 0
}

ui_poll_activity() {
  local ch="" key="" mouse=""
  ui_poll_resize
  if (( TERMINAL_EVENT_POLL )); then
    local -i count result
    for (( count=0; count<32; count++ )); do
      terminal_read_event input_win ch key mouse poll
      ui_activity_input "$ch" "$key"
      result=$?
      (( result == 0 )) || return "$result"
      [[ -n $ch$key$mouse ]] || break
      (( TERMINAL_EVENT_POLL )) || break
    done
    (( count == 0 && TERMINAL_EVENT_POLL )) && terminal_wait_input "${1:-50}"
    return 0
  fi
  zcoder_curses timeout input_win "${1:-50}"
  terminal_read_event input_win ch key mouse
  ui_activity_input "$ch" "$key"
}

_ui_wait_for_activity() {
  local ready="$1" expired="${2:-}" poll_interval="${3:-50}"
  local -i poll_status=0
  ui_activity_begin
  {
    while ! "$ready"; do
      if [[ -n "$expired" ]] && "$expired"; then return 124; fi
      ui_poll_activity "$poll_interval"
      poll_status=$?
      (( poll_status == 0 )) || return "$poll_status"
    done
  } always {
    ui_activity_end
  }
  return 0
}

ui_wait_for_generation() {
  if [[ -n "${HTTP_ASYNC_STREAM_FD:-}" ]] && (( $+functions[agent_stream_ready] )); then
    _ui_wait_for_activity agent_stream_ready
  else _ui_wait_for_activity http_async_ready
  fi
}
ui_wait_for_delegate() { _ui_wait_for_activity delegate_async_ready delegate_async_timed_out; }
ui_wait_for_models() { _ui_wait_for_activity http_async_ready ollama_model_discovery_expired; }
ui_wait_for_context() { _ui_wait_for_activity agent_context_discovery_ready; }
ui_wait_for_tool_process() { _ui_wait_for_activity tool_process_ready tool_process_expired; }
ui_wait_for_mcp_request() { _ui_wait_for_activity _mcp_request_ready _mcp_request_expired; }
ui_wait_for_mcp_start() { _ui_wait_for_activity _mcp_start_ready _mcp_request_expired; }
# Remote events require one HTTP exchange apiece; avoid adding the generation
# wait's 50 ms input timeout to each event in a burst.
ui_wait_for_remote_request() { _ui_wait_for_activity http_async_ready remote_client_request_expired 10; }
ui_poll_remote_turn() { ui_poll_activity "${1:-50}"; }

ui_chat_select() {
  emulate -L zsh
  setopt extendedglob
  local -i delta=$1 count=${#UI_ROLES} group
  (( count > 0 )) || return 0
  (( UI_SELECTED_EVENT > 0 && UI_SELECTED_EVENT <= count )) || UI_SELECTED_EVENT=$count
  (( UI_SELECTED_EVENT += delta ))
  (( UI_SELECTED_EVENT < 1 )) && UI_SELECTED_EVENT=1
  (( UI_SELECTED_EVENT > count )) && UI_SELECTED_EVENT=$count
  group=${UI_ASSISTANT_GROUPS[UI_SELECTED_EVENT]:-0}
  if (( group > 0 && group != UI_SELECTED_EVENT && ! ${UI_BLOCK_OPEN[group]:-1} )); then
    if (( delta > 0 )); then
      while (( UI_SELECTED_EVENT < count && ${UI_ASSISTANT_GROUPS[UI_SELECTED_EVENT+1]:-0} == group )); do
        (( UI_SELECTED_EVENT++ ))
      done
      (( UI_SELECTED_EVENT < count )) && (( UI_SELECTED_EVENT++ )) || UI_SELECTED_EVENT=$group
    else
      UI_SELECTED_EVENT=$group
    fi
  fi
  UI_AUTO_SCROLL=0
  UI_REVEAL_SELECTED=1
  ui_draw_chat
}

ui_toggle_block() {
  emulate -L zsh
  setopt extendedglob
  local -i i=$UI_SELECTED_EVENT
  (( i > 0 && i <= ${#UI_ROLES} )) || return 0
  if [[ "${UI_ROLES[i]}" == assistant ]]; then
    i=${UI_ASSISTANT_GROUPS[i]:-$i}
    UI_SELECTED_EVENT=$i
  elif [[ -z "${UI_CONTENTS[i]}" && -n "${UI_THINKINGS[i]}" ]]; then
    ui_toggle_reasoning
    return 0
  fi
  UI_BLOCK_OPEN[i]=$(( ! ${UI_BLOCK_OPEN[i]:-1} ))
  transcript_changed "$i"
  UI_AUTO_SCROLL=0; UI_REVEAL_SELECTED=1
  [[ "${UI_BLOCK_OPEN[i]}" == 1 ]] && UI_SCROLL=$(( ${UI_MESSAGE_STARTS[i]:-1} - 1 ))
  (( $+functions[state_save_session] )) && state_save_session
  ui_draw_chat
}

ui_chat_input() {
  emulate -L zsh
  setopt extendedglob
  local ch="$1" key="$2"
  if [[ "$key" == UP || "$ch" == k ]]; then ui_chat_select -1
  elif [[ "$key" == DOWN || "$ch" == j ]]; then ui_chat_select 1
  elif [[ "$key" == HOME ]]; then ui_chat_select -${#UI_ROLES}
  elif [[ "$key" == END ]]; then ui_chat_select ${#UI_ROLES}
  elif [[ "$key" == ENTER || "$key" == PADENTER || "$ch" == $'\n' || "$ch" == $'\r' || "$ch" == ' ' ]]; then ui_toggle_block
  else return 1
  fi
  return 0
}

ui_toggle_reasoning() {
  local -i i first=${#UI_ROLES} last=1
  if [[ "$UI_FOCUS" == chat ]]; then
    first=$UI_SELECTED_EVENT; last=$UI_SELECTED_EVENT
    (( first > 0 && first <= ${#UI_ROLES} )) || return 0
  fi
  for (( i=first; i>=last; i-- )); do
    if [[ "${UI_ROLES[i]}" == assistant && -n "${UI_THINKINGS[i]}" ]]; then
      UI_REASONING_OPEN[i]=$(( ! ${UI_REASONING_OPEN[i]:-0} ))
      transcript_changed "$i"
      [[ "$UI_FOCUS" == chat ]] && { UI_AUTO_SCROLL=0; UI_REVEAL_SELECTED=1; }
      break
    fi
  done
  (( $+functions[state_save_and_refresh] )) && state_save_and_refresh
  ui_draw_chat
}
