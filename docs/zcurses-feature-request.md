# Feature request: dependable input, efficient rendering, and portable modern terminal support for zcurses

**Consumer:** zcoder.zsh, a Zsh-first coding agent with local and remote terminal interfaces

**Request type:** staged enhancement proposal / tracking issue

**Baseline:** zcoder v0.12.3 plus the local dependency integration; zcurses commit `52d8e844dfdcff579cddc6230583536ff8100416`

**Date:** 7 September 2026

## Request

Please evolve zcurses into a small, dependable native foundation for interactive Zsh applications: responsive input while work is running, efficient incremental drawing, predictable cursor and window lifecycles, and explicit support for modern terminal capabilities.

Our immediate priorities are capability discovery, cursor/window control, and a bounded input API. Faster styled drawing, consistent Unicode handling, and stronger colors should follow with measured benefits and clear compatibility contracts.

We would like independently reviewable extensions that remain useful beyond zcoder and suitable for eventual discussion with Zsh maintainers. All new API names and representations should be agreed during design; the descriptions below specify behavior rather than an already established interface.

## Why this matters to our application

zcoder now streams model responses, renders styled tool results, folds conversation blocks, manages multiline drafts, and opens palettes, inspectors, and command-approval dialogs. Users continue typing, pasting, navigating, and cancelling while network requests and tools run.

The project's recent work provides concrete evidence:

| Project experience | What it asks of the module |
| --- | --- |
| v0.12.0 introduced steering during active work and queued follow-ups. Multiple changes made model, MCP, command, and remote waits responsive. | Input must cooperate with an application event loop and preserve event identity. |
| v0.12.1 brought grouped transcripts, shared modals, incremental layout, changed-window rendering, and synchronized updates. | Better primitives for cursor ownership, window changes, and styled updates. |
| v0.12.2 reduced a local 100,000-character paste-decoding fixture from 16.7 seconds to 1.34 seconds. | Bulk or chunked native input deserves investigation; the numbers are historical parser measurements, not end-to-end terminal latency. |
| Cell-aware wrapping improved wide characters and combining marks, while complex emoji remain terminal-dependent. | A documented relationship between text boundaries, display cells, and actual curses rendering. |
| Native `geometry` now replaces `stty size` in due resize polls, which can run four times per second. | Small, general-purpose native primitives can remove real application overhead. |

