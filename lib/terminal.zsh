# Optional terminal modes belong to the interactive UI, never to workers.
typeset -g TERMINAL_FD='' TERMINAL_SYNC_STATE=inactive TERMINAL_SYNC_POLICY=auto
typeset -gi TERMINAL_SYNC_ENABLED=0 TERMINAL_FRAME_ACTIVE=0 TERMINAL_PASTE=0 TERMINAL_CSI_DISCARD=0
typeset -gF TERMINAL_QUERY_DEADLINE=0.0 TERMINAL_ESCAPE_AT=0.0
typeset -g TERMINAL_SEQUENCE='' TERMINAL_PASTE_TAIL=''
typeset -ga TERMINAL_INPUT_QUEUE=()
typeset -gi TERMINAL_NOREFRESH_INPUT=0
typeset -ga TERMINAL_EVENT_FLAGS=()
typeset -gi TERMINAL_CAN_PASTE=0 TERMINAL_NATIVE_PASTE=0 TERMINAL_EVENT_POLL=0
typeset -gi TERMINAL_INPUT_FD=-1 TERMINAL_WAIT_MS=20
typeset -gi TERMINAL_PASTE_BYTES=0 TERMINAL_PASTE_REJECTED=0 TERMINAL_PASTE_LIMIT=1048576
typeset -ga TERMINAL_PASTE_CHUNKS=()
# Paste payload is separate from character input: dialogs must never see pasted
# approval keys. It is valid only alongside the current PASTE event.
typeset -g TERMINAL_EVENT_TEXT=''

# Discover once per UI entry; input timeouts must never probe another reader.
terminal_detect_input() {
  emulate -L zsh
  local -a reply=()
  TERMINAL_NOREFRESH_INPUT=0; TERMINAL_EVENT_FLAGS=()
  TERMINAL_CAN_PASTE=0; TERMINAL_EVENT_POLL=0
  if zcoder_curses_features &&
     (( ${reply[(Ie)structured_events]} && ${reply[(Ie)norefresh_events]} )); then
    TERMINAL_NOREFRESH_INPUT=1
    TERMINAL_EVENT_FLAGS=(norefresh)
    (( ${reply[(Ie)mouse]} )) && TERMINAL_EVENT_FLAGS+=(mouse)
    (( ${reply[(Ie)streaming_paste]} )) && TERMINAL_CAN_PASTE=1
    (( ${reply[(Ie)event_poll]} && ${reply[(Ie)input_info]} )) && TERMINAL_EVENT_POLL=1
  fi
  return 0
}

_terminal_write() {
  [[ -n "$TERMINAL_FD" ]] || return 1
  print -rn -u "$TERMINAL_FD" -- "$1" 2>/dev/null
}

terminal_start() {
  emulate -L zsh
  terminal_end
  terminal_detect_input
  TERMINAL_SYNC_POLICY=${ZCODER_SYNC_OUTPUT:-auto}
  TERMINAL_SYNC_STATE=unavailable
  zmodload zsh/system || { TERMINAL_EVENT_POLL=0; return 0; }
  sysopen -w -o cloexec -u TERMINAL_FD /dev/tty 2>/dev/null || { TERMINAL_EVENT_POLL=0; return 0; }
  if (( TERMINAL_CAN_PASTE )) && zcoder_curses paste on 2>/dev/null; then
    TERMINAL_NATIVE_PASTE=1
  else
    _terminal_write $'\e[?2004h'
  fi
  if (( TERMINAL_EVENT_POLL )); then
    local -A input_info=()
    if zmodload zsh/zselect && zcoder_curses inputinfo input_info &&
       [[ ${input_info[fd]} == 0 && ${input_info[wait_ms]} == <1-> ]]; then
      TERMINAL_INPUT_FD=0
      TERMINAL_WAIT_MS=$(( input_info[wait_ms] < 20 ? input_info[wait_ms] : 20 ))
    else
      TERMINAL_EVENT_POLL=0
    fi
  fi
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
  if (( TERMINAL_NATIVE_PASTE )); then
    # An unfinished paste cannot be disabled. End the session to abandon its
    # queued bytes and restore raw mode; normal UI teardown also calls end.
    zcoder_curses paste off 2>/dev/null || zcoder_curses end 2>/dev/null
  fi
  if [[ -n "$TERMINAL_FD" ]]; then
    (( TERMINAL_FRAME_ACTIVE )) && _terminal_write $'\e[?2026l'
    _terminal_write $'\e[?2004l'
    exec {TERMINAL_FD}>&-
  fi
  TERMINAL_FD=''; TERMINAL_FRAME_ACTIVE=0; TERMINAL_SYNC_ENABLED=0
  TERMINAL_SYNC_STATE=inactive
  TERMINAL_NOREFRESH_INPUT=0; TERMINAL_EVENT_FLAGS=()
  TERMINAL_CAN_PASTE=0; TERMINAL_NATIVE_PASTE=0; TERMINAL_EVENT_POLL=0
  TERMINAL_INPUT_FD=-1; TERMINAL_WAIT_MS=20
  TERMINAL_PASTE_BYTES=0; TERMINAL_PASTE_REJECTED=0; TERMINAL_PASTE_CHUNKS=(); TERMINAL_EVENT_TEXT=''
  TERMINAL_SEQUENCE=''; TERMINAL_INPUT_QUEUE=(); TERMINAL_PASTE=0; TERMINAL_PASTE_TAIL=''; TERMINAL_CSI_DISCARD=0
  return 0
}

