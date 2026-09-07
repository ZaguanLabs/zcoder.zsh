#!/usr/bin/env zsh
# Opt-in microbenchmarks: no Ollama, terminal, filesystem writes, or timing gates.
emulate -R zsh
setopt extendedglob
zmodload zsh/datetime zsh/system || exit 1
benchmark_root="${0:A:h:h}"
for benchmark_library in util json http transcript input ui agent; do
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

benchmark_quote() { json_quote "$benchmark_text"; }
for benchmark_kind in DEL SOH; do
  benchmark_control=$'\177'
  [[ "$benchmark_kind" == SOH ]] && benchmark_control=$'\001'
  for benchmark_size in 16384 32768 65536; do
    benchmark_text="${(pl:benchmark_size::é:)}${benchmark_control}"
    benchmark_measure "JSON ${benchmark_size} é + one $benchmark_kind" benchmark_quote || exit 1
  done
done

input_reset; INPUT_BUF="${(pl:100000::x:)}"; INPUT_POS=${#INPUT_BUF}
benchmark_layout() { INPUT_LAYOUT_WIDTH=-1; input_layout 74 4; return 0; }
benchmark_cached_layout() { input_layout 74 4; return 0; }
benchmark_measure 'input layout 100000 characters' benchmark_layout || exit 1
benchmark_measure 'input cached layout 100000 chars' benchmark_cached_layout || exit 1

ZCODER_MODEL=benchmark; AGENT_SYSTEM_PROMPT=benchmark; AGENT_CONTEXT_TOOLS='[]'
benchmark_text="${(pl:1024::x:)}"
json_quote "$benchmark_text"
for benchmark_index in {1..1000}; do AGENT_MESSAGES+=('{"role":"assistant","content":'"$REPLY"'}'); done
benchmark_context_cold() {
  AGENT_ACCOUNTING_MESSAGES=(); AGENT_ACCOUNTING_BYTES=(); AGENT_ACCOUNTING_REASONING_BYTES=()
  agent_context_bill
}
benchmark_measure 'context 1000 x 1KiB cold cache' benchmark_context_cold || exit 1
benchmark_measure 'context 1000 x 1KiB warm cache' agent_context_bill || exit 1

zcurses() { return 0; }
UI_ACTIVE=1; SCREEN_W=80; SCREEN_H=24; SIDE_W=0; INPUT_H=3; UI_FOCUS=input
transcript_reset
for benchmark_index in {1..1000}; do ui_append_message assistant "Short assistant text $benchmark_index"; done
_ui_paint_chat 1
benchmark_redraw() { _ui_paint_chat 1; return 0; }
benchmark_measure 'cached redraw 1000 events' benchmark_redraw || exit 1
