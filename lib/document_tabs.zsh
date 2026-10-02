# Persistent read-only views. Slot numbers are stable for the lifetime of a tab.
source "${${(%):-%x}:A:h}/document_files.zsh"
typeset -gi UI_DOCUMENT_TAB=3 UI_DOCUMENT_GENERATION=0 UI_DOCUMENT_LOADING=0
typeset -gA UI_DOCUMENT_PATHS=() UI_DOCUMENT_TEXTS=() UI_DOCUMENT_SCROLLS=()
typeset -g UI_DOCUMENT_CACHE_KEY=''
typeset -ga UI_DOCUMENT_LINES=() UI_DOCUMENT_ATTRS=() UI_DOCUMENT_NATIVE=()
typeset -ga UI_DOCUMENT_STARTS=() UI_DOCUMENT_COUNTS=() UI_DOCUMENT_SPANS=() UI_DOCUMENT_STYLES=()

ui_document_select() {
  emulate -L zsh
  [[ $1 == [3-7] ]] || return 1
  [[ $1 == 3 || -n ${UI_DOCUMENT_PATHS[$1]:-} ]] || return 0
  ui_selection_cancel
  UI_DOCUMENT_TAB=$1
  if [[ $1 == 3 ]]; then UI_FOCUS=input
  else UI_FOCUS=document; fi
  ui_invalidate chat footer
  ui_refresh_all
}

ui_document_open() {
  emulate -L zsh
  local requested=$1 canonical text failure='' HTTP_BODY='' HTTP_ERROR=''
  local -a reply=()
  local -i slot=0 i reload=${2:-0}
  (( UI_DOCUMENT_LOADING )) && return 0
  (( UI_ACTIVE )) || { ui_append_message error '/open requires the interactive reader.'; return 1; }
  # Preserve the active slot while a remote request pumps the ordinary UI loop.
  (( reload )) && slot=$UI_DOCUMENT_TAB
  UI_DOCUMENT_LOADING=1
  {
    if [[ ${REMOTE_MODE:-local} == client ]]; then
      if [[ ${REMOTE_DOCUMENTS_SUPPORTED:-false} != true ]]; then
        failure='This server does not support document reading; update the server.'
      else
        zjson_quote "$requested"
        if ! remote_client_request POST /v1/document "{\"path\":$REPLY}"; then
          failure=$REMOTE_ERROR
        elif ! json_parse_flat_object "$HTTP_BODY" ||
            [[ ${JSON_OBJECT_TYPES[path]:-} != string || ${JSON_OBJECT_TYPES[text]:-} != string || -z ${JSON_OBJECT[path]} ]]; then
          failure='Invalid document response from server.'
        else
          canonical=$JSON_OBJECT[path]; text=$JSON_OBJECT[text]
        fi
      fi
    elif document_read "$requested"; then
      canonical=$reply[1]; text=$reply[2]
    else failure=$REPLY
    fi
    if [[ -n $failure ]]; then
      zcoder_terminal_safe "$failure"
      ui_status_notice warning "$REPLY"; ui_draw_header
      return 1
    fi
    if (( ! reload )); then
      for i in 4 5 6 7; do
        if [[ ${UI_DOCUMENT_PATHS[$i]:-} == "$canonical" ]]; then ui_document_select "$i"; return 0; fi
        [[ -z ${UI_DOCUMENT_PATHS[$i]:-} && $slot == 0 ]] && slot=$i
      done
      if (( ! slot )); then
        ui_status_notice warning 'Four documents are already open. Close one with x.'; ui_draw_header
        return 1
      fi
      UI_DOCUMENT_SCROLLS[$slot]=0
    fi
    UI_DOCUMENT_PATHS[$slot]=$canonical
    UI_DOCUMENT_TEXTS[$slot]=$text
    (( UI_DOCUMENT_GENERATION++ ))
    ui_document_select "$slot"
  } always {
    UI_DOCUMENT_LOADING=0
  }
}

ui_document_close() {
  emulate -L zsh
  (( UI_DOCUMENT_TAB > 3 && ! UI_DOCUMENT_LOADING )) || return 0
  local slot=$UI_DOCUMENT_TAB
  unset "UI_DOCUMENT_PATHS[$slot]" "UI_DOCUMENT_TEXTS[$slot]" "UI_DOCUMENT_SCROLLS[$slot]"
  (( UI_DOCUMENT_GENERATION++ ))
  ui_document_select 3
}

