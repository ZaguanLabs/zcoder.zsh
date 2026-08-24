# Conservative conversation compaction for local Ollama models.

typeset -g ZCODER_CONTEXT_WINDOW="${ZCODER_CONTEXT_WINDOW:-auto}"
typeset -gi ZCODER_CONTEXT_FALLBACK="${ZCODER_CONTEXT_FALLBACK:-65536}"
typeset -gi ZCODER_COMPACT_PERCENT="${ZCODER_COMPACT_PERCENT:-85}"
typeset -gi ZCODER_COMPACT_MAX_TOKENS="${ZCODER_COMPACT_MAX_TOKENS:-2048}"
typeset -gi ZCODER_COMPACT_KEEP_USER_TOKENS="${ZCODER_COMPACT_KEEP_USER_TOKENS:-4096}"
typeset -gi ZCODER_COMPACT_KEEP_RECENT_TOKENS="${ZCODER_COMPACT_KEEP_RECENT_TOKENS:-16384}"
typeset -gi AGENT_CONTEXT_WINDOW="$ZCODER_CONTEXT_FALLBACK"
typeset -g AGENT_CONTEXT_MODEL=""
typeset -gi AGENT_CONTEXT_DISCOVERY_PENDING=0
typeset -gi AGENT_LAST_PROMPT_TOKENS=0
typeset -gi AGENT_LAST_OUTPUT_TOKENS=0
typeset -gi AGENT_LAST_PAYLOAD_BYTES=0
typeset -gi AGENT_ESTIMATED_TOKENS=0
typeset -gi AGENT_COMPACTION_COUNT=0
typeset -gi AGENT_COMPACTION_IN_PROGRESS=0
typeset -gi AGENT_COMPACTION_REARM_TOKENS=0
typeset -g AGENT_COMPACTION_SUMMARY=""
typeset -ga AGENT_USER_MESSAGES=()

(( ZCODER_CONTEXT_FALLBACK >= 4096 )) || ZCODER_CONTEXT_FALLBACK=65536
(( ZCODER_COMPACT_PERCENT >= 25 && ZCODER_COMPACT_PERCENT <= 90 )) || ZCODER_COMPACT_PERCENT=85
(( ZCODER_COMPACT_MAX_TOKENS >= 256 )) || ZCODER_COMPACT_MAX_TOKENS=2048
(( ZCODER_COMPACT_KEEP_USER_TOKENS >= 256 )) || ZCODER_COMPACT_KEEP_USER_TOKENS=4096
(( ZCODER_COMPACT_KEEP_RECENT_TOKENS >= 256 )) || ZCODER_COMPACT_KEEP_RECENT_TOKENS=16384

typeset -g AGENT_COMPACTION_PROMPT=$'Create a compact continuation checkpoint for another coding model that will resume this exact task.\n\nInclude only durable, actionable information:\n- the user\'s goal and explicit preferences\n- project instructions and constraints that affect the work\n- decisions made and why\n- files, symbols, commands, errors, and tool results that still matter\n- changes already completed and their verification status\n- unresolved problems and precise next steps\n\nDo not call tools. Do not continue the task. Return only the checkpoint, using concise headings and preserving exact paths and technical details.'

agent_compaction_reset() {
  AGENT_CONTEXT_MODEL=""
  AGENT_CONTEXT_WINDOW="$ZCODER_CONTEXT_FALLBACK"
  AGENT_CONTEXT_DISCOVERY_PENDING=0
  AGENT_LAST_PROMPT_TOKENS=0
  AGENT_LAST_OUTPUT_TOKENS=0
  AGENT_LAST_PAYLOAD_BYTES=0
  AGENT_ESTIMATED_TOKENS=0
  AGENT_COMPACTION_COUNT=0
  AGENT_COMPACTION_IN_PROGRESS=0
  AGENT_COMPACTION_REARM_TOKENS=0
  AGENT_COMPACTION_SUMMARY=""
  AGENT_USER_MESSAGES=()
}

