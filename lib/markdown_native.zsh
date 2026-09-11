# Optional structured Markdown. Layout and drawing share an explicit native
# width policy; the original transcript remains the source for copying/reflow.
typeset -g UI_MARKDOWN_BACKEND=zsh UI_MARKDOWN_REASON='not initialized'
typeset -gi UI_MARKDOWN_FALLBACKS=0
typeset -g UI_MARKDOWN_POLICY=unicode-17.0.0-egc-wcwidth-sum-attach-zero

zcoder_markdown_load() {
  emulate -L zsh
  zmodload -e zmdown && return 0
  local root="${1:-$ZCODER_DIR}/vendor/zmdown/.build"
  local signature="$ZSH_VERSION:$ZSH_PATCHLEVEL:$MACHTYPE:$OSTYPE:$HOST"
  [[ -r $root/zcoder-abi && -f $root/modules/zmdown.so &&
     $(<"$root/zcoder-abi") == "$signature" ]] || return 1
  local -a module_path=("$root/modules" "${module_path[@]}")
  zmodload zmdown 2>/dev/null
}

ui_markdown_init() {
  emulate -L zsh
  UI_MARKDOWN_BACKEND=zsh
  UI_MARKDOWN_REASON='native modules unavailable'
  case ${ZCODER_MARKDOWN:-auto} in
    zsh) UI_MARKDOWN_REASON='disabled by ZCODER_MARKDOWN'; return 0 ;;
    auto) ;;
    *) UI_MARKDOWN_REASON='ZCODER_MARKDOWN expects auto or zsh'; return 0 ;;
  esac
  if [[ ${ZCODER_SPANS:-auto} == false ]]; then
    UI_MARKDOWN_REASON='disabled by ZCODER_SPANS'
    return 0
  fi
  local -a reply=()
  local -A contract probe
  zcoder_curses_features || return 0
  (( ${reply[(Ie)grapheme_safe_text]} && ${reply[(Ie)text_policy]} )) || return 0
  zcoder_curses textpolicy contract "$UI_MARKDOWN_POLICY" 2>/dev/null || return 0
  [[ $contract[grapheme_available] == 1 && $contract[style_policy] == first-scalar ]] || return 0
  zcoder_markdown_load || return 0
  zmdown --spans probe --width 20 --width-policy wcwidth-sum --cluster-styles first-base --text '**ready**' 2>/dev/null || return 0
  [[ $probe[schema] == 1 && $probe[width_policy_name] == wcwidth-sum &&
     $probe[cluster_styles] == first-base ]] || return 0
  UI_MARKDOWN_BACKEND=zmdown
  UI_MARKDOWN_REASON='wcwidth-sum / first-base'
}

# Exceptional presentation fallback: preserve every scalar visibly instead of
# letting curses silently drop unsupported combining marks. No stored data changes.
_ui_markdown_ascii() {
  emulate -L zsh
  local char escaped
  REPLY=''
  for char in "${(@s::)1}"; do
    if [[ $char == [\ -\~] || $char == $'\n' ]]; then
      REPLY+=$char
    else
      printf -v escaped '\\u{%04X}' "'$char"
      REPLY+=$escaped
    fi
  done
}

