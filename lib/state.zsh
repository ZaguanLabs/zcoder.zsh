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
typeset -g STATE_SAVED_SNAPSHOT="" STATE_ERROR=""
# Ownership is separate from append-cache validity: even a lossy load must not
# overwrite a generation published later by another process.
typeset -g STATE_OBSERVED_BASE="" STATE_OBSERVED_SNAPSHOT=""
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
  SESSION_IDS=(); SESSION_TITLES=(); SESSION_MODELS=()
  (( STATE_ENABLED )) || return 0
  local session_dir='' id='' record=''
  local -a records=() reply=()
  local -A titles=() models=()
  # Legacy remote histories can be shared through directory symlinks.
  for session_dir in "$ZCODER_SESSIONS_DIR"/*.session(N-/); do
    id="${session_dir:t:r}"
    _state_valid_id "$id" || continue
    state_snapshot_values "$session_dir" workspace profile updated_at title model || continue
    _state_scope_matches "$reply[1]" "$reply[2]" || continue
    [[ "$reply[3]" == <1-> ]] || reply[3]="${id%%_*}"
    records+=("$reply[3]:$id")
    titles[$id]="${reply[4]:-Untitled}"; models[$id]="${reply[5]:-unknown}"
  done
  for record in "${(@O)records}"; do
    id="${record#*:}"
    SESSION_IDS+=("$id"); SESSION_TITLES+=("${titles[$id]}"); SESSION_MODELS+=("${models[$id]}")
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

# Resolve a single committed generation. A malformed current marker is an
# error, never permission to silently load an older legacy transcript.
state_snapshot_dir() {
  emulate -L zsh
  setopt extendedglob
  local base="$1" generation=''
  REPLY="$base"
  [[ -e "$base/current" || -h "$base/current" ]] || return 0
  [[ -f "$base/current" && ! -h "$base/current" ]] || return 1
  generation="${mapfile[$base/current]}"
  [[ "$generation" == <1->'_'<1->'_'<0-> && -d "$base/generations/$generation" && ! -h "$base/generations/$generation" ]] || return 1
  REPLY="$base/generations/$generation"
}

# Snapshot readers cooperate with publication/collection through a read lock.
# Callback inputs are internal function names, never data loaded from disk.
state_with_snapshot() {
  emulate -L zsh
  setopt extendedglob
  local base="$1" callback="$2" session_dir='' read_lock='' create_fd=''
  shift 2
  [[ -d "$base" ]] || return 2
  if [[ ! -f "$base/save.lock" ]]; then
    sysopen -w -m 0600 -o creat,nofollow,cloexec -u create_fd "$base/save.lock" || return 2
    exec {create_fd}>&-
  fi
  zsystem flock -r -t 5 -f read_lock "$base/save.lock" || return 2
  {
    state_snapshot_dir "$base" || return 2
    session_dir="$REPLY"
    "$callback" "$@"
  } always { zsystem flock -u "$read_lock"; }
}

_state_snapshot_values() {
  local key=''
  reply=()
  for key in "$@"; do reply+=("${mapfile[$session_dir/$key]:-}"); done
}

state_snapshot_values() {
  local base="$1"; shift
  state_with_snapshot "$base" _state_snapshot_values "$@"
}

# Cancellation runs after the remote owner has stopped. A subshell isolates
# all loader-owned arrays, skills and goal state from the listening broker.
state_pause_saved_goal() (
  trap - EXIT INT TERM HUP WINCH
  local id="$1" reason="$2"
  local -a reply=()
  _state_valid_id "$id" || return 1
  state_snapshot_values "$ZCODER_SESSIONS_DIR/$id.session" goal_status || return 1
  [[ "$reply[1]" == active || "$reply[1]" == verifying ]] || return 0
  STATE_ENABLED=0
  CURRENT_SESSION_ID=''
  state_load_session "$id" || return 1
  GOAL_STATUS=paused; GOAL_BLOCK_REASON="$reason"; GOAL_UPDATED_AT=$EPOCHSECONDS
  STATE_ENABLED=1
  state_save_session
)

# Called only under the writer lock, after publication. Keep the current and
# previous manifests plus every record either references. Existing readers
# hold shared locks, so collection cannot invalidate their snapshot.
_state_collect_generations() {
  local root="$1" current="$2" previous="$3" directory='' file='' ref='' suffix='' collection='' snapshot=''
  local -a refs=() snapshots=("$root/$current")
  local -A keep=()
  [[ "$previous" != "$current" && -d "$root/$previous" ]] && snapshots+=("$root/$previous")
  for snapshot in "${snapshots[@]}"; do
    for collection in agent_messages ui_events context_users active_skills; do
      refs=()
      [[ -s "$snapshot/$collection.refs" ]] && refs=("${(@f)mapfile[$snapshot/$collection.refs]}")
      for ref in "${refs[@]}"; do
        if [[ "$collection" == ui_events ]]; then
          for suffix in role content thinking time reasoning_open meta; do keep[$root/$ref.$suffix]=1; done
        else keep[$root/$ref]=1
        fi
      done
    done
  done
  for directory in "$root"/*(N/); do
    [[ "${directory:t}" == "$current" || "${directory:t}" == "$previous" ]] && continue
    for file in "$directory"/*(N.); do zf_rm -f -- "$file" || return 1; done
    for collection in agent_messages ui_events context_users active_skills; do
      for file in "$directory/$collection"/*(N.); do
        [[ -n "${keep[$file]:-}" ]] || zf_rm -f -- "$file" || return 1
      done
      zf_rmdir -- "$directory/$collection" 2>/dev/null || true
    done
    zf_rmdir -- "$directory" 2>/dev/null || true
  done
}

# A manifest lists immutable record prefixes relative to generations/.
# Legacy sessions have no manifests and retain their original record paths.
state_record_paths() {
  emulate -L zsh
  setopt extendedglob
  local snapshot="$1" collection="$2" count="$3" item='' seq='' root=''
  local -i i
  reply=()
  [[ "$collection" == agent_messages || "$collection" == ui_events || "$collection" == context_users || "$collection" == active_skills ]] || return 1
  [[ "$count" == <0-> && ${#count} -le 9 ]] || return 1
  if [[ "${snapshot:h:t}" == generations ]]; then
    [[ -f "$snapshot/$collection.refs" ]] || return 1
    (( count > 0 )) && reply=("${(@f)mapfile[$snapshot/$collection.refs]}")
    (( ${#reply} == count )) || return 1
    root="${snapshot:h}"
    for (( i=1; i<=count; i++ )); do
      item="${reply[i]}"
      [[ "$item" == <1->'_'<1->'_'<0->/"$collection"/<0-> ]] || return 1
      reply[i]="$root/$item"
    done
  else
    for (( i=1; i<=count; i++ )); do
      printf -v seq '%06d' "$i"
      reply+=("$snapshot/$collection/$seq")
    done
  fi
  return 0
}

_state_write() {
  local destination="$1" value="$2"
  zcoder_write_text_file "$destination" "$value" || {
    STATE_ERROR="could not write session record: $destination"
    return 1
  }
}

_state_validate_snapshot() {
  [[ "${session_dir:h:t}" == generations ]] || return 0
  local collection='' count_key='' record='' suffix='' count=''
  local -a reply=()
  for collection count_key in agent_messages agent_message_count ui_events ui_event_count context_users context_user_count active_skills active_skill_count; do
    count="${mapfile[$session_dir/$count_key]:-}"
    state_record_paths "$session_dir" "$collection" "$count" || return 1
    for record in "${reply[@]}"; do
      if [[ "$collection" == ui_events ]]; then
        for suffix in role content thinking time reasoning_open meta; do
          [[ -f "$record.$suffix" && ! -h "$record.$suffix" ]] || return 1
        done
      else
        [[ -f "$record" && ! -h "$record" ]] || return 1
      fi
    done
  done
  return 0
}

state_saved_message_matches() {
  state_with_snapshot "$ZCODER_SESSIONS_DIR/$1.session" _state_saved_message_matches "$@"
}

_state_saved_message_matches() {
  local snapshot="$session_dir" record=''
  local -a reply=()
  [[ "${mapfile[$snapshot/agent_message_count]}" == "$4" ]] || return 1
  state_record_paths "$snapshot" agent_messages "$4" || return 1
  record="${reply[$2]}"
  [[ -f "$record" && "${mapfile[$record]}" == "$3" ]]
}

# The only publication point is current's atomic rename. All referenced
# records are immutable, so readers holding an earlier snapshot stay coherent.
# Legacy files are retained on first migration; no executable state is sourced.
state_save_session() {
  emulate -L zsh
  setopt extendedglob
  (( STATE_ENABLED && ! STATE_LOADING )) || return 0
  [[ -n "$CURRENT_SESSION_ID" ]] || return 0
  _state_valid_id "$CURRENT_SESSION_ID" || return 1
  local base="$ZCODER_SESSIONS_DIR/$CURRENT_SESSION_ID.session" previous='' generation='' session_dir=''
  local agent_dir='' ui_dir='' users_dir='' skills_dir='' seq='' lock_fd='' marker=''
  local old_umask="$(umask)"
  local -i i agent_start=1 ui_start=1 users_start=1 skills_start=1 committed=0
  local -a reply=() agent_refs=() ui_refs=() user_refs=() skill_refs=()
  STATE_ERROR=''
  umask 077
  {
    zf_mkdir -p "$base/generations" || return 1
    sysopen -w -m 0600 -o creat,nofollow,cloexec -u lock_fd "$base/save.lock" || return 1
    exec {lock_fd}>&-
    zsystem flock -t 5 -f lock_fd "$base/save.lock" || { STATE_ERROR='session save is busy'; return 1; }
    state_snapshot_dir "$base" || { STATE_ERROR='invalid session commit marker'; return 1; }
    previous="$REPLY"
    if [[ "$STATE_OBSERVED_BASE" == "$base" && "$STATE_OBSERVED_SNAPSHOT" != "$previous" ]]; then
      STATE_ERROR='session changed by another process; unsaved work remains in memory'
      return 1
    fi
    if [[ "$previous" != "$base" && "$previous" == "$STATE_SAVED_SNAPSHOT" ]]; then
      state_record_paths "$previous" agent_messages "$STATE_SAVED_AGENT_COUNT" || return 1
      agent_refs=("${(@)reply#${base}/generations/}")
      state_record_paths "$previous" ui_events "$STATE_SAVED_UI_COUNT" || return 1
      ui_refs=("${(@)reply#${base}/generations/}")
      state_record_paths "$previous" context_users "$STATE_SAVED_USER_COUNT" || return 1
      user_refs=("${(@)reply#${base}/generations/}")
      state_record_paths "$previous" active_skills "$STATE_SAVED_SKILL_COUNT" || return 1
      skill_refs=("${(@)reply#${base}/generations/}")
    fi
    # mkdir reserves the generation without overwriting a crashed writer.
    for (( i=1; i<=32; i++ )); do
      generation="${EPOCHSECONDS}_${sysparams[pid]}_${RANDOM}"
      session_dir="$base/generations/$generation"
      zf_mkdir "$session_dir" 2>/dev/null && break
    done
    (( i <= 32 )) || return 1
    agent_dir="$session_dir/agent_messages"; ui_dir="$session_dir/ui_events"
    users_dir="$session_dir/context_users"; skills_dir="$session_dir/active_skills"
    zf_mkdir "$agent_dir" "$ui_dir" "$users_dir" "$skills_dir" || return 1
    _state_save_records || return 1
    _state_write "$session_dir/agent_messages.refs" "${(F)agent_refs[1,${#AGENT_MESSAGES}]}" || return 1
    _state_write "$session_dir/ui_events.refs" "${(F)ui_refs[1,${#UI_ROLES}]}" || return 1
    _state_write "$session_dir/context_users.refs" "${(F)user_refs[1,${#AGENT_USER_MESSAGES}]}" || return 1
    _state_write "$session_dir/active_skills.refs" "${(F)skill_refs[1,${#SKILL_ACTIVE_NAMES}]}" || return 1
    _state_write "$session_dir/previous" "${previous:t}" || return 1
    marker="$base/.current.$sysparams[pid].$RANDOM"
    _state_write "$marker" "$generation" || return 1
    [[ ! -d "$base/current" && ! -h "$base/current" ]] || return 1
    zf_mv -f -- "$marker" "$base/current" || return 1
    committed=1
    local -a manifests=("$base/generations/"*/previous(N))
    if (( ${#manifests} > 32 )); then
      _state_collect_generations "$base/generations" "$generation" "${previous:t}" ||
        zcoder_debug session_collection_failed "session=$CURRENT_SESSION_ID"
    fi
    STATE_SAVED_SNAPSHOT="$session_dir"
    STATE_OBSERVED_BASE="$base"
    STATE_OBSERVED_SNAPSHOT="$session_dir"
    STATE_SAVED_SESSION_ID="$CURRENT_SESSION_ID"
    STATE_SAVED_COMPACTIONS=$AGENT_COMPACTION_COUNT
    STATE_SAVED_AGENT_COUNT=${#AGENT_MESSAGES}
    STATE_SAVED_UI_COUNT=${#UI_ROLES}
    STATE_SAVED_USER_COUNT=${#AGENT_USER_MESSAGES}
    STATE_SAVED_SKILL_COUNT=${#SKILL_ACTIVE_NAMES}
    STATE_SAVED_REASONING="${(j::)UI_REASONING_OPEN}"
    UI_PERSIST_DIRTY_FROM=0
    return 0
  } always {
    if (( ! committed )); then
      [[ -n "$STATE_ERROR" ]] || STATE_ERROR='session save failed before commit'
      [[ -n "$session_dir" && "$session_dir" == "$base/generations/"* && "${mapfile[$base/current]:-}" != "$generation" ]] && zf_rm -rf -- "$session_dir" 2>/dev/null
      [[ -n "$marker" ]] && zf_rm -f -- "$marker" 2>/dev/null
      print -ru2 -- "Session save failed: $STATE_ERROR"
    fi
    [[ -n "$lock_fd" ]] && zsystem flock -u "$lock_fd" 2>/dev/null
    umask "$old_umask"
  }
}

# Deliberate dynamic scope: the transaction owns the directories/ref arrays;
# this serializer never publishes or advances the saved cursors itself.
_state_save_records() {
  if [[ "$previous" != "$base" && "$CURRENT_SESSION_ID" == "$STATE_SAVED_SESSION_ID" && "$previous" == "$STATE_SAVED_SNAPSHOT" ]] && \
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

  if (( UI_PERSIST_DIRTY_FROM > 0 && UI_PERSIST_DIRTY_FROM < ui_start )); then
    ui_start=$UI_PERSIST_DIRTY_FROM
  fi
  _state_write "$session_dir/id" "$CURRENT_SESSION_ID" || return 1
  _state_write "$session_dir/title" "$SESSION_TITLE" || return 1
  _state_write "$session_dir/workspace" "${ZCODER_WORKSPACE:A}" || return 1
  _state_write "$session_dir/profile" "$ZCODER_PROFILE" || return 1
  _state_write "$session_dir/model" "$ZCODER_MODEL" || return 1
  _state_write "$session_dir/updated_at" "$EPOCHSECONDS" || return 1
  _state_write "$session_dir/agent_message_count" "${#AGENT_MESSAGES}" || return 1
  _state_write "$session_dir/ui_event_count" "${#UI_ROLES}" || return 1
  _state_write "$session_dir/selected_event" "${UI_IDS[UI_SELECTED_EVENT]:-}" || return 1
  _state_write "$session_dir/context_user_count" "${#AGENT_USER_MESSAGES}" || return 1
  _state_write "$session_dir/active_skill_count" "${#SKILL_ACTIVE_NAMES}" || return 1
  _state_write "$session_dir/compaction_summary" "$AGENT_COMPACTION_SUMMARY" || return 1
  _state_write "$session_dir/compaction_count" "$AGENT_COMPACTION_COUNT" || return 1
  _state_write "$session_dir/compaction_rearm_tokens" "$AGENT_COMPACTION_REARM_TOKENS" || return 1
  _state_write "$session_dir/last_prompt_tokens" "$AGENT_LAST_PROMPT_TOKENS" || return 1
  _state_write "$session_dir/last_output_tokens" "$AGENT_LAST_OUTPUT_TOKENS" || return 1
  _state_write "$session_dir/last_payload_bytes" "$AGENT_LAST_PAYLOAD_BYTES" || return 1
  _state_write "$session_dir/goal_id" "${GOAL_ID:-}" || return 1
  _state_write "$session_dir/goal_status" "${GOAL_STATUS:-none}" || return 1
  _state_write "$session_dir/goal_objective" "${GOAL_OBJECTIVE:-}" || return 1
  _state_write "$session_dir/goal_feedback" "${GOAL_FEEDBACK:-}" || return 1
  _state_write "$session_dir/goal_block_reason" "${GOAL_BLOCK_REASON:-}" || return 1
  _state_write "$session_dir/goal_candidate_response" "${GOAL_CANDIDATE_RESPONSE:-}" || return 1
  _state_write "$session_dir/goal_created_at" "${GOAL_CREATED_AT:-0}" || return 1
  _state_write "$session_dir/goal_updated_at" "${GOAL_UPDATED_AT:-0}" || return 1
  _state_write "$session_dir/goal_attempts" "${GOAL_ATTEMPTS:-0}" || return 1
  _state_write "$session_dir/goal_rejections" "${GOAL_REJECTIONS:-0}" || return 1
  _state_write "$session_dir/goal_tokens_used" "${GOAL_TOKENS_USED:-0}" || return 1
  _state_write "$session_dir/goal_token_budget" "${GOAL_TOKEN_BUDGET:-0}" || return 1

  for (( i=agent_start; i<=${#AGENT_MESSAGES}; i++ )); do
    printf -v seq '%06d' "$i"
    _state_write "$agent_dir/$seq" "${AGENT_MESSAGES[i]}" || return 1
    agent_refs[i]="$generation/agent_messages/$seq"
  done
  for (( i=ui_start; i<=${#UI_ROLES}; i++ )); do
    printf -v seq '%06d' "$i"
    _state_write "$ui_dir/$seq.role" "${UI_ROLES[i]}" || return 1
    _state_write "$ui_dir/$seq.content" "${UI_CONTENTS[i]}" || return 1
    _state_write "$ui_dir/$seq.thinking" "${UI_THINKINGS[i]}" || return 1
    _state_write "$ui_dir/$seq.time" "${UI_TIMES[i]}" || return 1
    _state_write "$ui_dir/$seq.reasoning_open" "${UI_REASONING_OPEN[i]:-0}" || return 1
    ui_refs[i]="$generation/ui_events/$seq"
    transcript_metadata_json "$i"
    _state_write "$ui_dir/$seq.meta" "$REPLY" || return 1
  done
  for (( i=users_start; i<=${#AGENT_USER_MESSAGES}; i++ )); do
    printf -v seq '%06d' "$i"
    _state_write "$users_dir/$seq" "${AGENT_USER_MESSAGES[i]}" || return 1
    user_refs[i]="$generation/context_users/$seq"
  done
  for (( i=skills_start; i<=${#SKILL_ACTIVE_NAMES}; i++ )); do
    printf -v seq '%06d' "$i"
    _state_write "$skills_dir/$seq" "${SKILL_ACTIVE_NAMES[i]}" || return 1
    skill_refs[i]="$generation/active_skills/$seq"
  done
  return 0
}

state_save_and_refresh() {
  state_save_session || return 1
  state_refresh_sessions_list
}

state_new_session() {
  if (( STATE_ENABLED )); then state_save_session || return 1; fi
  CURRENT_SESSION_ID="${EPOCHSECONDS}_${RANDOM}"
  SESSION_TITLE="New Job"
  agent_reset
  transcript_reset
  state_save_and_refresh
}

state_load_session() {
  local id="$1"
  local -a reply=()
  _state_valid_id "$id" || return 1
  state_snapshot_values "$ZCODER_SESSIONS_DIR/$id.session" workspace profile || return 1
  _state_scope_matches "$reply[1]" "$reply[2]" || return 1
  if (( STATE_ENABLED )); then state_save_session || return 1; fi
  state_with_snapshot "$ZCODER_SESSIONS_DIR/$id.session" _state_load_snapshot "$id"
}

_state_load_snapshot() {
  local id="$1" saved_workspace="" saved_profile="" saved_model=""
  local agent_dir="" ui_dir="" users_dir="" skills_dir="" seq="" skill_name=""
  local -i i count=0
  local -a reply=() record_paths=()
  _state_validate_snapshot || { STATE_ERROR='committed session is incomplete'; return 1; }
  STATE_LOADING=1
  CURRENT_SESSION_ID="$id"
  SESSION_TITLE="${mapfile[$session_dir/title]:-Untitled}"
  saved_model="${mapfile[$session_dir/model]}"
  if (( ! ${ZCODER_MODEL_OVERRIDE:-0} )) && [[ -n "$saved_model" ]]; then
    ZCODER_MODEL="$saved_model"
  fi
  agent_reset
  transcript_reset

  local -i disk_agent_count=0 disk_ui_count=0 disk_user_count=0 disk_skill_count=0
  agent_dir="$session_dir/agent_messages"
  _state_nonnegative "${mapfile[$session_dir/agent_message_count]:-0}"; count=$REPLY
  disk_agent_count=$count
  state_record_paths "$session_dir" agent_messages "$count" || { STATE_LOADING=0; return 1; }
  record_paths=("${reply[@]}")
  for (( i=1; i<=count; i++ )); do
    agent_dir="${record_paths[i]:h}"
    seq="${record_paths[i]:t}"
    [[ -f "$agent_dir/$seq" ]] && AGENT_MESSAGES+=("${mapfile[$agent_dir/$seq]}")
  done

  ui_dir="$session_dir/ui_events"
  _state_nonnegative "${mapfile[$session_dir/ui_event_count]:-0}"; count=$REPLY
  disk_ui_count=$count
  state_record_paths "$session_dir" ui_events "$count" || { STATE_LOADING=0; return 1; }
  record_paths=("${reply[@]}")
  for (( i=1; i<=count; i++ )); do
    ui_dir="${record_paths[i]:h}"
    seq="${record_paths[i]:t}"
    [[ -f "$ui_dir/$seq.role" ]] || continue
    UI_ROLES+=("${mapfile[$ui_dir/$seq.role]:-system}")
    UI_CONTENTS+=("${mapfile[$ui_dir/$seq.content]}")
    UI_THINKINGS+=("${mapfile[$ui_dir/$seq.thinking]}")
    UI_TIMES+=("${mapfile[$ui_dir/$seq.time]}")
    _state_nonnegative "${mapfile[$ui_dir/$seq.reasoning_open]:-0}"
    (( REPLY > 0 )) && UI_REASONING_OPEN+=(1) || UI_REASONING_OPEN+=(0)
    transcript_restore_metadata ${#UI_ROLES} "${mapfile[$ui_dir/$seq.meta]:-}"
  done
  local selected_id="${mapfile[$session_dir/selected_event]:-}"
  [[ -n "$selected_id" ]] && UI_SELECTED_EVENT=${UI_IDS[(Ie)$selected_id]}

  AGENT_COMPACTION_SUMMARY="${mapfile[$session_dir/compaction_summary]}"
  _state_nonnegative "${mapfile[$session_dir/compaction_count]:-0}"; AGENT_COMPACTION_COUNT=$REPLY
  _state_nonnegative "${mapfile[$session_dir/compaction_rearm_tokens]:-0}"; AGENT_COMPACTION_REARM_TOKENS=$REPLY
  _state_nonnegative "${mapfile[$session_dir/last_prompt_tokens]:-0}"; AGENT_LAST_PROMPT_TOKENS=$REPLY
  _state_nonnegative "${mapfile[$session_dir/last_output_tokens]:-0}"; AGENT_LAST_OUTPUT_TOKENS=$REPLY
  _state_nonnegative "${mapfile[$session_dir/last_payload_bytes]:-0}"; AGENT_LAST_PAYLOAD_BYTES=$REPLY

  GOAL_ID="${mapfile[$session_dir/goal_id]}"
  case "${mapfile[$session_dir/goal_status]:-none}" in
    none|active|verifying|paused|blocked|budget_limited|complete) GOAL_STATUS="${mapfile[$session_dir/goal_status]:-none}" ;;
    *) GOAL_STATUS="none" ;;
  esac
  # A process cannot resume an in-flight worker or verifier frame. Preserve the
  # goal and make continuation explicit after a crash or session switch.
  if [[ "$GOAL_STATUS" == active || "$GOAL_STATUS" == verifying ]]; then
    GOAL_STATUS="paused"
    [[ -n "${mapfile[$session_dir/goal_block_reason]}" ]] || GOAL_BLOCK_REASON="goal execution was interrupted"
  fi
  GOAL_OBJECTIVE="${mapfile[$session_dir/goal_objective]}"
  GOAL_FEEDBACK="${mapfile[$session_dir/goal_feedback]}"
  [[ -n "$GOAL_BLOCK_REASON" ]] || GOAL_BLOCK_REASON="${mapfile[$session_dir/goal_block_reason]}"
  GOAL_CANDIDATE_RESPONSE="${mapfile[$session_dir/goal_candidate_response]}"
  _state_nonnegative "${mapfile[$session_dir/goal_created_at]:-0}"; GOAL_CREATED_AT=$REPLY
  _state_nonnegative "${mapfile[$session_dir/goal_updated_at]:-0}"; GOAL_UPDATED_AT=$REPLY
  _state_nonnegative "${mapfile[$session_dir/goal_attempts]:-0}"; GOAL_ATTEMPTS=$REPLY
  _state_nonnegative "${mapfile[$session_dir/goal_rejections]:-0}"; GOAL_REJECTIONS=$REPLY
  _state_nonnegative "${mapfile[$session_dir/goal_tokens_used]:-0}"; GOAL_TOKENS_USED=$REPLY
  _state_nonnegative "${mapfile[$session_dir/goal_token_budget]:-0}"; GOAL_TOKEN_BUDGET=$REPLY

  users_dir="$session_dir/context_users"
  _state_nonnegative "${mapfile[$session_dir/context_user_count]:-0}"; count=$REPLY
  disk_user_count=$count
  state_record_paths "$session_dir" context_users "$count" || { STATE_LOADING=0; return 1; }
  record_paths=("${reply[@]}")
  for (( i=1; i<=count; i++ )); do
    users_dir="${record_paths[i]:h}"
    seq="${record_paths[i]:t}"
    [[ -f "$users_dir/$seq" ]] && AGENT_USER_MESSAGES+=("${mapfile[$users_dir/$seq]}")
  done

  skills_dir="$session_dir/active_skills"
  _state_nonnegative "${mapfile[$session_dir/active_skill_count]:-0}"; count=$REPLY
  disk_skill_count=$count
  state_record_paths "$session_dir" active_skills "$count" || { STATE_LOADING=0; return 1; }
  record_paths=("${reply[@]}")
  for (( i=1; i<=count; i++ )); do
    skills_dir="${record_paths[i]:h}"
    seq="${record_paths[i]:t}"
    skill_name="${mapfile[$skills_dir/$seq]}"
    [[ -n "$skill_name" && -n "${SKILL_FILES[$skill_name]:-}" ]] && skills_activate "$skill_name" >/dev/null 2>&1
  done

  AGENT_CONTEXT_MODEL=""
  UI_SCROLL=0
  UI_AUTO_SCROLL=1
  STATE_LOADING=0
  STATE_OBSERVED_BASE="$ZCODER_SESSIONS_DIR/$id.session"
  STATE_OBSERVED_SNAPSHOT="$session_dir"
  # When every on-disk record loaded, the arrays mirror the session directory
  # exactly and the next save can append from these counts. A lossy load
  # (missing files, failed skill activation) forces that save to rewrite all
  # records instead.
  if (( ${#AGENT_MESSAGES} == disk_agent_count && ${#UI_ROLES} == disk_ui_count && \
        ${#AGENT_USER_MESSAGES} == disk_user_count && ${#SKILL_ACTIVE_NAMES} == disk_skill_count )); then
    STATE_SAVED_SNAPSHOT="$session_dir"
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
  local start_mode="${1:-new}" session_id="" session_dir="" old_umask="$(umask)"
  local -i agent_count=0 ui_count=0
  local -a reply=()
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
  if [[ "$start_mode" == storage ]]; then
    return 0
  elif [[ "$start_mode" == resume ]] && (( ${#SESSION_IDS} > 0 )); then
    state_load_session "${SESSION_IDS[1]}" || state_new_session
  elif (( ${#SESSION_IDS} > 0 )); then
    for session_id in "${SESSION_IDS[@]}"; do
      session_dir="$ZCODER_SESSIONS_DIR/${session_id}.session"
      state_snapshot_values "$session_dir" agent_message_count ui_event_count || continue
      _state_nonnegative "$reply[1]"; agent_count=$REPLY
      _state_nonnegative "$reply[2]"; ui_count=$REPLY
      if (( agent_count == 0 && ui_count == 0 )); then
        state_load_session "$session_id" || state_new_session
        return $?
      fi
    done
    state_new_session
  else
    state_new_session
  fi
}