agent_context_configure() {
  if [[ "$AGENT_CONTEXT_MODEL" == "$ZCODER_MODEL" ]]; then
    return 0
  fi
  AGENT_CONTEXT_MODEL="$ZCODER_MODEL"
  AGENT_LAST_PROMPT_TOKENS=0
  AGENT_LAST_PAYLOAD_BYTES=0
  AGENT_CONTEXT_DISCOVERY_PENDING=0
  AGENT_COMPACTION_REARM_TOKENS=0
  if [[ "$ZCODER_CONTEXT_WINDOW" == <4096-> ]]; then
    AGENT_CONTEXT_WINDOW="$ZCODER_CONTEXT_WINDOW"
    return 0
  fi

  AGENT_CONTEXT_WINDOW="$ZCODER_CONTEXT_FALLBACK"
  if ollama_get_running_context "$ZCODER_MODEL" "$OLLAMA_HOST"; then
    AGENT_CONTEXT_WINDOW="$OLLAMA_RUNNING_CONTEXT"
  else
    # A model absent from /api/ps has not been loaded yet. Refresh after the
    # first response, when Ollama can report the allocation it actually made.
    AGENT_CONTEXT_DISCOVERY_PENDING=1
  fi
  HTTP_ERROR=""
}

agent_context_refresh_after_response() {
  (( AGENT_CONTEXT_DISCOVERY_PENDING )) || return 0
  if ollama_get_running_context "$ZCODER_MODEL" "$OLLAMA_HOST"; then
    AGENT_CONTEXT_WINDOW="$OLLAMA_RUNNING_CONTEXT"
    AGENT_CONTEXT_DISCOVERY_PENDING=0
  fi
  HTTP_ERROR=""
}

agent_compaction_limit() {
  local -i limit=$(( AGENT_CONTEXT_WINDOW * ZCODER_COMPACT_PERCENT / 100 ))
  (( AGENT_COMPACTION_REARM_TOKENS > limit )) && limit=$AGENT_COMPACTION_REARM_TOKENS
  (( limit > AGENT_CONTEXT_WINDOW * 95 / 100 )) && limit=$(( AGENT_CONTEXT_WINDOW * 95 / 100 ))
  REPLY="$limit"
}

agent_compaction_output_limit() {
  local -i window_limit=$(( AGENT_CONTEXT_WINDOW / 10 ))
  (( window_limit < 256 )) && window_limit=256
  (( window_limit > ZCODER_COMPACT_MAX_TOKENS )) && window_limit=$ZCODER_COMPACT_MAX_TOKENS
  REPLY="$window_limit"
}

agent_estimate_payload_tokens() {
  local payload="$1"
  local -i bytes estimate
  _http_byte_length "$payload"
  bytes=$REPLY
  if (( AGENT_LAST_PROMPT_TOKENS > 0 && AGENT_LAST_PAYLOAD_BYTES > 0 )); then
    estimate=$(( (bytes * AGENT_LAST_PROMPT_TOKENS + AGENT_LAST_PAYLOAD_BYTES - 1) / AGENT_LAST_PAYLOAD_BYTES ))
    # Allow for tokenizer/template variance as the mix of prose, code, and JSON changes.
    estimate=$(( (estimate * 110 + 99) / 100 ))
  else
    # Three bytes per token plus fixed chat-template headroom is deliberately
    # conservative for code-heavy local-model prompts.
    estimate=$(( (bytes + 2) / 3 + 512 ))
  fi
  AGENT_ESTIMATED_TOKENS="$estimate"
  REPLY="$estimate"
}

agent_context_options_json() {
  # In auto mode the fallback is only an internal accounting budget. Omitting
  # num_ctx on the first request lets Ollama honor the model's Modelfile or the
  # server default instead of silently replacing it with our fallback.
  if [[ "$ZCODER_CONTEXT_WINDOW" == auto ]] && (( AGENT_CONTEXT_DISCOVERY_PENDING )); then
    REPLY=""
    return 0
  fi
  REPLY="\"num_ctx\":${AGENT_CONTEXT_WINDOW},"
}

