# Chat-only mouse selection. zdraw owns geometry; the application owns the
# displayed projection, soft-wrap joins, input routing and explicit copying.
typeset -gi UI_SELECTION_ENABLED=0 UI_SELECTION_REVISION=0 UI_SELECTION_AUTO_SCROLL=0
typeset -g UI_SELECTION_VIEW='' UI_SELECTION_REASON='native mouse selection unavailable'
typeset -gA zdraw_text_selection=()
typeset -ga UI_COPY_TEXTS=() UI_COPY_COLUMNS=() UI_COPY_GAPS=()
typeset -ga UI_SELECTION_STARTS=() UI_SELECTION_ENDS=() UI_SELECTION_TEXTS=()
typeset -ga UI_SELECTION_COLUMNS=() UI_SELECTION_GAPS=()
source "${${(%):-%x}:A:h:h}/vendor/zdraw/lib/zdraw-text-selection.zsh"

# Rows are excluded by default. Call after emitting selectable content; prefix
# is presentation indentation, gap is logical text consumed between soft wraps.
_ui_copy_row() {
  local -i n=${#UI_LINES}
  UI_COPY_COLUMNS[n]=${(m)#1}
  UI_COPY_TEXTS[n]=$2
  UI_COPY_GAPS[n]=${3-$'\n'}
}

ui_selection_start() {
  emulate -L zsh
  UI_SELECTION_ENABLED=0
  UI_SELECTION_REASON='native mouse selection unavailable'
  zdraw_text_selection=()
  if [[ ${ZCODER_MOUSE_SELECTION:-auto} == false ]]; then
    UI_SELECTION_REASON='disabled by ZCODER_MOUSE_SELECTION'
    return 0
  fi
  [[ ${ZCODER_MOUSE_SELECTION:-auto} != false && $ZCODER_CURSES_COMMAND == zdraw ]] || return 0
  local feature
  local -a reply
  zcoder_curses_features || return 0
  for feature in mouse structured_events norefresh_events grapheme_safe_text text_policy region_restyle region_copy; do
    (( ${reply[(Ie)$feature]} )) || return 0
  done
  (( UI_STYLED_SPANS && TERMINAL_NOREFRESH_INPUT )) || return 0
  zcoder_curses mouse delay 0 motion 2>/dev/null || return 0
  UI_SELECTION_ENABLED=1
  UI_SELECTION_REASON='left drag; Ctrl+Y copies; Esc clears'
}

ui_selection_cancel() {
  emulate -L zsh
  if [[ -n ${zdraw_text_selection[format]-} ]]; then
    if (( ${zdraw_text_selection[selected]:-0} )); then
      UI_AUTO_SCROLL=$UI_SELECTION_AUTO_SCROLL
      ui_invalidate chat footer
    fi
    zdraw-text-selection-invalidate
  fi
  UI_SELECTION_VIEW=''
  return 0
}

_ui_selection_view_key() {
  REPLY="$SCREEN_H:$SCREEN_W:$SIDE_W:$INPUT_H:$UI_SCROLL:$UI_TRANSCRIPT_GENERATION:${CURRENT_SESSION_ID:-}"
}

# Build only the visible rows, on demand at the first press after a repaint.
# Geometry uses a newline-separated display projection. Copying replaces those
# separators with the retained logical gaps (including soft-wrap whitespace).
_ui_selection_prepare() {
  emulate -L zsh
  local -i height=$((SCREEN_H-TOP_H-INPUT_H-FOOT_H-2)) width=$((SCREEN_W-SIDE_W-2))
  local -i r idx col bytes=0 n
  local source='' text style REPLY
  local -a records
  local -A measured
  (( height > 0 && width > 0 && (height+2)*(width+2)<=65536 )) || return 1
  UI_SELECTION_STARTS=() UI_SELECTION_ENDS=() UI_SELECTION_TEXTS=()
  UI_SELECTION_COLUMNS=() UI_SELECTION_GAPS=()
  for (( r=0; r<height; r++ )); do
    idx=$((UI_SCROLL+r+1)); col=${UI_COPY_COLUMNS[idx]:--1}
    (( col >= 0 && col < width )) || continue
    text=${UI_COPY_TEXTS[idx]}
    zcoder_curses textinfo measured "$text" "$((width-col))" "$UI_MARKDOWN_POLICY" 2>/dev/null || return 1
    text=$measured[text]
    [[ -z $source ]] || { source+=$'\n'; (( bytes++ )); }
    n=$((r+1))
    UI_SELECTION_STARTS[n]=$bytes
    UI_SELECTION_TEXTS[n]=$text UI_SELECTION_COLUMNS[n]=$col
    UI_SELECTION_GAPS[n]=${UI_COPY_GAPS[idx]-$'\n'}
    ui_style "${UI_ATTRS[idx]:-white/black}"; style=${REPLY// /,}
    records+=("$r" "$col" "$bytes" "$style" "$text")
    source+=$text
    _zdraw_ts_bytes "$text"; (( bytes+=REPLY ))
    UI_SELECTION_ENDS[n]=$bytes
  done
  (( UI_SELECTION_REVISION++ ))
  zdraw-text-selection-init "$source" "$UI_SELECTION_REVISION" "$((TOP_H+1))" "$((SIDE_W+1))" "$height" "$width" "$UI_MARKDOWN_POLICY" "${records[@]}" 2>/dev/null || return 1
  _ui_selection_view_key; UI_SELECTION_VIEW=$REPLY
}

# The screen beneath the highlight stays unchanged while streaming continues.
# Only selected cell ranges are restyled; a normal repaint restores base styles.
_ui_selection_paint() {
  emulate -L zsh
  local -i n start end left right cells
  local -A a b
  local text REPLY
  # Restore the retained frame before applying the new range, without rendering
  # incoming transcript data. The snapshot contains cells, never copy text.
  zcoder_curses copy selection_win 0 0 chat_win 0 0 "$UI_SELECTION_HEIGHT" "$UI_SELECTION_WIDTH" 2>/dev/null || return 1
  for (( n=1; n<=${#UI_SELECTION_TEXTS}; n++ )); do
    [[ -n ${UI_SELECTION_COLUMNS[n]} ]] || continue
    start=${UI_SELECTION_STARTS[n]} end=${UI_SELECTION_ENDS[n]}
    left=$((zdraw_text_selection[start]>start ? zdraw_text_selection[start]-start : 0))
    right=$((zdraw_text_selection[end]<end ? zdraw_text_selection[end]-start : end-start))
    (( right>left )) || continue
    text=$UI_SELECTION_TEXTS[n]
    zcoder_curses textpos a "$text" byte "$left" "$UI_MARKDOWN_POLICY" || return 1
    zcoder_curses textpos b "$text" byte "$right" "$UI_MARKDOWN_POLICY" || return 1
    cells=$(( b[column_start]-a[column_start] ))
    (( cells>0 )) || continue
    ui_style 'reverse bold text/surface'
    zcoder_curses restyle chat_win "$n" "$((1+UI_SELECTION_COLUMNS[n]+a[column_start]))" 1 "$cells" "${REPLY// /,}" || return 1
  done
  terminal_refresh chat_win input_win
}

ui_selection_get() {
  emulate -L zsh
  local -i n start end left right seen=0
  local result=''
  (( ${zdraw_text_selection[selected]:-0} && ${zdraw_text_selection[valid]:-0} )) || { REPLY=''; return 1; }
  for (( n=1; n<=${#UI_SELECTION_TEXTS}; n++ )); do
    [[ -n ${UI_SELECTION_COLUMNS[n]} ]] || continue
    start=$UI_SELECTION_STARTS[n] end=$UI_SELECTION_ENDS[n]
    (( zdraw_text_selection[end] > start && zdraw_text_selection[start] <= end )) || continue
    left=$((zdraw_text_selection[start]>start ? zdraw_text_selection[start]-start : 0))
    right=$((zdraw_text_selection[end]<end ? zdraw_text_selection[end]-start : end-start))
    (( right>=left )) || continue
    (( seen )) && result+=$UI_SELECTION_GAPS[n]
    _zdraw_ts_slice "$UI_SELECTION_TEXTS[n]" "$left" "$right"
    result+=$REPLY; seen=1
  done
  # Deliberately return via the caller's parameter, never command substitution.
  REPLY=$result
}

_ui_selection_base64() {
  emulate -L zsh
  local LC_ALL=C text=$1 alphabet=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/
  local -i i a b c size=${#1}
  local -a parts
  for (( i=1; i<=size; i+=3 )); do
    printf -v a '%d' "'$text[i]"
    b=0 c=0
    (( i+1<=size )) && printf -v b '%d' "'$text[i+1]"
    (( i+2<=size )) && printf -v c '%d' "'$text[i+2]"
    parts+=("$alphabet[$(( (a>>2)+1 ))]$alphabet[$(( ((a&3)<<4 | b>>4)+1 ))]")
    if (( i+1<=size )); then parts+=("$alphabet[$(( ((b&15)<<2 | c>>6)+1 ))]"); else parts+=(=); fi
    if (( i+2<=size )); then parts+=("$alphabet[$(( (c&63)+1 ))]"); else parts+=(=); fi
  done
  REPLY=${(j::)parts}
}

ui_selection_copy() {
  emulate -L zsh
  local REPLY selected
  ui_selection_get || return 1
  selected=$REPLY
  if [[ ${ZCODER_CLIPBOARD:-osc52} == view ]]; then
    ui_copy_view "$selected"
    return
  fi
  _zdraw_ts_bytes "$selected"
  if (( REPLY > 262144 )); then
    ui_copy_view "$selected"
    return
  fi
  _ui_selection_base64 "$selected"
  if _terminal_write $'\e]52;c;'"$REPLY"$'\a'; then
    ui_status_notice success 'Selection sent to terminal clipboard. Esc clears.'
  else
    ui_copy_view "$selected"
  fi
}

# Called only by the shared structured-event reader, before any pane or modal.
# Success means consumed. Paste records can never become copy/clear commands.
ui_selection_event() {
  emulate -L zsh
  (( UI_SELECTION_ENABLED )) || return 1
  local -A zdraw_selection_event=("${(@kv)terminal_event}")
  local -i was_selected=${zdraw_text_selection[selected]:-0} consumed=0
  local REPLY type=${terminal_event[type]} buttons=" ${terminal_event[buttons]-} "
  if (( was_selected )) && [[ $type == character && ${terminal_event[text]} == $'\x19' ]]; then
    ui_selection_copy
    return 0
  fi
  if [[ $type == mouse && $buttons == *' PRESSED'[45]' '* ]] && (( ! ${zdraw_text_selection[active]:-0} && ! ${UI_MODAL_ACTIVE:-0} )); then
    if (( terminal_event[x]>SIDE_W && terminal_event[x]<SCREEN_W-1 && terminal_event[y]>TOP_H && terminal_event[y]<SCREEN_H-INPUT_H-FOOT_H-1 )); then
      ui_selection_cancel
      UI_AUTO_SCROLL=0
      if [[ $buttons == *' PRESSED4 '* ]]; then (( UI_SCROLL=UI_SCROLL>3 ? UI_SCROLL-3 : 0 )); else (( UI_SCROLL+=3 )); fi
      ui_draw_chat
      return 0
    fi
  fi
  if [[ $type == mouse && $buttons == *' PRESSED1 '* ]] && (( ! ${UI_MODAL_ACTIVE:-0} && ! ${zdraw_text_selection[valid]:-0} )); then
    _ui_selection_prepare || { ui_status_notice warning 'This view cannot be selected. Use /copy.'; return 0; }
  fi
  [[ -n ${zdraw_text_selection[format]-} ]] || return 1
  zdraw-text-selection-event "$UI_SELECTION_REVISION" || return 0
  consumed=${zdraw_text_selection[consumed]:-0}
  if (( zdraw_text_selection[selected] && ! was_selected )); then
    UI_SELECTION_AUTO_SCROLL=$UI_AUTO_SCROLL; UI_AUTO_SCROLL=0
    typeset -gi UI_SELECTION_HEIGHT=$((SCREEN_H-TOP_H-INPUT_H-FOOT_H)) UI_SELECTION_WIDTH=$((SCREEN_W-SIDE_W))
    zcoder_curses delwin selection_win 2>/dev/null || true
    if ! zcoder_curses addwin selection_win "$UI_SELECTION_HEIGHT" "$UI_SELECTION_WIDTH" "$TOP_H" "$SIDE_W" ||
       ! zcoder_curses copy chat_win 0 0 selection_win 0 0 "$UI_SELECTION_HEIGHT" "$UI_SELECTION_WIDTH"; then
      ui_selection_cancel; ui_refresh_all; return 0
    fi
    typeset -gi UI_SELECTION_SURFACE=1
    ui_invalidate footer; ui_draw_footer
  fi
  if (( was_selected && ! zdraw_text_selection[selected] )); then
    ui_selection_cancel
    UI_AUTO_SCROLL=$UI_SELECTION_AUTO_SCROLL
    ui_invalidate chat footer; ui_refresh_all
  elif (( zdraw_text_selection[changed] && zdraw_text_selection[selected] )); then
    _ui_selection_paint || { ui_selection_cancel; ui_refresh_all; }
  fi
  (( consumed ))
}
