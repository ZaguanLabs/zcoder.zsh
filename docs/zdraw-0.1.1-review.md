# zdraw 0.1.1 verification

Reviewed on 2026-09-17. Updated `vendor/zdraw` from `64263c7` (v0.1.0)
to `fc05998` (v0.1.1), following the [previous review](zdraw-0.1.0-review.md).

## Changes under review

The release addresses both reported issues:

- The build patch now uses context shared by Zsh 5.8 and 5.9.2. Native parameter
  results use a private, permanent deep-copy conversion instead of the newer
  two-argument `zlinklist2array` API.
- Selection remembers a gesture that began outside selectable text. Repeated
  `PRESSED1` motion cannot establish an inside anchor before release, including
  when the layout is replaced during the gesture. These events remain available
  to the pane that owns the gesture.

The underlying selection API remains experimental. zcoder 0.18.0 now integrates
it with a retained chat projection, shared input routing, confined highlighting,
streaming-view pause, and explicit clipboard copying. See
[Select and copy chat text](interface.md#select-and-copy-chat-text) for the shipped
behavior and limits. The dependency checks below preceded that integration;
the release notes record the application validation.

## Build setup

Used separate build directories for Zsh 5.8 and 5.9.2, and each matching built
shell for syntax checks and native/PTY tests. The 5.8 build uses the unchanged
release sources at `/tmp/zcoder-zmdown-review-58/.source/zsh-5.8`, with the
documented compiler flags:

```sh
export CFLAGS='-O2 -std=gnu17 -Wno-error=implicit-int -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types'
export zsh_cv_sys_tcsetpgrp=yes
```

The cache answer is appropriate to this Linux host; it is not a portability
claim for other systems. No temporary source or patch adaptations from the
v0.1.0 investigation are used. The exported integration patch applies to the
5.8 source tree with `patch --dry-run --fuzz=0 -p1`.

## Results

- Native builds passed on actual Zsh 5.8 and 5.9.2, with matching modules.
  Both expose the same 48 compiled feature flags.
- zcoder `make native` and `make compile` passed.
- Full upstream `make test`, including matching-shell syntax checks:

  | Matching shell | Result | Duration |
  | --- | --- | ---: |
  | Zsh 5.8 | 174 passed, no failures or skips | 306.852 s |
  | Zsh 5.9.2 | 174 passed, no failures or skips | 353.985 s |

- All five selection tests passed on each version, including the outside-origin
  repeated-press regression, layout replacement during the gesture, native
  styling, and real encoded mouse events through a PTY.
- zcoder `make test`: **3,741 assertions passed**, 87.434 seconds, no omitted
  integration groups. Document Escape closure remained at 0.213–0.215 seconds.

Both issues from the v0.1.0 review are resolved in these checks. No new failure
was found. This verifies Linux/ncurses with PTYs; it does not repeat the earlier
real Kitty pointer observations or establish other operating-system support.
