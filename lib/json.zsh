# Native JSON tokenizer and the small codecs zcoder needs for Ollama.

typeset -g JSON_SOURCE=""
typeset -gi JSON_POS=1
typeset -gi JSON_LEN=0
typeset -gi JSON_TOKEN_START=1
typeset -g JSON_TOKEN_TYPE=""
typeset -g JSON_TOKEN_VALUE=""
typeset -g JSON_ERROR=""

typeset -g JSON_RESPONSE_CONTENT=""
typeset -g JSON_RESPONSE_THINKING=""
typeset -g JSON_RESPONSE_ERROR=""
typeset -g JSON_RESPONSE_TOOL_CALLS="[]"
typeset -gi JSON_RESPONSE_PROMPT_TOKENS=0
typeset -gi JSON_RESPONSE_OUTPUT_TOKENS=0
typeset -ga JSON_TOOL_NAMES=()
typeset -ga JSON_TOOL_ARGS=()
typeset -ga JSON_MODEL_NAMES=()
typeset -gi JSON_RUNNING_MODEL_CONTEXT=0
typeset -gA JSON_OBJECT=()

json_quote() {
  local input="$1" output='"' ch="" escaped=""
  local -i i code

  for (( i=1; i<=${#input}; i++ )); do
    ch="${input[i]}"
    case "$ch" in
      '"') output+='\"' ;;
      $'\\') output+='\\\\' ;;
      $'\b') output+='\b' ;;
      $'\f') output+='\f' ;;
      $'\n') output+='\n' ;;
      $'\r') output+='\r' ;;
      $'\t') output+='\t' ;;
      *)
        printf -v code '%d' "'$ch"
        if (( code < 32 )); then
          printf -v escaped '\\u%04x' "$code"
          output+="$escaped"
        else
          output+="$ch"
        fi
        ;;
    esac
  done
  REPLY="${output}\""
}

