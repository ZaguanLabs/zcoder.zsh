# User input belongs to the session owner, never to an HTTP/ACP broker's copy
# of AGENT_MESSAGES. Private records are published atomically under an OS lock.
typeset -g INPUT_QUEUE_TURN_ID='' INPUT_QUEUE_ERROR=''
typeset -g REMOTE_INPUT_TURN_ID='' REMOTE_INPUT_SUPPORTED=false
typeset -g INPUT_QUEUE_DRAFT_ID='' INPUT_QUEUE_DRAFT_KEY=''

input_queue_has_steer() {
  emulate -L zsh
  setopt extendedglob
  local queue_dir='' queue_lock='' file='' id=''
  [[ -n "$INPUT_QUEUE_TURN_ID" ]] || return 1
  _input_queue_lock "$CURRENT_SESSION_ID" || return 1
  {
    for file in "$queue_dir/items/"*.json(N.on); do
      id="${${file:t:r}#*-}"
      [[ -f "$queue_dir/consumed/$id" ]] && continue
      [[ "${mapfile[$file]}" == '{"turn_id":"'"$INPUT_QUEUE_TURN_ID"'",'*'","mode":"steer",'* ]] && return 0
    done
    return 1
  } always { zsystem flock -u "$queue_lock"; }
}

input_queue_status() {
  emulate -L zsh
  setopt extendedglob
  local queue_dir='' queue_lock='' id="$2"
  local -a matches=()
  [[ -n "$id" && ${#id} -le 64 && "$id" != *[^A-Za-z0-9_-]* ]] || return 1
  _input_queue_lock "$1" || return 1
  {
    matches=("$queue_dir/items/"*-"$id".json(N))
    (( ${#matches} )) || { INPUT_QUEUE_ERROR='unknown message ID'; return 1; }
    input_queue_receipt "$queue_dir" "$id"
  } always { zsystem flock -u "$queue_lock"; }
}

_input_queue_lock() {
  local session="$1" base=''
  INPUT_QUEUE_ERROR='could not access private input queue'
  _state_valid_id "$session" || { INPUT_QUEUE_ERROR='invalid session'; return 1; }
  base="$ZCODER_SESSIONS_DIR/${session}.session"
  [[ -d "$base" && ! -h "$base" && -O "$base" ]] || { INPUT_QUEUE_ERROR='unknown session'; return 1; }
  queue_dir="$base/input_queue"
  [[ ! -h "$queue_dir" ]] || return 1
  (umask 077; zf_mkdir -p "$queue_dir/items" "$queue_dir/consumed") || return 1
  [[ ! -h "$queue_dir/items" && ! -h "$queue_dir/consumed" ]] || return 1
  local fd=''
  sysopen -w -m 0600 -o creat,nofollow,cloexec -u fd "$queue_dir/lock" || return 1
  exec {fd}>&-
  zsystem flock -t 1 -f queue_lock "$queue_dir/lock" 2>/dev/null || {
    INPUT_QUEUE_ERROR='input queue is busy; retry with the same message ID'; return 1
  }
  INPUT_QUEUE_ERROR=''
}

_input_queue_write() {
  local dest="$1" value="$2" tmp="$1.$sysparams[pid].tmp"
  if ! (umask 077; zcoder_write_text_file "$tmp" "$value") || ! zf_mv -f -- "$tmp" "$dest"; then
    INPUT_QUEUE_ERROR='could not persist input queue state'; return 1
  fi
}

input_queue_open() {
  emulate -L zsh
  local queue_dir='' queue_lock=''
  _input_queue_lock "$1" || return 1
  { _input_queue_write "$queue_dir/active" "$2"; } always { zsystem flock -u "$queue_lock"; }
}

# Receipt lookup remains available after completion, so an ambiguous HTTP
# response can be retried without injecting the message a second time.
input_queue_submit() {
  emulate -L zsh
  setopt extendedglob
  local session="$1" turn="$2" id="$3" mode="$4" body="$5"
  local queue_dir='' queue_lock='' record='' body_json='' seq='' file='' id_part=''
  local -a files=() matches=()
  local -i bytes=0
  INPUT_QUEUE_ERROR=''
  [[ -n "$id" && ${#id} -le 64 && "$id" != *[^A-Za-z0-9_-]* ]] || { INPUT_QUEUE_ERROR='invalid message ID'; return 1; }
  [[ "$mode" == steer || "$mode" == follow_up ]] || { INPUT_QUEUE_ERROR='mode must be steer or follow_up'; return 1; }
  _http_byte_length "$body"; bytes=$REPLY
  (( bytes > 0 && bytes <= 65536 )) || { INPUT_QUEUE_ERROR='input must contain 1 to 65536 bytes'; return 1; }
  _input_queue_lock "$session" || return 1
  {
    json_quote "$body"; body_json="$REPLY"
    json_quote "$turn"; record='{"turn_id":'"$REPLY"',"message_id":"'"$id"'","mode":"'"$mode"'","text":'"$body_json"'}'
    matches=("$queue_dir/items/"*-"$id".json(N))
    if (( ${#matches} )); then
      [[ "${mapfile[$matches[1]]}" == "$record" ]] || { INPUT_QUEUE_ERROR='message ID already used for different input'; return 1; }
      input_queue_receipt "$queue_dir" "$id"
      return 0
    fi
    [[ -n "$turn" && "${mapfile[$queue_dir/active]:-}" == "$turn" ]] || { INPUT_QUEUE_ERROR='turn is no longer accepting input'; return 1; }
    files=("$queue_dir/items/"*.json(N))
    (( ${#files} < 1000 )) || { INPUT_QUEUE_ERROR='session input queue receipt limit reached (1000)'; return 1; }
    local -i pending=0
    for file in "${files[@]}"; do
      id_part="${${file:t:r}#*-}"
      [[ -f "$queue_dir/consumed/$id_part" ]] || (( pending++ ))
    done
    (( pending < 100 )) || { INPUT_QUEUE_ERROR='input queue is full (100 messages)'; return 1; }
    printf -v seq '%06d' $(( ${#files} + 1 ))
    _input_queue_write "$queue_dir/items/$seq-$id.json" "$record" || { INPUT_QUEUE_ERROR='could not persist input'; return 1; }
    input_queue_receipt "$queue_dir" "$id"
  } always { zsystem flock -u "$queue_lock"; }
}

input_queue_receipt() {
  local state=accepted
  [[ -f "$1/consumed/$2" ]] && state="${mapfile[$1/consumed/$2]}"
  REPLY='{"message_id":"'"$2"'","state":"'"$state"'"}'
}

# Called only by the agent at request boundaries. Keep the lock through history
# persistence: enqueue and turn completion cannot race past the final check.
input_queue_drain() {
  emulate -L zsh
  setopt extendedglob
  local mode="${1:-steer}" queue_dir='' queue_lock='' file='' id='' text='' message='' selected=''
  local -i count=0 found=0 message_index=0
  local seq=''
  INPUT_QUEUE_ERROR=''
  [[ -n "$INPUT_QUEUE_TURN_ID" ]] || return 1
  local JSON_SOURCE='' JSON_TOKEN_TYPE='' JSON_TOKEN_VALUE='' JSON_ERROR=''
  local -a JSON_CHARS=()
  local -A JSON_OBJECT=() JSON_OBJECT_TYPES=()
  local -i JSON_POS=1 JSON_LEN=0 JSON_TOKEN_START=1
  _input_queue_lock "$CURRENT_SESSION_ID" || return 1
  {
    for file in "$queue_dir/items/"*.json(N.on); do
      id="${${file:t:r}#*-}"
      [[ -f "$queue_dir/consumed/$id" ]] && continue
      json_parse_flat_object "${mapfile[$file]}" || { INPUT_QUEUE_ERROR='invalid queued input'; return 1; }
      [[ "$mode" == recovery || "${JSON_OBJECT[turn_id]}" == "$INPUT_QUEUE_TURN_ID" ]] || continue
      [[ "$mode" == all || "$mode" == recovery || "${JSON_OBJECT[mode]}" == "$mode" ]] || continue
      text="${JSON_OBJECT[text]}"
      selected='"input_id":"'"$id"'"'
      found=0
      message_index=0
      for message in "${AGENT_MESSAGES[@]}"; do
        (( message_index++ ))
        [[ "$message" == *,"$selected"'}' ]] && { found=1; break; }
      done
      if (( ! found )); then
        skills_activate_explicit_from_text "$text" || true
        agent_add_message user "$text"
        AGENT_MESSAGES[-1]="${AGENT_MESSAGES[-1]%\}},$selected}"
        message_index=${#AGENT_MESSAGES}
        state_note_user "$text"
        agent_emit user "$text"
      fi
      state_save_session || { INPUT_QUEUE_ERROR='could not persist consumed input'; return 1; }
      if ! state_saved_message_matches "$CURRENT_SESSION_ID" "$message_index" "${AGENT_MESSAGES[message_index]}" "${#AGENT_MESSAGES}"; then
        INPUT_QUEUE_ERROR='queued input was not saved; delivery remains pending'; return 1
      fi
      _input_queue_write "$queue_dir/consumed/$id" consumed || { INPUT_QUEUE_ERROR='could not save input receipt'; return 1; }
      (( count++ ))
      [[ "$mode" == all || "$mode" == recovery ]] && break
    done
    (( count > 0 ))
  } always { zsystem flock -u "$queue_lock"; }
}

# Returns 1 while accepted messages remain, otherwise closes admission
# atomically. Failure/cancellation closes admission but preserves the records.
input_queue_close() {
  emulate -L zsh
  setopt extendedglob
  local force="${1:-false}" queue_dir='' queue_lock='' file='' id=''
  [[ -n "$INPUT_QUEUE_TURN_ID" ]] || return 0
  _input_queue_lock "$CURRENT_SESSION_ID" || return 2
  {
    if [[ "$force" != true ]]; then
      for file in "$queue_dir/items/"*.json(N.on); do
        id="${${file:t:r}#*-}"
        [[ -f "$queue_dir/consumed/$id" ]] && continue
        [[ ${INPUT_QUEUE_RESUME:-0} == 1 || "${mapfile[$file]}" == '{"turn_id":"'"$INPUT_QUEUE_TURN_ID"'"'* ]] && return 1
      done
    fi
    if [[ "${mapfile[$queue_dir/active]:-}" == "$INPUT_QUEUE_TURN_ID" ]]; then
      _input_queue_write "$queue_dir/active" '' || return 2
    fi
    return 0
  } always { zsystem flock -u "$queue_lock"; }
}

input_queue_ui_submit() {
  (( ${INPUT_QUEUE_SENDING:-0} )) && return 0
  local -i INPUT_QUEUE_SENDING=1
  local mode="${1:-steer}" text="$INPUT_BUF" id="${EPOCHSECONDS}_${sysparams[pid]}_$RANDOM" receipt=''
  local key="$CURRENT_SESSION_ID|$INPUT_QUEUE_TURN_ID|$REMOTE_INPUT_TURN_ID|$mode|$text"
  if [[ "$INPUT_QUEUE_DRAFT_KEY" == "$key" ]]; then id="$INPUT_QUEUE_DRAFT_ID"
  else INPUT_QUEUE_DRAFT_ID="$id"; INPUT_QUEUE_DRAFT_KEY="$key"
  fi
  [[ -n "$text" ]] || return 0
  # Slash commands have control effects owned by the idle loop.
  [[ "$text" != /* ]] || { ui_append_message error 'Send slash commands after the active turn finishes.'; return 0; }
  if [[ "${REMOTE_MODE:-local}" == client ]]; then
    remote_client_submit_input "$id" "$mode" "$text" || {
      (( $? == 130 )) && return 130
      ui_append_message error "$REMOTE_ERROR"; return 0
    }
  else
    input_queue_submit "$CURRENT_SESSION_ID" "$INPUT_QUEUE_TURN_ID" "$id" "$mode" "$text" || {
      ui_append_message error "Input not queued: $INPUT_QUEUE_ERROR"; return 0
    }
  fi
  input_submit
  INPUT_QUEUE_DRAFT_KEY=''; INPUT_QUEUE_DRAFT_ID=''
  local label=steering
  [[ "$mode" == follow_up ]] && label=follow-up
  ui_append_message system "Queued $label [$id]: $text"
  ui_input_changed
  ui_refresh_all
}

input_queue_command() {
  emulate -L zsh
  setopt extendedglob
  local action="${1:-list}" id="${2:-}" queue_dir='' queue_lock='' file='' text='' turn=''
  local JSON_SOURCE='' JSON_TOKEN_TYPE='' JSON_TOKEN_VALUE='' JSON_ERROR=''
  local -a JSON_CHARS=()
  local -A JSON_OBJECT=() JSON_OBJECT_TYPES=()
  local -i JSON_POS=1 JSON_LEN=0 JSON_TOKEN_START=1
  if [[ "${REMOTE_MODE:-local}" == client ]]; then
    if [[ "$action" == resume ]]; then remote_client_user_turn '/queue resume'; return $?; fi
    remote_client_input_request "$action" '' "$id" '' '' || { agent_emit error "$REMOTE_ERROR"; return 1; }
    json_parse_flat_object "$REPLY" || return 1
    agent_emit system "${JSON_OBJECT[pending]:-${JSON_OBJECT[state]:-No pending input.}}"
    return 0
  fi
  _input_queue_lock "$CURRENT_SESSION_ID" || return 1
  {
    for file in "$queue_dir/items/"*.json(N.on); do
      local item_id="${${file:t:r}#*-}"
      [[ -f "$queue_dir/consumed/$item_id" ]] && continue
      json_parse_flat_object "${mapfile[$file]}" || return 1
      case "$action" in
        list) text+="[$item_id] ${JSON_OBJECT[mode]}: ${JSON_OBJECT[text]}"$'\n' ;;
        drop)
          [[ "$item_id" == "$id" ]] || continue
          _input_queue_write "$queue_dir/consumed/$item_id" discarded || return 1
          text="Discarded queued input $id"; break ;;
        resume) turn="${JSON_OBJECT[turn_id]}"; break ;;
        *) return 1 ;;
      esac
    done
  } always { zsystem flock -u "$queue_lock"; }
  if [[ -n "$turn" ]]; then
    local -i INPUT_QUEUE_RESUME=1
    (( $+functions[relay_mark_busy] )) && relay_mark_busy || true
    { _agent_run_turn '' queue_resume; } always {
      (( $+functions[relay_mark_ready] )) && relay_mark_ready || true
    }
  else
    agent_emit system "${text:-No matching pending input.}"
  fi
}

# Shared flat request contract for HTTP and the namespaced ACP extension.
# No mutation of the broker's conversation arrays occurs here.
input_queue_request() {
  emulate -L zsh
  setopt extendedglob
  local action="$1" session="$2" turn="$3" id="$4" mode="$5" body="$6"
  local queue_dir='' queue_lock='' file='' item_id='' pending='' active=''
  local JSON_SOURCE='' JSON_TOKEN_TYPE='' JSON_TOKEN_VALUE='' JSON_ERROR=''
  local -a JSON_CHARS=()
  local -A JSON_OBJECT=() JSON_OBJECT_TYPES=()
  local -i JSON_POS=1 JSON_LEN=0 JSON_TOKEN_START=1
  INPUT_QUEUE_ERROR=''
  case "$action" in
    submit) input_queue_submit "$session" "$turn" "$id" "$mode" "$body"; return $? ;;
    status) input_queue_status "$session" "$id"; return $? ;;
    list|drop) ;;
    *) INPUT_QUEUE_ERROR='unknown input queue action'; return 1 ;;
  esac
  _input_queue_lock "$session" || return 1
  {
    active="${mapfile[$queue_dir/active]:-}"
    for file in "$queue_dir/items/"*.json(N.on); do
      item_id="${${file:t:r}#*-}"
      [[ -f "$queue_dir/consumed/$item_id" ]] && continue
      if [[ "$action" == drop ]]; then
        [[ "$item_id" == "$id" ]] || continue
        _input_queue_write "$queue_dir/consumed/$item_id" discarded || return 1
        input_queue_receipt "$queue_dir" "$id"
        return 0
      fi
      json_parse_flat_object "${mapfile[$file]}" || return 1
      pending+="[$item_id] ${JSON_OBJECT[mode]}: ${JSON_OBJECT[text]}"$'\n'
    done
    [[ "$action" == list ]] || { INPUT_QUEUE_ERROR='no matching pending input'; return 1; }
    json_quote "$pending"; pending="$REPLY"
    json_quote "$active"
    REPLY='{"turn_id":'"$REPLY"',"pending":'"$pending"'}'
  } always { zsystem flock -u "$queue_lock"; }
}
