ANSIBLE_DIR := ansible
export ANSIBLE_CONFIG := $(CURDIR)/$(ANSIBLE_DIR)/ansible.cfg

# Every target runs on YOUR computer (Linux, macOS, or WSL on Windows), never on
# the Pi: Ansible reaches the Pis over SSH. Run `make` alone for this list.
.DEFAULT_GOAL := help

.PHONY: help new-pi wait-pi deps deps-dev lock ping apply check health lint hooks test octoprint-backup molecule-image molecule

# Ansible (and, for development, ansible-lint and Molecule) live in .venv, at the
# exact versions in requirements.txt / requirements-dev.txt, so every computer and
# CI run the same ones. Targets that need them create or update .venv first, and
# use it without you activating anything. With uv (recommended) .venv gets the
# Python in .python-version, downloaded if needed; without it, python3 -m venv.
VENV := $(CURDIR)/.venv
UV := $(shell command -v uv 2>/dev/null)
PYTHON_VERSION := $(shell cat .python-version)
export VIRTUAL_ENV := $(VENV)
export PATH := $(VENV)/bin:$(PATH)
ifneq ($(UV),)
PIP_INSTALL := uv pip install --quiet --python $(VENV)/bin/python
else
PIP_INSTALL := $(VENV)/bin/python -m pip install --quiet --disable-pip-version-check
endif
# Collections are installed again only when ansible/requirements.yml changes
# (by content, so a restored CI cache counts as installed).
COLLECTIONS := $(ANSIBLE_DIR)/.collections/.installed-$(word 1,$(shell cksum < $(ANSIBLE_DIR)/requirements.yml))

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

deps: $(VENV)/.deps $(COLLECTIONS) ## Install the pinned Ansible into .venv, and its collections

deps-dev: deps $(VENV)/.deps-dev $(COLLECTIONS)-dev ## Also install ansible-lint, yamllint and Molecule (make lint/test)

lock: ## After editing requirements*.in: pin exact versions in requirements*.txt (needs uv)
	uv pip compile --quiet --universal --python-version $(PYTHON_VERSION) $(LOCK_ARGS) requirements.in -o requirements.txt
	uv pip compile --quiet --universal --python-version $(PYTHON_VERSION) $(LOCK_ARGS) requirements.in requirements-dev.in -o requirements-dev.txt

# A new .python-version recreates .venv.
$(VENV)/pyvenv.cfg: .python-version
	@rm -rf $(VENV)
ifneq ($(UV),)
	uv venv --quiet --python $(PYTHON_VERSION) $(VENV)
else
	@python3 -c 'import sys; sys.exit(sys.version_info < tuple(map(int, "$(PYTHON_VERSION)".split("."))))' 2>/dev/null || { \
	  echo "Need uv, or python3 $(PYTHON_VERSION) or newer, to install Ansible. Install uv:"; \
	  echo "  curl -LsSf https://astral.sh/uv/install.sh | sh    (macOS: brew install uv)"; exit 1; }
	python3 -m venv $(VENV)
endif

$(VENV)/.deps: requirements.txt $(VENV)/pyvenv.cfg
	$(PIP_INSTALL) -r requirements.txt
	@touch $@

$(VENV)/.deps-dev: requirements-dev.txt $(VENV)/.deps
	$(PIP_INSTALL) -r requirements-dev.txt
	@touch $@

$(COLLECTIONS): | $(VENV)/.deps
	@rm -f $(ANSIBLE_DIR)/.collections/.installed-*
	cd $(ANSIBLE_DIR) && ansible-galaxy collection install -r requirements.yml
	@touch $@

# Molecule's docker driver.
$(COLLECTIONS)-dev: | $(COLLECTIONS)
	cd $(ANSIBLE_DIR) && ansible-galaxy collection install community.docker
	@touch $@

ping: deps ## Check the Pis are reachable over SSH
	cd $(ANSIBLE_DIR) && ansible $(or $(LIMIT),pis) -m ansible.builtin.ping

apply: deps ## Configure the Pis
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml $(LIMIT_ARG)

check: deps ## Dry run with diff
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml --check --diff $(LIMIT_ARG)

health: deps ## Read-only health report (fails if something needs attention)
	cd $(ANSIBLE_DIR) && ansible-playbook health.yml $(LIMIT_ARG)

octoprint-backup: deps ## Copy OctoPrint settings from the printer Pi to backups/octoprint/
	cd $(ANSIBLE_DIR) && ansible-playbook octoprint-backup.yml $(LIMIT_ARG)

lint: deps-dev ## Lint YAML, Ansible and shell
	yamllint .
	cd $(ANSIBLE_DIR) && ansible-lint
	shellcheck -x scripts/*.sh client/linux/*.sh client/linux/usbip-autoattach tests/client/*.sh tests/bootstrap/*.sh .github/scripts/*.sh .githooks/pre-commit

hooks: ## Lint before every commit (git pre-commit hook in .githooks/)
	git config core.hooksPath .githooks

test: lint ## Lint, then test ROLE (or every role) in a container: make test ROLE=base
	@for role in $(or $(ROLE),$(ROLES)); do $(MAKE) --no-print-directory molecule ROLE=$$role || exit 1; done

molecule-image: ## Build the Debian/systemd image Molecule tests run in
	$(CONTAINER_ENGINE) build -t pi-setup-molecule:trixie molecule/

molecule: molecule-image deps-dev ## Test one role in a container: make molecule ROLE=octoprint
	@test -n "$(ROLE)" || { echo "usage: make molecule ROLE=<role>"; exit 1; }
	cd $(ANSIBLE_DIR)/roles/$(ROLE) && molecule test $(MOLECULE_ARGS)
