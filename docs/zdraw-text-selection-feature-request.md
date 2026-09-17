# Feature request: mouse text selection confined to a pane

**Consumer:** zcoder.zsh v0.17.4
**Dependency baseline:** zdraw `c86877608f4882b2e1fccc1c89335dbff4ea3b1d`
**Observed terminal:** Kitty
**Status:** proposal for a bounded, reusable selection component

## Request

Please provide mouse-driven text selection constrained to an application-defined
content rectangle. In zcoder, that rectangle is the interior of the chat pane.
A user should be able to drag across several chat lines and copy their text
without selecting the sidebar, borders, input prompt, or footer—even when the
pointer moves outside the chat pane during the drag.

**Confinement must apply to both the highlight and the extracted text.** Drawing
a clipped highlight is insufficient if copying still includes adjacent columns.

The region is rectangular; selection follows normal reading order within it.
This should work for other applications' log viewers, documents, and output
panes without introducing chat concepts into zdraw.

## Current behavior and evidence

The user confirmed that Kitty's Shift + left-button drag selects text while
zcoder is running. However, that selection operates on terminal screen cells
and can include neighboring UI content. Kitty cannot infer our chat boundary.
zcoder's `/copy` avoids the problem by temporarily displaying a plain-text
transcript outside the TUI, but interrupts interaction with the chat.

Kitty's Shift-drag gesture is terminal-owned. The proposed feature needs
application-owned mouse events, such as an ordinary left-button drag; zdraw
cannot constrain a selection that Kitty handles without delivering those events.
Preserve the terminal's existing selection override as an alternative.

The pinned zdraw already supplies structured mouse events with screen
coordinates, mouse motion reporting, and `textpos` for mapping display columns
to text boundaries. This request is for their reusable composition into a
confined selection contract, plus any demonstrated missing primitive.

References:

