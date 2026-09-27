# Bounded, read-only documents use the application's modal lifecycle. The
# transcript and approval dialogs keep their existing independent renderers.
typeset -gi UI_DOCUMENT_HELPERS=0
() {
  emulate -L zsh
  local library="${1:A:h:h}/vendor/zdraw/lib/zdraw-document.zsh"
  [[ -r $library ]] || return 0
  source "$library" || return 0
  UI_DOCUMENT_HELPERS=1
} "${(%):-%x}"

ui_document_view() {
  emulate -L zsh
  local -i document_markdown=0
  if [[ $1 == --markdown ]]; then
    [[ ${UI_MARKDOWN_BACKEND:-zsh} == zmdown ]] && document_markdown=1
    shift
  fi
  local title=$1 id kind text
  shift
  (( $# % 3 == 0 )) || return 1
  local -a document_blocks=() modal_lines=() document_headings=() document_line_blocks=() document_line_kinds=()
  local -a document_starts=() document_counts=() document_texts=() document_styles=()
  local -A zdraw_ui_document zdraw_ui_theme
  local -i document_native=0 document_width=0
  local modal_hint='Esc Close  Up/Down Scroll  [/] Section'
  for id kind text in "$@"; do
    # This viewer accepts trusted block metadata and literal, printable text.
    [[ $kind == (heading|subheading|paragraph|bullet|code) ]] || return 1
    zcoder_terminal_safe "$text"
    document_blocks+=("$id" "$kind" "$REPLY")
  done
  if (( ! document_markdown && UI_DOCUMENT_HELPERS )) && ui_widgets_available text_positions; then
    document_native=1
    ui_widget_theme
    modal_hint='Esc Close  [/] Section  PgUp/PgDn Scroll'
  fi
  ui_modal_run "$title" _ui_document_draw _ui_document_input 24 92
}

# The source stays literal for copying and fallback. Only this adapter adds
# Markdown, highlighting the shortcut before a bullet's colon. Escape source
# punctuation so runtime descriptions cannot introduce Markdown structure.
_ui_document_markdown_layout() {
  emulate -L zsh
  local id kind text escaped char markdown label previous_kind=''
  local -i block=0 row span start count old_block=${document_line_blocks[modal_selected]:-0}
  local -i UI_SELECTION_ENABLED=0
  local -a native_lines native_attrs native_starts native_counts native_texts native_styles
  local -a native_copy_texts native_copy_columns native_copy_gaps
  modal_lines=(); document_headings=(); document_line_blocks=(); document_line_kinds=()
  document_starts=(); document_counts=(); document_texts=(); document_styles=()
  for id kind text in "${document_blocks[@]}"; do
    if [[ -n $previous_kind && "$previous_kind/$kind" != bullet/bullet ]]; then
      modal_lines+=(''); document_line_blocks+=("$block"); document_line_kinds+=(paragraph)
      document_starts+=(1); document_counts+=(0)
    fi
    (( block++ ))
    (( block == old_block )) && modal_selected=$(( ${#modal_lines}+1 ))
    [[ $kind == (heading|subheading) ]] && document_headings+=("$(( ${#modal_lines}+1 ))")
    label=''
    if [[ $kind == bullet && $text == *': '* && $text != *\`* ]]; then
      label=${text%%: *}; text=${text#*: }
    fi
    escaped=''
    for char in "${(@s::)text}"; do
      [[ $char == [[:punct:]] && $char == [\ -\~] ]] && escaped+='\'
      escaped+=$char
    done
    case $kind in
      heading) markdown="## $escaped" ;;
      subheading) markdown="### $escaped" ;;
      bullet)
        markdown="- $escaped"
        [[ -n $label ]] && markdown='- `'$label'`: '$escaped ;;
      code) markdown=$'```\n'$text$'\n```' ;;
      *) markdown=$escaped ;;
    esac
    _ui_markdown_native_layout "$markdown" "$1" || return 1
    for (( row=1; row<=${#native_lines}; row++ )); do
      modal_lines+=("$native_lines[row]")
      document_line_blocks+=("$block"); document_line_kinds+=("$kind")
      document_starts+=("$(( ${#document_texts}+1 ))")
      count=$native_counts[row]; start=$native_starts[row]
      document_counts+=("$count")
      for (( span=start; span<start+count; span++ )); do
        document_texts+=("$native_texts[span]")
        # Shortcuts remain distinct when the theme suppresses color.
        if [[ $native_styles[span] == yellow/black ]]; then
          document_styles+=('bold yellow/black')
        else
          document_styles+=("$native_styles[span]")
        fi
      done
    done
    previous_kind=$kind
  done
  return 0
}

_ui_document_layout() {
  emulate -L zsh
  local -i width=$(( modal_w-4 )) i block=0 old_block=${document_line_blocks[modal_selected]:-0}
  local id kind text line previous_kind='' prefix=''
  local -i wrap_width
  (( width == document_width )) && return 0
  if (( document_markdown )); then
    if _ui_document_markdown_layout "$width"; then
      document_width=$width
      return 0
    fi
    # A rejected layout falls back as a whole, using the original literal text.
    document_markdown=0
  fi
  if (( document_native )); then
    if (( document_width )); then
      zdraw-document-reflow "$width" 2>/dev/null || document_native=0
    else
      zdraw-document-init "$width" "${document_blocks[@]}" 2>/dev/null || document_native=0
    fi
  fi
  modal_lines=(); document_headings=(); document_line_blocks=(); document_line_kinds=()
  if (( document_native )); then
    for (( i=1; i<=zdraw_ui_document[line_count]; i++ )); do
      modal_lines+=("${zdraw_ui_document[$i,text]}")
      document_line_blocks+=("${zdraw_ui_document[$i,block]}")
      document_line_kinds+=("${zdraw_ui_document[b,${zdraw_ui_document[$i,block]},kind]}")
    done
    for (( i=1; i<=zdraw_ui_document[count]; i++ )); do
      [[ ${zdraw_ui_document[b,$i,kind]} == (heading|subheading) ]] && document_headings+=("${zdraw_ui_document[b,$i,line]}")
    done
    modal_selected=$zdraw_ui_document[first]
  else
    # Stock curses retains the same content and section navigation. On reflow,
    # preserve its source block; zdraw additionally preserves a source byte.
    for id kind text in "${document_blocks[@]}"; do
      if [[ -n $previous_kind && "$previous_kind/$kind" != bullet/bullet ]]; then
        modal_lines+=(''); document_line_blocks+=("$block"); document_line_kinds+=(paragraph)
      fi
      (( block++ ))
      (( block == old_block )) && modal_selected=$(( ${#modal_lines}+1 ))
      [[ $kind == (heading|subheading) ]] && document_headings+=("$(( ${#modal_lines}+1 ))")
      prefix=''; wrap_width=$width
      if [[ $kind == bullet ]] && (( width > 2 )); then
        prefix='- '; (( wrap_width-=2 ))
      fi
      for line in "${(@ps:\n:)text}"; do
        if [[ $kind == code ]]; then zcoder_hard_wrap "$line" "$wrap_width"
        else zcoder_wrap "$line" "$wrap_width"; fi
        for line in "${ZCODER_WRAPPED[@]}"; do
          modal_lines+=("$prefix$line"); document_line_blocks+=("$block"); document_line_kinds+=("$kind")
          [[ -n $prefix ]] && prefix='  '
        done
      done
      previous_kind=$kind
    done
  fi
  document_width=$width
  return 0
}

_ui_document_draw() {
  emulate -L zsh
  _ui_document_layout || return
  if (( document_native )); then
    zdraw-document-scroll "$modal_rows" keep || return
    modal_selected=$zdraw_ui_document[first]
    if zdraw-document overlay_win 2 2 "$modal_rows" "$document_width" normal 2>/dev/null; then
      ui_modal_text "$(( modal_h-2 ))" "$modal_hint" 'dim cyan/black'
      return 0
    fi
    # Compiled text and position remain usable after a partial paint failure.
    document_native=0
    ui_modal_frame
  fi
  local -i i row=2 span start count max_scroll=$(( ${#modal_lines}-modal_rows+1 ))
  local -a spans
  local attr
  (( max_scroll < 1 )) && max_scroll=1
  (( modal_selected > max_scroll )) && modal_selected=$max_scroll
  for (( i=modal_selected; i<=${#modal_lines} && row<modal_h-2; i++,row++ )); do
    if (( document_markdown )); then
      spans=(); start=$document_starts[i]; count=$document_counts[i]
      if (( ! count )); then
        ui_modal_text "$row" ' ' 'white/black'
        continue
      fi
      for (( span=start; span<start+count; span++ )); do
        spans+=("$document_styles[span]" "$document_texts[span]")
      done
      ui_markdown_draw_row overlay_win "$row" 2 "$document_width" "${spans[@]}"
      continue
    fi
    attr='white/black'
    [[ ${document_line_kinds[i]} == (heading|subheading) ]] && attr='bold cyan/black'
    ui_modal_text "$row" "${modal_lines[i]}" "$attr"
  done
  ui_modal_text "$(( modal_h-2 ))" "$modal_hint" 'dim cyan/black'
  return 0
}

_ui_document_input() {
  emulate -L zsh
  local action=''
  local -i heading target=0 max_scroll=$(( ${#modal_lines}-modal_rows+1 ))
  case $modal_key in
    UP) action=up ;; DOWN) action=down ;; PPAGE) action=page-up ;;
    NPAGE) action=page-down ;; HOME) action=home ;; END) action=end ;;
    ENTER|PADENTER) modal_done=1; modal_accepted=1; return 0 ;;
  esac
  if [[ -z $action ]]; then
    case $modal_ch in
      k) action=up ;; j) action=down ;; '[') action=previous-heading ;; ']') action=next-heading ;;
      q|$'\e'|$'\x03'|$'\r'|$'\n') modal_done=1; modal_accepted=1; return 0 ;;
      *) return 0 ;;
    esac
  fi
  if (( document_native )); then
    zdraw-document-scroll "$modal_rows" "$action" || return
    modal_selected=$zdraw_ui_document[first]
  else
    case $action in
      up) (( modal_selected-- )) ;; down) (( modal_selected++ )) ;;
      page-up) (( modal_selected-=modal_rows-1 )) ;; page-down) (( modal_selected+=modal_rows-1 )) ;;
      home) modal_selected=1 ;; end) modal_selected=$max_scroll ;;
      next-heading|previous-heading)
        for heading in "${document_headings[@]}"; do
          if [[ $action == next-heading ]] && (( heading > modal_selected && ! target )); then target=$heading
          elif [[ $action == previous-heading ]] && (( heading < modal_selected )); then target=$heading; fi
        done
        (( target )) && modal_selected=$target ;;
    esac
    (( max_scroll < 1 )) && max_scroll=1
    (( modal_selected > max_scroll )) && modal_selected=$max_scroll
    (( modal_selected < 1 )) && modal_selected=1
  fi
  modal_dirty=1
  return 0
}
