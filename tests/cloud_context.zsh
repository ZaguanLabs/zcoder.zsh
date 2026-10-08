# Reported training limits must never replace local runtime allocations.
cloud_context_tests() {
  emulate -L zsh
  setopt extendedglob
  local -i UI_ACTIVE=0 AGENT_CONTEXT_WINDOW=0 AGENT_CONTEXT_DISCOVERY_PENDING=0
  local -i AGENT_LAST_PROMPT_TOKENS=0 AGENT_LAST_PAYLOAD_BYTES=0 AGENT_COMPACTION_REARM_TOKENS=0
  local -i JSON_MODEL_CONTEXT=0 JSON_MODEL_IS_CLOUD=0 OLLAMA_RUNNING_CONTEXT=0 OLLAMA_MODEL_CONTEXT=0 OLLAMA_MODEL_IS_CLOUD=0
  local ZCODER_MODEL='mistral-large-4:cloud' OLLAMA_HOST=fixture:11434 ZCODER_CONTEXT_WINDOW=auto
  local AGENT_CONTEXT_MODEL='' AGENT_CONTEXT_HOST='' AGENT_CONTEXT_SETTING='' AGENT_CONTEXT_SOURCE=fallback
  local AGENT_CONTEXT_PID='' AGENT_CONTEXT_BASE='' AGENT_CONTEXT_REQUEST_MODEL='' AGENT_CONTEXT_REQUEST_HOST='' AGENT_CONTEXT_REQUEST_STAGE=''
  local -F AGENT_CONTEXT_DEADLINE=0.0
  local HTTP_BODY='' HTTP_ERROR='' REPLY='' response='' captured_payload='' captured_method='' captured_target='' captured_endpoint=''
  local -i calls=0 running_calls=0 mock_failure=0
  local saved_request="${functions[http_request]}" saved_running="${functions[ollama_get_running_context]}"
  local -A ZJSON_OBJECT=(sentinel value) ZJSON_OBJECT_TYPES=(sentinel string)
  local -a ZJSON_OBJECT_KEYS=(sentinel) ZJSON_OBJECT_DUPLICATE_KEYS=()
  local metadata='{"model_info":{"vision.context_length":1024,"mistral4.context_length":1048576,"general.architecture":"mistral4"},"capabilities":["tools","thinking"]}'
  json_parse_model_context "$metadata" "$ZCODER_MODEL"
  assert_success 'cloud context metadata parses architecture keys in any source order' $?
  assert_eq '1048576:1' "$JSON_MODEL_CONTEXT:$JSON_MODEL_IS_CLOUD" 'cloud accounting selects the text model limit rather than vision context'
  assert_eq value "${ZJSON_OBJECT[sentinel]}" 'metadata decoding preserves caller object scratch outputs'
  json_parse_model_context "$metadata" 'gpt-oss:120b-cloud'
  assert_eq 1 "$JSON_MODEL_IS_CLOUD" 'legacy cloud tag suffixes are recognized'
  json_parse_model_context '{"remote_model":"mistral-large-4","model_info":{"general.architecture":"mistral4","mistral4.context_length":1048576}}' alias
  assert_eq '1048576:1' "$JSON_MODEL_CONTEXT:$JSON_MODEL_IS_CLOUD" 'remote metadata identifies cloud aliases without a cloud tag'
  json_parse_model_context '{"remote_host":"https://ollama.com"}' alias
  assert_eq '0:1' "$JSON_MODEL_CONTEXT:$JSON_MODEL_IS_CLOUD" 'cloud aliases remain identifiable without context metadata'
  json_parse_model_context "$metadata" local-model
  assert_eq '1048576:0' "$JSON_MODEL_CONTEXT:$JSON_MODEL_IS_CLOUD" 'local model maxima are decoded without claiming a cloud allocation'
  for response in '{' "$metadata trailing" '{"model_info":{},}' '[]'; do
    json_parse_model_context "$response" "$ZCODER_MODEL"
    assert_failure 'malformed model metadata fails without publishing a partial context' $?
    assert_eq '0:0' "$JSON_MODEL_CONTEXT:$JSON_MODEL_IS_CLOUD" 'invalid metadata clears published context outputs'
  done
  for response in '"1048576"' '-1' '0' '1.5' '1e6' '9999999999999999999999'; do
    json_parse_model_context '{"model_info":{"general.architecture":"fixture","fixture.context_length":'"$response"'}}' "$ZCODER_MODEL"
    assert_success 'invalid context values do not prevent cloud identification' $?
    assert_eq '0:1' "$JSON_MODEL_CONTEXT:$JSON_MODEL_IS_CLOUD" 'unusable context values are excluded from arithmetic'
  done
  assert_eq 262144 "$ZCODER_CLOUD_CONTEXT_FALLBACK" 'unknown cloud windows default to 256K tokens'
  http_request() {
    (( calls++ ))
    captured_method="$1"; captured_target="$2"; captured_payload="$3"; captured_endpoint="$4"
    HTTP_BODY="$response"
    (( ! mock_failure ))
  }
  ollama_get_running_context() {
    (( running_calls++ ))
    [[ "$1" == loaded-local ]] || return 1
    OLLAMA_RUNNING_CONTEXT=32768
  }
  {
    response="$metadata"
    agent_context_configure
    assert_eq '1048576:cloud:0' "$AGENT_CONTEXT_WINDOW:$AGENT_CONTEXT_SOURCE:$AGENT_CONTEXT_DISCOVERY_PENDING" 'automatic cloud context adopts the per-model reported maximum'
    assert_eq 'POST:/api/show:fixture:11434' "$captured_method:$captured_target:$captured_endpoint" 'cloud discovery queries model metadata on the selected host'
    assert_eq '{"model":"mistral-large-4:cloud"}' "$captured_payload" 'metadata requests encode the exact selected tag'
    assert_eq 0 "$running_calls" 'cloud tags do not rely on the running-model list'
    agent_context_options_json
    assert_eq '' "$REPLY" 'a discovered cloud maximum does not impose a num_ctx override'
    agent_build_payload
    assert_not_contains "$REPLY" '"num_ctx"' 'cloud chat payload leaves provider context selection intact'
    agent_build_compaction_payload 1
    assert_not_contains "$REPLY" '"num_ctx"' 'cloud compaction payload leaves provider context selection intact'
    agent_compaction_limit
    assert_eq 891289 "$REPLY" 'cloud compaction uses the reported 1M window'
    agent_context_configure
    assert_eq 1 "$calls" 'successful discovery is cached for this model and host'
    OLLAMA_HOST=other-fixture:11434
    agent_context_configure
    assert_eq 2 "$calls" 'changing Ollama host invalidates discovery'
    ZCODER_CONTEXT_WINDOW=262144
    agent_context_configure
    agent_context_options_json
    assert_eq '"num_ctx":262144,' "$REPLY" 'explicit context overrides remain available for cloud models'
    assert_eq 2 "$calls" 'explicit sizing bypasses discovery'
    ZCODER_CONTEXT_WINDOW=auto; response='{}'
    agent_context_configure
    assert_eq '262144:cloud_fallback:1' "$AGENT_CONTEXT_WINDOW:$AGENT_CONTEXT_SOURCE:$AGENT_CONTEXT_DISCOVERY_PENDING" 'cloud metadata without a maximum retains the 256K fallback and retries'
    response="$metadata"
    agent_context_refresh_after_response
    assert_eq '1048576:cloud:0' "$AGENT_CONTEXT_WINDOW:$AGENT_CONTEXT_SOURCE:$AGENT_CONTEXT_DISCOVERY_PENDING" 'a later response refreshes a cloud fallback from metadata'
    ZCODER_MODEL='unavailable:cloud'; mock_failure=1
    agent_context_configure
    assert_eq '262144:cloud_fallback:1' "$AGENT_CONTEXT_WINDOW:$AGENT_CONTEXT_SOURCE:$AGENT_CONTEXT_DISCOVERY_PENDING" 'failed discovery retains the cloud fallback'
    assert_eq '' "$HTTP_ERROR" 'optional discovery does not leave a generation error'
    mock_failure=0; ZCODER_MODEL=unloaded-local; response="$metadata"
    agent_context_configure
    assert_eq '65536:fallback:1' "$AGENT_CONTEXT_WINDOW:$AGENT_CONTEXT_SOURCE:$AGENT_CONTEXT_DISCOVERY_PENDING" 'unloaded local models do not use their training maximum'
    ZCODER_MODEL=loaded-local
    agent_context_configure
    assert_eq '32768:allocation:0' "$AGENT_CONTEXT_WINDOW:$AGENT_CONTEXT_SOURCE:$AGENT_CONTEXT_DISCOVERY_PENDING" 'loaded local models retain their actual allocation'
    agent_context_options_json
    assert_eq '"num_ctx":32768,' "$REPLY" 'local allocation remains present in automatic options'
    ZCODER_MODEL=alias
    response='{"remote_model":"mistral-large-4","model_info":{"general.architecture":"mistral4","mistral4.context_length":1048576}}'
    agent_context_configure
    assert_eq '1048576:cloud:0' "$AGENT_CONTEXT_WINDOW:$AGENT_CONTEXT_SOURCE:$AGENT_CONTEXT_DISCOVERY_PENDING" 'automatic sizing discovers cloud aliases after checking residency'
    agent_context_options_json
    assert_eq '' "$REPLY" 'cloud aliases also leave num_ctx to Ollama'
  } always {
    functions[http_request]="$saved_request"
    functions[ollama_get_running_context]="$saved_running"
  }
}
cloud_context_tests
unfunction cloud_context_tests