# Status 2 means the caller may use its full teardown/reinitialization fallback.
# A runtime refusal (notably an unfinished paste) must not trigger that fallback.
terminal_suspend() {
  emulate -L zsh
  local -a reply=()
  (( TERMINAL_PASTE )) && return 1
  zcoder_curses_features && (( ${reply[(Ie)suspend_resume]} )) || return 2
  if (( TERMINAL_FRAME_ACTIVE )); then
    _terminal_write $'\e[?2026l' || return 1
    TERMINAL_FRAME_ACTIVE=0
  fi
  zcoder_curses suspend 2>/dev/null || return $?
  # zdraw restores only the protocols it owns. Older builds may still use our
  # Zsh paste decoder, whose mode must be disabled during foreground input.
  if (( ! TERMINAL_NATIVE_PASTE )) && [[ -n $TERMINAL_FD ]]; then
    _terminal_write $'\e[?2004l'
  fi
  return 0
}

terminal_resume() {
  emulate -L zsh
  _terminal_present resume 2>/dev/null || return $?
  if (( ! TERMINAL_NATIVE_PASTE )) && [[ -n $TERMINAL_FD ]]; then
    _terminal_write $'\e[?2004h'
  fi
  return 0
}

terminal_refresh() { _terminal_present refresh "$@"; }

