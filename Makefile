# Convenience targets. CI runs the same checks (see .github/workflows/ci.yml).

SHELL       := /usr/bin/env bash
SCRIPTS     := $(shell find scripts -name '*.sh')
PREFIX      ?= /opt/linux-admin-lab
SHELLCHECK  ?= shellcheck
BATS        ?= bats

.PHONY: help lint test check install-timer

help:
	@echo "make lint           ShellCheck + bash -n on all scripts"
	@echo "make test           run the bats test suite"
	@echo "make check          lint + test"
	@echo "sudo make install-timer   install scripts to $(PREFIX) and enable the health-check timer"

lint:
	$(SHELLCHECK) -x $(SCRIPTS) tests/test_helper.bash
	@for f in $(SCRIPTS); do bash -n "$$f" || exit 1; done
	@echo "lint OK"

test:
	$(BATS) tests/

check: lint test

install-timer:
	install -d -m 0755 $(PREFIX)/scripts/lib
	install -m 0755 scripts/*.sh $(PREFIX)/scripts/
	install -m 0644 scripts/lib/common.sh $(PREFIX)/scripts/lib/
	install -m 0644 systemd/health-check.service systemd/health-check.timer /etc/systemd/system/
	[ -f /etc/default/health-check ] || install -m 0644 systemd/health-check.default /etc/default/health-check
	systemctl daemon-reload
	systemctl enable --now health-check.timer
	systemctl list-timers health-check.timer
