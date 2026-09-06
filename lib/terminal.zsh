# Optional terminal modes belong to the interactive UI, never to workers.
typeset -g TERMINAL_FD='' TERMINAL_SYNC_STATE=inactive TERMINAL_SYNC_POLICY=auto
typeset -gi TERMINAL_SYNC_ENABLED=0 TERMINAL_FRAME_ACTIVE=0 TERMINAL_PASTE=0 TERMINAL_CSI_DISCARD=0
typeset -gF TERMINAL_QUERY_DEADLINE=0.0 TERMINAL_ESCAPE_AT=0.0
typeset -g TERMINAL_SEQUENCE='' TERMINAL_PASTE_TAIL=''
typeset -ga TERMINAL_INPUT_QUEUE=()

_terminal_write() {
  [[ -n "$TERMINAL_FD" ]] || return 1
  print -rn -u "$TERMINAL_FD" -- "$1" 2>/dev/null
}

terminal_start() {
  emulate -L zsh
  terminal_end
  TERMINAL_SYNC_POLICY=${ZCODER_SYNC_OUTPUT:-auto}
  TERMINAL_SYNC_STATE=unavailable
  zmodload zsh/system || return 0
  sysopen -w -o cloexec -u TERMINAL_FD /dev/tty 2>/dev/null || return 0
  _terminal_write $'\e[?2004h'
  case "$TERMINAL_SYNC_POLICY" in
    true) TERMINAL_SYNC_ENABLED=1; TERMINAL_SYNC_STATE=forced ;;
    false) TERMINAL_SYNC_STATE=disabled ;;
    auto)
      TERMINAL_SYNC_STATE=pending
      TERMINAL_QUERY_DEADLINE=$(( EPOCHREALTIME + 1.0 ))
      _terminal_write $'\e[?2026$p' || TERMINAL_SYNC_STATE=unavailable
      ;;
    *) TERMINAL_SYNC_STATE='disabled (invalid setting)' ;;
  esac
  return 0
}

terminal_end() {
  emulate -L zsh
  if [[ -n "$TERMINAL_FD" ]]; then
    (( TERMINAL_FRAME_ACTIVE )) && _terminal_write $'\e[?2026l'
    _terminal_write $'\e[?2004l'
    exec {TERMINAL_FD}>&-
  fi
  TERMINAL_FD=''; TERMINAL_FRAME_ACTIVE=0; TERMINAL_SYNC_ENABLED=0
  TERMINAL_SYNC_STATE=inactive
  TERMINAL_SEQUENCE=''; TERMINAL_INPUT_QUEUE=(); TERMINAL_PASTE=0; TERMINAL_PASTE_TAIL=''; TERMINAL_CSI_DISCARD=0
  return 0
}

terminal_refresh() {
  emulate -L zsh
  local -i refresh_result=0
  {
    if (( TERMINAL_SYNC_ENABLED )) && _terminal_write $'\e[?2026h'; then
      TERMINAL_FRAME_ACTIVE=1
    fi
    zcurses refresh "$@"
    refresh_result=$?
  } always {
    if (( TERMINAL_FRAME_ACTIVE )); then
      _terminal_write $'\e[?2026l'
      TERMINAL_FRAME_ACTIVE=0
    fi
  }
  return "$refresh_result"
}

terminal_poll() {
  if [[ "$TERMINAL_SYNC_STATE" == pending ]] && (( EPOCHREALTIME >= TERMINAL_QUERY_DEADLINE )); then
    TERMINAL_SYNC_STATE='no reply'
  fi
}

