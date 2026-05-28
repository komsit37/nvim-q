# nvim-q Makefile
# Requires: nvim, plenary.nvim (at ~/.local/share/nvim/lazy/plenary.nvim)

NVIM ?= nvim
PLENARY ?= $(HOME)/.local/share/nvim/lazy/plenary.nvim
REPO := $(shell pwd)

.PHONY: test spike spike-encode spike-decode spike-compress help

## Run the full test suite via plenary busted (all *_spec.lua in test/)
test:
	$(NVIM) --headless \
	  --cmd "set rtp+=$(PLENARY)" \
	  --cmd "set rtp+=$(REPO)" \
	  --cmd "runtime plugin/plenary.vim" \
	  -c "PlenaryBustedDirectory test/ {minimal_init='test/minimal_init.lua', pattern='_spec'}" \
	  -c "qa"

## Run a single spec file quickly
test-encode:
	$(NVIM) --headless \
	  --cmd "set rtp+=$(PLENARY)" \
	  --cmd "set rtp+=$(REPO)" \
	  --cmd "runtime plugin/plenary.vim" \
	  -c "PlenaryBustedFile test/encode_spec.lua {minimal_init='test/minimal_init.lua'}" \
	  -c "qa"

test-decode:
	$(NVIM) --headless \
	  --cmd "set rtp+=$(PLENARY)" \
	  --cmd "set rtp+=$(REPO)" \
	  --cmd "runtime plugin/plenary.vim" \
	  -c "PlenaryBustedFile test/decode_spec.lua {minimal_init='test/minimal_init.lua'}" \
	  -c "qa"

test-integration:
	$(NVIM) --headless \
	  --cmd "set rtp+=$(PLENARY)" \
	  --cmd "set rtp+=$(REPO)" \
	  --cmd "runtime plugin/plenary.vim" \
	  -c "PlenaryBustedFile test/integration_spec.lua {minimal_init='test/minimal_init.lua'}" \
	  -c "qa"

## Quick spike: connect to real q, send .Q.s til 10, print result
spike:
	$(NVIM) -l test/spike.lua

## Compression investigation spike
spike-compress:
	$(NVIM) -l test/spike_compress.lua

## Decompress unit test spike
spike-decompress:
	$(NVIM) -l test/spike_compress2.lua

## Capture fresh fixtures from real q (requires q on port 5000)
fixtures:
	$(NVIM) -l test/capture_fixtures.lua

help:
	@echo "Targets:"
	@echo "  make test              -- run full plenary suite"
	@echo "  make test-encode       -- encode_spec.lua only"
	@echo "  make test-decode       -- decode_spec.lua only"
	@echo "  make test-integration  -- integration_spec.lua only"
	@echo "  make spike             -- quick real-q roundtrip spike"
	@echo "  make spike-compress    -- compression threshold probe"
	@echo "  make spike-decompress  -- decompressor unit tests"
	@echo "  make fixtures          -- recapture test/fixtures/*.bin"
