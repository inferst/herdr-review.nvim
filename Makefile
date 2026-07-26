PLENARY_PATH ?= deps/plenary.nvim
NVIM ?= nvim

.PHONY: test lint format format-check check

test:
	test -d "$(PLENARY_PATH)"
	PLENARY_PATH="$(PLENARY_PATH)" $(NVIM) --headless -u tests/minimal_init.lua -i NONE -n -c 'PlenaryBustedDirectory tests { minimal_init = "tests/minimal_init.lua" }'

lint:
	luacheck lua tests

format:
	stylua lua tests

format-check:
	stylua --check lua tests

check: format-check lint test