# Queue complete ordinary escape sequences unchanged. Consume DECRPM replies
# before any editor, palette, or approval callback can interpret their final y.
# The queue stores character/key/mouse triples; it never evaluates input text.
terminal_filter_input() {
  emulate -L zsh
  local byte="$1" event_key="$2" event_mouse="$3" queued_byte=''
  terminal_poll
  if [[ -n "$event_key" ]]; then
    # Decoded keys may arrive between reply fragments. Deliver the key without
    # losing the CSI prefix, or its eventual final byte could reach a dialog.
    if [[ "$event_key" == RESIZE || "$TERMINAL_SEQUENCE" == $'\e['* ]]; then
      TERMINAL_INPUT_QUEUE+=("$byte" "$event_key" "$event_mouse")
      return 0
    fi
    # Curses has already decoded this key. Any preceding Escape is independent.
    for queued_byte in "${(@s::)TERMINAL_SEQUENCE}"; do
      TERMINAL_INPUT_QUEUE+=("$queued_byte" '' '')
    done
    TERMINAL_SEQUENCE=''; TERMINAL_CSI_DISCARD=0
    TERMINAL_INPUT_QUEUE+=("$byte" "$event_key" "$event_mouse")
    return 0
  fi
  if [[ -z "$byte" ]]; then
    if [[ "$TERMINAL_SEQUENCE" == $'\e' ]] && (( EPOCHREALTIME - TERMINAL_ESCAPE_AT >= 0.05 )); then
      TERMINAL_INPUT_QUEUE+=($'\e' '' '')
      TERMINAL_SEQUENCE=''
    fi
    return 0
  fi
  if (( TERMINAL_PASTE )); then
    TERMINAL_INPUT_QUEUE+=("$byte" '' "$event_mouse")
    TERMINAL_PASTE_TAIL="${TERMINAL_PASTE_TAIL}${byte}"
    TERMINAL_PASTE_TAIL="${TERMINAL_PASTE_TAIL[-6,-1]}"
    [[ "$TERMINAL_PASTE_TAIL" == $'\e[201~' ]] && TERMINAL_PASTE=0
    return 0
  fi
  if [[ -z "$TERMINAL_SEQUENCE" ]]; then
    if [[ "$byte" == $'\e' ]]; then
      TERMINAL_SEQUENCE="$byte"; TERMINAL_ESCAPE_AT=$EPOCHREALTIME
    else
      TERMINAL_INPUT_QUEUE+=("$byte" '' "$event_mouse")
    fi
    return 0
  fi
  TERMINAL_SEQUENCE+="$byte"
  if [[ "$TERMINAL_SEQUENCE" == $'\e[' ]]; then return 0; fi
  if [[ "$TERMINAL_SEQUENCE" == $'\e['* ]]; then
    # A CSI ends at its first ASCII final byte. Keep memory bounded even when a
    # broken terminal supplies unending parameter bytes; discard until final.
    if [[ "$byte" != [@-~] ]]; then
      if (( ${#TERMINAL_SEQUENCE} > 64 )); then
        TERMINAL_SEQUENCE=$'\e['; TERMINAL_CSI_DISCARD=1
      fi
      return 0
    fi
    if (( TERMINAL_CSI_DISCARD )); then
      TERMINAL_SEQUENCE=''; TERMINAL_CSI_DISCARD=0
      return 0
    fi
    if [[ "$TERMINAL_SEQUENCE" == $'\e[?2026;'* ]]; then
      if [[ "$TERMINAL_SYNC_STATE" == pending ]]; then
        case "$TERMINAL_SEQUENCE" in
          $'\e[?2026;1$y'|$'\e[?2026;2$y')
            TERMINAL_SYNC_ENABLED=1; TERMINAL_SYNC_STATE=supported ;;
          *) TERMINAL_SYNC_STATE=unsupported ;;
        esac
      fi
      TERMINAL_SEQUENCE=''
      return 0
    fi
    [[ "$TERMINAL_SEQUENCE" == $'\e[200~' ]] && { TERMINAL_PASTE=1; TERMINAL_PASTE_TAIL=''; }
  fi
  for queued_byte in "${(@s::)TERMINAL_SEQUENCE}"; do
    TERMINAL_INPUT_QUEUE+=("$queued_byte" '' '')
  done
  TERMINAL_SEQUENCE=''
  return 0
}

# Output variables are caller-owned (Zsh dynamic scope), like zcurses input.
terminal_read_event() {
  emulate -L zsh
  local terminal_byte='' terminal_key='' terminal_mouse=''
  if (( ! ${#TERMINAL_INPUT_QUEUE} )); then
    zcurses input "$1" terminal_byte terminal_key terminal_mouse
    terminal_filter_input "$terminal_byte" "$terminal_key" "$terminal_mouse"
  fi
  printf -v "$2" '%s' "${TERMINAL_INPUT_QUEUE[1]:-}"
  printf -v "$3" '%s' "${TERMINAL_INPUT_QUEUE[2]:-}"
  printf -v "$4" '%s' "${TERMINAL_INPUT_QUEUE[3]:-}"
  TERMINAL_INPUT_QUEUE[1,3]=()
  return 0
}
