ANSIBLE_DIR := ansible
export ANSIBLE_CONFIG := $(CURDIR)/$(ANSIBLE_DIR)/ansible.cfg

.PHONY: deps ping apply check lint octoprint-backup molecule-image molecule

# Limit a run to one Pi or group, e.g. make apply LIMIT=octopi
LIMIT_ARG := $(if $(LIMIT),--limit $(LIMIT))

deps: ## Install Ansible collections
	cd $(ANSIBLE_DIR) && ansible-galaxy collection install -r requirements.yml

ping: ## Check the Pis are reachable over SSH
	cd $(ANSIBLE_DIR) && ansible $(or $(LIMIT),pis) -m ansible.builtin.ping

apply: ## Configure the Pis
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml $(LIMIT_ARG)

check: ## Dry run with diff
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml --check --diff $(LIMIT_ARG)

octoprint-backup: ## Copy OctoPrint settings from the printer Pi to backups/octoprint/
	cd $(ANSIBLE_DIR) && ansible-playbook octoprint-backup.yml $(LIMIT_ARG)

lint: ## Lint YAML, Ansible and shell
	yamllint .
	cd $(ANSIBLE_DIR) && ansible-lint
	shellcheck -x scripts/*.sh client/linux/*.sh client/linux/usbip-autoattach tests/client/*.sh

molecule-image: ## Build the Debian/systemd image Molecule tests run in
	docker build -t pi-setup-molecule:trixie molecule/

molecule: molecule-image ## Test one role in a container: make molecule ROLE=octoprint
	@test -n "$(ROLE)" || { echo "usage: make molecule ROLE=<role>"; exit 1; }
	cd $(ANSIBLE_DIR)/roles/$(ROLE) && molecule test