json_begin() {
  JSON_SOURCE="$1"
  JSON_POS=1
  JSON_LEN=${#JSON_SOURCE}
  JSON_TOKEN_TYPE=""
  JSON_TOKEN_VALUE=""
  JSON_ERROR=""
  json_next
}

json_next() {
  local ch="" esc="" hex="" low_hex="" encoded="" decoded="" value=""
  local -i cp low_cp

  while (( JSON_POS <= JSON_LEN )); do
    ch="${JSON_SOURCE[JSON_POS]}"
    [[ "$ch" == [[:space:]] ]] || break
    (( JSON_POS++ ))
  done
  JSON_TOKEN_START=$JSON_POS
  if (( JSON_POS > JSON_LEN )); then
    JSON_TOKEN_TYPE="eof"
    JSON_TOKEN_VALUE=""
    return 0
  fi

  ch="${JSON_SOURCE[JSON_POS]}"
  case "$ch" in
    '{'|'}'|'['|']'|':'|',')
      JSON_TOKEN_TYPE="$ch"
      JSON_TOKEN_VALUE="$ch"
      (( JSON_POS++ ))
      ;;
    '"')
      (( JSON_POS++ ))
      value=""
      while (( JSON_POS <= JSON_LEN )); do
        ch="${JSON_SOURCE[JSON_POS]}"
        (( JSON_POS++ ))
        if [[ "$ch" == '"' ]]; then
          JSON_TOKEN_TYPE="string"
          JSON_TOKEN_VALUE="$value"
          return 0
        fi
        if [[ "$ch" != $'\\' ]]; then
          value+="$ch"
          continue
        fi
        (( JSON_POS <= JSON_LEN )) || { JSON_ERROR="unterminated JSON escape"; return 1; }
        esc="${JSON_SOURCE[JSON_POS]}"
        (( JSON_POS++ ))
        case "$esc" in
          '"'|$'\\'|'/') value+="$esc" ;;
          b) value+=$'\b' ;;
          f) value+=$'\f' ;;
          n) value+=$'\n' ;;
          r) value+=$'\r' ;;
          t) value+=$'\t' ;;
          u)
            hex="${JSON_SOURCE[JSON_POS,$(( JSON_POS + 3 ))]}"
            [[ "$hex" == [[:xdigit:]]## ]] || { JSON_ERROR="invalid JSON unicode escape"; return 1; }
            (( JSON_POS += 4 ))
            cp=$(( 16#$hex ))
            if (( cp >= 0xD800 && cp <= 0xDBFF )) && \
               [[ "${JSON_SOURCE[JSON_POS,$(( JSON_POS + 1 ))]}" == $'\\u' ]]; then
              low_hex="${JSON_SOURCE[$(( JSON_POS + 2 )),$(( JSON_POS + 5 ))]}"
              if [[ "$low_hex" == [[:xdigit:]]## ]]; then
                low_cp=$(( 16#$low_hex ))
                if (( low_cp >= 0xDC00 && low_cp <= 0xDFFF )); then
                  cp=$(( 0x10000 + ((cp - 0xD800) << 10) + low_cp - 0xDC00 ))
                  (( JSON_POS += 6 ))
                fi
              fi
            fi
            if (( cp <= 0xFFFF )); then
              printf -v encoded '\\u%04x' "$cp"
            else
              printf -v encoded '\\U%08x' "$cp"
            fi
            printf -v decoded '%b' "$encoded"
            value+="$decoded"
            ;;
          *) JSON_ERROR="invalid JSON escape"; return 1 ;;
        esac
      done
      JSON_ERROR="unterminated JSON string"
      return 1
      ;;
    -|[0-9])
      value=""
      while (( JSON_POS <= JSON_LEN )); do
        ch="${JSON_SOURCE[JSON_POS]}"
        [[ "$ch" == [0-9eE+.-] ]] || break
        value+="$ch"
        (( JSON_POS++ ))
      done
      JSON_TOKEN_TYPE="number"
      JSON_TOKEN_VALUE="$value"
      ;;
    [tfn])
      value=""
      while (( JSON_POS <= JSON_LEN )); do
        ch="${JSON_SOURCE[JSON_POS]}"
        [[ "$ch" == [[:alpha:]] ]] || break
        value+="$ch"
        (( JSON_POS++ ))
      done
      case "$value" in
        true|false|null) JSON_TOKEN_TYPE="$value"; JSON_TOKEN_VALUE="$value" ;;
        *) JSON_ERROR="invalid JSON literal"; return 1 ;;
      esac
      ;;
    *) JSON_ERROR="unexpected JSON character at character $JSON_POS"; return 1 ;;
  esac
}

# Advance over a complete JSON value without rebuilding it. This is useful for
# large protocol envelopes where the caller only needs one top-level member.
json_discard_value() {
  case "$JSON_TOKEN_TYPE" in
    string|number|true|false|null)
      json_next || return 1
      ;;
    '[')
      json_next || return 1
      while [[ "$JSON_TOKEN_TYPE" != ']' ]]; do
        json_discard_value || return 1
        if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
          json_next || return 1
        elif [[ "$JSON_TOKEN_TYPE" != ']' ]]; then
          JSON_ERROR="expected comma or closing bracket"
          return 1
        fi
      done
      json_next || return 1
      ;;
    '{')
      json_next || return 1
      while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
        [[ "$JSON_TOKEN_TYPE" == string ]] || { JSON_ERROR="expected object key"; return 1; }
        json_next || return 1
        [[ "$JSON_TOKEN_TYPE" == ':' ]] || { JSON_ERROR="expected colon"; return 1; }
        json_next || return 1
        json_discard_value || return 1
        if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
          json_next || return 1
        elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
          JSON_ERROR="expected comma or closing brace"
          return 1
        fi
      done
      json_next || return 1
      ;;
    *)
      JSON_ERROR="expected JSON value"
      return 1
      ;;
  esac
}

# Preserve the exact source slice for a value while using the tokenizer only
# to locate its boundary. Unlike json_capture_value this performs no repeated
# string concatenation or JSON re-encoding.
json_capture_raw_value() {
  local -i start=$JSON_TOKEN_START end=0
  json_discard_value || return 1
  end=$(( JSON_TOKEN_START - 1 ))
  while (( end >= start )) && [[ "${JSON_SOURCE[end]}" == [[:space:]] ]]; do (( end-- )); done
  (( end >= start )) && REPLY="${JSON_SOURCE[start,end]}" || REPLY=""
}

