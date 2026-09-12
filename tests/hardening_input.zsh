# Run after the shared UI fixtures have installed the terminal-free recorder.
_hardening_input_tests() {
  emulate -L zsh
  setopt extendedglob
  local text='' ch='' expected='' sequence='' base="$TEST_TMP/input-cells" chunk='' output=''
  local -i old_active=$UI_ACTIVE pos=0 width=0
  local -a cases=('word' 'hello world' 'hello world   ' $'hello\tworld\n' 'hello world tail')
  local -a positions=(4 11 14 12 8) results=('' 'hello ' 'hello ' $'hello\t' 'hello rld tail')
  for (( pos=1; pos<=${#cases}; pos++ )); do
    INPUT_BUF="${cases[pos]}"; INPUT_POS=${positions[pos]}
    input_kill_word
    assert_eq "${results[pos]}" "$INPUT_BUF" "Ctrl+W deletes the previous word at boundary $pos"
  done
  # Delimiters and UTF-8 survive every offset around a chunk boundary.
  for width in 250 256 259 262 1018 1024 1027 1030 2050; do
    input_reset
    text="${(pl:width::x:)}"$'界\r\nend\r'
    expected="${(pl:width::x:)}"$'界\nend\n'
    sequence=$'\e[200~'"$text"$'\e[201~'
    for ch in "${(@s::)sequence}"; do
      input_decode_terminal_event "$ch" ''
    done
    assert_eq paste "$INPUT_EVENT_ACTION" "paste delimiter survives chunk boundary $width"
    assert_eq "$expected" "$INPUT_EVENT_TEXT" "paste preserves Unicode and normalizes CRLF at $width"
    assert_eq 0 "${#INPUT_PASTE_CHUNKS}" "paste chunks are released at $width"
  done
  input_reset
  INPUT_BUF='界界界'; INPUT_POS=3; input_layout 4 4
  assert_eq '界界|界' "${(j:|:)INPUT_VISUAL_LINES}" 'wide input wraps in terminal cells'
  assert_eq 2 "$INPUT_CURSOR_ROW" 'wide input cursor follows its wrapped row'
  assert_eq 2 "$INPUT_CURSOR_COL" 'wide input cursor counts cells'
  input_move_vertical -1 4 4
  assert_eq 1 "$INPUT_POS" 'vertical movement converts target cells back to character offsets'
  INPUT_BUF=$'a\u0301b'; INPUT_POS=3; input_layout 4 4
  assert_eq 2 "$INPUT_CURSOR_COL" 'combining input consumes no extra cursor cell'
  zcoder_clip "$INPUT_BUF" 1
  assert_eq $'a\u0301' "$REPLY" 'clipping preserves a combining mark at the right edge'
  zcoder_clip $'\u0301' 0
  assert_eq $'\u0301' "$REPLY" 'zero-width syntax segments survive at the right edge'
  zcoder_pad '界a' 2
  assert_eq 界 "$REPLY" 'padding clips by display columns'
  zcoder_pad 界 1
  assert_eq ' ' "$REPLY" 'a glyph wider than the clip limit never overflows'
  zcoder_hard_wrap '界界界' 1
  assert_eq '?|?|?' "${(j:|:)ZCODER_WRAPPED}" 'one-column wrapping consumes overwide characters visibly'
  for text in '界界界' $'a\u0301b\u0301c' '🐚🐚 test'; do
    for width in 1 2 3 4; do
      zcoder_wrap "$text" "$width"
      for ch in "${ZCODER_WRAPPED[@]}"; do
        assert_success "wrapped Unicode fits $width cells" $(( ${(m)#ch} <= width ? 0 : 1 ))
      done
    done
  done
  # Count expensive layout construction, including the two UI entry points.
  functions[_hardening_real_wrap]="${functions[zcoder_hard_wrap]}"
  local -i hardening_wrap_calls=0
  zcoder_hard_wrap() { (( hardening_wrap_calls++ )); _hardening_real_wrap "$@"; }
  input_reset; INPUT_BUF='cached layout'; INPUT_POS=13
  input_layout 74 4; input_layout 74 1; input_layout 74 4
  assert_eq 1 "$hardening_wrap_calls" 'identical layout requests reuse cached geometry'
  INPUT_POS=12; input_layout 74 4
  assert_eq 2 "$hardening_wrap_calls" 'cursor movement invalidates the layout result'
  functions[zcoder_hard_wrap]="${functions[_hardening_real_wrap]}"
  unfunction _hardening_real_wrap
  input_reset

  if test_integration hardening_input; then
    local backend=''
    for backend in stock auto; do
      output=$(LC_ALL=C.UTF-8 zsh -df "$TEST_DIR/fixtures/grapheme_input.zsh" "$PROJECT_DIR" "$backend" 2>&1)
      assert_success "$backend grapheme editing checks: $output" $?
    done

    # The real curses fixture checks cursor coordinates and retained glyphs.
    zmodload zsh/zpty
    _hardening_input_pty_start() {
      trap - EXIT INT TERM
      exec zsh -f "$TEST_DIR/fixtures/input_cells_ui.zsh" "$PROJECT_DIR" "$base"
    }
    TERM=xterm-256color zpty -b input-cells _hardening_input_pty_start
    local -F deadline=$(( EPOCHREALTIME + 5.0 ))
    while (( EPOCHREALTIME < deadline )); do
      while zpty -r input-cells chunk 2>/dev/null; do output+="$chunk"; done
      [[ -f "$base.done" ]] && break
      zselect -t 1 2>/dev/null
    done
    assert_eq '2:6:界:界' "${mapfile[$base.wide]:-missing}" 'real curses wraps wide input and positions its cursor correctly'
    assert_eq '1:6' "${mapfile[$base.combining]:-missing}" 'real curses places a combining-text cursor by terminal cells'
    assert_eq 1 "${mapfile[$base.done]:-missing}" 'Unicode input fixture restores the terminal'
    zpty -d input-cells 2>/dev/null
    unfunction _hardening_input_pty_start
  fi
  UI_ACTIVE=$old_active
  input_reset
}
_hardening_input_tests
unfunction _hardening_input_tests
