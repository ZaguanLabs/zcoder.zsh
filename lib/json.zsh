# Application codecs and scalar tool arguments; generic JSON lives in zjson.
() {
  local entry="${${(%):-%x}:A:h:h}/vendor/zjson/zjson.zsh"
  [[ -r "$entry" ]] || {
    print -ru2 -- 'Missing zjson dependency. Run make json or git submodule update --init --recursive.'
    return 1
  }
  source "$entry"
} || return 1

typeset -g JSON_RESPONSE_CONTENT=""
typeset -g JSON_RESPONSE_THINKING=""
typeset -g JSON_RESPONSE_ERROR=""
typeset -g JSON_RESPONSE_TOOL_CALLS="[]"
typeset -gi JSON_RESPONSE_PROMPT_TOKENS=0
typeset -gi JSON_RESPONSE_OUTPUT_TOKENS=0
typeset -gi JSON_RESPONSE_DONE=-1
typeset -ga JSON_TOOL_NAMES=()
typeset -ga JSON_TOOL_ARGS=()
typeset -ga JSON_MODEL_NAMES=()
typeset -gi JSON_RUNNING_MODEL_CONTEXT=0
typeset -gA JSON_OBJECT=()

_json_parse_tool_function() {
  local key="" name="" args="{}"
  local -i has_args=0
  [[ "$ZJSON_TOKEN_TYPE" == '{' ]] || return 1
  zjson_next || return 1
  while [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$ZJSON_TOKEN_TYPE" == string ]] || return 1
    key="$ZJSON_TOKEN_VALUE"
    zjson_next || return 1
    [[ "$ZJSON_TOKEN_TYPE" == ':' ]] || return 1
    zjson_next || return 1
    case "$key:$ZJSON_TOKEN_TYPE" in
      name:string) name="$ZJSON_TOKEN_VALUE"; zjson_next || return 1 ;;
      arguments:'{') zjson_capture_value || return 1; args="$REPLY"; has_args=1 ;;
      *) zjson_skip_value || return 1 ;;
    esac
    if [[ "$ZJSON_TOKEN_TYPE" == ',' ]]; then
      zjson_next || return 1
    elif [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  zjson_next || return 1
  if (( ${JSON_REQUIRE_COMPLETE_TOOLS:-0} && ! has_args )); then
    ZJSON_ERROR="streamed tool arguments must be a complete object"
    return 1
  fi
  JSON_TOOL_NAMES+=("$name")
  JSON_TOOL_ARGS+=("$args")
}

