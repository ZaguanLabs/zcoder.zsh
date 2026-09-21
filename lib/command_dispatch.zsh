# Interactive slash-command routing and external harness availability.

zcoder_delegate_host_label() {
  if [[ "$REMOTE_MODE" == client ]]; then
    REPLY="remote server '${REMOTE_SERVER_NAME:-unknown}'"
  else
    REPLY="this zcoder host"
  fi
}

zcoder_delegate_require_available() {
  local provider="$1" host_label=""
  if [[ "$REMOTE_MODE" == client ]]; then
    (( ${REMOTE_HARNESS_DISCOVERY_SUPPORTED:-0} )) || return 0
  else
    delegate_refresh_availability
  fi
  zcoder_delegate_host_label; host_label="$REPLY"
  delegate_require_available "$provider" "$host_label"
}

zcoder_delegate_availability_summary() {
  local host_label=""
  if [[ "$REMOTE_MODE" == client && ${REMOTE_HARNESS_DISCOVERY_SUPPORTED:-0} -ne 1 ]]; then
    REPLY="External harness availability is not reported by this remote server."
    return 0
  fi
  [[ "$REMOTE_MODE" == client ]] || delegate_refresh_availability
  zcoder_delegate_host_label; host_label="$REPLY"
  delegate_availability_summary "$host_label"
}