# Private staging arrays use Zsh dynamic scope so existing syntax helpers can
# populate them. Publish only after the entire message passes native preflight.
_ui_markdown_native_layout() {
  emulate -L zsh
  setopt extendedglob
  local -a UI_LINES=() UI_ATTRS=() UI_LINE_NATIVE=()
  local -a UI_LINE_SEGMENT_STARTS=() UI_LINE_SEGMENT_COUNTS=()
  local -a UI_SEGMENT_TEXTS=() UI_SEGMENT_ATTRS=()
  local -A document measured
  local -i width=$2 row span block flags available=$(( $2 - 2 ))
  local base=${3:-white/black} key style language text
  (( available > 0 )) || return 1
  zmdown --spans document --width "$available" --width-policy wcwidth-sum --cluster-styles first-base --text "$1" 2>/dev/null || return 1
  [[ $document[schema] == 1 && $document[width_policy_name] == wcwidth-sum &&
     $document[cluster_styles] == first-base ]] || return 1
  for (( row=1; row<=document[line_count]; row++ )); do
    text=$document[line,$row,text]
    zcoder_curses textinfo measured "$text" "$available" "$UI_MARKDOWN_POLICY" 2>/dev/null || return 1
    [[ $measured[text] == "$text" && $measured[width] == $document[line,$row,cells] ]] || return 1
    block=$document[line,$row,block]
    if [[ $document[line,$row,role] == content && $document[block,$block,kind] == code ]]; then
      language=${document[block,$block,language]:l}
      case $language in
        shell|shellscript) language=shell ;;
        python|javascript|typescript|rust|ruby|markup) ;;
        diff|patch) language=diff ;;
        *) _ui_language_for_path "code.$language"; language=$REPLY ;;
      esac
      if [[ $language == diff ]]; then
        _ui_diff_attr "$text"
        _ui_add_line "  $text" "$REPLY"
      else
        _ui_add_syntax_line "$text" "$language" '  '
      fi
    else
      _ui_add_line "  $text" "$base"
      _ui_add_segment '  ' "$base"
      for (( span=1; span<=document[line,$row,span_count]; span++ )); do
        key=line,$row,span,$span; flags=$document[$key,style]; style=$base
        (( flags & document[style,heading] )) && style='bold magenta/black'
        (( flags & document[style,code] )) && style=yellow/black
        (( flags & document[style,strong] )) && style="bold $style"
        (( flags & (document[style,emphasis] | document[style,link]) )) && style="underline $style"
        (( flags & (document[style,muted] | document[style,deletion]) )) && style="dim $style"
        _ui_add_segment "$document[$key,text]" "$style"
      done
    fi
    # Includes application indentation and reserves one span for row padding.
    (( UI_LINE_SEGMENT_COUNTS[row] < 4096 )) || return 1
    zcoder_curses textinfo measured "$UI_LINES[row]" "$width" "$UI_MARKDOWN_POLICY" 2>/dev/null || return 1
    [[ $measured[text] == "$UI_LINES[row]" ]] || return 1
  done
  native_lines=("${UI_LINES[@]}"); native_attrs=("${UI_ATTRS[@]}")
  native_starts=("${UI_LINE_SEGMENT_STARTS[@]}"); native_counts=("${UI_LINE_SEGMENT_COUNTS[@]}")
  native_texts=("${UI_SEGMENT_TEXTS[@]}"); native_styles=("${UI_SEGMENT_ATTRS[@]}")
  return 0
}

_ui_add_markdown() {
  emulate -L zsh
  if [[ $UI_MARKDOWN_BACKEND != zmdown ]]; then
    _ui_add_markdown_fallback "$@"
    return
  fi
  local -a native_lines native_attrs native_starts native_counts native_texts native_styles
  local -i row span start count
  if _ui_markdown_native_layout "$@"; then
    for (( row=1; row<=${#native_lines}; row++ )); do
      _ui_add_line "$native_lines[row]" "$native_attrs[row]"
      UI_LINE_NATIVE[${#UI_LINES}]=1
      start=$native_starts[row]; count=$native_counts[row]
      for (( span=start; span<start+count; span++ )); do
        _ui_add_segment "$native_texts[span]" "$native_styles[span]"
      done
    done
    return 0
  fi
  (( UI_MARKDOWN_FALLBACKS++ ))
  UI_MARKDOWN_REASON='message rejected by native layout/preflight; visible Unicode escapes'
  local REPLY
  _ui_markdown_ascii "$1"
  _ui_add_markdown_fallback "$REPLY" "$2" "${3:-white/black}"
}

ui_markdown_draw_row() {
  emulate -L zsh
  local window=$1 row=$2 col=$3 width=$4 style text REPLY plain=''
  shift 4
  local -a batch=()
  for style text in "$@"; do
    ui_style "$style"
    batch+=("${REPLY// /,}" "$text")
    plain+=$text
  done
  zcoder_curses spansclip "$window" "$row" "$col" "$width" "policy=$UI_MARKDOWN_POLICY" "${batch[@]}" 2>/dev/null && return 0
  (( UI_MARKDOWN_FALLBACKS++ ))
  UI_MARKDOWN_REASON='native row draw failed; visible Unicode escapes'
  _ui_markdown_ascii "$plain"
  # Never retry rejected Unicode through the legacy scalar clipper.
  ui_draw_row "$window" "$row" "$col" "$width" white/black "$REPLY"
}