# Headless preparation must accept cloud metadata without local residency.
cloud_remote_context_tests() {
  emulate -L zsh
  setopt extendedglob
  local ZCODER_MODEL=fixture:cloud OLLAMA_HOST=fixture:11434 ZCODER_CONTEXT_WINDOW=auto
  local AGENT_CONTEXT_MODEL='' AGENT_CONTEXT_HOST='' AGENT_CONTEXT_SETTING='' AGENT_CONTEXT_SOURCE=fallback
  local -i AGENT_CONTEXT_WINDOW=65536 AGENT_CONTEXT_DISCOVERY_PENDING=1
  local REMOTE_MODEL_STATUS=unknown REMOTE_MODEL_ERROR='' REMOTE_MODEL_REQUEST_KIND=''
  local -F REMOTE_MODEL_DEADLINE=0.0
  local REMOTE_LISTEN_FD=51 HTTP_BODY='' HTTP_ERROR='' REPLY=''
  local -A REMOTE_CONNECTION_PHASE=()
  local -i cloud_warmups=0
  local cloud_request='' cloud_detached='' cloud_response='{"model_info":{"general.architecture":"fixture","fixture.context_length":1048576}}'
  local -A saved_functions=()
  local fn=''
  for fn in http_async_start http_async_ready http_async_collect _remote_server_model_start_warmup; do
    saved_functions[$fn]="${functions[$fn]}"
  done
  http_async_start() { cloud_request="$1:$2:$3:$4"; cloud_detached="$5:$6"; return 0; }
  http_async_ready() { return 0; }
  http_async_collect() { HTTP_BODY="$cloud_response"; return 0; }
  _remote_server_model_start_warmup() { (( cloud_warmups++ )); return 0; }
  {
    _remote_server_model_start_check check 52
    assert_success 'headless cloud preparation starts metadata discovery' $?
    assert_eq 'POST:/api/show:{"model":"fixture:cloud"}:fixture:11434' "$cloud_request" 'headless cloud preparation queries metadata instead of residency'
    assert_eq '51:52' "$cloud_detached" 'headless metadata worker detaches listener and client sockets'
    _remote_server_model_poll
    assert_success 'headless cloud models become ready without appearing in ps' $?
    assert_eq 'ready:1048576:cloud:0' "$REMOTE_MODEL_STATUS:$AGENT_CONTEXT_WINDOW:$AGENT_CONTEXT_SOURCE:$AGENT_CONTEXT_DISCOVERY_PENDING" 'headless readiness applies the reported cloud context'
    assert_eq 0 "$cloud_warmups" 'cloud metadata discovery does not generate a warm-up response'
    ZCODER_CONTEXT_WINDOW=262144
    _remote_server_model_start_check
    _remote_server_model_poll
    assert_eq '262144:configured:0' "$AGENT_CONTEXT_WINDOW:$AGENT_CONTEXT_SOURCE:$AGENT_CONTEXT_DISCOVERY_PENDING" 'headless readiness preserves explicit cloud overrides'
    ZCODER_CONTEXT_WINDOW=auto; ZCODER_MODEL=alias; AGENT_CONTEXT_SOURCE=fallback
    _remote_server_model_start_check
    cloud_response='{"models":[]}'
    _remote_server_model_poll
    assert_eq 1 "$?" 'headless preparation asynchronously inspects absent model metadata'
    assert_eq show_check "$REMOTE_MODEL_REQUEST_KIND" 'headless aliases advance from residency to metadata discovery'
    cloud_response='{"remote_model":"fixture","model_info":{"general.architecture":"fixture","fixture.context_length":524288}}'
    _remote_server_model_poll
    assert_eq 'ready:524288:cloud' "$REMOTE_MODEL_STATUS:$AGENT_CONTEXT_WINDOW:$AGENT_CONTEXT_SOURCE" 'headless cloud aliases adopt their own reported maximum'
    cloud_response='{"remote_model":"fixture"}'
    _remote_server_model_start_check
    _remote_server_model_poll
    assert_eq 'ready:262144:cloud_fallback:1' "$REMOTE_MODEL_STATUS:$AGENT_CONTEXT_WINDOW:$AGENT_CONTEXT_SOURCE:$AGENT_CONTEXT_DISCOVERY_PENDING" 'headless cloud metadata without a limit uses the 256K fallback'
    cloud_response='{'
    _remote_server_model_start_check
    _remote_server_model_poll
    assert_eq '2:error' "$?:$REMOTE_MODEL_STATUS" 'malformed headless cloud metadata reports preparation failure'
  } always {
    for fn in "${(@k)saved_functions}"; do functions[$fn]="${saved_functions[$fn]}"; done
  }
}
cloud_remote_context_tests
unfunction cloud_remote_context_tests
