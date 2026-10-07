#!/usr/bin/env bash
set -eo pipefail

# Apply AAP Controller + EDA objects for Patching Loop.
# Sources the repo-root .env for AAP, AWS, ServiceNow, and AO credentials.
#
# Usage:
#   ./ansible_deployment/scripts/cac-apply.sh
#
# Prerequisites:
#   ansible-galaxy collection install -r ansible_deployment/cac/requirements.yml

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PLAYBOOK="${REPO_ROOT}/ansible_deployment/cac/apply.yml"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  echo "Loading environment from ${REPO_ROOT}/.env"
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

ansible-playbook "${PLAYBOOK}" "$@"
