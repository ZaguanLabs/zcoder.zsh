.DEFAULT_GOAL := all
.PHONY: all setup native json check test test-fast test-visual benchmark model-eval compile clean curses markdown

all: native compile

setup: all

native: export MAKE := $(MAKE)
native: check
	zsh -df scripts/setup-native.zsh

json:
	zsh -df scripts/setup-json.zsh

check: json
	zsh -fc 'for f in zcoder.zsh chat.sh lib/*.zsh scripts/*.zsh tests/*.zsh tests/fixtures/*.zsh vendor/zjson/zjson.zsh vendor/zjson/lib/*.zsh; do zsh -n "$$f" || exit $$?; done'

# Advanced builds for an installed shell retain the explicit source-tree path.
ifdef ZSH_BUILD_ROOT
curses: check
	zsh -df scripts/build-curses.zsh

markdown: check
	zsh -df scripts/build-markdown.zsh
else
curses markdown: native
endif

test: check
	zsh tests/run.zsh

test-fast: check
	zsh tests/run.zsh --fast

test-visual: check
	ZCODER_REQUIRE_VISUALS=1 zsh -df tests/picker.zsh
	ZCODER_REQUIRE_VISUALS=1 zsh -df tests/document.zsh

benchmark: check
	zsh tests/benchmark.zsh

model-eval: check
	zsh tests/model_eval.zsh

# Precompile libraries to zsh wordcode (.zwc). `source` picks a .zwc up
# automatically when it is not older than its .zsh, roughly halving launch
# time; a stale .zwc is ignored, so recompiling is an optimization, never a
# correctness requirement.
compile: check
	zsh -fc 'for f in lib/*.zsh vendor/zjson/zjson.zsh vendor/zjson/lib/*.zsh; do zcompile -R "$$f" || exit $$?; done'

clean:
	rm -f lib/*.zwc vendor/zjson/*.zwc vendor/zjson/lib/*.zwc
