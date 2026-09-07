.PHONY: check test benchmark model-eval compile clean

check:
	zsh -fc 'for f in zcoder.zsh chat.sh lib/*.zsh tests/*.zsh tests/fixtures/*.zsh; do zsh -n "$$f" || exit $$?; done'

test: check
	zsh tests/run.zsh

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
