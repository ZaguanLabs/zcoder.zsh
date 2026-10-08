#!/usr/bin/env zsh
# Opt-in microbenchmarks: no Ollama, terminal, filesystem writes, or timing gates.
emulate -R zsh
setopt extendedglob
zmodload zsh/datetime zsh/system || exit 1
benchmark_root="${0:A:h:h}"
for benchmark_library in util json http stream compact transcript input ui agent agent_prompts agent_lfm agent_loop; do
  source "$benchmark_root/lib/$benchmark_library.zsh" || exit 1
done
typeset -gi benchmark_samples=${ZCODER_BENCHMARK_SAMPLES:-5}
typeset -gi benchmark_warmups=${ZCODER_BENCHMARK_WARMUPS:-3}
(( benchmark_samples >= 3 && benchmark_warmups >= 1 )) || {
  print -u2 -r -- 'Use at least three samples and one warmup.'; exit 1
}
print -r -- "Zsh $ZSH_VERSION; $MACHTYPE; $OSTYPE; locale=${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}"
print -r -- "${benchmark_warmups} warmups, ${benchmark_samples} samples; elapsed milliseconds (median/min/max)."
print -r -- 'Cached redraw mocks curses; these measurements exclude terminal and network latency.'

benchmark_measure() {
  local label="$1" callback="$2"; shift 2
  local -i iteration position middle=$(( (benchmark_samples + 1) / 2 ))
  local -F started elapsed
  local -a samples=()
  for (( iteration=1; iteration<=benchmark_warmups; iteration++ )); do "$callback" "$@" || return 1; done
  for (( iteration=1; iteration<=benchmark_samples; iteration++ )); do
    started=$EPOCHREALTIME
    "$callback" "$@" || return 1
    elapsed=$(( (EPOCHREALTIME-started)*1000.0 ))
    samples+=("$elapsed")
  done
  # Zsh's numeric expansion sort compares digit runs, not floating-point values.
  for (( iteration=2; iteration<=${#samples}; iteration++ )); do
    elapsed=${samples[iteration]}
    position=$iteration
    while (( position > 1 && samples[position-1] > elapsed )); do
      samples[position]=${samples[position-1]}
      (( position-- ))
    done
    samples[position]=$elapsed
  done
  elapsed=${samples[middle]}
  (( benchmark_samples % 2 )) || elapsed=$(( (elapsed + samples[middle+1]) / 2.0 ))
  printf '%-35s %10.3f / %10.3f / %10.3f\n' "$label" "$elapsed" "${samples[1]}" "${samples[-1]}"
}

benchmark_paste() {
  local -i count=$1 i
  local byte='' delimiter=$'\e[201~'
  input_reset; INPUT_TERM_STATE=paste
  for (( i=0; i<count; i++ )); do input_decode_terminal_event x ''; done
  for byte in "${(@s::)delimiter}"; do input_decode_terminal_event "$byte" ''; done
  [[ "$INPUT_EVENT_ACTION" == paste ]] && (( ${#INPUT_EVENT_TEXT} == count ))
}
for benchmark_size in 25000 50000 100000; do
  benchmark_measure "paste ${benchmark_size} characters" benchmark_paste "$benchmark_size" || exit 1
done

benchmark_quote() { zjson_quote "$benchmark_text"; }
for benchmark_kind in DEL SOH; do
  benchmark_control=$'\177'
  [[ "$benchmark_kind" == SOH ]] && benchmark_control=$'\001'
  for benchmark_size in 16384 32768 65536; do
    benchmark_text="${(pl:benchmark_size::é:)}${benchmark_control}"
    benchmark_measure "JSON ${benchmark_size} é + one $benchmark_kind" benchmark_quote || exit 1
  done
done

# Isolate accumulation costs; these fixtures exclude socket reads and HTTP
# parsing. Keep both strategies so future changes can be compared directly.
benchmark_response_scalar() {
  emulate -L zsh
  setopt nomultibyte
  local assembled='' chunk=''
  for chunk in "${benchmark_chunks[@]}"; do assembled+="$chunk"; done
  (( ${#assembled} == benchmark_bytes ))
}
benchmark_response_array() {
  emulate -L zsh
  setopt nomultibyte
  local assembled='' chunk=''
  local -a chunks=()
  for chunk in "${benchmark_chunks[@]}"; do chunks+=("$chunk"); done
  assembled="${(j::)chunks}"
  (( ${#assembled} == benchmark_bytes ))
}
benchmark_http_feed() {
  emulate -L zsh
  setopt nomultibyte
  local chunk=''
  local -i received=0
  http_stream_reset
  http_stream_feed $'HTTP/1.1 200 OK\r\nContent-Length: '"$benchmark_bytes"$'\r\n\r\n' || return 1
  for chunk in "${benchmark_chunks[@]}"; do
    http_stream_feed "$chunk" || return 1
    (( received += ${#HTTP_STREAM_OUTPUT} ))
  done
  http_stream_finish && (( received == benchmark_bytes && ${#HTTP_STREAM_WIRE} == 0 ))
}
for benchmark_size in 32 128 512; do
  benchmark_chunks=()
  benchmark_text="${(pl:32768::x:)}"
  for (( benchmark_index=0; benchmark_index<benchmark_size; benchmark_index++ )); do benchmark_chunks+=("$benchmark_text"); done
  benchmark_bytes=$(( benchmark_size * 32768 ))
  benchmark_measure "buffer scalar ${benchmark_size} x 32KiB" benchmark_response_scalar || exit 1
  benchmark_measure "buffer array ${benchmark_size} x 32KiB" benchmark_response_array || exit 1
  benchmark_measure "HTTP feed ${benchmark_size} x 32KiB" benchmark_http_feed || exit 1
done

benchmark_recover() { json_recover_model_object "$benchmark_text"; }
for benchmark_size in 16384 65536 131072; do
  benchmark_text=$'Model preface\n```json\n{"text":"'"${(pl:benchmark_size::x:)}"$'","nested":{"ok":true}}\n```'
  benchmark_measure "JSON recovery ${benchmark_size} string" benchmark_recover || exit 1
  benchmark_text="${(pl:benchmark_size::x:)}"' {"ok":true}'
  benchmark_measure "JSON recovery ${benchmark_size} preface" benchmark_recover || exit 1
done

benchmark_truncate() { zcoder_truncate_head_tail "$benchmark_text" 32768; }
benchmark_text="${(pl:1048576::x:)}"
benchmark_measure 'truncate 1MiB to 32KiB' benchmark_truncate || exit 1

input_reset; INPUT_BUF="${(pl:100000::x:)}"; INPUT_POS=${#INPUT_BUF}
benchmark_layout() { INPUT_LAYOUT_WIDTH=-1; input_layout 74 4; return 0; }
benchmark_cached_layout() { input_layout 74 4; return 0; }
benchmark_measure 'input layout 100000 characters' benchmark_layout || exit 1
benchmark_measure 'input cached layout 100000 chars' benchmark_cached_layout || exit 1

ZCODER_MODEL=benchmark; AGENT_SYSTEM_PROMPT=benchmark; AGENT_CONTEXT_TOOLS='[]'
benchmark_text="${(pl:1024::x:)}"
zjson_quote "$benchmark_text"
for benchmark_index in {1..1000}; do AGENT_MESSAGES+=('{"role":"assistant","content":'"$REPLY"'}'); done
benchmark_context_cold() {
  AGENT_ACCOUNTING_MESSAGES=(); AGENT_ACCOUNTING_BYTES=(); AGENT_ACCOUNTING_REASONING_BYTES=()
  agent_context_bill
}
benchmark_measure 'context 1000 x 1KiB cold cache' benchmark_context_cold || exit 1
benchmark_measure 'context 1000 x 1KiB warm cache' agent_context_bill || exit 1
benchmark_measure 'history JSON 1000 x 1KiB' agent_history_payload_json || exit 1
benchmark_payload() { agent_build_payload false '[]'; }
benchmark_measure 'chat payload 1000 x 1KiB' benchmark_payload || exit 1

zcoder_curses() { return 0; }
UI_ACTIVE=1; SCREEN_W=80; SCREEN_H=24; SIDE_W=0; INPUT_H=3; UI_FOCUS=input
transcript_reset
for benchmark_index in {1..1000}; do ui_append_message assistant "Short assistant text $benchmark_index"; done
_ui_paint_chat 1
benchmark_redraw() { _ui_paint_chat 1; return 0; }
benchmark_measure 'cached redraw 1000 events' benchmark_redraw || exit 1
benchmark_complete_layout() { ui_render_messages 78; return 0; }
benchmark_measure 'complete layout 1000 events' benchmark_complete_layout || exit 1
