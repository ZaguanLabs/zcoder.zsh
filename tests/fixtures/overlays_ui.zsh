#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
zmodload zsh/curses zsh/terminfo zsh/datetime zsh/mapfile || exit 1
typeset -g fixture_root="$1" fixture_base="$2"
for fixture_lib in util json transcript input ui overlays commands compact; do
  source "$fixture_root/lib/${fixture_lib}.zsh"
done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=alpha
typeset -g ZCODER_WORKSPACE="$fixture_root" OLLAMA_HOST=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset -gi fixture_context_reads=0
typeset -ga OLLAMA_MODELS=() AGENT_CONTEXT_COMPONENT_LABELS=(Guidance Tools) AGENT_CONTEXT_COMPONENT_VALUES=(100 400)
typeset -g fixture_dispatched=""
typeset -gi AGENT_WARMUP_ACTIVE=1
agent_warmup_poll() {
  AGENT_WARMUP_ACTIVE=0
  ui_set_status Ready
  ui_draw_header
  mapfile[${fixture_base}.warmup_done]="$UI_MODAL_ACTIVE"
}
ollama_get_models() { OLLAMA_MODELS=(alpha beta); }
agent_context_summary() {
  (( fixture_context_reads++ ))
  AGENT_CONTEXT_WINDOW=65536; AGENT_ESTIMATED_TOKENS=512
  AGENT_LAST_PROMPT_TOKENS=432; AGENT_LAST_OUTPUT_TOKENS=31
  REPLY="fixture snapshot"
}
handle_slash_command() { fixture_dispatched="$1"; }
functions[_fixture_palette_draw]="${functions[_ui_palette_draw]}"
_ui_palette_draw() {
  _fixture_palette_draw
  mapfile[${fixture_base}.palette_draw]="${palette_query}:${SCREEN_W}"
}
functions[_fixture_view_draw]="${functions[_ui_modal_view_draw]}"
_ui_modal_view_draw() {
  _fixture_view_draw
  mapfile[${fixture_base}.view_draw]="${modal_title}:${SCREEN_W}"
}
functions[_fixture_list_draw]="${functions[_ui_modal_list_draw]}"
_ui_modal_list_draw() {
  _fixture_list_draw
  mapfile[${fixture_base}.list_draw]="${modal_title}:${modal_selected}:${SCREEN_W}"
}
command stty rows 24 cols 80 < /dev/tty || exit 1
trap 'ui_end' EXIT
INPUT_BUF="draft text"; INPUT_POS=3
ui_init || exit 1
mapfile[${fixture_base}.tty]="$TTY"
ui_command_palette
mapfile[${fixture_base}.palette_done]="${INPUT_BUF}:${INPUT_POS}:${fixture_dispatched}:${UI_MODAL_ACTIVE}"
ui_show_context
mapfile[${fixture_base}.context_done]="${fixture_context_reads}:${UI_MODAL_ACTIVE}"
ui_confirm_external_action 'External action with exact arguments'
mapfile[${fixture_base}.approval_done]="$REPLY"
ui_select_model
mapfile[${fixture_base}.model_done]="$ZCODER_MODEL"
ui_end
mapfile[${fixture_base}.done]=1
