# Display-only Markdown subset for model replies. No evaluation or terminal
# dependencies: emit the same rows and styled spans as the edit previews.
# Unsupported constructs and incomplete streaming delimiters remain literal.

# Append to the dynamically scoped md_texts/md_attrs owned by the line renderer.
_ui_markdown_inline() {
  emulate -L zsh
  setopt extendedglob
  local text="$1" attr="$2" plain='' ch='' marker='' body='' styled=''
  local -i depth=${3:-0} pos=1 end=0 run=0 close=0 stop=0 length=${#1}
  if [[ "$text" != *[\*\_\`\\]* ]]; then
    [[ -n "$text" ]] && { md_texts+=("$text"); md_attrs+=("$attr"); }
    return 0
  fi
  while (( pos <= length )); do
    ch="${text[pos]}"
    if [[ "$ch" == \\ && "${text[pos+1]}" == [[:punct:]] ]]; then
      plain+="${text[pos+1]}"; (( pos += 2 )); continue
    fi
    if (( depth < 8 )) && [[ "$ch" == [\*\_\`] ]]; then
      end=$pos
      while (( end <= length )) && [[ "${text[end]}" == "$ch" ]]; do (( end++ )); done
      run=$(( end - pos )); marker="${text[pos,end-1]}"; close=0
      # Underscores within identifiers are data, not emphasis delimiters.
      if [[ "$ch" == \` ]] || { (( run <= 3 )) &&
          [[ "${text[end]}" != [[:space:]] && -n "${text[end]}" ]] &&
          { [[ "$ch" != _ ]] || (( pos == 1 )) || [[ "${text[pos-1]}" != [[:alnum:]] ]]; }; }; then
        stop=$end
        while (( stop <= length )); do
          if [[ "$ch" != \` && "${text[stop]}" == \\ ]]; then
            (( stop += 2 )); continue
          fi
          if [[ "${text[stop]}" == "$ch" ]]; then
            close=$stop
            while (( stop <= length )) && [[ "${text[stop]}" == "$ch" ]]; do (( stop++ )); done
            if (( stop - close == run && close > end )) &&
                { [[ "$ch" == \` ]] || [[ "${text[close-1]}" != [[:space:]] ]]; } &&
                { [[ "$ch" != _ ]] || [[ "${text[stop]}" != [[:alnum:]] ]]; }; then
              break
            fi
            close=0
          else
            (( stop++ ))
          fi
        done
      fi
      if (( close > 0 )); then
        [[ -n "$plain" ]] && { md_texts+=("$plain"); md_attrs+=("$attr"); plain=''; }
        body="${text[end,close-1]}"
        if [[ "$ch" == \` ]]; then
          # Code spans are opaque, including Markdown and shell metacharacters.
          if [[ "$body" == ' '*' ' && "$body" != ' '# ]]; then body="${body[2,-2]}"; fi
          md_texts+=("$body"); md_attrs+=("yellow/black")
        else
          styled="$attr"
          (( run != 1 )) && styled="bold $styled"
          # Underline works on both stock zsh/curses and zdraw terminals.
          (( run != 2 )) && styled="underline $styled"
          _ui_markdown_inline "$body" "$styled" $(( depth + 1 ))
        fi
        pos=$stop
        continue
      fi
      plain+="$marker"; pos=$end; continue
    fi
    plain+="$ch"; (( pos++ ))
  done
  [[ -n "$plain" ]] && { md_texts+=("$plain"); md_attrs+=("$attr"); }
  return 0
}

_ui_add_markdown_inline() {
  emulate -L zsh
  local text="$1" prefix="$3" attr="$4" line='' visible=''
  local -a md_texts=() md_attrs=() lines=() lengths=()
  local -i width=$2 row=0 offset=0 span=1 span_start=0 span_end=0 first=0 last=0 row_end=0
  _ui_markdown_inline "$text" "$attr"
  visible="${(j::)md_texts}"
  zcoder_wrap "$visible" $(( width - ${(m)#prefix} ))
  lines=("${ZCODER_WRAPPED[@]}"); lengths=("${ZCODER_WRAPPED_LENGTHS[@]}")
  for line in "${lines[@]}"; do
    (( row++ )); row_end=$(( offset + ${#line} ))
    _ui_add_line "${prefix}${line}" "$attr"
    _ui_add_segment "$prefix" "$attr"
    # Wrapper lengths count consumed source characters, including skipped
    # spaces. Intersect each visible row with spans before advancing by that
    # count, so styles survive word wraps, wide glyphs and combining marks.
    while (( span <= ${#md_texts} )); do
      span_end=$(( span_start + ${#md_texts[span]} ))
      (( span_start >= row_end )) && break
      first=$(( (span_start > offset ? span_start : offset) - offset + 1 ))
      last=$(( (span_end < row_end ? span_end : row_end) - offset ))
      (( last >= first )) && _ui_add_segment "${line[first,last]}" "${md_attrs[span]}"
      (( span_end > row_end )) && break
      span_start=$span_end; (( span++ ))
    done
    (( offset += lengths[row] ))
  done
  return 0
}

_ui_add_markdown() {
  emulate -L zsh
  setopt extendedglob
  local content="$1" attr="${3:-white/black}" line='' trimmed='' fence='' marker='' language=plain info=''
  local -a lines=("${(@f)content}")
  local -i width=$2 run=0
  for line in "${lines[@]}"; do
    trimmed="${line## #}"
    # At most three leading spaces; indented code remains literal.
    if (( ${#line} - ${#trimmed} <= 3 )) && [[ "$trimmed" == (\`\`\`*|\~\~\~*) ]]; then
      marker="${trimmed[1]}"; run=1
      while [[ "${trimmed[run+1]}" == "$marker" ]]; do (( run++ )); done
      info="${trimmed[run+1,-1]}"
      if [[ -n "$fence" ]]; then
        if [[ "$marker" == "${fence[1]}" && "$info" == [[:space:]]# ]] && (( run >= ${#fence} )); then
          fence=''; continue
        fi
      elif [[ "$marker" != \` || "$info" != *\`* ]]; then
        fence="${trimmed[1,run]}"
        info="${info##[[:space:]]#}"; info="${info%%[[:space:]]*}"
        _ui_language_for_path "code.${info:l}"; language="$REPLY"
        case "${info:l}" in
          shell|shellscript) language=shell ;;
          python|javascript|typescript|rust|ruby|markup) language="${info:l}" ;;
          diff|patch) language=diff ;;
        esac
        _ui_add_hard_wrapped "${info:-code}" "$width" '  ' 'dim cyan/black'
        continue
      fi
    fi
    if [[ -n "$fence" ]]; then
      if [[ "$language" == diff ]]; then
        _ui_diff_attr "$line"
        _ui_add_hard_wrapped "$line" "$width" '    ' "$REPLY"
      else
        _ui_add_syntax_wrapped "$line" "$width" '    ' "$language"
      fi
    elif [[ -z "$line" ]]; then
      _ui_add_line '' default/default
    elif [[ "$line" == '    '* ]]; then
      _ui_add_hard_wrapped "$line" "$width" '  ' 'white/black'
    elif (( ${#line} - ${#trimmed} <= 3 )) && [[ "$trimmed" == \#(#c1,6)[[:space:]]* ]]; then
      trimmed="${trimmed##\##}"; trimmed="${trimmed##[[:space:]]#}"
      _ui_add_markdown_inline "$trimmed" "$width" '  ' "bold magenta/black"
    else
      _ui_add_markdown_inline "$line" "$width" '  ' "$attr"
    fi
  done
}
