# Native JSON tokenizer and the small codecs zcoder needs for Ollama.

typeset -g JSON_SOURCE=""
typeset -ga JSON_CHARS=()
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
typeset -gi JSON_RESPONSE_DONE=-1
typeset -ga JSON_TOOL_NAMES=()
typeset -ga JSON_TOOL_ARGS=()
typeset -ga JSON_MODEL_NAMES=()
typeset -gi JSON_RUNNING_MODEL_CONTEXT=0
typeset -gA JSON_OBJECT=()

# Escape the remaining JSON controls with at most 32 native split/join passes.
# Dynamic delimiters preserve empty fields; no scalar character indexing or
# per-match string replacement is needed even for control-heavy Unicode text.
_json_quote_controls() {
  local output="$1" ch="" encoded="" escaped=""
  local -i code
  for (( code=0; code<32; code++ )); do
    printf -v encoded '\\x%02x' "$code"
    printf -v ch '%b' "$encoded"
    [[ "$output" == *"$ch"* ]] || continue
    printf -v escaped '\\u%04x' "$code"
    output="${(pj:$escaped:)${(@ps:$ch:)output}}"
  done
  REPLY="$output"
}

# Repair malformed UTF-8 at the JSON boundary, including bytes in old saved
# transcripts. Work in bytes regardless of the process locale. Valid text is
# copied in bounded blocks: an unbounded repeated glob can exhaust Zsh's stack.
_json_utf8_text() {
  emulate -L zsh
  setopt extendedglob nomultibyte
  local LC_ALL=C
  local input="$1" chunk='' byte='' second='' replacement=$'\xef\xbf\xbd'
  local unit=$'([\x00-\x7f]|[\xc2-\xdf][\x80-\xbf]|\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xec\xee-\xef][\x80-\xbf][\x80-\xbf]|\xed[\x80-\x9f][\x80-\xbf]|\xf0[\x90-\xbf][\x80-\xbf][\x80-\xbf]|[\xf1-\xf3][\x80-\xbf][\x80-\xbf][\x80-\xbf]|\xf4[\x80-\x8f][\x80-\xbf][\x80-\xbf])'
  local -a pieces=() bytes=()
  local -i offset=1 end length=${#input} i j width count extra
  if [[ "$input" != *[$'\x80'-$'\xff']* ]]; then
    REPLY="$input"
    return 0
  fi
  while (( offset <= length )); do
    end=$(( offset + 1023 ))
    (( end > length )) && end=$length
    # Include continuation bytes when a valid character crosses a block edge.
    for extra in 1 2 3; do
      (( end < length )) || break
      [[ ${input[end+1]} == [$'\x80'-$'\xbf'] ]] || break
      (( end++ ))
    done
    chunk="${input[offset,end]}"
    if [[ "$chunk" == (${~unit})# ]]; then
      pieces+=("$chunk")
    else
      bytes=("${(@s::)chunk}")
      count=${#bytes}
      for (( i=1; i<=count; )); do
        byte=${bytes[i]}
        width=1
        second=$'[\x80-\xbf]'
        case "$byte" in
          [$'\x00'-$'\x7f']) pieces+=("$byte"); (( i++ )); continue ;;
          [$'\xc2'-$'\xdf']) width=2 ;;
          $'\xe0') width=3; second=$'[\xa0-\xbf]' ;;
          [$'\xe1'-$'\xec']|[$'\xee'-$'\xef']) width=3 ;;
          $'\xed') width=3; second=$'[\x80-\x9f]' ;;
          $'\xf0') width=4; second=$'[\x90-\xbf]' ;;
          [$'\xf1'-$'\xf3']) width=4 ;;
          $'\xf4') width=4; second=$'[\x80-\x8f]' ;;
        esac
        j=$(( i + 1 ))
        if (( width > 1 && j <= count )) && [[ ${bytes[j]} == ${~second} ]]; then
          (( j++ ))
          while (( j < i + width && j <= count )) && [[ ${bytes[j]} == [$'\x80'-$'\xbf'] ]]; do
            (( j++ ))
          done
        fi
        if (( width > 1 && j == i + width )); then
          pieces+=("${(j::)bytes[i,j-1]}")
        else
          # Consume only the malformed prefix; retain the following character.
          pieces+=("$replacement")
        fi
        i=$j
      done
    fi
    offset=$(( end + 1 ))
  done
  REPLY="${(j::)pieces}"
}