- [Kitty mouse selection bindings](https://sw.kovidgoyal.net/kitty/conf/#mouse.Start-selecting-text-even-when-grabbed)
- [zdraw text positions and hit-testing](../vendor/zdraw/docs/native-api.md#text-positions-and-hit-testing)
- [zdraw native API](../vendor/zdraw/docs/native-api.md)
- [zcoder's current copy view](interface.md#copy-the-transcript)

## Required interaction

1. The application registers a selectable content rectangle, excluding its
   borders, title, scroll indicators, padding, and other decorations.
2. A left-button press inside selectable text establishes an anchor. A press
   outside the region does not start a selection in it.
3. Motion with the button held updates the endpoint and highlights the selected
   text. Forward and reverse drags behave consistently.
4. When the pointer leaves the region, clamp the endpoint to the nearest valid
   content boundary. The anchor remains unchanged. Crossing into a neighboring
   pane neither selects its text nor activates its controls.
5. A release anywhere within the terminal finishes the active drag, including
   a release outside the owning pane. The selection remains available to copy.
6. Escape clears the selection and restores its previous visual styling.

For example, dragging from the middle of a chat line into the sidebar and then
downward must produce only a range of chat text. The sidebar's labels must never
appear in the extracted result. The same rule applies at every edge and corner.

## Text and geometry contract

- Use explicit content geometry and screen-to-content coordinate conversion;
  do not infer the selectable region from a window's outer dimensions.
- Associate endpoints with selectable text positions, rather than retaining
  only screen coordinates. Specify zero-based offsets and exclusive range ends,
  consistently with the existing text-position APIs.
- Let the caller provide displayed text and the mapping from rendered rows to
  that text. Styled Markdown, gutter labels, and wrapping need this distinction:
  copying should follow the supplied text, not reconstruct whole terminal rows.
- Distinguish soft wraps from actual newline characters. Joining wrapped rows
  must not introduce artificial newlines, while code indentation, real line
  breaks, and meaningful spaces remain intact.
- Never return partial UTF-8 sequences or split the text units supported by the
  chosen renderer/text-position policy. Test wide CJK characters, combining
  marks, and the supported grapheme mode; document terminal-specific limitations.
- Blank area after a short line and unused rows must not contribute display
  padding. Border cells and excluded decorations must never contribute text.
- Selection styling must compose with existing spans and restore correctly on
  clear, redraw, and selection changes, including monochrome operation.

## Ownership and integration

Prefer an optional Zsh companion component built on the existing native APIs.
Keep any necessary C changes limited to reusable geometry, drawing, or input
primitives. Proposed API names and state representation should be reviewed
before becoming public interfaces.

| zdraw component | Consuming application |
| --- | --- |
| Confined selection geometry, anchor/endpoint state, and selection lifecycle | Which pane is selectable and which displayed text belongs to it |
| Highlight spans and selected ranges/text from caller-supplied content | Message boundaries, folded content, Markdown presentation, and decorations |
| Event handling that reports whether an event was consumed | Routing consumed drags so another pane cannot also act on them |
| Explicit handling of content/geometry invalidation | Streaming updates, viewport scrolling, and when to invalidate or preserve selection |
| A callable operation to retrieve selected text | The copy command, shortcut, and clipboard transport |

The application must retain its event loop and presentation boundary. The
component should consume events passed to it, without starting a second reader
or blocking model/network work. Mouse tracking must be opt-in and restored when
the component releases ownership.

Expose selected text without requiring a clipboard program. Clipboard delivery
can remain a separate application adapter. Kitty's Ctrl+Shift+C normally copies
Kitty's own selection; a zdraw highlight alone does not populate that selection.
The example must therefore explain how its explicit copy action retrieves the
application selection. Clipboard protocols are outside this initial request.

## Streaming, scrolling, and resizing

Existing selected text must not silently change because new output arrives.
Support a content revision or equivalent invalidation mechanism. zcoder can
keep a stable view while selecting and continue receiving output in the
background; the component should not dictate that scheduling policy.

For the first milestone, cancelling selection explicitly on content replacement,
scrolling, reflow, pane removal, or incompatible resize is acceptable. Preserve
it only when the caller supplies valid mappings to the updated content. Opening
a modal or losing mouse ownership must not leave an active drag behind. If a
terminal fails to report a release outside its window, provide a documented
cancel/reset path rather than assuming that release was observed.

Automatic scrolling while dragging at an edge, word/paragraph selection, and
selection spanning off-screen history can follow separately. They are not
required to demonstrate the essential pane-boundary behavior.

## Acceptance criteria

| Scenario | Required result |
| --- | --- |
| Chat beside a sidebar, above a prompt and footer | Only the chat's selectable content can be highlighted or extracted. |
| Drag across each edge and corner, then release outside the chat | Endpoint remains confined; selection finishes; neighboring controls receive no action from that drag. |
| Press outside, then move into chat | No chat selection starts. |
| Reverse drag, empty pane, short lines, and trailing blank rows | Predictable ranges, no padding leakage, no stale selection. |
| Wrapped prose and indented multiline code | Extracted text matches supplied logical text, preserving real breaks and indentation. |
| CJK, combining accents, and supported grapheme sequences | Boundaries agree with the documented rendering policy; output remains valid UTF-8. |
| Streaming append, scrolling, resize, modal open, or pane removal | Selection is preserved through valid mappings or explicitly cleared; it never points at unrelated content. |
| Clear and redraw in color and monochrome | Original styles return and highlighting stays within the content rectangle. |
| Mouse capability unavailable or selection disabled | Existing input and drawing remain usable; the application can retain `/copy` or another fallback. |

Ship a standalone two-pane example with borders, a footer, wrapped prose, and
code. Show the extracted selection separately so text leakage is visible,
without depending on zcoder or a system clipboard utility. Add automated range
and event-sequence tests, plus PTY checks for routing and lifecycle behavior.
Manually verify the example in Kitty: PTY tests alone cannot establish correct
mouse interaction and visible selection. Record versions and configuration when
comparing it with Kitty's native selection or another pane-aware implementation.

Measure drag responsiveness on short and long documents. Selection updates
should work from retained text/layout information rather than rebuilding the
entire document for each motion event. Keep compatibility with Zsh 5.8+ and the
existing dependency model; discuss any additional runtime requirement first.

**First deliverable:** a reusable component and small example proving that both
highlighting and text extraction remain confined to one pane. This proposal
does not authorize broader roadmap progression or add an application framework.
