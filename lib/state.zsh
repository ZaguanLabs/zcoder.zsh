# Persistent, directory-backed agent sessions scoped to workspace and profile.

typeset -g ZCODER_SESSIONS_DIR="${ZCODER_SESSIONS_DIR:-${ZCODER_HOME}/sessions}"
typeset -g CURRENT_SESSION_ID=""
typeset -g SESSION_TITLE="New Job"
typeset -gi STATE_ENABLED=0
typeset -gi STATE_LOADING=0
typeset -ga SESSION_IDS=()
typeset -ga SESSION_TITLES=()
typeset -ga SESSION_MODELS=()

# What the last state_save_session wrote, so routine saves append only the new
# records instead of rewriting every file of a long session. Any signal that
# existing records changed — another session, a compaction checkpoint, a
# shrunken array, a toggled reasoning flag — forces a full rewrite.
typeset -g STATE_SAVED_SESSION_ID=""
typeset -g STATE_SAVED_REASONING=""
typeset -gi STATE_SAVED_AGENT_COUNT=0 STATE_SAVED_UI_COUNT=0
typeset -gi STATE_SAVED_USER_COUNT=0 STATE_SAVED_SKILL_COUNT=0
typeset -gi STATE_SAVED_COMPACTIONS=-1

_state_valid_id() {
  [[ "$1" == <1->'_'<1-> ]]
}

_state_nonnegative() {
  [[ "$1" == <0-> ]] && REPLY="$1" || REPLY=0
}

_state_scope_matches() {
  [[ -n "$1" && -n "$2" && "${1:A}" == "${ZCODER_WORKSPACE:A}" && "$2" == "$ZCODER_PROFILE" ]]
}

