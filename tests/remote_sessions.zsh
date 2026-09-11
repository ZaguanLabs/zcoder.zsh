#!/usr/bin/env zsh
# Real server startup and authenticated HTTP, with no Ollama dependency.
emulate -R zsh
setopt extendedglob
zmodload zsh/files zsh/mapfile zsh/datetime zsh/system zsh/net/tcp zsh/zselect
typeset root=${0:A:h:h} scratch=${TMPDIR:-/tmp}/zcoder-shared-sessions-$$ server_pid=''
umask 077
zf_mkdir -p "$scratch"
cleanup() {
  if [[ -n $server_pid ]]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    # Wake native accept so Zsh can dispatch the pending termination trap.
    if ztcp 127.0.0.1 "$port" 2>/dev/null; then ztcp -c "$REPLY"; fi
    wait "$server_pid" 2>/dev/null || true
  fi
  zf_rm -rf -- "$scratch"
}
trap cleanup EXIT
fail() { print -ru2 -- "FAIL: $*"; exit 1; }
for library in util json transcript state http remote; do source "$root/lib/$library.zsh"; done
typeset token=fixture_shared_sessions_token_0123456789 endpoint='' store='' server_home='' mode=''
typeset ZCODER_WORKSPACE="$scratch/project" ZCODER_PROFILE=coding HTTP_READ_TIMEOUT=2
typeset -i STATE_ENABLED=1 port=0 attempt=0
zf_mkdir -p "$ZCODER_WORKSPACE" "$scratch/other"
zf_ln -s "$ZCODER_WORKSPACE" "$scratch/workspace-alias"
print -r -- "$token" > "$scratch/token"
seed_session() {
  local directory=$1 id=$2 workspace=$3 profile=$4
  directory+="/$id.session"
  zf_mkdir -p "$directory/ui_events"
  mapfile[$directory/workspace]=$workspace
  mapfile[$directory/profile]=$profile
  mapfile[$directory/model]=fixture
  mapfile[$directory/title]="Session $id"
  mapfile[$directory/updated_at]=${id%%_*}
  mapfile[$directory/agent_message_count]=0
  mapfile[$directory/ui_event_count]=1
  mapfile[$directory/ui_events/000001.role]=assistant
  mapfile[$directory/ui_events/000001.content]="History $id"
  mapfile[$directory/ui_events/000001.thinking]='saved reasoning'
}
request() {
  http_request "$1" "$2" "${3:-}" "$endpoint" "Authorization: Bearer $token"
}
start_server() {
  for attempt in {1..20}; do
    port=$(( 20000 + RANDOM ))
    if ztcp -l "$port" 2>/dev/null; then ztcp -c "$REPLY"; break; fi
  done
  endpoint="127.0.0.1:$port"
  (
    trap - EXIT
    export ZCODER_HOME=$server_home ZCODER_RELAY=off
    if [[ $mode == custom ]]; then export ZCODER_SESSIONS_DIR=$store
    else unset ZCODER_SESSIONS_DIR
    fi
    exec zsh -df "$root/zcoder.zsh" --server shared-fixture --port "$port" \
      --token-file "$scratch/token" --workspace "$scratch/workspace-alias" \
      --profile coding --model fixture --context-window 32768 --no-warmup --deny-commands
  ) > "$scratch/server.log" 2>&1 &
  server_pid=$!
  for attempt in {1..100}; do
    request GET '/v1/sessions?after=0' && return 0
    kill -0 "$server_pid" 2>/dev/null || break
    zselect -t 5
  done
  fail "server startup: ${mapfile[$scratch/server.log]:-}"
}
stop_server() {
  kill -TERM "$server_pid" 2>/dev/null || true
  if ztcp 127.0.0.1 "$port" 2>/dev/null; then ztcp -c "$REPLY"; fi
  wait "$server_pid" 2>/dev/null || true
  server_pid=''
}
typeset id='' cursor='' new_id='' original_selection='' legacy_root='' legacy_dir='' generation=''
typeset -a api_ids=()
for mode in default custom; do
  server_home="$scratch/$mode-home"
  store="$server_home/sessions"
  [[ $mode == custom ]] && store="$scratch/custom-store"
  ZCODER_SESSIONS_DIR=$store
  REMOTE_RUNTIME_DIR="$server_home/remote/shared-fixture"
  legacy_root="$REMOTE_RUNTIME_DIR/sessions"
  for attempt in {1..7}; do seed_session "$store" "100000000${attempt}_1" "$ZCODER_WORKSPACE" coding; done
  seed_session "$store" 1000000010_1 "$scratch/other" coding
  seed_session "$store" 1000000011_1 "$ZCODER_WORKSPACE" sysadmin
  seed_session "$legacy_root" 1000000008_1 "$ZCODER_WORKSPACE" coding
  # Existing remote history uses committed generations, unlike the local
  # legacy-format fixtures. Sharing must preserve both storage formats.
  legacy_dir="$legacy_root/1000000008_1.session"
  generation=1000000008_1_0
  zf_mkdir -p "$legacy_dir/generations/$generation"
  zf_mv "$legacy_dir"/{workspace,profile,model,title,updated_at,agent_message_count,ui_event_count,ui_events} \
    "$legacy_dir/generations/$generation" || fail 'could not create generation fixture'
  for id in agent_messages context_users active_skills; do
    mapfile[$legacy_dir/generations/$generation/$id.refs]=''
  done
  mapfile[$legacy_dir/generations/$generation/context_user_count]=0
  mapfile[$legacy_dir/generations/$generation/active_skill_count]=0
  mapfile[$legacy_dir/generations/$generation/ui_events.refs]="$generation/ui_events/000001"
  for id in time reasoning_open meta; do
    mapfile[$legacy_dir/generations/$generation/ui_events/000001.$id]=''
  done
  mapfile[$legacy_dir/current]=$generation
  mapfile[$REMOTE_RUNTIME_DIR/selected_session]=1000000008_1
  state_refresh_sessions_list
  (( ${#SESSION_IDS} == 7 )) || fail 'local fixture must start with seven sessions'
  start_server
  api_ids=(); cursor=0; original_selection=''
  for attempt in {1..20}; do
    request GET "/v1/sessions?after=$cursor" || fail 'session listing failed'
    json_parse_flat_object "$HTTP_BODY" || fail 'invalid session JSON'
    [[ ${JSON_OBJECT[event]} == none ]] && break
    [[ ${JSON_OBJECT[event]} == session ]] || fail 'unexpected session response'
    api_ids+=("${JSON_OBJECT[id]}"); cursor=${JSON_OBJECT[seq]}
    [[ ${JSON_OBJECT[current]} == 1 ]] && original_selection=${JSON_OBJECT[id]}
  done
  (( ${#api_ids} == 8 )) || fail "$mode: expected eight shared sessions, got ${(j:,:)api_ids}; $HTTP_BODY"
  [[ $original_selection == 1000000008_1 ]] || fail 'legacy selected session changed'
  state_refresh_sessions_list
  [[ ${(j:,:)api_ids} == ${(j:,:)SESSION_IDS} ]] || fail 'API and local session lists differ'
  for id in 1000000001_1 1000000008_1; do
    request POST /v1/session/select "{\"id\":\"$id\"}" || fail 'could not select saved history'
    request GET "/v1/session?id=$id&after=0" || fail 'could not read saved history'
    json_parse_flat_object "$HTTP_BODY"
    [[ ${JSON_OBJECT[content]} == "History $id" && ${JSON_OBJECT[thinking]} == 'saved reasoning' ]] || fail 'history changed'
  done
  for id in 1000000010_1 1000000011_1; do
    request POST /v1/session/select "{\"id\":\"$id\"}" && fail 'selected a session outside server scope'
    [[ $HTTP_ERROR == *' 404 '* ]] || fail 'wrong scope selection status'
    request GET "/v1/session?id=$id&after=0" && fail 'read a transcript outside server scope'
    [[ $HTTP_ERROR == *' 404 '* ]] || fail 'wrong scope transcript status'
  done
  request POST /v1/session/new '{}' || fail 'new remote session failed'
  json_parse_flat_object "$HTTP_BODY"; new_id=${JSON_OBJECT[id]}
  state_refresh_sessions_list
  (( ${SESSION_IDS[(Ie)$new_id]} && ${#SESSION_IDS} == 9 )) || fail 'API-created session missing from local list'
  [[ -d $store/$new_id.session && ! -h $store/$new_id.session ]] || fail 'new session is not stored directly in shared directory'
  stop_server
  start_server
  request GET '/v1/sessions?after=0' || fail 'restart lost shared sessions'
  [[ ${mapfile[$REMOTE_RUNTIME_DIR/selected_session]} == "$new_id" ]] || fail 'restart lost selected session'
  state_refresh_sessions_list
  (( ${#SESSION_IDS} == 9 )) || fail 'restart duplicated a legacy session'
  stop_server
  # Existing legacy writers and the shared name use the same files and lock.
  mapfile[$legacy_dir/generations/$generation/title]='Updated legacy title'
  state_refresh_sessions_list
  [[ ${SESSION_TITLES[${SESSION_IDS[(Ie)1000000008_1]}]} == 'Updated legacy title' ]] || fail 'legacy history was copied instead of shared'
  seed_session "$legacy_root" 1000000001_1 "$ZCODER_WORKSPACE" coding
  _remote_server_share_legacy_sessions 2>/dev/null && fail 'legacy collision was silently accepted'
  [[ $REMOTE_ERROR == *'ID conflict'* && ! -h $store/1000000001_1.session ]] || fail 'collision replaced a local session'
  [[ ! -e $store/1000000001_1.session/1000000001_1.session ]] || fail 'collision nested a legacy link inside a local session'
  print -r -- "PASS: $mode store shares local/API histories, preserves legacy sessions, restarts and scope filters"
done
