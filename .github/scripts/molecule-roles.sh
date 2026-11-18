#!/usr/bin/env bash
# Print, as a JSON list, the roles whose Molecule scenario CI should run.
#
#   molecule-roles.sh            every role with a scenario
#   molecule-roles.sh BASE_REF   only roles affected by changes since BASE_REF:
#     - a change under ansible/roles/<role>/ runs that role, plus every
#       scenario that also applies it (octoprint's converge applies podman)
#     - a change to shared Ansible or Molecule files runs every role
#     - anything else (docs, client, boot scripts, other workflows) runs none
set -euo pipefail
cd "$(dirname "$0")/../.."

all=$(find ansible/roles -mindepth 3 -maxdepth 3 -path "*/molecule/default" | cut -d/ -f3 | sort)

if [ $# -eq 0 ]; then
  selected=$all
else
  changed=$(git diff --name-only "$1"...HEAD)
  changed_roles=$(sed -nE 's#^ansible/roles/([^/]+)/.*#\1#p' <<<"$changed" | sort -u)
  shared='^(ansible/|molecule/|\.config/molecule/|Makefile$|\.github/workflows/molecule\.yml$|\.github/scripts/molecule-roles\.sh$)'
  if grep -vE '^ansible/roles/' <<<"$changed" | grep -qE "$shared"; then
    selected=$all
  else
    selected=""
    for role in $all; do
      for c in $changed_roles; do
        if [ "$role" = "$c" ] ||
          grep -qE "^[[:space:]]*-[[:space:]]+(role:[[:space:]]*)?${c}[[:space:]]*$" \
            ansible/roles/"$role"/molecule/default/*.yml; then
          selected="$selected $role"
          break
        fi
      done
    done
  fi
fi

# shellcheck disable=SC2086 # word splitting on purpose
printf '%s\n' $selected | sed '/^$/d' | jq -Rnc '[inputs]'