agent_build_compaction_payload() {
  local -i start="${1:-1}"
  local records="" source_text="" system_json="" user_json="" model_json="" options=""
  records="[${(j:,:)AGENT_MESSAGES[start,-1]}]"
  if [[ -n "$AGENT_COMPACTION_SUMMARY" ]]; then
    source_text=$'Previous checkpoint:\n'"$AGENT_COMPACTION_SUMMARY"$'\n\n'
  fi
  source_text+=$'Conversation records, oldest to newest, as JSON:\n'"$records"$'\n\n'"$AGENT_COMPACTION_PROMPT"
  json_quote "You summarize coding-agent state for loss-minimizing context compaction. Follow the user's checkpoint instructions exactly."; system_json="$REPLY"
  json_quote "$source_text"; user_json="$REPLY"
  json_quote "$ZCODER_MODEL"; model_json="$REPLY"
  agent_context_options_json; options="$REPLY"
  agent_compaction_output_limit
  REPLY="{\"model\":${model_json},\"messages\":[{\"role\":\"system\",\"content\":${system_json}},{\"role\":\"user\",\"content\":${user_json}}],\"stream\":false,\"think\":false,\"options\":{${options}\"num_predict\":${REPLY},\"temperature\":0}}"
}

agent_compaction_replace_history() {
  local summary="$1" message=""
  local -i user_token_budget=$(( AGENT_CONTEXT_WINDOW / 10 ))
  local -i recent_token_budget=$(( AGENT_CONTEXT_WINDOW / 6 )) i length remaining
  local -a kept_users=() recent_messages=()

  # Local models benefit from seeing the latest raw assistant/tool exchange
  # after a checkpoint. A summary alone can make them repeat the work that
  # immediately preceded compaction.
  (( recent_token_budget < 256 )) && recent_token_budget=256
  (( recent_token_budget > ZCODER_COMPACT_KEEP_RECENT_TOKENS )) && recent_token_budget=$ZCODER_COMPACT_KEEP_RECENT_TOKENS
  remaining=$(( recent_token_budget * 3 ))
  for (( i=${#AGENT_MESSAGES}; i>=1 && remaining>0; i-- )); do
    message="${AGENT_MESSAGES[i]}"
    length=${#message}
    (( length <= remaining )) || break
    recent_messages=("$message" "${recent_messages[@]}")
    (( remaining -= length ))
  done

  # Keep a bounded exact-user ledger for subsequent checkpoints even when the
  # transport tail above starts after an older user message.
  (( user_token_budget < 256 )) && user_token_budget=256
  (( user_token_budget > ZCODER_COMPACT_KEEP_USER_TOKENS )) && user_token_budget=$ZCODER_COMPACT_KEEP_USER_TOKENS
  remaining=$(( user_token_budget * 3 ))
  for (( i=${#AGENT_USER_MESSAGES}; i>=1 && remaining>0; i-- )); do
    message="${AGENT_USER_MESSAGES[i]}"
    length=${#message}
    if (( length <= remaining )); then
      kept_users=("$message" "${kept_users[@]}")
      (( remaining -= length ))
    else
      zcoder_truncate "$message" "$remaining"
      kept_users=("$REPLY" "${kept_users[@]}")
      remaining=0
    fi
  done

  AGENT_COMPACTION_SUMMARY="$summary"
  AGENT_USER_MESSAGES=("${kept_users[@]}")
  AGENT_MESSAGES=("${recent_messages[@]}")
}

agent_compact_history() {
  local trigger="${1:-manual}" payload="" best_payload="" response="" summary="" dropped_note="" size_note=""
  local -i start=1 count=${#AGENT_MESSAGES} hard_limit estimate request_status before after low high midpoint best_start
  HTTP_ERROR=""
  AGENT_CANCELLED=0
  (( count > 0 || ${#AGENT_COMPACTION_SUMMARY} > 0 )) || return 2
  (( AGENT_COMPACTION_IN_PROGRESS )) && { HTTP_ERROR="compaction is already running"; return 1; }
  AGENT_COMPACTION_IN_PROGRESS=1
  agent_context_configure
  agent_compaction_limit
  before="$AGENT_ESTIMATED_TOKENS"
  hard_limit=$(( AGENT_CONTEXT_WINDOW * 85 / 100 ))

  # The payload shrinks monotonically as its oldest records are omitted. Find
  # the smallest fitting start with a binary search instead of rebuilding and
  # JSON-escaping the whole history once for every discarded message.
  low=1
  high=$count
  best_start=$count
  while (( low <= high )); do
    midpoint=$(( (low + high) / 2 ))
    agent_build_compaction_payload "$midpoint"
    payload="$REPLY"
    agent_estimate_payload_tokens "$payload"
    estimate=$REPLY
    if (( estimate <= hard_limit )); then
      best_start=$midpoint
      best_payload="$payload"
      high=$(( midpoint - 1 ))
    else
      low=$(( midpoint + 1 ))
    fi
  done
  start=$best_start
  if [[ -n "$best_payload" ]]; then
    payload="$best_payload"
    agent_estimate_payload_tokens "$payload"
    estimate=$REPLY
  else
    agent_build_compaction_payload "$start"
    payload="$REPLY"
    agent_estimate_payload_tokens "$payload"
    estimate=$REPLY
  fi

  agent_set_status "Compacting"
  agent_ollama_chat "$payload" "$OLLAMA_HOST"
  request_status=$?
  if (( request_status != 0 )); then
    AGENT_COMPACTION_IN_PROGRESS=0
    return "$request_status"
  fi
  response="$HTTP_BODY"
  if ! json_parse_ollama_response "$response"; then
    HTTP_ERROR="could not parse compaction response: ${JSON_ERROR:-unknown JSON error}"
    AGENT_COMPACTION_IN_PROGRESS=0
    return 1
  fi
  if [[ -n "$JSON_RESPONSE_ERROR" ]]; then
    HTTP_ERROR="$JSON_RESPONSE_ERROR"
    AGENT_COMPACTION_IN_PROGRESS=0
    return 1
  fi
  summary="$JSON_RESPONSE_CONTENT"
  if [[ -z "$summary" ]]; then
    HTTP_ERROR="Ollama returned an empty compaction checkpoint"
    AGENT_COMPACTION_IN_PROGRESS=0
    return 1
  fi
  agent_compaction_output_limit
  zcoder_truncate "$summary" $(( REPLY * 4 ))
  summary="$REPLY"
  agent_compaction_replace_history "$summary"
  (( AGENT_COMPACTION_COUNT++ ))
  AGENT_LAST_PROMPT_TOKENS=0
  AGENT_LAST_OUTPUT_TOKENS=0
  AGENT_LAST_PAYLOAD_BYTES=0
  AGENT_COMPACTION_IN_PROGRESS=0

  agent_build_payload
  agent_estimate_payload_tokens "$REPLY"
  after=$REPLY
  AGENT_COMPACTION_REARM_TOKENS=$(( after + AGENT_CONTEXT_WINDOW / 10 ))
  (( before > 0 )) || before=$estimate
  (( start > 1 )) && dropped_note="; omitted $(( start - 1 )) oldest detailed record(s) from the checkpoint request to fit the window"
  (( after >= before )) && size_note="; the conversation was already small, so the checkpoint did not reduce its estimated size"
  agent_emit system "♻ Compacted context (${trigger}): approximately ${before} → ${after} tokens; checkpoint ${AGENT_COMPACTION_COUNT}${dropped_note}${size_note}."
  return 0
}

agent_prepare_payload() {
  local payload=""
  local -i estimate limit compact_status
  agent_context_configure
  agent_build_payload
  payload="$REPLY"
  agent_estimate_payload_tokens "$payload"
  estimate=$REPLY
  agent_compaction_limit
  limit=$REPLY
  if (( estimate >= limit && (${#AGENT_MESSAGES} > 0 || ${#AGENT_COMPACTION_SUMMARY} > 0) )); then
    agent_compact_history auto
    compact_status=$?
    (( compact_status == 0 )) || return "$compact_status"
    agent_build_payload
    payload="$REPLY"
    agent_estimate_payload_tokens "$payload"
  fi
  REPLY="$payload"
}

agent_context_summary() {
  local last_prompt="unknown"
  local -i estimate limit
  agent_context_configure
  agent_build_payload
  agent_estimate_payload_tokens "$REPLY"
  estimate=$REPLY
  agent_compaction_limit
  limit=$REPLY
  (( AGENT_LAST_PROMPT_TOKENS > 0 )) && last_prompt="$AGENT_LAST_PROMPT_TOKENS"
  REPLY="Context: ${AGENT_CONTEXT_WINDOW} tokens (${ZCODER_CONTEXT_WINDOW} setting); estimated next prompt: ${estimate} tokens; automatic compaction near ${limit} tokens (${ZCODER_COMPACT_PERCENT}%); checkpoints: ${AGENT_COMPACTION_COUNT}; last Ollama prompt: ${last_prompt}."
}
