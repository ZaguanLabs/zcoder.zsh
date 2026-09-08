# Application styles and bounded row drawing; curses retains screen ownership.
typeset -g UI_COLOR_MODE=basic UI_BORDER_MODE=plain
typeset -gi UI_STYLED_SPANS=0 UI_WIDE_SPANS=0 UI_SPAN_FALLBACKS=0
typeset -gA UI_COLOR_INFO=() UI_THEME_COLORS=() UI_STYLE_CACHE=()
typeset -gA UI_COLOR_ROLES=(white text black surface cyan accent green success
  yellow warning red error magenta syntax blue info)

ui_theme_palette() {
  case "$1" in
    rgb) UI_THEME_COLORS=(surface '#18212b' text '#d8dee9' accent '#88c0d0'
      success '#a3be8c' warning '#ebcb8b' error '#bf616a' syntax '#b48ead'
      info '#81a1c1' muted '#8293a6' border '#46596c') ;;
    256) UI_THEME_COLORS=(surface 234 text 253 accent 110 success 150 warning 222
      error 167 syntax 139 info 110 muted 103 border 60) ;;
    *) UI_THEME_COLORS=(surface black text white accent cyan success green
      warning yellow error red syntax magenta info blue muted white border blue) ;;
  esac
  UI_STYLE_CACHE=()
}

# Existing transcript style records stay terminal-independent. Resolve their
# color names (and new semantic roles) only at the drawing boundary.
ui_style() {
  local style="$1" token fg bg
  if (( ${+UI_STYLE_CACHE[$style]} )); then
    REPLY="${UI_STYLE_CACHE[$style]}"
    return 0
  fi
  local -a result=()
  for token in ${=style}; do
    if [[ "$token" == */* ]]; then
      [[ "$UI_COLOR_MODE" == mono ]] && continue
      fg=${token%%/*}; bg=${token#*/}
      fg=${UI_COLOR_ROLES[$fg]:-$fg}; bg=${UI_COLOR_ROLES[$bg]:-$bg}
      [[ "$fg" == default ]] && fg=text
      [[ "$bg" == default ]] && bg=surface
      token="${UI_THEME_COLORS[$fg]:-$fg}/${UI_THEME_COLORS[$bg]:-$bg}"
    fi
    result+=("$token")
  done
  REPLY="${(j: :)result}"
  # An empty style needs no cache entry (Zsh associations require nonempty keys).
  [[ -n "$style" ]] && UI_STYLE_CACHE[$style]="$REPLY"
  return 0
}

ui_attr() {
  local window="$1" REPLY
  shift
  ui_style "$*"
  [[ -n "$REPLY" ]] || return 0
  zcurses attr "$window" ${=REPLY}
}

ui_theme_init() {
  emulate -L zsh
  UI_COLOR_INFO=(); UI_STYLE_CACHE=(); UI_SPAN_FALLBACKS=0
  UI_STYLED_SPANS=0; UI_WIDE_SPANS=0; UI_BORDER_MODE=plain
  UI_COLOR_MODE=basic
  if zmodload -F -e zsh/curses +p:zcurses_features; then
    if [[ ${ZCODER_SPANS:-true} != false ]]; then
      (( ${zcurses_features[(Ie)styled_spans]} )) && UI_STYLED_SPANS=1
      (( ${zcurses_features[(Ie)wide_spans]} )) && UI_WIDE_SPANS=1
    fi
    if [[ ${ZCODER_BORDERS:-auto} != plain && -o multibyte ]] &&
       (( ${zcurses_features[(Ie)wide_borders]} )); then
      UI_BORDER_MODE=rounded
    fi
    if (( ${zcurses_features[(Ie)colorinfo]} )); then
      zcurses colorinfo UI_COLOR_INFO 2>/dev/null || UI_COLOR_INFO=()
    fi
  fi
  if [[ ${ZCODER_COLOR:-auto} == mono ]] ||
     [[ ${UI_COLOR_INFO[has_colors]:-1} == 0 || ${UI_COLOR_INFO[color_started]:-1} == 0 ]] ||
     (( ${ZCURSES_COLORS:-0} < 8 )); then
    UI_COLOR_MODE=mono
  elif [[ ${ZCODER_COLOR:-auto} != basic ]]; then
    if [[ ${UI_COLOR_INFO[truecolor_supported]:-0} == 1 ]] &&
       zcurses truecolor on 2>/dev/null; then
      UI_COLOR_MODE=rgb
    # Direct-color entries interpret numeric values differently from the
    # indexed cube. Never apply our 256-color palette to those descriptions.
    elif (( ${ZCURSES_COLORS:-0} == 256 )); then
      UI_COLOR_MODE=256
    fi
  fi
  ui_theme_palette "$UI_COLOR_MODE"
  # Reserve the finite palette before painting. Failed allocations do not
  # recycle retained pairs; degrade before any application cells are drawn.
  local role
  if [[ "$UI_COLOR_MODE" != mono ]]; then
    for role in text accent success warning error syntax info muted border surface; do
      if ! ui_attr stdscr "$role/surface" 2>/dev/null; then
        UI_COLOR_MODE=basic; ui_theme_palette basic
        if ! ui_attr stdscr text/surface 2>/dev/null; then UI_COLOR_MODE=mono; UI_STYLE_CACHE=(); fi
        break
      fi
    done
  fi
  ui_attr stdscr -bold -dim -reverse -underline text/surface 2>/dev/null
  return 0
}

ui_window_background() {
  [[ "$UI_COLOR_MODE" == mono ]] && return 0
  local REPLY
  ui_style text/surface
  zcurses bg "$1" "$REPLY" 2>/dev/null
}

ui_border() {
  if [[ "$UI_BORDER_MODE" == rounded ]]; then
    zcurses border "$1" '│' '│' '─' '─' '╭' '╮' '╰' '╯' 2>/dev/null && return 0
  fi
  zcurses border "$1"
}

# Rows arrive already clipped/padded by the existing layout. No clipping or
# grapheme policy lives here. A rejected batch is repainted with legacy calls.
ui_draw_row() {
  local window="$1" row="$2" col="$3" style text REPLY
  shift 3
  local -a batch=()
  local -i can_batch=$UI_STYLED_SPANS
  if (( can_batch )); then
    for style text in "$@"; do
      if (( ! UI_WIDE_SPANS )) && [[ "$text" == *[^\ -\~]* ]]; then can_batch=0; break; fi
      ui_style "$style"
      batch+=("${REPLY// /,}" "$text")
    done
  fi
  if (( can_batch )); then
    zcurses spans "$window" "$row" "$col" "${batch[@]}" 2>/dev/null && return 0
    (( UI_SPAN_FALLBACKS++ ))
  fi
  zcurses move "$window" "$row" "$col"
  for style text in "$@"; do
    ui_attr "$window" -bold -dim -reverse -underline default/default
    ui_attr "$window" ${=style}
    zcurses string "$window" "$text"
  done
  return 0
}

ui_theme_palette basic
