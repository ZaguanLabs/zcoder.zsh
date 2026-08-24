# Small native Zsh helpers shared by the TUI and tools.

typeset -ga ZCODER_WRAPPED=()
typeset -g ZCODER_DEBUG_LOG="${ZCODER_DEBUG_LOG:-}"
typeset -gi ZCODER_DEBUG_ACTIVE=0
typeset -gi ZCODER_DEBUG_MAX_CHARS="${ZCODER_DEBUG_MAX_CHARS:-16000}"

# Debugging must never write through curses. The opt-in logger appends escaped,
# single-line records to a private file so a broken model turn can be inspected
# after the UI returns to Ready.
zcoder_debug_init() {
  [[ -n "$ZCODER_DEBUG_LOG" ]] || return 0
  ZCODER_DEBUG_LOG="${ZCODER_DEBUG_LOG:A}"
  local parent="${ZCODER_DEBUG_LOG:h}" old_umask="$(umask)"
  zf_mkdir -p "$parent" 2>/dev/null || return 1
  umask 077
  if print -r -- "[${EPOCHREALTIME:-0}] pid=$$ debug_start log=${ZCODER_DEBUG_LOG}" >> "$ZCODER_DEBUG_LOG" 2>/dev/null; then
    ZCODER_DEBUG_ACTIVE=1
  fi
  umask "$old_umask"
  (( ZCODER_DEBUG_ACTIVE ))
}

zcoder_debug() {
  (( ZCODER_DEBUG_ACTIVE )) || return 0
  local event="${1:-event}" detail="${2:-}"
  detail="${detail//$'\r'/\\r}"
  detail="${detail//$'\n'/\\n}"
  detail="${detail//$'\t'/\\t}"
  if (( ${#detail} > ZCODER_DEBUG_MAX_CHARS )); then
    detail="${detail[1,$ZCODER_DEBUG_MAX_CHARS]}...[debug record truncated]"
  fi
  print -r -- "[${EPOCHREALTIME:-0}] pid=$$ ${event} ${detail}" >> "$ZCODER_DEBUG_LOG" 2>/dev/null || true
}

# Wrap using a character array and index arithmetic: re-slicing the remaining
# text each round makes wrapping quadratic in Zsh, which stalls redraws of
# transcripts containing long lines.
zcoder_wrap() {
  local width="${2:-1}" probe="" prefix=""
  local -a chars=()
  local -i cut pos=1 total
  ZCODER_WRAPPED=()
  (( width < 1 )) && width=1
  [[ -z "$1" ]] && { ZCODER_WRAPPED+=(""); return 0; }

  chars=("${(@s::)1}")
  total=${#chars}
  while (( total - pos + 1 > width )); do
    probe="${(j::)chars[pos,pos+width-1]}"
    prefix="${probe%[[:space:]]*}"
    if [[ "${chars[pos+width]}" == [[:space:]] ]]; then
      ZCODER_WRAPPED+=("$probe")
      (( pos += width + 1 ))
      while (( pos <= total )) && [[ "${chars[pos]}" == [[:space:]] ]]; do (( pos++ )); done
    elif [[ -n "$prefix" && "$prefix" != "$probe" ]]; then
      cut=${#prefix}
      ZCODER_WRAPPED+=("$prefix")
      (( pos += cut ))
      while (( pos <= total )) && [[ "${chars[pos]}" == [[:space:]] ]]; do (( pos++ )); done
    else
      ZCODER_WRAPPED+=("$probe")
      (( pos += width ))
    fi
  done
  ZCODER_WRAPPED+=("${(j::)chars[pos,total]}")
}

zcoder_pad() {
  local value="$1" width="${2:-0}"
  REPLY="${(r:$width:)value}"
}

zcoder_time() {
  strftime -s REPLY '%H:%M'
}

zcoder_truncate() {
  local value="$1" limit="${2:-${ZCODER_MAX_TOOL_OUTPUT:-32768}}"
  if (( ${#value} > limit )); then
    REPLY="${value[1,$limit]}"$'\n'"[output truncated at ${limit} characters]"
  else
    REPLY="$value"
  fi
}
