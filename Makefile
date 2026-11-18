ANSIBLE_DIR := ansible
export ANSIBLE_CONFIG := $(CURDIR)/$(ANSIBLE_DIR)/ansible.cfg

.PHONY: deps ping apply check lint octoprint-backup

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
	shellcheck -x scripts/*.sh
