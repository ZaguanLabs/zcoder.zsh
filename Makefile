.PHONY: check test model-eval

check:
	zsh -n zcoder.zsh chat.sh lib/*.zsh tests/*.zsh

test: check
	zsh tests/run.zsh

model-eval: check
	zsh tests/model_eval.zsh
