ANSIBLE_DIR := ansible
export ANSIBLE_CONFIG := $(CURDIR)/$(ANSIBLE_DIR)/ansible.cfg

.PHONY: deps ping apply check lint

deps: ## Install Ansible collections
	cd $(ANSIBLE_DIR) && ansible-galaxy collection install -r requirements.yml

ping: ## Check the Pi is reachable over SSH
	cd $(ANSIBLE_DIR) && ansible pis -m ansible.builtin.ping

apply: ## Configure the Pi
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml

check: ## Dry run with diff
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml --check --diff

lint: ## Lint YAML, Ansible and shell
	yamllint .
	cd $(ANSIBLE_DIR) && ansible-lint
	shellcheck -x scripts/*.sh