_json_parse_tool_call() {
  local key="" before=${#JSON_TOOL_NAMES}
  [[ "$ZJSON_TOKEN_TYPE" == '{' ]] || return 1
  zjson_next || return 1
  while [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$ZJSON_TOKEN_TYPE" == string ]] || return 1
    key="$ZJSON_TOKEN_VALUE"
    zjson_next || return 1
    [[ "$ZJSON_TOKEN_TYPE" == ':' ]] || return 1
    zjson_next || return 1
    if [[ "$key" == function && "$ZJSON_TOKEN_TYPE" == '{' ]]; then
      _json_parse_tool_function || return 1
    else
      zjson_skip_value || return 1
    fi
    if [[ "$ZJSON_TOKEN_TYPE" == ',' ]]; then
      zjson_next || return 1
    elif [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  zjson_next || return 1
  if (( ${#JSON_TOOL_NAMES} == before )); then
    ZJSON_ERROR="tool call did not contain a function"
    return 1
  fi
}

_json_parse_tool_calls() {
  local calls="[" comma="" name_json="" i
  [[ "$ZJSON_TOKEN_TYPE" == '[' ]] || return 1
  zjson_next || return 1
  while [[ "$ZJSON_TOKEN_TYPE" != ']' ]]; do
    _json_parse_tool_call || return 1
    if [[ "$ZJSON_TOKEN_TYPE" == ',' ]]; then
      zjson_next || return 1
    elif [[ "$ZJSON_TOKEN_TYPE" != ']' ]]; then
      return 1
    fi
  done
  zjson_next || return 1

  for (( i=1; i<=${#JSON_TOOL_NAMES}; i++ )); do
    zjson_quote "${JSON_TOOL_NAMES[i]}"; name_json="$REPLY"
    calls+="${comma}{\"type\":\"function\",\"function\":{\"name\":${name_json},\"arguments\":${JSON_TOOL_ARGS[i]}}}"
    comma=","
  done
  JSON_RESPONSE_TOOL_CALLS="${calls}]"
}

_json_parse_response_message() {
  local key=""
  [[ "$ZJSON_TOKEN_TYPE" == '{' ]] || return 1
  zjson_next || return 1
  while [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$ZJSON_TOKEN_TYPE" == string ]] || return 1
    key="$ZJSON_TOKEN_VALUE"
    zjson_next || return 1
    [[ "$ZJSON_TOKEN_TYPE" == ':' ]] || return 1
    zjson_next || return 1
    case "$key:$ZJSON_TOKEN_TYPE" in
      content:string) JSON_RESPONSE_CONTENT="$ZJSON_TOKEN_VALUE"; zjson_next || return 1 ;;
      thinking:string) JSON_RESPONSE_THINKING="$ZJSON_TOKEN_VALUE"; zjson_next || return 1 ;;
      tool_calls:'[') _json_parse_tool_calls || return 1 ;;
      *) zjson_skip_value || return 1 ;;
    esac
    if [[ "$ZJSON_TOKEN_TYPE" == ',' ]]; then
      zjson_next || return 1
    elif [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  zjson_next
}

json_parse_ollama_response() {
  _json_parse_ollama_response "$@" && return 0
  # A rejected document cannot leave executable partial tool arguments behind.
  JSON_TOOL_NAMES=(); JSON_TOOL_ARGS=(); JSON_RESPONSE_TOOL_CALLS='[]'
  return 1
}

_json_parse_ollama_response() {
  local key=""
  JSON_RESPONSE_CONTENT=""
  JSON_RESPONSE_THINKING=""
  JSON_RESPONSE_ERROR=""
  JSON_RESPONSE_TOOL_CALLS="[]"
  JSON_RESPONSE_PROMPT_TOKENS=0
  JSON_RESPONSE_OUTPUT_TOKENS=0
  JSON_RESPONSE_DONE=-1
  JSON_TOOL_NAMES=()
  JSON_TOOL_ARGS=()

  zjson_begin "$1" || return 1
  [[ "$ZJSON_TOKEN_TYPE" == '{' ]] || { ZJSON_ERROR="response is not an object"; return 1; }
  zjson_next || return 1
  while [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$ZJSON_TOKEN_TYPE" == string ]] || return 1
    key="$ZJSON_TOKEN_VALUE"
    zjson_next || return 1
    [[ "$ZJSON_TOKEN_TYPE" == ':' ]] || return 1
    zjson_next || return 1
    case "$key:$ZJSON_TOKEN_TYPE" in
      message:'{') _json_parse_response_message || return 1 ;;
      error:string) JSON_RESPONSE_ERROR="$ZJSON_TOKEN_VALUE"; zjson_next || return 1 ;;
      done:true) JSON_RESPONSE_DONE=1; zjson_next || return 1 ;;
      done:false) JSON_RESPONSE_DONE=0; zjson_next || return 1 ;;
      prompt_eval_count:number)
        [[ "$ZJSON_TOKEN_VALUE" == <0-> ]] && JSON_RESPONSE_PROMPT_TOKENS="$ZJSON_TOKEN_VALUE"
        zjson_next || return 1
        ;;
      eval_count:number)
        [[ "$ZJSON_TOKEN_VALUE" == <0-> ]] && JSON_RESPONSE_OUTPUT_TOKENS="$ZJSON_TOKEN_VALUE"
        zjson_next || return 1
        ;;
      *) zjson_skip_value || return 1 ;;
    esac
    if [[ "$ZJSON_TOKEN_TYPE" == ',' ]]; then
      zjson_next || return 1
    elif [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  zjson_next || return 1
  [[ "$ZJSON_TOKEN_TYPE" == eof ]]
}

_json_parse_model_object() {
  local key="" model_name=""
  [[ "$ZJSON_TOKEN_TYPE" == '{' ]] || { ZJSON_ERROR="expected model object"; return 1; }
  zjson_next || return 1
  while [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$ZJSON_TOKEN_TYPE" == string ]] || { ZJSON_ERROR="expected model field"; return 1; }
    key="$ZJSON_TOKEN_VALUE"
    zjson_next || return 1
    [[ "$ZJSON_TOKEN_TYPE" == ':' ]] || { ZJSON_ERROR="expected colon after model field"; return 1; }
    zjson_next || return 1
    if [[ "$key" == name && "$ZJSON_TOKEN_TYPE" == string ]]; then
      model_name="$ZJSON_TOKEN_VALUE"
      zjson_next || return 1
    else
      zjson_skip_value || return 1
    fi
    if [[ "$ZJSON_TOKEN_TYPE" == ',' ]]; then
      zjson_next || return 1
    elif [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; then
      ZJSON_ERROR="expected comma or closing model brace"
      return 1
    fi
  done
  zjson_next || return 1
  [[ -n "$model_name" ]] && JSON_MODEL_NAMES+=("$model_name")
}

# Decode model names from Ollama's GET /api/tags response.
json_parse_models() {
  local key=""
  JSON_MODEL_NAMES=()
  zjson_begin "$1" || return 1
  [[ "$ZJSON_TOKEN_TYPE" == '{' ]] || { ZJSON_ERROR="model response is not an object"; return 1; }
  zjson_next || return 1
  while [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$ZJSON_TOKEN_TYPE" == string ]] || return 1
    key="$ZJSON_TOKEN_VALUE"
    zjson_next || return 1
    [[ "$ZJSON_TOKEN_TYPE" == ':' ]] || return 1
    zjson_next || return 1
    if [[ "$key" == models && "$ZJSON_TOKEN_TYPE" == '[' ]]; then
      zjson_next || return 1
      while [[ "$ZJSON_TOKEN_TYPE" != ']' ]]; do
        _json_parse_model_object || return 1
        if [[ "$ZJSON_TOKEN_TYPE" == ',' ]]; then
          zjson_next || return 1
        elif [[ "$ZJSON_TOKEN_TYPE" != ']' ]]; then
          ZJSON_ERROR="expected comma or closing models bracket"
          return 1
        fi
      done
      zjson_next || return 1
    else
      zjson_skip_value || return 1
    fi
    if [[ "$ZJSON_TOKEN_TYPE" == ',' ]]; then
      zjson_next || return 1
    elif [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  zjson_next || return 1
  [[ "$ZJSON_TOKEN_TYPE" == eof ]] || { ZJSON_ERROR="trailing content after JSON object"; return 1; }
}

_json_model_names_match() {
  local left="$1" right="$2"
  [[ "$left" == *:* ]] || left+=":latest"
  [[ "$right" == *:* ]] || right+=":latest"
  [[ "$left" == "$right" ]]
}

_json_parse_running_model() {
  local target="$1" key="" name="" model=""
  local -i context_length=0
  [[ "$ZJSON_TOKEN_TYPE" == '{' ]] || return 1
  zjson_next || return 1
  while [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$ZJSON_TOKEN_TYPE" == string ]] || return 1
    key="$ZJSON_TOKEN_VALUE"
    zjson_next || return 1
    [[ "$ZJSON_TOKEN_TYPE" == ':' ]] || return 1
    zjson_next || return 1
    case "$key:$ZJSON_TOKEN_TYPE" in
      name:string) name="$ZJSON_TOKEN_VALUE"; zjson_next || return 1 ;;
      model:string) model="$ZJSON_TOKEN_VALUE"; zjson_next || return 1 ;;
      context_length:number)
        [[ "$ZJSON_TOKEN_VALUE" == <1-> ]] && context_length="$ZJSON_TOKEN_VALUE"
        zjson_next || return 1
        ;;
      *) zjson_skip_value || return 1 ;;
    esac
    if [[ "$ZJSON_TOKEN_TYPE" == ',' ]]; then
      zjson_next || return 1
    elif [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  zjson_next || return 1
  if _json_model_names_match "$name" "$target" || _json_model_names_match "$model" "$target"; then
    JSON_RUNNING_MODEL_CONTEXT="$context_length"
  fi
}

# Read the context actually allocated to a loaded model from GET /api/ps.
json_parse_running_model_context() {
  local source="$1" target="$2" key=""
  JSON_RUNNING_MODEL_CONTEXT=0
  zjson_begin "$source" || return 1
  [[ "$ZJSON_TOKEN_TYPE" == '{' ]] || { ZJSON_ERROR="running-model response is not an object"; return 1; }
  zjson_next || return 1
  while [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$ZJSON_TOKEN_TYPE" == string ]] || return 1
    key="$ZJSON_TOKEN_VALUE"
    zjson_next || return 1
    [[ "$ZJSON_TOKEN_TYPE" == ':' ]] || return 1
    zjson_next || return 1
    if [[ "$key" == models && "$ZJSON_TOKEN_TYPE" == '[' ]]; then
      zjson_next || return 1
      while [[ "$ZJSON_TOKEN_TYPE" != ']' ]]; do
        _json_parse_running_model "$target" || return 1
        if [[ "$ZJSON_TOKEN_TYPE" == ',' ]]; then
          zjson_next || return 1
        elif [[ "$ZJSON_TOKEN_TYPE" != ']' ]]; then
          return 1
        fi
      done
      zjson_next || return 1
    else
      zjson_skip_value || return 1
    fi
    if [[ "$ZJSON_TOKEN_TYPE" == ',' ]]; then
      zjson_next || return 1
    elif [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  zjson_next || return 1
  [[ "$ZJSON_TOKEN_TYPE" == eof ]] || { ZJSON_ERROR="trailing content after JSON object"; return 1; }
}

# Tool schemas in this project use flat argument objects. Values are decoded to
# strings; JSON_OBJECT_TYPES lets dispatchers distinguish strings and scalars.
typeset -gA JSON_OBJECT_TYPES=()
json_parse_flat_object() {
  local key="" value="" value_type=""
  JSON_OBJECT=()
  JSON_OBJECT_TYPES=()
  zjson_begin "$1" || return 1
  [[ "$ZJSON_TOKEN_TYPE" == '{' ]] || { ZJSON_ERROR="arguments must be an object"; return 1; }
  zjson_next || return 1
  while [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$ZJSON_TOKEN_TYPE" == string ]] || return 1
    key="$ZJSON_TOKEN_VALUE"
    zjson_next || return 1
    [[ "$ZJSON_TOKEN_TYPE" == ':' ]] || return 1
    zjson_next || return 1
    value_type="$ZJSON_TOKEN_TYPE"
    case "$value_type" in
      string|number|true|false|null)
        value="$ZJSON_TOKEN_VALUE"
        JSON_OBJECT[$key]="$value"
        JSON_OBJECT_TYPES[$key]="$value_type"
        zjson_next || return 1
        ;;
      *) ZJSON_ERROR="argument '$key' must be a scalar"; return 1 ;;
    esac
    if [[ "$ZJSON_TOKEN_TYPE" == ',' ]]; then
      zjson_next || return 1
    elif [[ "$ZJSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  zjson_next || return 1
  [[ "$ZJSON_TOKEN_TYPE" == eof ]] || { ZJSON_ERROR="trailing content after JSON object"; return 1; }
}