handle_slash_command() {
  local text="$1" value="" provider="" command_name="" previous_value="" failure=""
  local -i delegate_status=0 worker=0
  case "$text" in
    /claude|/claude\ *|/claude!|/claude!\ *|/codex|/codex\ *|/codex!|/codex!\ *|/agy|/agy\ *|/agy!|/agy!\ *|/opencode*|/help|/\?)
      zcoder_require harnesses delegate
      ;;
  esac
  provider=""
  case "$text" in
    /claude|/claude\ *|/claude!|/claude!\ *) provider="claude" ;;
    /codex|/codex\ *|/codex!|/codex!\ *) provider="codex" ;;
    /agy|/agy\ *|/agy!|/agy!\ *) provider="agy" ;;
    /opencode|/opencode\ *|/opencode!|/opencode!\ *|/opencode-model|/opencode-model\ *) provider="opencode" ;;
  esac
  if [[ -n "$provider" ]] && ! zcoder_delegate_require_available "$provider"; then
    ui_append_message error "$DELEGATE_ERROR"
    ui_refresh_all
    return 0
  fi
  case "$text" in
    /commands)
      ui_command_palette
      return 0
      ;;
    /goal|/goal\ *)
      if [[ "$REMOTE_MODE" == client ]]; then
        if (( ${REMOTE_GOALS_SUPPORTED:-0} )); then
          remote_client_user_turn "$text"
        else
          ui_append_message error "Persistent goals are not supported by this remote server."
        fi
      else
        goal_handle_command "$text"
      fi
      (( $+functions[zcoder_refresh_sessions] )) && zcoder_refresh_sessions
      ui_refresh_all
      return 0
      ;;
    /new|/clear)
      if [[ "$REMOTE_MODE" == client ]]; then
        if ! remote_client_new_session; then
          ui_append_message error "Could not create a remote session: $REMOTE_ERROR"
          return 0
        fi
      else
        state_new_session
        agent_warmup_start || true
      fi
      UI_FOCUS="input"
      ui_set_status "Ready"
      ;;
    /sessions)
      if [[ "$REMOTE_MODE" == client && ${REMOTE_SESSIONS_SUPPORTED:-0} -ne 1 ]]; then
        ui_append_message error "Remote session browsing is not supported by this server."
        return 0
      fi
      if (( UI_SIDEBAR_HIDDEN && SCREEN_W >= 88 )); then
        ui_toggle_sidebar
      fi
      if (( SIDE_W > 0 )); then
        UI_FOCUS="sidebar"
      else
        ui_append_message error "The terminal is too narrow to show the session sidebar."
      fi
      ;;
    /list-agents)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Agent discovery is local to the machine running the agent and is not bridged through a remote client."
      elif (( ! $+functions[relay_discover] || ! ${RELAY_ACTIVE:-0} )); then
        ui_append_message error "Inter-agent relay is unavailable: ${RELAY_ERROR:-not started}."
      elif relay_discover; then
        relay_agents_text
        zcoder_terminal_safe "$REPLY"
        ui_append_message system "$REPLY"
      else
        ui_append_message error "Could not list local agents: ${RELAY_ERROR:-unknown error}"
      fi
      ;;
    /agents)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Agent relay controls are local to the machine running the agent."
      elif (( $+functions[relay_status_text] )); then
        relay_status_text
        ui_append_message system "$REPLY"
      else
        ui_append_message error "Inter-agent relay is unavailable."
      fi
      ;;
    /agents\ pause)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Agent relay controls are local to the machine running the agent."
      elif (( $+functions[relay_pause] )) && relay_pause; then
        ui_append_message system "Inter-agent relay paused. New messages will be rejected; accepted messages remain queued."
      else
        ui_append_message error "Could not pause inter-agent relay: ${RELAY_ERROR:-not started}."
      fi
      ;;
    /agents\ resume)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Agent relay controls are local to the machine running the agent."
      elif (( $+functions[relay_resume] )) && relay_resume; then
        ui_append_message system "Inter-agent relay resumed."
      else
        ui_append_message error "Could not resume inter-agent relay: ${RELAY_ERROR:-not started}."
      fi
      ;;
    /agents\ *)
      ui_append_message error "Usage: /agents, /agents pause, or /agents resume"
      ;;
    /copy)
      ui_copy_view
      # Keep this recognized command out of the model fallback on fatal UI loss.
      (( UI_ACTIVE )) || return 0
      ;;
    /model)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message system "Remote model: $ZCODER_MODEL (selected by $REMOTE_SERVER_NAME)"
      else
        previous_value="$ZCODER_MODEL"
        ui_select_model
        [[ "$ZCODER_MODEL" != "$previous_value" ]] && agent_warmup_start || true
      fi
      ;;
    /model\ *)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "The remote model is fixed by the server process."
        return 0
      fi
      value="${text#/model }"; value="${value##[[:space:]]#}"
      if [[ -n "$value" ]]; then
        ZCODER_MODEL="$value"
        ui_append_message system "Model changed to $ZCODER_MODEL"
        agent_warmup_start || true
      fi
      ;;
    /host)
      [[ "$REMOTE_MODE" == client ]] && ui_append_message system "Connected to $REMOTE_SERVER_NAME at $REMOTE_ENDPOINT" || ui_append_message system "Current Ollama host: $OLLAMA_HOST"
      ;;
    /host\ *)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "The Ollama host is controlled by the remote server."
        return 0
      fi
      value="${text#/host }"; value="${value##[[:space:]]#}"
      if ollama_normalize_host "$value"; then
        OLLAMA_HOST="$REPLY"
        AGENT_CONTEXT_MODEL=""
        ui_append_message system "Ollama host changed to $OLLAMA_HOST"
        agent_warmup_start || true
      else
        ui_append_message error "$HTTP_ERROR"
      fi
      ;;
    /instructions)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Remote instruction inspection is not available in this first server release."
        return 0
      fi
      instructions_summary
      ui_append_message system "$REPLY"
      ;;
    /skills)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Remote Skill inspection is not available in this first server release."
        return 0
      fi
      skills_summary
      ui_append_message system "$REPLY"
      ;;
    /skills\ reload)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Skills are loaded and controlled by the remote server."
        return 0
      fi
      skills_load "$ZCODER_WORKSPACE"
      skills_summary
      ui_append_message system "Skills reloaded."$'\n'"$REPLY"
      agent_warmup_start || true
      ;;
    /mcp)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Remote MCP inspection is not available in this first server release."
        return 0
      fi
      ui_mcp_servers
      ;;
    /mcp\ reload)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "MCP servers are loaded and controlled by the remote server."
        return 0
      fi
      if mcp_load; then
        ui_append_message system "MCP configuration reloaded."
        agent_warmup_start || true
      else
        ui_append_message error "$MCP_ERROR"
      fi
      ;;
    /skill)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Skills are activated by prompts handled on the remote server."
        return 0
      fi
      ui_append_message error "/skill requires an installed Skill name"
      ;;
    /skill\ *)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Skills are activated by prompts handled on the remote server."
        return 0
      fi
      value="${text#/skill }"; value="${value%%[[:space:]]*}"
      if skills_activate "$value"; then
        ui_append_message system "$TOOL_RESULT"
        agent_warmup_start || true
      else
        ui_append_message error "$TOOL_RESULT"
      fi
      ;;
    /compact)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "Remote manual compaction is not available in this first server release."
        return 0
      fi
      (( AGENT_WARMUP_ACTIVE )) && agent_warmup_cancel "manual compaction started"
      if ! agent_compact_history manual; then
        if (( AGENT_CANCELLED )); then
          ui_append_message system "⏹ Compaction stopped."
          ui_set_status "Stopped"
        elif [[ "$HTTP_ERROR" == "" ]]; then
          ui_append_message system "Nothing to compact yet."
        else
          ui_append_message error "Compaction failed: $HTTP_ERROR"
          ui_set_status "Compaction error"
        fi
      else
        ui_set_status "Ready"
      fi
      ;;
    /terminal)
      ui_show_terminal
      return 0
      ;;
    /queue|/queue\ *)
      value="${text#/queue}"
      value="${value##[[:space:]]#}"
      input_queue_command "${${value%% *}:-list}" "${value#* }"
      ;;
    /context)
      if (( UI_ACTIVE )); then
        ui_show_context
        return 0
      fi
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message system "Remote model: $ZCODER_MODEL; context accounting is maintained by the server."
        return 0
      fi
      agent_context_summary
      ui_append_message system "$REPLY"
      ;;
    /claude|/codex|/agy|/claude!|/codex!|/agy!|/opencode!)
      command_name="${text#/}"
      [[ "$command_name" == *! ]] && worker=1 || worker=0
      provider="${command_name%!}"
      if [[ "$REMOTE_MODE" == client ]]; then
        (( worker )) && ui_append_message error "External workers are not exposed by the remote server." || \
          ui_append_message error "External consultations are not exposed by the remote server."
        return 0
      fi
      (( worker )) && ui_append_message error "/${provider}! requires a request" || \
        ui_append_message error "/${provider} requires a request"
      ;;
    /claude\ *|/codex\ *|/agy\ *|/opencode\ *|/claude!\ *|/codex!\ *|/agy!\ *|/opencode!\ *)
      command_name="${text%% *}"
      [[ "$command_name" == *! ]] && worker=1 || worker=0
      provider="${command_name#/}"; provider="${provider%!}"
      if [[ "$REMOTE_MODE" == client ]]; then
        (( worker )) && ui_append_message error "External workers are not exposed by the remote server." || \
          ui_append_message error "External consultations are not exposed by the remote server."
        return 0
      fi
      value="${text#${command_name} }"
      if [[ "$provider" == opencode && -z "$ZCODER_OPENCODE_MODEL" ]]; then
        ui_select_opencode_model || { ui_refresh_all; return 0; }
      fi
      if (( worker )); then
        delegate_run "$provider" "$value" execute || delegate_status=$?
        failure="${provider} worker failed"
      else
        delegate_run "$provider" "$value" || delegate_status=$?
        [[ "$provider" == opencode ]] && failure="OpenCode consultation failed" || failure="${provider} consultation failed"
      fi
      if (( delegate_status != 0 && delegate_status != 130 && ! DELEGATE_ERROR_REPORTED )); then
        ui_append_message error "${DELEGATE_ERROR:-$failure}"
      fi
      ;;
    /opencode)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "External consultations are not exposed by the remote server."
        return 0
      fi
      ui_select_opencode_model
      ;;
    /opencode-model)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "External consultations are not exposed by the remote server."
        return 0
      fi
      ui_select_opencode_model
      ;;
    /opencode-model\ *)
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message error "External consultations are not exposed by the remote server."
        return 0
      fi
      value="${text#/opencode-model }"; value="${value##[[:space:]]#}"
      if [[ "$value" == */* ]]; then
        ZCODER_OPENCODE_MODEL="$value"
        ui_append_message system "OpenCode model changed to $ZCODER_OPENCODE_MODEL"
      else
        ui_append_message error "OpenCode models use provider/model form"
      fi
      ;;
    /help|/\?)
      zcoder_delegate_availability_summary
      ui_show_help "$REPLY"
      ;;
    # EXIT cleanup owns the final save. Do not browse sessions (or contact the
    # remote server) and repaint an interface that is about to close.
    /quit|/exit|/q) RUNNING=0; return 0 ;;
    *) return 1 ;;
  esac
  (( $+functions[zcoder_refresh_sessions] )) && zcoder_refresh_sessions
  ui_refresh_all
}