# Resume also presents a frame; share the same balanced synchronization policy.
_terminal_present() {
  emulate -L zsh
  local -i refresh_result=0
  {
    if (( TERMINAL_SYNC_ENABLED )) && _terminal_write $'\e[?2026h'; then
      TERMINAL_FRAME_ACTIVE=1
    fi
    zcoder_curses "$@"
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
    if [[ -n $TERMINAL_SEQUENCE ]]; then
      for queued_byte in "${(@s::)TERMINAL_SEQUENCE}"; do
        TERMINAL_INPUT_QUEUE+=("$queued_byte" '' '')
      done
    fi
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

# A bounded wait wakes on terminal bytes without reading them. Worker output is
# currently spooled to regular files: selecting those would busy-loop at EOF.
# The activity loop checks worker completion again after at most one 20 ms tick.
terminal_wait_input() {
  emulate -L zsh
  local -i wait_ms=${1:-20} ticks
  (( wait_ms > TERMINAL_WAIT_MS )) && wait_ms=$TERMINAL_WAIT_MS
  (( wait_ms > 0 )) || return 0
  ticks=$(( (wait_ms + 9) / 10 )) # zselect uses hundredths of a second.
  if (( TERMINAL_INPUT_FD >= 0 )); then
    zselect -r "$TERMINAL_INPUT_FD" -t "$ticks" 2>/dev/null
  else
    zselect -t "$ticks" 2>/dev/null
  fi
  return 0
}

# The C decoder owns delimiters; retain raw chunks until end so UTF-8 and CRLF
# split across records are reassembled before the editor normalizes the text.
_terminal_paste_event() {
  emulate -L zsh
  setopt nomultibyte
  local phase=$1 chunk=$2
  REPLY=PASTE_PENDING
  if [[ $phase == begin ]]; then
    TERMINAL_PASTE_CHUNKS=(); TERMINAL_PASTE_BYTES=0; TERMINAL_PASTE_REJECTED=0
    REPLY=PASTE_BEGIN
    return 0
  fi
  if (( ! TERMINAL_PASTE_REJECTED )); then
    if (( ${#chunk} > TERMINAL_PASTE_LIMIT - TERMINAL_PASTE_BYTES )); then
      TERMINAL_PASTE_REJECTED=1; TERMINAL_PASTE_CHUNKS=()
    else
      (( TERMINAL_PASTE_BYTES += ${#chunk} ))
      if [[ -n $chunk ]]; then
        if (( ${#TERMINAL_PASTE_CHUNKS} && ${#TERMINAL_PASTE_CHUNKS[-1]} < 4096 )); then
          TERMINAL_PASTE_CHUNKS[-1]+="$chunk"
        else
          TERMINAL_PASTE_CHUNKS+=("$chunk")
        fi
      fi
    fi
  fi
  if [[ $phase == end ]]; then
    if (( TERMINAL_PASTE_REJECTED )); then
      REPLY=PASTE_REJECTED
    else
      TERMINAL_EVENT_TEXT="${(j::)TERMINAL_PASTE_CHUNKS}"
      REPLY=PASTE
    fi
    TERMINAL_PASTE_CHUNKS=(); TERMINAL_PASTE_BYTES=0; TERMINAL_PASTE_REJECTED=0
  fi
  return 0
}

# Output variables are caller-owned (Zsh dynamic scope), like zcoder_curses input.
# Optional fifth argument `poll` never changes the window's configured timeout.
terminal_read_event() {
  emulate -L zsh
  local terminal_byte='' terminal_key='' terminal_mouse=''
  local -a poll_flags=()
  TERMINAL_EVENT_TEXT=''
  [[ ${5:-} == poll ]] && (( TERMINAL_EVENT_POLL )) && poll_flags=(poll)
  if (( ! ${#TERMINAL_INPUT_QUEUE} )); then
    if (( TERMINAL_NOREFRESH_INPUT )); then
      local -A terminal_event=()
      if zcoder_curses event "$1" terminal_event "${TERMINAL_EVENT_FLAGS[@]}" "${poll_flags[@]}"; then
        case ${terminal_event[type]} in
          character) terminal_byte=${terminal_event[text]} ;;
          key) terminal_key=${terminal_event[key]} ;;
          resize) terminal_key=RESIZE ;;
          paste)
            _terminal_paste_event "${terminal_event[phase]}" "${terminal_event[text]}"
            terminal_key=$REPLY
            ;;
          mouse)
            terminal_key=MOUSE
            terminal_mouse="${terminal_event[id]} ${terminal_event[x]} ${terminal_event[y]} ${terminal_event[z]}"
            [[ -n ${terminal_event[buttons]} ]] && terminal_mouse+=" ${terminal_event[buttons]}"
            [[ -n ${terminal_event[modifiers]} ]] && terminal_mouse+=" ${terminal_event[modifiers]}"
            ;;
        esac
      else
        local -i terminal_read_result=$?
        # Status 2 guarantees no input was consumed. Other failures (including
        # timeouts) must not cause a second read or replay an old record.
        if (( terminal_read_result == 2 && TERMINAL_NATIVE_PASTE )); then
          # Legacy input is forbidden while zdraw owns paste. Retry structured
          # input on the next call without the optional polling flag.
          TERMINAL_EVENT_POLL=0
        elif (( terminal_read_result == 2 )); then
          TERMINAL_NOREFRESH_INPUT=0; TERMINAL_EVENT_FLAGS=()
          TERMINAL_EVENT_POLL=0
        fi
      fi
    fi
    if (( ! TERMINAL_NOREFRESH_INPUT )); then
      zcoder_curses input "$1" terminal_byte terminal_key terminal_mouse
    fi
    terminal_filter_input "$terminal_byte" "$terminal_key" "$terminal_mouse"
  fi
  printf -v "$2" '%s' "${TERMINAL_INPUT_QUEUE[1]:-}"
  printf -v "$3" '%s' "${TERMINAL_INPUT_QUEUE[2]:-}"
  printf -v "$4" '%s' "${TERMINAL_INPUT_QUEUE[3]:-}"
  TERMINAL_INPUT_QUEUE[1,3]=()
  return 0
}
