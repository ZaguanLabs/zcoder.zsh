# Transcript Markdown is testable with either curses backend, without Ollama.
transcript_reset
STATE_ENABLED=0
UI_ACTIVE=1; UI_FOCUS=input
SCREEN_H=24; SCREEN_W=42; SIDE_W=0; TOP_H=3; INPUT_H=3; FOOT_H=1
markdown_sample=$'The current version is **0.14.4**, as defined in `zcoder.zsh` at line 11:\n\n```zsh\ntypeset -gr ZCODER_VERSION="0.14.4"\n```'
ui_append_message assistant "$markdown_sample"
ui_render_messages 80
assert_contains "${(F)UI_LINES}" 'version is 0.14.4, as defined in zcoder.zsh' "assistant replies render inline Markdown from the screenshot"
assert_not_contains "${(F)UI_LINES}" '```' "fenced code uses a language label instead of backtick markers"
markdown_pairs=''
for (( markdown_index=1; markdown_index<=${#UI_SEGMENT_TEXTS}; markdown_index++ )); do
  markdown_pairs+="${UI_SEGMENT_TEXTS[markdown_index]}:${UI_SEGMENT_ATTRS[markdown_index]}"$'\n'
done
assert_contains "$markdown_pairs" '0.14.4:bold white/black' "Markdown strong emphasis reaches the styled row spans"
assert_contains "$markdown_pairs" 'zcoder.zsh:yellow/black' "inline code has distinct styling"
assert_contains "$markdown_pairs" 'typeset:bold magenta/black' "fenced Zsh code reuses the syntax highlighter"
assert_eq "$markdown_sample" "${UI_CONTENTS[1]}" "Markdown rendering preserves stored model content"
ui_plain_transcript
assert_contains "$REPLY" "$markdown_sample" "copying the transcript preserves original Markdown and code fences"

UI_CONTENTS=($'## Heading\nUse *emphasis* and __bold__.\nfile_name_part and \\*literal\\* and `**code**`\n`` `backtick` ``\n***Both***')
ui_render_messages 80
assert_contains "${(F)UI_LINES}" '  Heading' "ATX headings omit their Markdown prefix"
assert_not_contains "${(F)UI_LINES}" '## Heading' "ATX heading markers stay out of rendered text"
assert_contains "${(F)UI_LINES}" 'file_name_part and *literal* and **code**' "identifiers, escaped punctuation and code spans remain literal"
assert_contains "${(F)UI_LINES}" '`backtick`' "multi-backtick spans preserve embedded backticks"
assert_contains "${(F)UI_SEGMENT_ATTRS}" 'underline white/black' "single emphasis uses portable underline styling"
assert_contains "${(F)UI_SEGMENT_ATTRS}" 'underline bold white/black' "triple emphasis retains both styles"

# Open syntax remains readable while tokens arrive; rerendering closes it.
UI_CONTENTS=('A **partial')
UI_STREAM_INDEX=1
ui_render_messages 40
assert_contains "${(F)UI_LINES}" 'A **partial' "streaming unmatched emphasis remains visible"
UI_CONTENTS=('A **partial response**')
transcript_changed 1
ui_draw_chat
assert_not_contains "${(F)UI_LINES}" '**' "incremental transcript updates apply newly completed emphasis"
UI_CONTENTS=($'```zsh\nprint "**literal**"\n~~~\n```\nAfter **code**')
ui_render_messages 40
assert_contains "${(F)UI_LINES}" 'print "**literal**"' "fenced code never interprets inline Markdown"
assert_contains "${(F)UI_LINES}" '~~~' "a different fence marker cannot close a code block"
assert_contains "${(F)UI_LINES}" 'After code' "closing a fence restores inline prose formatting"
UI_CONTENTS=($'~~~~unknown\n  opaque **code**\n~~~\n~~~~')
ui_render_messages 40
assert_contains "${(F)UI_LINES}" '  opaque **code**' "unknown fenced languages preserve indentation and content"
assert_contains "${(F)UI_LINES}" '~~~' "a shorter fence cannot close a longer opening fence"

# Exercise the actual row/span contract, including whitespace discarded by
# word wrapping and zero-width combining marks at style boundaries.
UI_CONTENTS=('**one two three four 界 é five six** and `seven eight`')
for markdown_width in 12 18 40; do
  ui_render_messages "$markdown_width"
  markdown_bold=''
  for (( markdown_row=1; markdown_row<=${#UI_LINES}; markdown_row++ )); do
    markdown_start=${UI_LINE_SEGMENT_STARTS[markdown_row]}
    markdown_count=${UI_LINE_SEGMENT_COUNTS[markdown_row]}
    (( markdown_count )) || continue
    markdown_row_text=''
    for (( markdown_index=markdown_start; markdown_index<markdown_start+markdown_count; markdown_index++ )); do
      markdown_row_text+="${UI_SEGMENT_TEXTS[markdown_index]}"
      [[ "${UI_SEGMENT_ATTRS[markdown_index]}" == 'bold white/black' ]] && markdown_bold+="${UI_SEGMENT_TEXTS[markdown_index]}"
    done
    assert_eq "${UI_LINES[markdown_row]}" "$markdown_row_text" "Markdown spans reproduce the complete visible row at width $markdown_width"
    (( ${(m)#markdown_row_text} <= markdown_width ))
    assert_success "styled Markdown fits the terminal cell budget" $?
  done
  assert_eq 'onetwothreefour界éfivesix' "${markdown_bold// /}" "bold styling survives every wrap boundary"
done

UI_CONTENTS=($'**safe**\e]52;c;injected\a')
ui_render_messages 80
assert_not_contains "${(F)UI_SEGMENT_TEXTS}" $'\e' "Markdown spans expose terminal controls instead of emitting them"
UI_ROLES=(user); UI_CONTENTS=('Keep **literal** and `code`')
ui_render_messages 80
assert_contains "${(F)UI_LINES}" 'Keep **literal** and `code`' "user prompts retain their literal input"
UI_ROLES=(codex_worker)
ui_render_messages 80
assert_contains "${(F)UI_LINES}" 'Keep literal and code' "external model replies use the same Markdown renderer"
transcript_reset
