# Shared state and loading for the authenticated remote-agent transports.

typeset -g REMOTE_MODE="${REMOTE_MODE:-local}"
typeset -g REMOTE_SERVER_NAME="${REMOTE_SERVER_NAME:-}"
typeset -g REMOTE_SERVER_PORT="${REMOTE_SERVER_PORT:-7337}"
typeset -g REMOTE_ENDPOINT="${REMOTE_ENDPOINT:-}"
typeset -g REMOTE_TOKEN_FILE="${REMOTE_TOKEN_FILE:-}"
typeset -g REMOTE_TOKEN=""
typeset -g REMOTE_RUNTIME_DIR=""
typeset -g REMOTE_SESSION_ID=""
typeset -g REMOTE_TURN_ID=""
typeset -g REMOTE_LISTEN_FD=""
typeset -g REMOTE_CLIENT_EVENT_CURSOR="0"
typeset -g REMOTE_ERROR=""
typeset -gi REMOTE_REQUEST_CANCELLED=0
typeset -gi REMOTE_REQUEST_TIMEOUT="${ZCODER_REMOTE_REQUEST_TIMEOUT:-30}"
typeset -gi REMOTE_SESSION_SYNC_REQUIRED=0 REMOTE_LIST_CURRENT_EMPTY=0
typeset -g REMOTE_LIST_CURRENT_ID=''
typeset -g REMOTE_IDLE_PID='' REMOTE_IDLE_BASE='' REMOTE_IDLE_ENDPOINT=''
typeset -gF REMOTE_IDLE_DEADLINE=0.0
typeset -g REMOTE_MODEL_STATUS="unknown"
typeset -g REMOTE_MODEL_ERROR=""
typeset -g REMOTE_MODEL_REQUEST_KIND=''
typeset -gF REMOTE_MODEL_DEADLINE=0.0 REMOTE_SERVER_MODEL_CHECK_TIMEOUT=10.0
typeset -g REMOTE_GIT_STATUS='Git: unavailable'
typeset -gi REMOTE_GIT_SUPPORTED=0
typeset -g REMOTE_HARNESSES=""
typeset -gi REMOTE_SESSIONS_SUPPORTED=0
typeset -gi REMOTE_HARNESS_DISCOVERY_SUPPORTED=0
typeset -gi REMOTE_GOALS_SUPPORTED=0
typeset -gi REMOTE_SESSION_EMPTY=0
typeset -gi REMOTE_SERVER_WORKER=0
typeset -gi REMOTE_SERVER_TOOL_SEQUENCE=0
typeset -g REMOTE_SERVER_TOOL_CALL_ID=""
typeset -gi REMOTE_STRUCTURED_TOOL_EVENTS=0
typeset -gi REMOTE_MAX_REQUEST_BYTES="${ZCODER_REMOTE_MAX_REQUEST_BYTES:-1048576}"
typeset -gF REMOTE_SERVER_READ_TIMEOUT=10.0
typeset -gF REMOTE_SERVER_WRITE_TIMEOUT=10.0
typeset -gi REMOTE_SERVER_MAX_CONNECTIONS=16
# Only the listener mutates this pool. Writers inherit it solely to close
# unrelated sockets; application requests continue to run in the listener.
typeset -gA REMOTE_CONNECTION_PHASE=() REMOTE_CONNECTION_BUFFER=() REMOTE_CONNECTION_DEADLINE=()
typeset -gA REMOTE_CONNECTION_LENGTH=() REMOTE_CONNECTION_METHOD=() REMOTE_CONNECTION_TARGET=()
typeset -gA REMOTE_CONNECTION_AUTHORIZATION=() REMOTE_CONNECTION_WRITER=()
typeset -gi REMOTE_APPROVAL_TIMEOUT="${ZCODER_REMOTE_APPROVAL_TIMEOUT:-300}"
typeset -gF REMOTE_CLIENT_NEXT_MODEL_POLL=0.0
typeset -grF REMOTE_CLIENT_MODEL_POLL_INTERVAL=0.5

typeset -g REMOTE_REQUEST_METHOD=""
typeset -g REMOTE_REQUEST_TARGET=""
typeset -g REMOTE_REQUEST_BODY=""
typeset -g REMOTE_REQUEST_AUTHORIZATION=""
typeset -gi REMOTE_REQUEST_LENGTH=0

remote_load_token() {
  local path="$1" token=""
  local -A token_stat=()
  REMOTE_ERROR=""
  [[ -n "$path" ]] || { REMOTE_ERROR="--token-file is required for remote mode"; return 1; }
  path="${path:A}"
  [[ -f "$path" && -r "$path" ]] || { REMOTE_ERROR="token file is not readable: $path"; return 1; }
  # The token is a bearer credential. Refuse to launch unless the file is
  # private: owned by the invoking user and with no group or other permission
  # bits (0600, or stricter such as 0400).
  if ! zmodload -F zsh/stat b:zstat 2>/dev/null || ! zstat -H token_stat -- "$path" 2>/dev/null; then
    REMOTE_ERROR="could not inspect token file ownership and permissions: $path"
    return 1
  fi
  if [[ "${token_stat[uid]}" != "$EUID" ]]; then
    REMOTE_ERROR="token file must be owned by the current user: $path"
    return 1
  fi
  if (( token_stat[mode] & 8#077 )); then
    REMOTE_ERROR="token file is accessible to group or others; make it private with: chmod 600 $path"
    return 1
  fi
  token="${mapfile[$path]}"
  while [[ "$token" == *$'\n' || "$token" == *$'\r' ]]; do token="${token[1,-2]}"; done
  if (( ${#token} < 32 )) || [[ "$token" != [A-Za-z0-9._~-]## ]]; then
    REMOTE_ERROR="token must contain at least 32 URL-safe characters"
    return 1
  fi
  REMOTE_TOKEN_FILE="$path"
  REMOTE_TOKEN="$token"
}

# Keep the historical public module as the single loading boundary. The
# implementation files divide client, server-agent, and HTTP listener ownership.
source "${${(%):-%x}:A:h}/remote_client.zsh" || return $?
source "${${(%):-%x}:A:h}/remote_server_agent.zsh" || return $?
source "${${(%):-%x}:A:h}/remote_server.zsh" || return $?
