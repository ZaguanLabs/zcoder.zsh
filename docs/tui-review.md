# TUI review, 2026-09-10

This review checked the concerns about event-loop density, terminal modes,
Unicode, and shared overlay state against the current implementation and tests.

| Concern | Finding |
| --- | --- |
| Large `main_tui()` | The function is 170 lines, including startup, background polling, and keyboard dispatch. It does mix responsibilities, and sidebar session navigation repeats logic. That is maintenance debt, but function length alone does not establish a defect or a performance problem. |
| Terminal state | Resize, bracketed paste, and synchronized output are already managed in dedicated helpers. Tests exercise real curses lifecycle reentry, terminal-mode restoration, fragmented capability replies, and balanced frames after refresh failure. A stock-curses modal paste defect was reproduced and fixed below. |
| Wide characters | Clipping and editor layout count display cells; existing tests cover wide CJK characters and combining marks. Whole-grapheme clipping of joined emoji remains a documented limitation. Those are different levels of Unicode support. |
| Shared overlay window and dynamic scope | `ui_modal_run` rejects nested ownership, validates callback functions, owns modal locals, and releases the window and restores the underlying view in an `always` block. Dynamic scope is an intentional native Zsh callback contract. It requires care when adding handlers, but sharing the window is not itself evidence of broken ownership. |

## Reproduced defect: paste escaped its modal

In a real stock-curses PTY, sending a bracketed paste containing `y` and Enter
while an approval was open caused the dialog to return denial immediately.
Part of the paste, including delimiter text, then appeared in the editor
underneath. No command was executed by the fixture. The approval failed closed;
the defect was premature dismissal and input reaching the wrong owner.

The terminal filter recognized the opening paste delimiter but replayed its
bytes into ordinary character callbacks. Unlike the editor, modal callbacks
interpreted its initial Escape as cancellation. Bundled zdraw already supplies
separate paste events, and the existing real approval paste test covered only
that backend.

Modal input now requests paste discard from the shared terminal filter. The
filter consumes both delimiters and the payload, retaining only a six-character
delimiter tail. It also suppresses decoded navigation/Enter keys during that
paste, while allowing resize events. The discard decision stays attached to
the in-progress stream if modal ownership ends before the paste does; the next
input owner receives ordinary keystrokes only after the closing delimiter.
Editor paste keeps its existing behavior.

Regression coverage adds:

- a shared picker receiving pasted navigation, Enter, and Escape, followed by
  deliberate Enter, with its selection and the underlying draft preserved;
- fragmented paste, decoded keys, resize, and an input-owner change before the
  closing delimiter;
- a real stock-curses approval that stays open during and after paste, then
  accepts deliberate denial and preserves subsequent Unicode multiline input.

The existing bundled-backend paste and terminal lifecycle tests run alongside
these cases. These checks cover bracketed paste; unframed pasted text has no
protocol marker distinguishing it from typing.

## Remaining maintenance work

Extracting idle keyboard dispatch and sharing sidebar navigation would be
reasonable when those behaviors next change. Preserve ordering between resize,
slash completion, paste decoding, shortcuts, and focus-specific input; a purely
cosmetic split would not improve that contract. Keep callback state documented
and modal nesting prohibited unless nested ownership is explicitly designed.

Joined-emoji segmentation remains open. Implementing it would require a
separate design decision about Unicode rules and terminal width behavior; this
review does not claim to solve it or establish support across every emulator.