The release evidence is recorded in the notes for [v0.12.0](https://github.com/ZaguanLabs/zcoder.zsh/blob/ef1706d00b72a1ec4660f93c934e805d34b854f0/docs/releases/v0.12.0.md), [v0.12.1](https://github.com/ZaguanLabs/zcoder.zsh/blob/ef1706d00b72a1ec4660f93c934e805d34b854f0/docs/releases/v0.12.1.md), and [v0.12.2](https://github.com/ZaguanLabs/zcoder.zsh/blob/ef1706d00b72a1ec4660f93c934e805d34b854f0/docs/releases/v0.12.2.md). These links pin the source snapshot rather than assuming every version has a release tag. The new geometry integration is local work at this proposal's baseline; its repeated-resize and UI-reentry PTY fixture confirms zero `stty` invocations with the fork.

We already batch changed windows into one `zcurses refresh`, cache transcript layout, handle bracketed paste, and negotiate synchronized output in Zsh. The module's own [design notes](https://github.com/ZaguanLabs/zcurses/blob/52d8e844dfdcff579cddc6230583536ff8100416/docs/design.md) recognize these foundations. The following requests extend them.

## 1. Capability discovery and build identity — first milestone

**Problem:** The first failed geometry query currently cannot distinguish an absent extension from a temporary terminal-query failure. That selects the stock fallback for the rest of the UI session. Deployment also involves different hosts and Zsh builds.

**Requested behavior:**

- A side-effect-free query for module version, API version, compiled features, and relevant curses-library information. It must work without initializing curses or requiring a controlling terminal.
- Separate reporting for compiled support, terminfo information, and negotiated terminal state. Preserve distinctions such as unknown, pending, unsupported, supported, and explicitly disabled.
- Stable, documented error categories that distinguish unsupported operations, invalid arguments, unavailable terminal state, and transient failure.
- Build metadata available before loading a native binary, plus a documented compatibility matrix and reproducible build instructions. Start with the supported baseline, then explicitly test Zsh 5.8 and newer target versions. A version string alone must not be presented as proof of ABI compatibility.

**Acceptance:** zcoder can choose the geometry backend without deliberately invoking an unsupported command. Headless feature inspection produces no escape sequences. A copied or incompatible build has a documented rejection/fallback path. Builds remain isolated from the system installation and require no compiler at runtime.

## 2. Explicit cursor control and reusable windows — first milestone

**Problem:** The editor, transcript, and modals share one terminal cursor. We currently restore it with terminfo output and refresh the input window last to keep its position. Layout changes destroy and recreate windows, including when a draft grows or an overlay resizes.

**Requested behavior:**

- Cursor visibility and final frame position through the module; optional cursor shape only where supported.
- A way to choose the cursor position independently of the order in which dirty windows are refreshed.
- Window move/resize operations with documented content preservation, clipping, child-window constraints, invalidation, and failure behavior.
- Clear terminal suspension/resumption semantics for our plain-text transcript copy view, including restoration of modes the module enabled.

The application will continue to decide focus, layout, and overlay ownership.

**Acceptance:** repeated shrink/grow cycles, changing draft height, and opening/dismissing overlays preserve draft text, scroll position, and selection. The cursor does not jump into background output. Invalid geometry fails predictably without silently losing a usable window. Normal exit, handled interruption, and suspend/resume restore owned terminal state; document recovery limitations for uncatchable termination.

## 3. Bounded structured input with modern keyboard support — highest interaction priority

**Problem:** Input currently crosses curses decoding, a terminal-reply filter, and an application escape/paste parser. We need reliable modified keys and large pastes while also servicing network activity. A protocol reply or pasted newline must never become an approval or submit action.

**Requested behavior:**

- An opt-in event API with distinct text, key, paste, mouse, focus, and resize events. Include modifiers and, when available, press/repeat/release information.
- Explicit input ownership: legacy input remains compatible, while mixing decoders on the same terminal is either supported by one shared queue or rejected clearly.
- Nonblocking reads and reads with a total deadline, including partial escape decoding and signal retries. Distinguish no event, timeout, interruption, EOF, and error.
- Expose queued-event readiness and pending decoder deadlines so callers can integrate with `zselect` and their existing scheduling. Readiness must account for already buffered input, not only the terminal file descriptor.
- Configurable Escape disambiguation. The ncurses documentation describes this as a separate timing concern from ordinary input waiting; a window timeout alone should not be advertised as a complete latency bound. See [ncurses input semantics](https://invisible-island.net/ncurses/man/curs_getch.3x.html).
- Incremental paste delivery with begin/chunk/end semantics or an equivalent bounded representation. Specify size limits, overflow recovery, malformed input handling, and exact text preservation. Pasted text stays data.
- Negotiated modern keyboard support, with legacy fallback and balanced mode restoration. The [kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/) provides progressive enhancement, modifier information, event types, and state push/pop; support should be explicit rather than inferred from terminal names.

**Acceptance:** Enter and Shift+Enter remain distinguishable where the terminal supports them, while Alt+Enter remains usable on legacy terminals. Escape cancellation remains responsive during fragmented sequences and large pastes. Delayed capability replies never type into drafts or accept dialogs. Unsupported protocols do not disrupt ordinary keys. Input reads do not unexpectedly present an unfinished frame.

Use delayed-byte PTY fixtures to verify configured deadlines, and benchmark the complete paste path separately from decoder throughput. Establish latency budgets on a named reference machine before implementation; report tail latency as well as medians.

## 4. Efficient styled drawing — profile, then extend

**Problem:** Cached layout avoids rebuilding old transcript content, but an invalidated chat window still requires many Zsh calls for moves, attributes, clipping, and strings. Suppressing unchanged terminal bytes does not eliminate that shell work.

**Requested behavior:**

- Investigate structured row/span updates or a drawing batch that reduces shell-to-module calls. Pass arrays and literal text, never executable command strings.
- Specify clipping, attribute lifetime, cursor advancement, and invalid-operation reporting. Validate a batch before mutation where possible and document any partial-failure behavior.
- Reuse ncurses' screen representation and physical-screen comparison. Keep the existing multi-window refresh as the presentation boundary.
- Provide a benchmark/example comparing existing calls, application-side changed-row caching, and any proposed native batch.

**Acceptance:** on a 1,000-entry transcript, an update to the active response does not reprocess unchanged history. Compare identical final screens and report shell/module call counts, CPU time, input latency, terminal bytes, and retained memory independently. A new batch API should demonstrate an advantage over the smaller application-side optimization.

## 5. Consistent text measurement and editing boundaries

**Problem:** Display-cell counts are essential for wrapping and cursor placement, but code-point boundaries are insufficient for some visible characters.

**Requested behavior:** assess native measurement, clipping, and text-boundary helpers that agree with the renderer. Define units explicitly: bytes, code points, grapheme clusters, and terminal columns. Report the Unicode version and ambiguous-width policy, and document unsupported shaping cases.

[Unicode UAX #29](https://www.unicode.org/reports/tr29/) defines grapheme segmentation. Segmentation and terminal display width need separate contracts; neither alone guarantees correct emoji rendering across terminals. If full support requires a new Unicode library or substantial rendering changes, present that dependency and maintenance tradeoff before implementation.

**Acceptance:** test combining accents, CJK, variation selectors, flags, skin-tone modifiers, ZWJ sequences, tabs, and malformed input. Clipping must preserve supported text boundaries; editing helpers must return positions the Zsh application can use without guessing. Publish known differences between the helper, curses, and terminal.

## 6. Stronger colors with predictable degradation

**Problem:** The baseline module uses `short` color/pair identifiers and `init_pair`. Richer syntax highlighting and long sessions need explicit resource limits and failure behavior before adding more colors.

**Requested behavior:** audit identifier ranges, support appropriate extended-color interfaces when available, preserve default foreground/background semantics, and provide bounded color-pair allocation. Never silently recycle a pair still used by retained cells. Report exhaustion and supported color modes.

Truecolor should be exposed only when the curses/library/terminal path can render it correctly. The [ncurses color API](https://invisible-island.net/ncurses/man/curs_color.3x.html) documents color and pair constraints; arbitrary SGR escapes inside window text do not establish retained rendering support.

**Acceptance:** repeated theme changes and diverse highlighted content do not recolor older cells or cause unbounded allocation. Test monochrome, limited-color, 256-color, and supported extended-color configurations. The application retains control of themes, contrast, reduced motion, and text labels that remain understandable without color.

## 7. Selective terminal protocols after the foundations

These are useful follow-ups, with explicit owners and opt-in behavior:

- **Synchronized output:** move it into the module only if that simplifies ownership and cleanup. We already implement [mode 2026](https://contour-terminal.org/vt-extensions/synchronized-output/); any replacement must close frames before waiting and disable them on cleanup.
- **Mouse and focus:** normalized wheel/button/modifier events and focus changes can improve navigation and reduce unnecessary background animation. Mouse capture must be optional so terminal selection remains usable.
- **Clipboard copy:** an explicit user-invoked clipboard operation could complement our plain-text copy view. Define payload limits, support/failure reporting, and behavior through multiplexers. Clipboard reads and automatic writes are outside this request.
- **Hyperlinks:** investigate clickable file and URL spans only with a design for retained link identity, clipping, scrolling, and redraw. Validate protocol data and provide a plain-text fallback.

Inline images, application widgets, Markdown parsing, syntax grammars, fuzzy search, agent concepts, and tool dispatch are outside the initial module scope.

## Delivery and verification

Suggested delivery order:

1. Capability/error contract, build metadata, cursor control, and focused window operations.
2. A bounded structured event API, followed by keyboard negotiation and chunked paste.
3. Measured drawing improvements, text helpers, and color-resource handling as separate proposals.
4. Optional protocols with demonstrated application value.

Each feature should ship with a minimal Zsh example independent of zcoder, API documentation, legacy regression tests, and failure-path tests. Keep existing `zcurses` commands working. Our Zsh application must retain its stock-module fallback and keep headless operation independent of terminal initialization. Preserve the native Zsh/curses runtime model; discuss any additional runtime library before adopting it. Include at least one modest machine in performance checks because deployment includes older hardware.

Use automated PTY tests for fragmentation, resizing, deadlines, and lifecycle behavior. Add manual checks in actual terminal emulators, over SSH, and inside tmux, including unsupported and unanswered capability queries. PTYs alone cannot establish correct rendering, shaping, or multiplexer behavior. Publish which Zsh versions, operating systems, and curses configurations were actually exercised.

The first milestone would be useful even without the later features: zcoder could identify support reliably, place the cursor deliberately, and adapt windows with less reconstruction. The next milestone would address the most consequential interaction boundary: accepting user input predictably while the application is busy.
