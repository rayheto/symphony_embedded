.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e release release-assemble workbench-shots

MIX ?= mix

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, release, workbench-shots, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

# A release bundle. Burrito's wrap step needs `zig` and `xz`; when this host has
# neither, `release-assemble` still produces a runnable release directory. See
# docs/operations/README.md.
release:
	MIX_ENV=prod $(MIX) release symphony --overwrite

release-assemble:
	BURRITO_SKIP_WRAP=1 MIX_ENV=prod $(MIX) release symphony --overwrite

# Photograph the workbench at the Soft Glass reference viewport. Needs a browser
# on PATH; the frames are visual-acceptance evidence, not a test.
workbench-shots:
	./scripts/workbench-shots.sh $(SHOTS_DIR)

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