# Serialize and consume the value at the current token. This lets us preserve
# arbitrary tool argument objects without delegating JSON work to jq.
json_capture_value() {
  local output="" item="" key="" comma=""
  case "$JSON_TOKEN_TYPE" in
    string)
      json_quote "$JSON_TOKEN_VALUE"; output="$REPLY"
      json_next || return 1
      ;;
    number|true|false|null)
      output="$JSON_TOKEN_VALUE"
      json_next || return 1
      ;;
    '[')
      output="["
      json_next || return 1
      while [[ "$JSON_TOKEN_TYPE" != ']' ]]; do
        json_capture_value || return 1
        item="$REPLY"
        output+="${comma}${item}"
        comma=","
        if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
          json_next || return 1
        elif [[ "$JSON_TOKEN_TYPE" != ']' ]]; then
          JSON_ERROR="expected comma or closing bracket"
          return 1
        fi
      done
      json_next || return 1
      output+="]"
      ;;
    '{')
      output="{"
      json_next || return 1
      while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
        [[ "$JSON_TOKEN_TYPE" == string ]] || { JSON_ERROR="expected object key"; return 1; }
        key="$JSON_TOKEN_VALUE"
        json_next || return 1
        [[ "$JSON_TOKEN_TYPE" == ':' ]] || { JSON_ERROR="expected colon"; return 1; }
        json_next || return 1
        json_capture_value || return 1
        item="$REPLY"
        json_quote "$key"
        output+="${comma}${REPLY}:${item}"
        comma=","
        if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
          json_next || return 1
        elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
          JSON_ERROR="expected comma or closing brace"
          return 1
        fi
      done
      json_next || return 1
      output+="}"
      ;;
    *) JSON_ERROR="expected JSON value"; return 1 ;;
  esac
  REPLY="$output"
}

json_skip_value() {
  json_capture_value
}

_json_parse_tool_function() {
  local key="" name="" args="{}"
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || return 1
  json_next || return 1
  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1
    case "$key:$JSON_TOKEN_TYPE" in
      name:string) name="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      arguments:'{') json_capture_value || return 1; args="$REPLY" ;;
      *) json_skip_value || return 1 ;;
    esac
    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  json_next || return 1
  JSON_TOOL_NAMES+=("$name")
  JSON_TOOL_ARGS+=("$args")
}

_json_parse_tool_call() {
  local key="" before=${#JSON_TOOL_NAMES}
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || return 1
  json_next || return 1
  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1
    if [[ "$key" == function && "$JSON_TOKEN_TYPE" == '{' ]]; then
      _json_parse_tool_function || return 1
    else
      json_skip_value || return 1
    fi
    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  json_next || return 1
  if (( ${#JSON_TOOL_NAMES} == before )); then
    JSON_ERROR="tool call did not contain a function"
    return 1
  fi
}

_json_parse_tool_calls() {
  local calls="[" comma="" name_json="" i
  [[ "$JSON_TOKEN_TYPE" == '[' ]] || return 1
  json_next || return 1
  while [[ "$JSON_TOKEN_TYPE" != ']' ]]; do
    _json_parse_tool_call || return 1
    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != ']' ]]; then
      return 1
    fi
  done
  json_next || return 1

  for (( i=1; i<=${#JSON_TOOL_NAMES}; i++ )); do
    json_quote "${JSON_TOOL_NAMES[i]}"; name_json="$REPLY"
    calls+="${comma}{\"type\":\"function\",\"function\":{\"name\":${name_json},\"arguments\":${JSON_TOOL_ARGS[i]}}}"
    comma=","
  done
  JSON_RESPONSE_TOOL_CALLS="${calls}]"
}

_json_parse_response_message() {
  local key=""
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || return 1
  json_next || return 1
  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1
    case "$key:$JSON_TOKEN_TYPE" in
      content:string) JSON_RESPONSE_CONTENT="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      thinking:string) JSON_RESPONSE_THINKING="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      tool_calls:'[') _json_parse_tool_calls || return 1 ;;
      *) json_skip_value || return 1 ;;
    esac
    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  json_next
}

json_parse_ollama_response() {
  local key=""
  JSON_RESPONSE_CONTENT=""
  JSON_RESPONSE_THINKING=""
  JSON_RESPONSE_ERROR=""
  JSON_RESPONSE_TOOL_CALLS="[]"
  JSON_RESPONSE_PROMPT_TOKENS=0
  JSON_RESPONSE_OUTPUT_TOKENS=0
  JSON_TOOL_NAMES=()
  JSON_TOOL_ARGS=()

  json_begin "$1" || return 1
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || { JSON_ERROR="response is not an object"; return 1; }
  json_next || return 1
  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1
    case "$key:$JSON_TOKEN_TYPE" in
      message:'{') _json_parse_response_message || return 1 ;;
      error:string) JSON_RESPONSE_ERROR="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      prompt_eval_count:number)
        [[ "$JSON_TOKEN_VALUE" == <0-> ]] && JSON_RESPONSE_PROMPT_TOKENS="$JSON_TOKEN_VALUE"
        json_next || return 1
        ;;
      eval_count:number)
        [[ "$JSON_TOKEN_VALUE" == <0-> ]] && JSON_RESPONSE_OUTPUT_TOKENS="$JSON_TOKEN_VALUE"
        json_next || return 1
        ;;
      *) json_skip_value || return 1 ;;
    esac
    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
}

