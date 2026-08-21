.PHONY: check test

check:
	zsh -n zcoder.zsh chat.sh lib/*.zsh tests/*.zsh

test: check
	zsh tests/run.zsh
