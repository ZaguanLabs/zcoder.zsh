emulate -R zsh
setopt extendedglob
zmodload zsh/terminfo zsh/mapfile zsh/datetime
typeset ZCODER_DIR=$1 result_file=$2
for lib in util json transcript input terminal ui; do source "$ZCODER_DIR/lib/$lib.zsh"; done
fail() { print -r -- "FAIL: $*" >| "$result_file"; exit 1; }
zcoder_curses_load "$ZCODER_DIR" || fail 'curses load'
zcoder_markdown_load "$ZCODER_DIR" || { print -r -- 'SKIP: native Markdown module not built (loader tests passed)' >| "$result_file"; exit 0; }
[[ $ZCODER_CURSES_COMMAND == zdraw ]] || { print -r -- 'SKIP: zdraw not built (loader tests passed)' >| "$result_file"; exit 0; }
typeset ZCODER_HOME=${result_file:h}/home ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture
typeset ZCODER_WORKSPACE=$ZCODER_DIR OLLAMA_HOST=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset ZCODER_SYNC_OUTPUT=false ZCODER_COMMAND_POLICY=ask
typeset -i STATE_ENABLED=0
stty rows 35 cols 100 </dev/tty
trap 'ui_end' EXIT
typeset sample=$'# Heading\n\n| Name | State |\n| --- | --- |\n| **Spans** | ready |\n\n- [x] done\n  - nested\n\n```zsh\ntypeset answer="yes"\n```\n\n**👩‍💻** and **e**́'
ui_append_message assistant "$sample"
ui_init || fail init
[[ $UI_MARKDOWN_BACKEND == zmdown ]] || fail "$UI_MARKDOWN_REASON"
[[ ${(F)UI_LINES} != *'**'* && ${(F)UI_LINES} != *'```'* && ${(F)UI_LINES} == *nested* ]] || fail 'Markdown layout'
[[ ${(F)UI_SEGMENT_ATTRS} == *'bold magenta/black'* ]] || fail 'code syntax colors'
[[ $UI_MARKDOWN_FALLBACKS == 0 ]] || fail 'unexpected layout rejection'
ui_plain_transcript
[[ $REPLY == *"$sample"* ]] || fail 'original Markdown lost'
typeset -A snapshot measured
typeset -i row col start count span budget
typeset -a spans
typeset readback text
zcoder_curses addwin probe 3 90 1 1 || fail window
for budget in 14 32 80; do
  ui_render_messages "$budget"
  (( ${#UI_LINE_NATIVE} == ${#UI_LINES} )) || fail 'row metadata misaligned'
  for (( row=1; row<=${#UI_LINES}; row++ )); do
    (( UI_LINE_NATIVE[row] )) || continue
    spans=(); start=$UI_LINE_SEGMENT_STARTS[row]; count=$UI_LINE_SEGMENT_COUNTS[row]
    for (( span=start; span<start+count; span++ )); do
      spans+=("$UI_SEGMENT_ATTRS[span]" "$UI_SEGMENT_TEXTS[span]")
    done
    (( ${#spans} )) || spans=("$UI_ATTRS[row]" "$UI_LINES[row]")
    zcoder_curses clear probe
    ui_markdown_draw_row probe 0 1 "$budget" "${spans[@]}" || fail draw
    zcoder_curses textinfo measured "$UI_LINES[row]" "$budget" "$UI_MARKDOWN_POLICY" || fail measure
    zcoder_curses snapshot probe snapshot occupancy || fail snapshot
    readback=''
    for (( col=1; col<=measured[width]; col++ )); do
      [[ $snapshot[0,$col,occupancy] == continuation ]] || readback+=$snapshot[0,$col,text]
    done
    [[ $readback == "$UI_LINES[row]" ]] || fail "retained row at $budget: $readback"
    if [[ $UI_LINES[row] == '  👩‍💻'* ]]; then
      [[ $snapshot[0,3,attributes] == bold ]] || fail 'emoji base lost strong style'
    fi
  done
done
(( UI_MARKDOWN_FALLBACKS == 0 )) || fail 'draw fallback'
UI_CONTENTS=('A **partial'); ui_render_messages 74
UI_CONTENTS=('A **partial response**'); transcript_changed 1; ui_draw_chat
[[ ${(F)UI_LINES} == *'partial response'* && ${(F)UI_LINES} != *'**'* ]] || fail streaming
(( ${#UI_LINE_NATIVE} == ${#UI_LINES} )) || fail 'stream metadata'
UI_CONTENTS=($'valid\n\na\u0301\u0301\u0301\u0301\u0301'); ui_render_messages 74
(( UI_MARKDOWN_FALLBACKS > 0 )) || fail 'native cell limit not rejected'
[[ ${(F)UI_LINES} == *'\u{0301}'* && ${UI_LINE_NATIVE[(Ie)1]} == 0 ]] || fail 'partial native publication or lost combining marks'
UI_CONTENTS=($'\u0301leading'); ui_render_messages 74
[[ ${(F)UI_LINES} == *'\u{0301}'* ]] || fail 'leading zero-width input'
# Module errors publish only the fallback, even following a successful message.
zmdown() { return 1; }
UI_CONTENTS=('**still readable**'); ui_render_messages 74
[[ ${(F)UI_LINES} == *'still readable'* && ${UI_LINE_NATIVE[(Ie)1]} == 0 ]] || fail 'module failure fallback'
unfunction zmdown
ZCODER_MARKDOWN=zsh ui_markdown_init
ui_render_messages 74
[[ $UI_MARKDOWN_BACKEND == zsh && ${UI_LINE_NATIVE[(Ie)1]} == 0 ]] || fail 'backend change reused native rows'
# Force a draw rejection without changing the real stored row or text.
UI_MARKDOWN_POLICY=unsupported
ui_markdown_draw_row probe 0 1 30 white/black $'a\u0301'
zcoder_curses snapshot probe snapshot occupancy
[[ $snapshot[0,2,text] == '\' ]] || fail 'draw rejection retried unsafe Unicode'
ui_end
trap - EXIT
print -r -- 'PASS: native Markdown loader, layout, retained cells, reflow, streaming, copying and rejection' >| "$result_file"
