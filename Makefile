ANSIBLE_DIR := ansible
export ANSIBLE_CONFIG := $(CURDIR)/$(ANSIBLE_DIR)/ansible.cfg

# Every target runs on YOUR computer (Linux, macOS, or WSL on Windows), never on
# the Pi: Ansible reaches the Pis over SSH. Run `make` alone for this list.
.DEFAULT_GOAL := help

.PHONY: help new-pi wait-pi deps ping apply check health lint hooks test octoprint-backup molecule-image molecule

# Container engine for the Molecule tests: Docker if installed, else Podman
# (Fedora). Molecule's docker driver then talks to Podman's Docker-compatible
# socket; enable it once with: systemctl --user enable --now podman.socket
CONTAINER_ENGINE ?= $(if $(shell command -v docker 2>/dev/null),docker,podman)
ifeq ($(CONTAINER_ENGINE),podman)
export DOCKER_HOST ?= unix://$(XDG_RUNTIME_DIR)/podman/podman.sock
endif
ROLES := $(sort $(notdir $(patsubst %/molecule/default,%,$(wildcard $(ANSIBLE_DIR)/roles/*/molecule/default))))

# Limit a run to one Pi or group, e.g. make apply LIMIT=octopi
LIMIT_ARG := $(if $(LIMIT),--limit $(LIMIT))

help: ## List the targets
	@echo "Run these on your computer, from the repo folder. New Pi? Start with: make new-pi"
	@awk -F ':.*## ' '/^[a-z-]+:.*## / { printf "  %-18s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

new-pi: ## Guided setup for a new or re-flashed Pi: inventory, card, first boot
	scripts/new-pi.sh $(ARGS)

wait-pi: ## Wait for a freshly flashed Pi to answer on SSH: make wait-pi HOST=octopi
	@test -n "$(HOST)" || { echo "usage: make wait-pi HOST=<hostname>"; exit 1; }
	scripts/new-pi.sh --wait --hostname $(HOST)

deps: ## Install Ansible collections
	cd $(ANSIBLE_DIR) && ansible-galaxy collection install -r requirements.yml

ping: ## Check the Pis are reachable over SSH
	cd $(ANSIBLE_DIR) && ansible $(or $(LIMIT),pis) -m ansible.builtin.ping

apply: ## Configure the Pis
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml $(LIMIT_ARG)

check: ## Dry run with diff
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml --check --diff $(LIMIT_ARG)

health: ## Read-only health report (fails if something needs attention)
	cd $(ANSIBLE_DIR) && ansible-playbook health.yml $(LIMIT_ARG)

octoprint-backup: ## Copy OctoPrint settings from the printer Pi to backups/octoprint/
	cd $(ANSIBLE_DIR) && ansible-playbook octoprint-backup.yml $(LIMIT_ARG)

lint: ## Lint YAML, Ansible and shell
	yamllint .
	cd $(ANSIBLE_DIR) && ansible-lint
	shellcheck -x scripts/*.sh client/linux/*.sh client/linux/usbip-autoattach tests/client/*.sh tests/bootstrap/*.sh .github/scripts/*.sh .githooks/pre-commit

hooks: ## Lint before every commit (git pre-commit hook in .githooks/)
	git config core.hooksPath .githooks

test: lint ## Lint, then test ROLE (or every role) in a container: make test ROLE=base
	@for role in $(or $(ROLE),$(ROLES)); do $(MAKE) --no-print-directory molecule ROLE=$$role || exit 1; done

molecule-image: ## Build the Debian/systemd image Molecule tests run in
	$(CONTAINER_ENGINE) build -t pi-setup-molecule:trixie molecule/

molecule: molecule-image ## Test one role in a container: make molecule ROLE=octoprint
	@test -n "$(ROLE)" || { echo "usage: make molecule ROLE=<role>"; exit 1; }
	cd $(ANSIBLE_DIR)/roles/$(ROLE) && molecule test $(MOLECULE_ARGS)
