# Optional structured Markdown. Layout and drawing share an explicit native
# width policy; the original transcript remains the source for copying/reflow.
typeset -g UI_MARKDOWN_BACKEND=zsh UI_MARKDOWN_REASON='not initialized'
typeset -gi UI_MARKDOWN_FALLBACKS=0
typeset -g UI_MARKDOWN_POLICY=unicode-17.0.0-egc-wcwidth-sum-attach-zero

zcoder_markdown_load() {
  emulate -L zsh
  zmodload -e zmdown && return 0
  if [[ -n ${ZCODER_RUNTIME_ACTIVE:-} ]]; then
    zmodload zmdown 2>/dev/null
    return
  fi
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
  local -a UI_COPY_TEXTS=() UI_COPY_COLUMNS=() UI_COPY_GAPS=()
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
  if (( UI_SELECTION_ENABLED )); then
    _ui_markdown_copy_layout "$1" || return 1
  fi
  native_copy_texts=("${UI_COPY_TEXTS[@]}")
  native_copy_columns=("${UI_COPY_COLUMNS[@]}")
  native_copy_gaps=("${UI_COPY_GAPS[@]}")
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
  local -a native_copy_texts native_copy_columns native_copy_gaps
  local -i row span start count
  if _ui_markdown_native_layout "$@"; then
    for (( row=1; row<=${#native_lines}; row++ )); do
      _ui_add_line "$native_lines[row]" "$native_attrs[row]"
      UI_LINE_NATIVE[${#UI_LINES}]=1
      UI_COPY_TEXTS[-1]=$native_copy_texts[row]
      UI_COPY_COLUMNS[-1]=$native_copy_columns[row]
      UI_COPY_GAPS[-1]=$native_copy_gaps[row]
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

# Map narrow content to the renderer's wide logical rows. Only whitespace may
# separate matching slices; generated continuation indentation is excluded.
# Tables retain their displayed layout. If a block cannot be mapped exactly,
# retain its visible line breaks rather than guess or omit any displayed text.
_ui_markdown_copy_layout() {
  emulate -L zsh
  setopt extendedglob
  local -A wide logical cursor previous
  local -i r b drop pos j prefix_cells column padding
  local text candidate rest before kind line segment expanded
  local -A measured
  zmdown --spans wide --width 4096 --width-policy wcwidth-sum --cluster-styles first-base --text "$1" 2>/dev/null || return 1
  for (( r=1; r<=wide[line_count]; r++ )); do
    b=$wide[line,$r,block]
    [[ $wide[line,$r,role] == content ]] || continue
    (( ${+logical[$b]} )) && logical[$b]+=$'\n'
    text=$wide[line,$r,text]
    if [[ ${wide[block,$b,kind]-} == code ]]; then
      text=''
      for (( j=1; j<=wide[line,$r,span_count]; j++ )); do
        (( wide[line,$r,span,$j,style] & wide[style,code] )) && text+=$wide[line,$r,span,$j,text]
      done
    fi
    logical[$b]+=$text
  done
  # Code has an authoritative pre-wrap source. Use it even beyond the wide
  # layout's 4096-cell limit; expand tabs to the renderer's four-cell stops.
  for b in ${(k)logical}; do
    [[ ${document[block,$b,kind]-} == code ]] || continue
    text=$document[block,$b,text]
    expanded=''
    for line in "${(@ps:\n:)text}"; do
      column=0
      while [[ $line == *$'\t'* ]]; do
        segment=${line%%$'\t'*}; line=${line#*$'\t'}
        zcoder_curses textinfo measured "$segment" 2147483647 "$UI_MARKDOWN_POLICY" 2>/dev/null || return 1
        (( column+=measured[width], padding=4-column%4, column+=padding ))
        expanded+="$segment${(l:padding:: :)${:-}}"
      done
      expanded+="$line"$'\n'
    done
    logical[$b]=${expanded%$'\n'}
  done
  for (( r=1; r<=document[line_count]; r++ )); do
    text=$document[line,$r,text]; b=$document[line,$r,block]
    kind=${document[block,$b,kind]-}
    UI_COPY_TEXTS[r]=''; UI_COPY_COLUMNS[r]=-1; UI_COPY_GAPS[r]=$'\n'
    [[ $document[line,$r,role] == code-label || $kind == rule ]] && continue
    prefix_cells=2
    if [[ $kind == code ]]; then
      text=''
      for (( j=1; j<=document[line,$r,span_count]; j++ )); do
        if (( document[line,$r,span,$j,style] & document[style,code] )); then text+=$document[line,$r,span,$j,text]
        else (( prefix_cells+=document[line,$r,span,$j,cells] )); fi
      done
    fi
    UI_COPY_TEXTS[r]=$text; UI_COPY_COLUMNS[r]=$prefix_cells
    [[ -n $text && $kind != table && -n ${logical[$b]-} ]] || continue
    pos=${cursor[$b]:-1}; rest=${logical[$b][$pos,-1]}
    candidate=$text; drop=0
    while true; do
      if [[ $rest == *"$candidate"* ]]; then
        before=${rest%%"$candidate"*}
        if [[ $before == [[:space:]]# ]]; then
          [[ ${previous[$b]-0} == 1 ]] && UI_COPY_GAPS[r]=$before
          UI_COPY_TEXTS[r]=$candidate
          UI_COPY_COLUMNS[r]=$((prefix_cells+drop))
          cursor[$b]=$((pos+${#before}+${#candidate}))
          previous[$b]=1
          break
        fi
      fi
      # Only remove generated left padding, never a nonblank source character.
      [[ $candidate == ' '* && -n ${candidate# } ]] || { previous[$b]=0; break; }
      candidate=${candidate# }; (( drop++ ))
    done
  done
}