# Render into caller-local transcript arrays, then publish only reader arrays.
# The transcript's cache, scroll position and copying metadata remain independent.
_ui_document_tab_layout() {
  emulate -L zsh
  local cache_key="$UI_DOCUMENT_TAB:$UI_DOCUMENT_GENERATION:$1:$UI_MARKDOWN_BACKEND"
  [[ $cache_key == "$UI_DOCUMENT_CACHE_KEY" ]] && return 0
  local -a UI_LINES=() UI_ATTRS=() UI_LINE_NATIVE=() UI_LINE_SEGMENT_STARTS=() UI_LINE_SEGMENT_COUNTS=()
  local -a UI_SEGMENT_TEXTS=() UI_SEGMENT_ATTRS=() UI_COPY_TEXTS=() UI_COPY_COLUMNS=() UI_COPY_GAPS=()
  local -i UI_SELECTION_ENABLED=0
  local text=${UI_DOCUMENT_TEXTS[$UI_DOCUMENT_TAB]}
  text=${text//$'\r\n'/$'\n'}
  zjson_utf8_repair "$text"
  zcoder_terminal_safe "$REPLY"
  _ui_add_markdown "$REPLY" "$1"
  UI_DOCUMENT_LINES=("${UI_LINES[@]}"); UI_DOCUMENT_ATTRS=("${UI_ATTRS[@]}")
  UI_DOCUMENT_NATIVE=("${UI_LINE_NATIVE[@]}")
  UI_DOCUMENT_STARTS=("${UI_LINE_SEGMENT_STARTS[@]}"); UI_DOCUMENT_COUNTS=("${UI_LINE_SEGMENT_COUNTS[@]}")
  UI_DOCUMENT_SPANS=("${UI_SEGMENT_TEXTS[@]}"); UI_DOCUMENT_STYLES=("${UI_SEGMENT_ATTRS[@]}")
  UI_DOCUMENT_CACHE_KEY=$cache_key
}

_ui_document_tabs_draw() {
  emulate -L zsh
  local -i width=$(( SCREEN_W-SIDE_W-4 )) count=$(( ${#UI_DOCUMENT_PATHS}+1 )) slot cell used col=2
  local label style
  (( width > 0 && count > 1 )) || return 0
  cell=$(( width/count ))
  if (( cell < 3 )); then
    ui_draw_row chat_win 0 1 "$width" 'bold reverse cyan/black' "[$UI_DOCUMENT_TAB]"
    return 0
  fi
  # At very narrow widths show numbers for every slot, keeping the active
  # filename in the reader's path row instead of hiding its shortcut.
  for slot in 3 4 5 6 7; do
    [[ $slot == 3 || -n ${UI_DOCUMENT_PATHS[$slot]:-} ]] || continue
    [[ $slot == 3 ]] && label=Coding || label=${UI_DOCUMENT_PATHS[$slot]:t}
    zcoder_terminal_safe "$label"; label=${REPLY//$'\n'/ }
    if (( cell < 8 )); then label="[$slot]"
    else
      zcoder_clip "$label" "$(( cell-5 ))"; label="[$slot $REPLY]"
    fi
    style='dim white/black'
    (( slot == UI_DOCUMENT_TAB )) && style='bold reverse cyan/black'
    # Cap long names to share the available width, but place each tab directly
    # after its predecessor instead of spreading short labels across the row.
    used=${(m)#label}
    if (( used < cell )); then label+=' '; (( used++ )); fi
    ui_draw_row chat_win 0 "$col" "$used" "$style" "$label"
    (( col+=used ))
  done
}

_ui_document_tab_draw() {
  emulate -L zsh
  local -i width=$(( SCREEN_W-SIDE_W-2 )) height=$(( SCREEN_H-TOP_H-INPUT_H-FOOT_H-3 ))
  local -i row index start count span max_scroll scroll
  local -a spans
  (( width > 0 && height > 0 )) || return 0
  _ui_document_tab_layout "$width"
  max_scroll=$(( ${#UI_DOCUMENT_LINES}-height )); (( max_scroll < 0 )) && max_scroll=0
  scroll=${UI_DOCUMENT_SCROLLS[$UI_DOCUMENT_TAB]:-0}
  (( scroll > max_scroll )) && scroll=$max_scroll
  (( scroll < 0 )) && scroll=0
  UI_DOCUMENT_SCROLLS[$UI_DOCUMENT_TAB]=$scroll
  zcoder_curses clear chat_win
  ui_attr chat_win -dim bold accent/surface; ui_border chat_win
  _ui_document_tabs_draw
  zcoder_terminal_safe "${UI_DOCUMENT_PATHS[$UI_DOCUMENT_TAB]} · read-only"
  ui_draw_row chat_win 1 1 "$width" 'dim cyan/black' "${REPLY//$'\n'/ }"
  for (( row=1; row<=height && scroll+row<=${#UI_DOCUMENT_LINES}; row++ )); do
    index=$(( scroll+row )); spans=()
    start=${UI_DOCUMENT_STARTS[index]:-1}; count=${UI_DOCUMENT_COUNTS[index]:-0}
    for (( span=start; span<start+count; span++ )); do
      spans+=("${UI_DOCUMENT_STYLES[span]}" "${UI_DOCUMENT_SPANS[span]}")
    done
    (( count )) || spans=("${UI_DOCUMENT_ATTRS[index]}" "${UI_DOCUMENT_LINES[index]}")
    if [[ ${UI_DOCUMENT_NATIVE[index]} == 1 ]]; then
      ui_markdown_draw_row chat_win "$((row+1))" 1 "$width" "${spans[@]}"
    else ui_draw_row chat_win "$((row+1))" 1 "$width" "${spans[@]}"; fi
  done
}

ui_document_input() {
  emulate -L zsh
  [[ $UI_FOCUS == document ]] && (( UI_DOCUMENT_TAB > 3 )) || return 1
  local -i scroll=${UI_DOCUMENT_SCROLLS[$UI_DOCUMENT_TAB]:-0} page=$(( SCREEN_H-TOP_H-INPUT_H-FOOT_H-4 ))
  (( page < 1 )) && page=1
  case $2 in
    UP) (( scroll-- )) ;; DOWN) (( scroll++ )) ;;
    PPAGE) (( scroll-=page )) ;; NPAGE) (( scroll+=page )) ;;
    HOME) scroll=0 ;; END) scroll=${#UI_DOCUMENT_LINES} ;;
    *) case $1 in
      k) (( scroll-- )) ;; j) (( scroll++ )) ;;
      x) ui_document_close; return 0 ;;
      r) ui_document_open "${UI_DOCUMENT_PATHS[$UI_DOCUMENT_TAB]}" 1; return 0 ;;
      *) return 1 ;;
    esac ;;
  esac
  (( scroll < 0 )) && scroll=0
  UI_DOCUMENT_SCROLLS[$UI_DOCUMENT_TAB]=$scroll
  ui_invalidate chat; ui_draw_chat
  return 0
}