state_refresh_sessions_list() {
  SESSION_IDS=()
  SESSION_TITLES=()
  SESSION_MODELS=()
  (( STATE_ENABLED )) || return 0

  local session_dir="" id="" workspace="" profile="" updated="" record=""
  local -a records=()
  for session_dir in "$ZCODER_SESSIONS_DIR"/*.session(N/); do
    workspace="${mapfile[$session_dir/workspace]}"
    profile="${mapfile[$session_dir/profile]}"
    _state_scope_matches "$workspace" "$profile" || continue
    id="${session_dir:t:r}"
    _state_valid_id "$id" || continue
    updated="${mapfile[$session_dir/updated_at]:-${id%%_*}}"
    [[ "$updated" == <1-> ]] || updated="${id%%_*}"
    records+=("${updated}:${id}")
  done
  records=("${(@O)records}")

  for record in "${records[@]}"; do
    id="${record#*:}"
    session_dir="$ZCODER_SESSIONS_DIR/${id}.session"
    SESSION_IDS+=("$id")
    SESSION_TITLES+=("${mapfile[$session_dir/title]:-Untitled}")
    SESSION_MODELS+=("${mapfile[$session_dir/model]:-unknown}")
  done
}

state_note_user() {
  local content="$1" title=""
  [[ "$SESSION_TITLE" == "New Job" ]] || return 0
  title="${content//$'\r'/ }"
  title="${title//$'\n'/ }"
  title="${title##[[:space:]]#}"
  title="${title%%[[:space:]]#}"
  [[ -n "$title" ]] || return 0
  SESSION_TITLE="${title[1,42]}"
}

state_save_session() {
  (( STATE_ENABLED && ! STATE_LOADING )) || return 0
  _state_valid_id "$CURRENT_SESSION_ID" || return 0

  local session_dir="$ZCODER_SESSIONS_DIR/${CURRENT_SESSION_ID}.session"
  local agent_dir="$session_dir/agent_messages" ui_dir="$session_dir/ui_events"
  local users_dir="$session_dir/context_users" skills_dir="$session_dir/active_skills"
  local seq="" old_umask="$(umask)"
  local -i i agent_start=1 ui_start=1 users_start=1 skills_start=1
  umask 077
  if ! zf_mkdir -p "$agent_dir" "$ui_dir" "$users_dir" "$skills_dir" 2>/dev/null; then
    umask "$old_umask"
    return 1
  fi

  if [[ "$CURRENT_SESSION_ID" == "$STATE_SAVED_SESSION_ID" ]] && \
     (( AGENT_COMPACTION_COUNT == STATE_SAVED_COMPACTIONS )) && \
     (( ${#AGENT_MESSAGES} >= STATE_SAVED_AGENT_COUNT )) && \
     (( ${#UI_ROLES} >= STATE_SAVED_UI_COUNT )) && \
     (( ${#AGENT_USER_MESSAGES} >= STATE_SAVED_USER_COUNT )) && \
     (( ${#SKILL_ACTIVE_NAMES} >= STATE_SAVED_SKILL_COUNT )) && \
     [[ "${(j::)UI_REASONING_OPEN[1,STATE_SAVED_UI_COUNT]}" == "$STATE_SAVED_REASONING" ]]; then
    agent_start=$(( STATE_SAVED_AGENT_COUNT + 1 ))
    ui_start=$(( STATE_SAVED_UI_COUNT + 1 ))
    users_start=$(( STATE_SAVED_USER_COUNT + 1 ))
    skills_start=$(( STATE_SAVED_SKILL_COUNT + 1 ))
  fi

  mapfile[$session_dir/id]="$CURRENT_SESSION_ID"
  mapfile[$session_dir/title]="$SESSION_TITLE"
  mapfile[$session_dir/workspace]="${ZCODER_WORKSPACE:A}"
  mapfile[$session_dir/profile]="$ZCODER_PROFILE"
  mapfile[$session_dir/model]="$ZCODER_MODEL"
  mapfile[$session_dir/updated_at]="$EPOCHSECONDS"
  mapfile[$session_dir/agent_message_count]="${#AGENT_MESSAGES}"
  mapfile[$session_dir/ui_event_count]="${#UI_ROLES}"
  mapfile[$session_dir/context_user_count]="${#AGENT_USER_MESSAGES}"
  mapfile[$session_dir/active_skill_count]="${#SKILL_ACTIVE_NAMES}"
  mapfile[$session_dir/compaction_summary]="$AGENT_COMPACTION_SUMMARY"
  mapfile[$session_dir/compaction_count]="$AGENT_COMPACTION_COUNT"
  mapfile[$session_dir/compaction_rearm_tokens]="$AGENT_COMPACTION_REARM_TOKENS"
  mapfile[$session_dir/last_prompt_tokens]="$AGENT_LAST_PROMPT_TOKENS"
  mapfile[$session_dir/last_output_tokens]="$AGENT_LAST_OUTPUT_TOKENS"
  mapfile[$session_dir/last_payload_bytes]="$AGENT_LAST_PAYLOAD_BYTES"

  for (( i=agent_start; i<=${#AGENT_MESSAGES}; i++ )); do
    printf -v seq '%06d' "$i"
    mapfile[$agent_dir/$seq]="${AGENT_MESSAGES[i]}"
  done
  for (( i=ui_start; i<=${#UI_ROLES}; i++ )); do
    printf -v seq '%06d' "$i"
    mapfile[$ui_dir/$seq.role]="${UI_ROLES[i]}"
    mapfile[$ui_dir/$seq.content]="${UI_CONTENTS[i]}"
    mapfile[$ui_dir/$seq.thinking]="${UI_THINKINGS[i]}"
    mapfile[$ui_dir/$seq.time]="${UI_TIMES[i]}"
    mapfile[$ui_dir/$seq.reasoning_open]="${UI_REASONING_OPEN[i]:-0}"
  done
  for (( i=users_start; i<=${#AGENT_USER_MESSAGES}; i++ )); do
    printf -v seq '%06d' "$i"
    mapfile[$users_dir/$seq]="${AGENT_USER_MESSAGES[i]}"
  done
  for (( i=skills_start; i<=${#SKILL_ACTIVE_NAMES}; i++ )); do
    printf -v seq '%06d' "$i"
    mapfile[$skills_dir/$seq]="${SKILL_ACTIVE_NAMES[i]}"
  done
  umask "$old_umask"

  STATE_SAVED_SESSION_ID="$CURRENT_SESSION_ID"
  STATE_SAVED_COMPACTIONS=$AGENT_COMPACTION_COUNT
  STATE_SAVED_AGENT_COUNT=${#AGENT_MESSAGES}
  STATE_SAVED_UI_COUNT=${#UI_ROLES}
  STATE_SAVED_USER_COUNT=${#AGENT_USER_MESSAGES}
  STATE_SAVED_SKILL_COUNT=${#SKILL_ACTIVE_NAMES}
  STATE_SAVED_REASONING="${(j::)UI_REASONING_OPEN}"
}

state_save_and_refresh() {
  state_save_session || return 1
  state_refresh_sessions_list
}

state_new_session() {
  (( STATE_ENABLED )) && state_save_session
  CURRENT_SESSION_ID="${EPOCHSECONDS}_${RANDOM}"
  SESSION_TITLE="New Job"
  agent_reset
  UI_ROLES=()
  UI_CONTENTS=()
  UI_THINKINGS=()
  UI_TIMES=()
  UI_REASONING_OPEN=()
  (( UI_TRANSCRIPT_GENERATION++ ))
  UI_SCROLL=0
  UI_AUTO_SCROLL=1
  state_save_and_refresh
}

state_load_session() {
  local id="$1" session_dir="" saved_workspace="" saved_profile="" saved_model=""
  local agent_dir="" ui_dir="" users_dir="" skills_dir="" seq="" skill_name=""
  local -i i count=0
  _state_valid_id "$id" || return 1
  session_dir="$ZCODER_SESSIONS_DIR/${id}.session"
  [[ -d "$session_dir" ]] || return 1
  saved_workspace="${mapfile[$session_dir/workspace]}"
  saved_profile="${mapfile[$session_dir/profile]}"
  _state_scope_matches "$saved_workspace" "$saved_profile" || return 1

  (( STATE_ENABLED )) && state_save_session
  STATE_LOADING=1
  CURRENT_SESSION_ID="$id"
  SESSION_TITLE="${mapfile[$session_dir/title]:-Untitled}"
  saved_model="${mapfile[$session_dir/model]}"
  if (( ! ${ZCODER_MODEL_OVERRIDE:-0} )) && [[ -n "$saved_model" ]]; then
    ZCODER_MODEL="$saved_model"
  fi
  agent_reset
  UI_ROLES=()
  UI_CONTENTS=()
  UI_THINKINGS=()
  UI_TIMES=()
  UI_REASONING_OPEN=()
  (( UI_TRANSCRIPT_GENERATION++ ))

  local -i disk_agent_count=0 disk_ui_count=0 disk_user_count=0 disk_skill_count=0
  agent_dir="$session_dir/agent_messages"
  _state_nonnegative "${mapfile[$session_dir/agent_message_count]:-0}"; count=$REPLY
  disk_agent_count=$count
  for (( i=1; i<=count; i++ )); do
    printf -v seq '%06d' "$i"
    [[ -f "$agent_dir/$seq" ]] && AGENT_MESSAGES+=("${mapfile[$agent_dir/$seq]}")
  done

  ui_dir="$session_dir/ui_events"
  _state_nonnegative "${mapfile[$session_dir/ui_event_count]:-0}"; count=$REPLY
  disk_ui_count=$count
  for (( i=1; i<=count; i++ )); do
    printf -v seq '%06d' "$i"
    [[ -f "$ui_dir/$seq.role" ]] || continue
    UI_ROLES+=("${mapfile[$ui_dir/$seq.role]:-system}")
    UI_CONTENTS+=("${mapfile[$ui_dir/$seq.content]}")
    UI_THINKINGS+=("${mapfile[$ui_dir/$seq.thinking]}")
    UI_TIMES+=("${mapfile[$ui_dir/$seq.time]}")
    _state_nonnegative "${mapfile[$ui_dir/$seq.reasoning_open]:-0}"
    (( REPLY > 0 )) && UI_REASONING_OPEN+=(1) || UI_REASONING_OPEN+=(0)
  done

  AGENT_COMPACTION_SUMMARY="${mapfile[$session_dir/compaction_summary]}"
  _state_nonnegative "${mapfile[$session_dir/compaction_count]:-0}"; AGENT_COMPACTION_COUNT=$REPLY
  _state_nonnegative "${mapfile[$session_dir/compaction_rearm_tokens]:-0}"; AGENT_COMPACTION_REARM_TOKENS=$REPLY
  _state_nonnegative "${mapfile[$session_dir/last_prompt_tokens]:-0}"; AGENT_LAST_PROMPT_TOKENS=$REPLY
  _state_nonnegative "${mapfile[$session_dir/last_output_tokens]:-0}"; AGENT_LAST_OUTPUT_TOKENS=$REPLY
  _state_nonnegative "${mapfile[$session_dir/last_payload_bytes]:-0}"; AGENT_LAST_PAYLOAD_BYTES=$REPLY

  users_dir="$session_dir/context_users"
  _state_nonnegative "${mapfile[$session_dir/context_user_count]:-0}"; count=$REPLY
  disk_user_count=$count
  for (( i=1; i<=count; i++ )); do
    printf -v seq '%06d' "$i"
    [[ -f "$users_dir/$seq" ]] && AGENT_USER_MESSAGES+=("${mapfile[$users_dir/$seq]}")
  done

  skills_dir="$session_dir/active_skills"
  _state_nonnegative "${mapfile[$session_dir/active_skill_count]:-0}"; count=$REPLY
  disk_skill_count=$count
  for (( i=1; i<=count; i++ )); do
    printf -v seq '%06d' "$i"
    skill_name="${mapfile[$skills_dir/$seq]}"
    [[ -n "$skill_name" && -n "${SKILL_FILES[$skill_name]:-}" ]] && skills_activate "$skill_name" >/dev/null 2>&1
  done

  AGENT_CONTEXT_MODEL=""
  UI_SCROLL=0
  UI_AUTO_SCROLL=1
  STATE_LOADING=0
  # When every on-disk record loaded, the arrays mirror the session directory
  # exactly and the next save can append from these counts. A lossy load
  # (missing files, failed skill activation) forces that save to rewrite all
  # records instead.
  if (( ${#AGENT_MESSAGES} == disk_agent_count && ${#UI_ROLES} == disk_ui_count && \
        ${#AGENT_USER_MESSAGES} == disk_user_count && ${#SKILL_ACTIVE_NAMES} == disk_skill_count )); then
    STATE_SAVED_SESSION_ID="$CURRENT_SESSION_ID"
    STATE_SAVED_COMPACTIONS=$AGENT_COMPACTION_COUNT
    STATE_SAVED_AGENT_COUNT=${#AGENT_MESSAGES}
    STATE_SAVED_UI_COUNT=${#UI_ROLES}
    STATE_SAVED_USER_COUNT=${#AGENT_USER_MESSAGES}
    STATE_SAVED_SKILL_COUNT=${#SKILL_ACTIVE_NAMES}
    STATE_SAVED_REASONING="${(j::)UI_REASONING_OPEN}"
  else
    STATE_SAVED_SESSION_ID=""
  fi
  zcoder_debug session_loaded "id=$id title=${(qqq)SESSION_TITLE} events=${#UI_ROLES} messages=${#AGENT_MESSAGES}"
  return 0
}

state_init() {
  local old_umask="$(umask)"
  umask 077
  if ! zf_mkdir -p "$ZCODER_SESSIONS_DIR" 2>/dev/null; then
    umask "$old_umask"
    STATE_ENABLED=0
    return 1
  fi
  zf_chmod 700 "$ZCODER_SESSIONS_DIR" 2>/dev/null || true
  umask "$old_umask"
  STATE_ENABLED=1
  state_refresh_sessions_list
  if (( ${#SESSION_IDS} > 0 )); then
    state_load_session "${SESSION_IDS[1]}" || state_new_session
  else
    state_new_session
  fi
}
