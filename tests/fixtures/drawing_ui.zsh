#!/usr/bin/env zsh
# Capture real retained cells and exercise both drawing paths in a private PTY.
emulate -R zsh
setopt extendedglob
typeset -g fixture_root=$1 fixture_base=$2 fixture_backend=$3 fixture_connection=${4:-local}
source "$fixture_root/lib/curses.zsh"
ZCODER_CURSES=$fixture_backend zcoder_curses_load "$fixture_root" || exit 1
# A loaded but inactive stock module must not affect zdraw dispatch or colors.
if [[ $ZCODER_CURSES_COMMAND == zdraw ]]; then
  zmodload -e zsh/curses && exit 14
  zmodload zsh/curses || exit 1
  zcoder_curses_load "$fixture_root" || exit 1
  [[ $ZCODER_CURSES_COMMAND == zdraw ]] || exit 15
fi
zmodload zsh/terminfo zsh/datetime zsh/mapfile || exit 1
for fixture_lib in util json skills transcript agent input terminal ui; do
  source "$fixture_root/lib/$fixture_lib.zsh"
done
typeset -g ZCODER_NAME=zcoder.zsh ZCODER_VERSION=preview ZCODER_MODEL=qwen3-coder
typeset -g ZCODER_WORKSPACE=$fixture_root OLLAMA_HOST=localhost:11434 ZCODER_PROFILE=coding
typeset -g REMOTE_MODE=$fixture_connection ZCODER_SYNC_OUTPUT=false
typeset -g REMOTE_SERVER_NAME=fixture-server REMOTE_ENDPOINT=localhost:7337
typeset -g ZCODER_COMMAND_POLICY=ask CURRENT_SESSION_ID=preview
typeset -a SESSION_IDS=(preview earlier) SESSION_TITLES=('Rendering refresh' 'Review tool output')
typeset -a SESSION_MODELS=(qwen3-coder qwen3-coder)
typeset -g INPUT_BUF='Explain the fallback for combining characters.'
typeset -gi INPUT_POS=${#INPUT_BUF}
command stty rows 30 cols 110 </dev/tty || exit 1
trap 'ui_end' EXIT
ui_append_message user 'Make the terminal interface easier to read.'
ui_append_message assistant 'The renderer now uses a coordinated palette and rounded borders.'
transcript_tool_event begin write_file '{"path":"render.zsh","content":"render_row() {\n  local message=\"Hello, terminal\"\n  print -r -- \"$message\"\n}"}'
transcript_tool_event complete write_file '{}' 'Wrote render.zsh' 1
UI_BLOCK_OPEN[${#UI_ROLES}]=1
ui_append_message assistant 'Styled rows keep keyboard input and refresh ownership unchanged.'
ui_set_status Ready
ui_init || exit 1
(( ${#UI_SEGMENT_TEXTS} > 0 )) || exit 6
mapfile[$fixture_base.mode]="$UI_COLOR_MODE:$UI_BORDER_MODE:$UI_STYLED_SPANS"
mapfile[$fixture_base.rgb]="${UI_COLOR_INFO[truecolor_supported]:-0}"
mapfile[$fixture_base.clipping]="$UI_CLIPPED_SPANS"
ZCODER_SPANS=false ui_theme_init
(( UI_STYLED_SPANS == 0 && UI_CLIPPED_SPANS == 0 )) || exit 13
mapfile[$fixture_base.spans_disabled]=1
ui_theme_init
typeset -i row col
typeset -a cell before after
typeset connection_label=''
for (( col=2; col<=9; col++ )); do
  zcoder_curses move top_win 0 $col
  zcoder_curses querychar top_win cell || exit 23
  connection_label+=$cell[1]
done
if [[ $REMOTE_MODE == client ]]; then
  [[ $connection_label == *REMOTE* ]] || exit 24
  if [[ $UI_COLOR_MODE != mono ]]; then
    for col in 0 3; do
      zcoder_curses move top_win 0 $col
      zcoder_curses querychar top_win cell || exit 26
      [[ $cell[2] == "$UI_THEME_COLORS[header]/$UI_THEME_COLORS[surface]" ]] || exit 27
    done
  fi
else
  [[ $connection_label != *REMOTE* ]] || exit 25
fi
mapfile[$fixture_base.connection]=1
typeset -a fixture_spans=('bold cyan/black' 'const ' 'magenta/black' 'value ' 'white/black' '= ' 'yellow/black' '"hello"' 'white/black' '        ')
zcoder_curses addwin sample 3 50 0 0 || exit 1
if [[ $UI_COLOR_MODE == basic ]]; then
  [[ $UI_THEME_COLORS[success] != $UI_THEME_COLORS[warning] &&
     $UI_THEME_COLORS[warning] != $UI_THEME_COLORS[error] &&
     $UI_THEME_COLORS[success] != $UI_THEME_COLORS[error] ]] || exit 16
fi
if [[ $ZCODER_CURSES_COMMAND == zdraw ]]; then
  source "$fixture_root/vendor/zdraw/lib/zdraw-ui.zsh" || exit 1
  typeset -A zdraw_ui_theme zdraw_ui_style color_cell
  ui_widget_theme
  zdraw-label sample 1 1 20 'Status' normal fg=error || exit 17
  zdraw move sample 1 1
  zdraw cellinfo sample color_cell || exit 18
  if [[ $UI_COLOR_MODE == mono ]]; then
    [[ $color_cell[pair] == 0 ]] || exit 19
  else
    [[ $color_cell[color] == "$UI_THEME_COLORS[error]/$UI_THEME_COLORS[surface]" ]] || exit 20
  fi
  zdraw-ui-style selected 'fg=#ff0000' reverse || exit 21
  case $UI_COLOR_MODE in
    rgb) expected_red='#ff0000' ;;
    256) expected_red=196 ;;
    mono) expected_red=default ;;
    basic)
      expected_red=1
      if [[ $UI_COLOR_RESOLVER[encoding] == rgb && $UI_COLOR_RESOLVER[rgb_min] == 0 ]]; then
        expected_red='#800000'
      fi ;;
  esac
  [[ $zdraw_ui_style[fg] == $expected_red && $zdraw_ui_style[style] == *reverse* ]] || exit 22
  zcoder_curses clear sample
fi
mapfile[$fixture_base.colors]=1
ui_window_background sample
UI_STYLED_SPANS=0
ui_draw_row sample 1 1 48 "${fixture_spans[@]}"
for ((col=1; col<28; col++)); do
  zcoder_curses move sample 1 $col
  zcoder_curses querychar sample cell || exit 1
  before+=("${(j: :)cell}")
done
zcoder_curses clear sample
[[ $fixture_backend == auto ]] && UI_STYLED_SPANS=1
ui_draw_row sample 1 1 48 "${fixture_spans[@]}"
for ((col=1; col<28; col++)); do
  zcoder_curses move sample 1 $col
  zcoder_curses querychar sample cell || exit 1
  after+=("${(j: :)cell}")
done
[[ "${(j:|:)before}" == "${(j:|:)after}" ]] || exit 2
mapfile[$fixture_base.equivalent]=1
if [[ $fixture_backend == auto ]]; then
  # A syntax boundary can leave a combining mark at the start of a span.
  # The batch must reject it; the existing renderer still displays the row.
  ui_draw_row sample 1 1 48 'white/black' e 'white/black' $'\u0301' 'green/black' Z
  (( UI_SPAN_FALLBACKS == 1 )) || exit 3
  zcoder_curses move sample 1 1
  zcoder_curses querychar sample cell || exit 1
  [[ $cell[1] == e ]] || exit 4
  zcoder_curses move sample 1 2
  zcoder_curses querychar sample cell || exit 1
  [[ $cell[1] == Z ]] || exit 5
  mapfile[$fixture_base.fallback]=1
fi
# Exercise untrimmed rows under native clipping, old span batching, and stock
# drawing. Include both border cells in the comparison to catch any overflow.
fixture_compare_clipped() {
  local -i budget=$1 mode col clip_calls=0
  shift
  local -a modes=(0) expected=() actual=() cursor_before cursor_after
  [[ $fixture_backend == auto ]] && modes+=(1 2)
  local -i UI_STYLED_SPANS UI_CLIPPED_SPANS
  for mode in $modes; do
    UI_STYLED_SPANS=$(( mode > 0 )); UI_CLIPPED_SPANS=$(( mode == 2 ))
    zcoder_curses clear sample
    ui_attr sample -bold -dim -reverse -underline text/surface
    zcoder_curses move sample 1 0; zcoder_curses string sample '|'
    zcoder_curses move sample 1 8; zcoder_curses string sample '|'
    zcoder_curses position sample cursor_before
    clip_calls=0
    ui_draw_row sample 1 1 "$budget" "$@"
    zcoder_curses position sample cursor_after
    if (( mode == 2 && budget > 0 )); then
      (( clip_calls == 0 )) || return 7
      [[ "$cursor_before" == "$cursor_after" ]] || return 8
    fi
    actual=()
    for (( col=0; col<=8; col++ )); do
      zcoder_curses move sample 1 $col
      zcoder_curses querychar sample cell || return 1
      actual+=("${(j: :)cell}")
      if (( col == 0 || col == 8 )); then [[ $cell[1] == '|' ]] || return 9; fi
    done
    if (( mode == 0 )); then
      expected=("${actual[@]}")
    else
      [[ "${(j:|:)expected}" == "${(j:|:)actual}" ]] || return 10
    fi
  done
}
functions[fixture_original_clip]="${functions[zcoder_clip]}"
zcoder_clip() { (( clip_calls++ )); fixture_original_clip "$@"; }
for fixture_budget in 0 1 2 3 4 7; do
  fixture_compare_clipped "$fixture_budget" 'bold cyan/black' abc 'yellow/black' 'defghijk' || exit $?
  fixture_compare_clipped "$fixture_budget" 'bold cyan/black' $'e\u0301' 'green/black' 界 'yellow/black' 'Z      ' || exit $?
  fixture_compare_clipped "$fixture_budget" 'reverse bold cyan/black' 'X       ' || exit $?
done
functions[zcoder_clip]="${functions[fixture_original_clip]}"
unfunction fixture_original_clip fixture_compare_clipped
mapfile[$fixture_base.clipped_equivalent]=1
# A rejected batch must still respect its row budget when falling back.
zcoder_curses clear sample
zcoder_curses move sample 1 2; zcoder_curses string sample '|'
ui_draw_row sample 1 1 1 'white/black' e 'white/black' $'\u0301' 'green/black' Z
zcoder_curses move sample 1 1; zcoder_curses querychar sample cell
[[ $cell[1] == e ]] || exit 11
zcoder_curses move sample 1 2; zcoder_curses querychar sample cell
[[ $cell[1] == '|' ]] || exit 12
mapfile[$fixture_base.bounded_fallback]=1
zcoder_curses delwin sample
ui_invalidate
ui_refresh_all
# Export the actual curses cells, including resolved pair spelling, for visual QA.
typeset window out='' ch pair x y
typeset -a geometry
for window in top_win side_win chat_win input_win foot_win; do
  zcoder_curses position "$window" geometry || exit 1
  for ((row=0; row<geometry[5]; row++)); do
    for ((col=0; col<geometry[6]; col++)); do
      zcoder_curses move "$window" $row $col
      zcoder_curses querychar "$window" cell || exit 1
      x=$(( geometry[4]+col )); y=$(( geometry[3]+row ))
      out+="$x"$'\t'"$y"$'\t'"$cell[2]"$'\t'"$cell[1]"$'\n'
    done
  done
done
mapfile[$fixture_base.cells]="$out"
ui_end
mapfile[$fixture_base.done]=1
