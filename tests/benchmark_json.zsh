#!/usr/bin/env zsh
# Opt-in JSON measurements, without Ollama or terminal setup. To compare a
# source snapshot, set ZJSON_BENCH_ROOT to its directory (containing zjson.zsh).
emulate -R zsh
setopt extendedglob
typeset benchmark_root=${0:A:h:h}
source "$benchmark_root/lib/json.zsh" || exit 1
if [[ -n ${ZJSON_BENCH_ROOT:-} ]]; then
  source "$ZJSON_BENCH_ROOT/zjson.zsh" || exit 1
fi
typeset -i samples=${ZCODER_BENCHMARK_SAMPLES:-7}
(( samples >= 3 )) || exit 2
printf '# zjson=%s zsh=%s platform=%s locale=%s samples=%d\n' \
  "$ZJSON_VERSION" "$ZSH_VERSION" "$OSTYPE/$MACHTYPE" \
  "${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}" "$samples"
print -r -- 'Milliseconds per operation; two warmup batches; median/min/max.'

measure() {
  local label=$1 callback=$2
  local -i count=$3 i j micros middle=$(( (samples + 1) / 2 ))
  shift 3
  local -a timings=()
  local -F 6 SECONDS=0
  for (( i=-1; i<=samples; ++i )); do
    SECONDS=0
    for (( j=0; j<count; ++j )); do
      "$callback" "$@" || { print -ru2 -- "$label failed: $ZJSON_ERROR"; return 1; }
    done
    micros=$(( SECONDS * 1000000 / count ))
    (( i > 0 )) && timings+=("$micros")
  done
  timings=( ${(on)timings} )
  local -F median=$(( timings[middle] / 1000.0 ))
  (( samples % 2 )) || median=$(( (timings[middle] + timings[middle+1]) / 2000.0 ))
  printf '%-34s %9.3f / %9.3f / %9.3f\n' "$label" "$median" \
    "$(( timings[1] / 1000.0 ))" "$(( timings[-1] / 1000.0 ))"
}

compact() { zjson_begin "$1" && zjson_capture_value; }
raw() { zjson_begin "$1" && zjson_capture_raw_value; }
three_gets() {
  local document=$1 pointer
  for pointer in /message/content /prompt_eval_count /eval_count; do
    zjson_get "$document" "$pointer" || return 1
  done
}
multi_get() { zjson_get_multi "$1" /message/content /prompt_eval_count /eval_count; }
each_noop() { return 0; }
each_object() { zjson_each_object "$1" each_noop; }
encode_object() { zjson_encode_object; }

typeset chunk='{"message":{"role":"assistant","content":"A short streamed token."},"done":false}'
typeset response='{"message":{"role":"assistant","content":"Done.","tool_calls":[{"function":{"name":"read_file","arguments":{"path":"lib/json.zsh"}}}]},"done":true,"prompt_eval_count":2048,"eval_count":128}'
typeset -a members=()
typeset -i n
for (( n=1; n<=500; ++n )); do members+=("\"field$n\":$n"); done
typeset wide="{${(j:,:)members}}"
typeset unicode=''
# Keep the payload at 16,384 two-byte characters in both C and UTF-8 locales.
() {
  emulate -L zsh
  setopt nomultibyte
  unicode="${(pl:32768::é:)}"
}
measure 'Ollama stream chunk' json_parse_ollama_response 100 "$chunk" || exit 1
measure 'Ollama tool response' json_parse_ollama_response 30 "$response" || exit 1
measure 'Flat tool arguments' json_parse_flat_object 100 '{"path":"lib/json.zsh","start_line":1,"end_line":80}' || exit 1
measure 'Quote 16Ki characters UTF-8' zjson_quote 5 "$unicode" || exit 1
measure 'Validate 16Ki characters UTF-8' zjson_validate 5 "\"$unicode\"" || exit 1
measure 'Raw capture 500 fields' raw 1 "$wide" || exit 1
measure 'Compact capture 500 fields' compact 1 "$wide" || exit 1
measure 'Object decode 500 fields' zjson_parse_object 1 "$wide" || exit 1
measure 'Three separate Pointers' three_gets 10 "$response" || exit 1
if [[ $ZJSON_VERSION != 0.1.0 ]]; then
  measure 'One multi-Pointer lookup' multi_get 10 "$response" || exit 1
  measure 'Object callbacks 500 fields' each_object 1 "$wide" || exit 1
  zjson_parse_object "$wide" || exit 1
  measure 'Object encode 500 fields' encode_object 1 || exit 1
fi