json_quote() {
  local input="$1" output=""

  # Parameter substitution performs the common JSON string encoding in native
  # Zsh internals. Building the result one character at a time is quadratic
  # for large resumed histories and can pin a core during compaction.
  # ${//} pays a rebuild per match, so the frequent newline and tab escapes use
  # a C-speed split+join instead; quoted (@s) splitting keeps empty fields, so
  # the round trip is exact.
  _json_utf8_text "$input"
  output="$REPLY"
  [[ "$output" == *'\'* ]] && output="${(pj:\\\\:)${(@ps:\\:)output}}"
  [[ "$output" == *'"'* ]] && output="${(pj:\\\":)${(@ps:\":)output}}"
  [[ "$output" == *$'\b'* ]] && output="${(pj:\\b:)${(@ps:\b:)output}}"
  [[ "$output" == *$'\f'* ]] && output="${(pj:\\f:)${(@ps:\f:)output}}"
  [[ "$output" == *$'\r'* ]] && output="${(pj:\\r:)${(@ps:\r:)output}}"
  [[ "$output" == *$'\n'* ]] && output="${(pj:\\n:)${(@ps:\n:)output}}"
  [[ "$output" == *$'\t'* ]] && output="${(pj:\\t:)${(@ps:\t:)output}}"

  # JSON forbids only U+0000 through U+001F, not DEL or other characters
  # that a locale may classify as controls.
  if [[ "$output" == *[$'\0'-$'\37']* ]]; then
    _json_quote_controls "$output"
    output="$REPLY"
  fi
  REPLY="\"${output}\""
}

json_begin() {
  JSON_SOURCE="$1"
  # Tokenize over a character array: Zsh scalar subscripting walks the string
  # from its start on every access, which makes per-character parsing of large
  # responses quadratic. Array indexing is constant time and subscript-pattern
  # searches over the array run at C speed.
  if [[ -n "$1" ]]; then
    JSON_CHARS=("${(@s::)1}")
  else
    JSON_CHARS=()
  fi
  JSON_POS=1
  JSON_LEN=${#JSON_CHARS}
  JSON_TOKEN_TYPE=""
  JSON_TOKEN_VALUE=""
  JSON_ERROR=""
  json_next
}

# Decode a string token whose opening quote has been consumed. Strings without
# escapes copy in one slice; strings with only the simple two-character escapes
# decode with C-speed split+join transforms. Anything else — \u escapes,
# invalid escapes, unterminated input — falls back to the exact
# character-by-character scanner so every error and edge case is unchanged.
_json_scan_string() {
  local raw="" part="" quote_char='"' backslash_char='\'
  local -a parts=() decoded_parts=()
  local -i quote backslash before
  quote=${JSON_CHARS[(ib:JSON_POS:)$quote_char]}
  if (( quote > JSON_LEN )); then
    _json_scan_string_slow
    return
  fi
  backslash=${JSON_CHARS[(ib:JSON_POS:)$backslash_char]}
  if (( quote < backslash )); then
    (( quote > JSON_POS )) && JSON_TOKEN_VALUE="${(j::)JSON_CHARS[JSON_POS,quote-1]}" || JSON_TOKEN_VALUE=""
    [[ "$JSON_TOKEN_VALUE" != *[$'\0'-$'\37']* ]] || { JSON_ERROR="unescaped JSON control character"; return 1; }
    JSON_TOKEN_TYPE="string"
    JSON_POS=$(( quote + 1 ))
    return 0
  fi
  # The closing quote is the next one preceded by an even run of backslashes.
  while true; do
    before=$(( quote - 1 ))
    while (( before >= JSON_POS )) && [[ "${JSON_CHARS[before]}" == '\' ]]; do (( before-- )); done
    (( (quote - 1 - before) % 2 == 0 )) && break
    quote=${JSON_CHARS[(ib:quote+1:)$quote_char]}
    if (( quote > JSON_LEN )); then
      _json_scan_string_slow
      return
    fi
  done
  raw="${(j::)JSON_CHARS[JSON_POS,quote-1]}"
  [[ "$raw" != *[$'\0'-$'\37']* ]] || { JSON_ERROR="unescaped JSON control character"; return 1; }
  if [[ "$raw" == *'\u'* ]]; then
    _json_scan_string_slow
    return
  fi
  parts=("${(@ps:\\\\:)raw}")
  for part in "${parts[@]}"; do
    if [[ "$part" == *'\'* ]]; then
      part="${(pj:\n:)${(@ps:\\n:)part}}"
      part="${(pj:\t:)${(@ps:\\t:)part}}"
      part="${(pj:\r:)${(@ps:\\r:)part}}"
      part="${(pj:\b:)${(@ps:\\b:)part}}"
      part="${(pj:\f:)${(@ps:\\f:)part}}"
      part="${(pj:\":)${(@ps:\\\":)part}}"
      part="${(pj:/:)${(@ps:\\/:)part}}"
      if [[ "$part" == *'\'* ]]; then
        _json_scan_string_slow
        return
      fi
    fi
    decoded_parts+=("$part")
  done
  JSON_TOKEN_VALUE="${(pj:\\:)decoded_parts}"
  JSON_TOKEN_TYPE="string"
  JSON_POS=$(( quote + 1 ))
  return 0
}

_json_scan_string_slow() {
  local ch="" esc="" hex="" low_hex="" encoded="" decoded="" value="" run=""
  local -i cp low_cp boundary
  while (( JSON_POS <= JSON_LEN )); do
    # Copy the run up to the next quote or escape in one slice instead of
    # appending character by character.
    boundary=${JSON_CHARS[(ib:JSON_POS:)[\"\\\\]]}
    (( boundary <= JSON_LEN )) || break
    if (( boundary > JSON_POS )); then
      run="${(j::)JSON_CHARS[JSON_POS,boundary-1]}"
      [[ "$run" != *[$'\0'-$'\37']* ]] || { JSON_ERROR="unescaped JSON control character"; return 1; }
      value+="$run"
    fi
    ch="${JSON_CHARS[boundary]}"
    JSON_POS=$(( boundary + 1 ))
    if [[ "$ch" == '"' ]]; then
      JSON_TOKEN_TYPE="string"
      JSON_TOKEN_VALUE="$value"
      return 0
    fi
    (( JSON_POS <= JSON_LEN )) || { JSON_ERROR="unterminated JSON escape"; return 1; }
    esc="${JSON_CHARS[JSON_POS]}"
    (( JSON_POS++ ))
    case "$esc" in
      '"'|$'\\'|'/') value+="$esc" ;;
      b) value+=$'\b' ;;
      f) value+=$'\f' ;;
      n) value+=$'\n' ;;
      r) value+=$'\r' ;;
      t) value+=$'\t' ;;
      u)
        hex="${(j::)JSON_CHARS[JSON_POS,JSON_POS+3]}"
        # JSON requires exactly four ASCII hex digits. Streaming callers use
        # emulate -L zsh, so validation must not depend on EXTENDED_GLOB (or a
        # pattern cached by an earlier decode with different options).
        [[ ${#hex} -eq 4 && "$hex" != *[^0-9a-fA-F]* ]] || { JSON_ERROR="invalid JSON unicode escape"; return 1; }
        (( JSON_POS += 4 ))
        cp=$(( 16#$hex ))
        if (( cp >= 0xD800 && cp <= 0xDBFF )) && \
           [[ "${(j::)JSON_CHARS[JSON_POS,JSON_POS+1]}" == $'\\u' ]]; then
          low_hex="${(j::)JSON_CHARS[JSON_POS+2,JSON_POS+5]}"
          if [[ ${#low_hex} -eq 4 && "$low_hex" != *[^0-9a-fA-F]* ]]; then
            low_cp=$(( 16#$low_hex ))
            if (( low_cp >= 0xDC00 && low_cp <= 0xDFFF )); then
              cp=$(( 0x10000 + ((cp - 0xD800) << 10) + low_cp - 0xDC00 ))
              (( JSON_POS += 6 ))
            fi
          fi
        fi
        if (( cp >= 0xD800 && cp <= 0xDFFF )); then
          # An unpaired UTF-16 surrogate has no character encoding. Substitute
          # the Unicode replacement character; handing the raw code point to
          # printf %b is a fatal error that would abort the whole process.
          decoded=$'\uFFFD'
        else
          if (( cp <= 0xFFFF )); then
            printf -v encoded '\\u%04x' "$cp"
          else
            printf -v encoded '\\U%08x' "$cp"
          fi
          {
            printf -v decoded '%b' "$encoded" 2>/dev/null
          } always {
            # A code point the current locale cannot encode is also fatal in
            # printf; contain it and substitute the replacement character.
            if (( TRY_BLOCK_ERROR )); then
              TRY_BLOCK_ERROR=0
              decoded=$'\uFFFD'
            fi
          }
        fi
        value+="$decoded"
        ;;
      *) JSON_ERROR="invalid JSON escape"; return 1 ;;
    esac
  done
  JSON_ERROR="unterminated JSON string"
  return 1
}

json_next() {
  local ch="" value="" previous="$JSON_TOKEN_TYPE" whitespace=$' \t\r\n'
  local -i boundary
  local MATCH MBEGIN MEND
  local -a match mbegin mend

  # First non-whitespace character at or after JSON_POS, located in C.
  JSON_POS=${JSON_CHARS[(ib:JSON_POS:)[^${whitespace}]]}
  JSON_TOKEN_START=$JSON_POS
  if (( JSON_POS > JSON_LEN )); then
    JSON_TOKEN_TYPE="eof"
    JSON_TOKEN_VALUE=""
    return 0
  fi

  ch="${JSON_CHARS[JSON_POS]}"
  if [[ "$previous" == ',' && ( "$ch" == '}' || "$ch" == ']' ) ]]; then
    JSON_ERROR="trailing comma in JSON container"
    return 1
  fi
  case "$ch" in
    '{'|'}'|'['|']'|':'|',')
      JSON_TOKEN_TYPE="$ch"
      JSON_TOKEN_VALUE="$ch"
      (( JSON_POS++ ))
      ;;
    '"')
      (( JSON_POS++ ))
      _json_scan_string
      ;;
    -|[0-9])
      boundary=${JSON_CHARS[(ib:JSON_POS:)[^0-9eE+.-]]}
      value="${(j::)JSON_CHARS[JSON_POS,boundary-1]}"
      [[ "$value" =~ '^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$' ]] || {
        JSON_ERROR="invalid JSON number"
        return 1
      }
      JSON_POS=$boundary
      JSON_TOKEN_TYPE="number"
      JSON_TOKEN_VALUE="$value"
      ;;
    [tfn])
      boundary=${JSON_CHARS[(ib:JSON_POS:)[^[:alpha:]]]}
      value="${(j::)JSON_CHARS[JSON_POS,boundary-1]}"
      JSON_POS=$boundary
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
  while (( end >= start )) && [[ "${JSON_CHARS[end]}" == [[:space:]] ]]; do (( end-- )); done
  (( end >= start )) && REPLY="${(j::)JSON_CHARS[start,end]}" || REPLY=""
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

# Callers that skip a member only need the cursor advanced past it; rebuilding
# the serialized value just to throw it away is pure waste for large payloads.
json_skip_value() {
  json_discard_value
}

_json_parse_tool_function() {
  local key="" name="" args="{}"
  local -i has_args=0
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
      arguments:'{') json_capture_value || return 1; args="$REPLY"; has_args=1 ;;
      *) json_skip_value || return 1 ;;
    esac
    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  json_next || return 1
  if (( ${JSON_REQUIRE_COMPLETE_TOOLS:-0} && ! has_args )); then
    JSON_ERROR="streamed tool arguments must be a complete object"
    return 1
  fi
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
      done:true) JSON_RESPONSE_DONE=1; json_next || return 1 ;;
      done:false) JSON_RESPONSE_DONE=0; json_next || return 1 ;;
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
  json_next || return 1
  [[ "$JSON_TOKEN_TYPE" == eof ]]
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
  json_next || return 1
  [[ "$JSON_TOKEN_TYPE" == eof ]] || { JSON_ERROR="trailing content after JSON object"; return 1; }
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
  json_next || return 1
  [[ "$JSON_TOKEN_TYPE" == eof ]] || { JSON_ERROR="trailing content after JSON object"; return 1; }
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
  json_next || return 1
  [[ "$JSON_TOKEN_TYPE" == eof ]] || { JSON_ERROR="trailing content after JSON object"; return 1; }
}
