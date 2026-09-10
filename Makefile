.PHONY: check test test-visual benchmark model-eval compile clean curses

check:
	zsh -fc 'for f in zcoder.zsh chat.sh lib/*.zsh scripts/*.zsh tests/*.zsh tests/fixtures/*.zsh; do zsh -n "$$f" || exit $$?; done'

# Requires an initialized submodule and ZSH_BUILD_ROOT for this host's Zsh ABI.
curses: check
	zsh -df scripts/build-curses.zsh

test: check
	zsh tests/run.zsh

test-visual: check
	ZCODER_REQUIRE_VISUALS=1 zsh -df tests/picker.zsh

benchmark: check
	zsh tests/benchmark.zsh

model-eval: check
	zsh tests/model_eval.zsh

# Precompile libraries to zsh wordcode (.zwc). `source` picks a .zwc up
# automatically when it is not older than its .zsh, roughly halving launch
# time; a stale .zwc is ignored, so recompiling is an optimization, never a
# correctness requirement.
compile: check
	zsh -fc 'for f in lib/*.zsh; do zcompile -R $$f; done'

clean:
	rm -f lib/*.zwc
