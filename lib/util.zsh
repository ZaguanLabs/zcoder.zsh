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

zcoder_wrap() {
  local rest="$1" width="${2:-1}" probe="" line="" prefix=""
  local -i cut
  ZCODER_WRAPPED=()
  (( width < 1 )) && width=1
  [[ -z "$rest" ]] && { ZCODER_WRAPPED+=(""); return 0; }

  while (( ${#rest} > width )); do
    probe="${rest[1,$width]}"
    prefix="${probe%[[:space:]]*}"
    if [[ "${rest[$(( width + 1 ))]}" == [[:space:]] ]]; then
      line="$probe"
      rest="${rest[$(( width + 2 )),-1]}"
      rest="${rest##[[:space:]]#}"
    elif [[ -n "$prefix" && "$prefix" != "$probe" ]]; then
      cut=${#prefix}
      line="${rest[1,$cut]}"
      rest="${rest[$(( cut + 1 )),-1]}"
      rest="${rest##[[:space:]]#}"
    else
      line="$probe"
      rest="${rest[$(( width + 1 )),-1]}"
    fi
    ZCODER_WRAPPED+=("$line")
  done
  ZCODER_WRAPPED+=("$rest")
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