_json_parse_model_object() {
  local key="" model_name=""
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || { JSON_ERROR="expected model object"; return 1; }
  json_next || return 1
  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || { JSON_ERROR="expected model field"; return 1; }
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || { JSON_ERROR="expected colon after model field"; return 1; }
    json_next || return 1
    if [[ "$key" == name && "$JSON_TOKEN_TYPE" == string ]]; then
      model_name="$JSON_TOKEN_VALUE"
      json_next || return 1
    else
      json_skip_value || return 1
    fi
    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      JSON_ERROR="expected comma or closing model brace"
      return 1
    fi
  done
  json_next || return 1
  [[ -n "$model_name" ]] && JSON_MODEL_NAMES+=("$model_name")
}

# Decode model names from Ollama's GET /api/tags response.
json_parse_models() {
  local key=""
  JSON_MODEL_NAMES=()
  json_begin "$1" || return 1
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || { JSON_ERROR="model response is not an object"; return 1; }
  json_next || return 1
  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1
    if [[ "$key" == models && "$JSON_TOKEN_TYPE" == '[' ]]; then
      json_next || return 1
      while [[ "$JSON_TOKEN_TYPE" != ']' ]]; do
        _json_parse_model_object || return 1
        if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
          json_next || return 1
        elif [[ "$JSON_TOKEN_TYPE" != ']' ]]; then
          JSON_ERROR="expected comma or closing models bracket"
          return 1
        fi
      done
      json_next || return 1
    else
      json_skip_value || return 1
    fi
    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  return 0
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
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || return 1
  json_next || return 1
  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1
    case "$key:$JSON_TOKEN_TYPE" in
      name:string) name="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      model:string) model="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      context_length:number)
        [[ "$JSON_TOKEN_VALUE" == <1-> ]] && context_length="$JSON_TOKEN_VALUE"
        json_next || return 1
        ;;
      *) json_skip_value || return 1 ;;
    esac
    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  json_next || return 1
  if _json_model_names_match "$name" "$target" || _json_model_names_match "$model" "$target"; then
    JSON_RUNNING_MODEL_CONTEXT="$context_length"
  fi
}

# Read the context actually allocated to a loaded model from GET /api/ps.
json_parse_running_model_context() {
  local source="$1" target="$2" key=""
  JSON_RUNNING_MODEL_CONTEXT=0
  json_begin "$source" || return 1
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || { JSON_ERROR="running-model response is not an object"; return 1; }
  json_next || return 1
  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1
    if [[ "$key" == models && "$JSON_TOKEN_TYPE" == '[' ]]; then
      json_next || return 1
      while [[ "$JSON_TOKEN_TYPE" != ']' ]]; do
        _json_parse_running_model "$target" || return 1
        if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
          json_next || return 1
        elif [[ "$JSON_TOKEN_TYPE" != ']' ]]; then
          return 1
        fi
      done
      json_next || return 1
    else
      json_skip_value || return 1
    fi
    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  return 0
}

# Tool schemas in this project use flat argument objects. Values are decoded to
# strings; JSON_OBJECT_TYPES lets dispatchers distinguish strings and scalars.
typeset -gA JSON_OBJECT_TYPES=()
json_parse_flat_object() {
  local key="" value="" value_type=""
  JSON_OBJECT=()
  JSON_OBJECT_TYPES=()
  json_begin "$1" || return 1
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || { JSON_ERROR="arguments must be an object"; return 1; }
  json_next || return 1
  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1
    value_type="$JSON_TOKEN_TYPE"
    case "$value_type" in
      string|number|true|false|null)
        value="$JSON_TOKEN_VALUE"
        JSON_OBJECT[$key]="$value"
        JSON_OBJECT_TYPES[$key]="$value_type"
        json_next || return 1
        ;;
      *) JSON_ERROR="argument '$key' must be a scalar"; return 1 ;;
    esac
    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
}
