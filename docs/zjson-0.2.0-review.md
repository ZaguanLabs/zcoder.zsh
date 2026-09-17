# zjson 0.2.0 integration and measurements

Measured on 2026-09-17. The dependency moves from `2f9b6d3` to release
`05c6c7115a5543f5c1ca91d352460940560afae7`.

The upgrade improves the small ASCII documents common in Ollama traffic. It
also strengthens UTF-8 validation, with a measurable cost for large Unicode
strings. It is not a uniform speed improvement.

## Integration

- Added explicit trailing-comma checks to the 23 application container loops
  in JSON, MCP, compaction, agent-response classification, and delegate parsing.
  The new grammar-neutral tokenizer no longer performs these checks for callers.
  Without this adaptation, inputs such as `{"x":1,}` and
  `{"message":{"content":"hello",}}` were accepted. Rejection preserves the
  upstream error text, code, and byte-based location.
- Adopted `zjson_parse` in `_mcp_json_string`. The helper now requires a complete
  JSON string, rejects trailing content, and releases the tokenizer byte array.
- Added `lib/encode.zsh` to dependency completeness checks and updated the
  incomplete-checkout regression.
- Added `tests/json_upgrade.zsh` and a standalone `tests/benchmark_json.zsh`.

## Performance

Linux x86_64, Zsh 5.9.2, C.UTF-8. Each run uses two warmup batches and seven
measured batches. Small operations repeat within each batch; times below are
milliseconds per operation. Both versions use the same adapted application
parsers. Two comparisons ran in opposite version order, without concurrent test
suites. Ranges below span the two run medians, not confidence intervals.
These are local microbenchmarks, excluding Ollama, network, and terminal time.

| Workload | Previous revision | 0.2.0 |
| --- | ---: | ---: |
| Ollama stream chunk | 0.526–0.532 | 0.480–0.490 |
| Ollama tool response | 1.507–1.551 | 1.399–1.443 |
| Flat tool arguments | 0.394–0.404 | 0.360–0.370 |
| Quote 16,384 `é` characters | 3.805–3.828 | 4.434–4.997 |
| Validate the same Unicode string | 6.569–6.620 | 7.182–7.231 |
| Raw capture, 500 fields | 64.289–65.138 | 61.181–62.066 |
| Compact capture, 500 fields | 88.662–89.740 | 85.840–87.414 |
| Object decode, 500 fields | 65.791–67.753 | 65.893–66.270 |

Stream chunks improve about 7–10%; tool responses about 4–10%. Unicode quoting
costs about 16–31% more and validation about 9% more. Wide-object decoding is
roughly unchanged. Compact capture improves only modestly in this workload;
the join-once change does not produce a large measured gain here.

A separate C-locale comparison used identical payload bytes. Unicode quoting
measured 9.417 → 9.646 ms and validation 12.137 → 12.527 ms, much smaller
relative changes than the UTF-8-locale quoting regression. Stream parsing was
essentially unchanged (0.512 → 0.513 ms). Locale materially affects these results.

In 0.2.0, three separate Pointer lookups take 4.146–4.324 ms; one multi-Pointer
lookup takes 1.757–1.812 ms, about 2.4 times faster. The existing single-pass
Ollama codec takes only 1.399–1.443 ms while also extracting tool calls.

Object callbacks take 333.548–335.413 ms for 500 fields, versus
65.893–66.270 ms for object decoding. Callback context preservation copies the
outer parser state for each member. Retain direct parsing on these hot paths.

Reproduce against a clean source snapshot without changing the submodule:

```zsh
baseline=$(mktemp -d)
git -C vendor/zjson archive 2f9b6d3 | tar -x -C "$baseline"
ZJSON_BENCH_ROOT="$baseline" LC_ALL=C.UTF-8 zsh -df tests/benchmark_json.zsh
LC_ALL=C.UTF-8 zsh -df tests/benchmark_json.zsh
```

## API opportunities and limits

- **Multi-Pointer lookup:** useful when several required paths would otherwise
  reparse one document. Missing or ambiguous paths fail the entire operation.
  Ollama and MCP envelopes have optional fields, so replacing their codecs
  wholesale would change semantics or require fallback parsing.
- **Source-order keys and duplicate reporting:** useful for future configuration
  editing and precise duplicate-key diagnostics. Existing last-value-wins
  behavior remains unchanged by this integration.
- **Typed encoding:** reduces manual punctuation for new code, but the container
  type tags currently do not enforce the root type. On this pinned release,
  `zjson_encode_value 42 '{'` succeeds and returns `42`. Callers requiring an
  object or array must check its root type separately. No vendor fix is included.
- **Callbacks:** convenient for small collections and nested parsing. They run
  before validation of the entire document completes; do not dispatch tools
  directly from a callback while parsing untrusted arguments.
- **Byte-array release:** successful upstream whole-document APIs now clear
  `ZJSON_CHARS`. Custom token consumers retain their existing lifecycle; the
  release does not automatically change memory retention in every zcoder codec.

## Verification

- `make compile` and `make test`: 3,741 assertions, all integration groups run.
- Upstream suite: 14,208 checks, zero failures for each combination of actual
  Zsh 5.8 / 5.9.2 and C / C.UTF-8.
- Actual Zsh 5.8: all application and dependency libraries compile; the 72 new
  application regression assertions pass in each locale.

Compilation with the installed Zsh alone is not evidence of 5.8 compatibility;
the separate 5.8 interpreter was used for those checks.
