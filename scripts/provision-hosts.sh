#!/usr/bin/env bash
set -eo pipefail

# Provision 9 EC2 instances for the patching loop demo.
# 3 groups (A, B, C) × 3 hosts each.
# Handles hostname setup, RHEL subscription, Insights registration,
# and triggers AAP inventory sync.
#
# Ported from the battle-tested provision-demo.sh in ao-cve-remediation-simplified.
#
# RHEL 8.4 is intentional — older packages mean PwnKit (CVE-2021-4034) is present
# with both mitigation and patching routes available.
#
# Usage:
#   ./scripts/provision-hosts.sh [--destroy-existing]
#     --destroy-existing  Terminate existing demo instances before provisioning

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DESTROY_EXISTING=false
for arg in "$@"; do
  case "$arg" in
    --destroy-existing) DESTROY_EXISTING=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

REGION="${AWS_REGION:-eu-west-1}"
AMI="${AWS_BASE_AMI_ID:?Set AWS_BASE_AMI_ID in .env}"
INSTANCE_TYPE="${AWS_INSTANCE_TYPE:-t3.small}"
SUBNET="${AWS_SUBNET_ID:?Set AWS_SUBNET_ID in .env}"
SG="${AWS_SECURITY_GROUP_ID:?Set AWS_SECURITY_GROUP_ID in .env}"
KEY_NAME="${AWS_KEY_PAIR_NAME:-patching-loop}"
SSH_KEY="${PROBE_SSH_KEY_PATH:?Set PROBE_SSH_KEY_PATH in .env}"
SSH_USER="ec2-user"
DEMO_TAG="patching-loop"
DOMAIN="summit-demo.chrislab.dev"

AAP_HOST="${AAP_HOSTNAME:?Set AAP_HOSTNAME in .env}"
AAP_HOST="${AAP_HOST%/}"
AAP_TOKEN_VAL="${AAP_TOKEN:?Set AAP_TOKEN in .env}"

RH_ORG="${RH_ORG_ID:-}"
RH_AK="${RH_ACTIVATION_KEY:-}"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

GROUP_A="summit-rhel-01 summit-rhel-02 summit-rhel-03"
GROUP_B="summit-rhel-04 summit-rhel-05 summit-rhel-06"
GROUP_C="summit-rhel-07 summit-rhel-08 summit-rhel-09"

hosts_for_group() {
  case "$1" in
    A) echo "$GROUP_A" ;;
    B) echo "$GROUP_B" ;;
    C) echo "$GROUP_C" ;;
  esac
}

ALL_NODES=($GROUP_A $GROUP_B $GROUP_C)

if [[ -z "$RH_ORG" || -z "$RH_AK" ]]; then
  echo "WARNING: RH_ORG_ID / RH_ACTIVATION_KEY not set in .env"
  echo "         Instances will NOT be registered with Insights."
  echo "         Create a key at: https://console.redhat.com/insights/connector/activation-keys"
  echo ""
fi

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║    Summit Patching Loop — Instance Provisioning           ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║  AMI:      ${AMI}                        ║"
echo "║  Region:   ${REGION}                                    ║"
echo "║  Nodes:    ${#ALL_NODES[@]} (3 groups × 3 hosts)                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# ─── Step 1: Handle existing instances ───────────────────────────────────────
if [[ "$DESTROY_EXISTING" == true ]]; then
  echo "── Step 1/5: Terminating existing instances ──"
  EXISTING_IDS=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:demo,Values=${DEMO_TAG}" "Name=instance-state-name,Values=running,stopped,stopping" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text 2>/dev/null || true)

  if [[ -n "$EXISTING_IDS" && "$EXISTING_IDS" != "None" ]]; then
    EXISTING_INFO=$(aws ec2 describe-instances \
      --region "$REGION" \
      --filters "Name=tag:demo,Values=${DEMO_TAG}" "Name=instance-state-name,Values=running" \
      --query "Reservations[].Instances[].{IP:PublicIpAddress,Name:Tags[?Key=='Name']|[0].Value}" \
      --output json 2>/dev/null || echo "[]")

    echo "  Deregistering from Insights before termination..."
    DEREG_FILE=$(mktemp)
    echo "$EXISTING_INFO" | python3 -c "
import json, sys
for i in json.load(sys.stdin):
    if i.get('IP'):
        print(f\"{i['Name']}:{i['IP']}\")
" > "$DEREG_FILE"

    DEREG_PIDS=()
    while IFS=: read -r dname dip; do
      [[ -z "$dname" ]] && continue
      (
        elapsed=0
        while ! ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${dip}" true 2>/dev/null; do
          elapsed=$((elapsed + 5))
          if [[ $elapsed -ge 60 ]]; then
            echo "  [SKIP] ${dname} (SSH timeout after 60s)"
            exit 1
          fi
          sleep 5
        done
        ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${dip}" \
          "sudo insights-client --unregister 2>/dev/null || true; sudo rhc disconnect 2>/dev/null || true; sudo subscription-manager unregister 2>/dev/null || true" \
          > /dev/null 2>&1 && echo "  [OK] ${dname} deregistered" || echo "  [SKIP] ${dname} (deregister failed)"
      ) &
      DEREG_PIDS+=($!)
    done < "$DEREG_FILE"

    for pid in "${DEREG_PIDS[@]}"; do wait "$pid" || true; done
    rm -f "$DEREG_FILE"

    count=$(echo "$EXISTING_IDS" | wc -w | tr -d ' ')
    echo "  Terminating ${count} instances..."
    aws ec2 terminate-instances --region "$REGION" --instance-ids $EXISTING_IDS > /dev/null
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids $EXISTING_IDS
    echo "  [OK] All terminated"
  else
    echo "  No existing demo instances found"
  fi
else
  echo "── Step 1/5: Checking for existing instances ──"
  EXISTING=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:demo,Values=${DEMO_TAG}" "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text 2>/dev/null || true)

  if [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
    count=$(echo "$EXISTING" | wc -w | tr -d ' ')
    echo "  Found ${count} existing instance(s). Use --destroy-existing to replace them."
    echo "  Proceeding will create additional instances."
    echo ""
    read -r -p "  Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy] ]] || exit 0
  else
    echo "  No existing instances — fresh provisioning"
  fi
fi
echo ""

# ─── Step 2: Launch instances ────────────────────────────────────────────────
echo "── Step 2/5: Launching ${#ALL_NODES[@]} RHEL 8 instances ──"
NEW_IDS=()
UD_TMPFILE=$(mktemp)
trap "rm -f '${UD_TMPFILE}'" EXIT

for GROUP in A B C; do
  for HOST_NAME in $(hosts_for_group "$GROUP"); do
    fqdn="${HOST_NAME}.${DOMAIN}"

    cat > "$UD_TMPFILE" <<USERDATA
#cloud-config
bootcmd:
  - [ systemctl, mask, rhcd.service ]
  - [ systemctl, stop, rhcd.service ]
  - [ systemctl, mask, insights-client.timer ]
  - [ systemctl, mask, rhsmcertd.service ]
  - [ systemctl, stop, rhsmcertd.service ]
runcmd:
  - hostnamectl set-hostname ${fqdn}
  - echo '${fqdn}' > /etc/hostname
USERDATA

    instance_id=$(aws ec2 run-instances \
      --region "$REGION" \
      --image-id "$AMI" \
      --instance-type "$INSTANCE_TYPE" \
      --subnet-id "$SUBNET" \
      --security-group-ids "$SG" \
      --key-name "$KEY_NAME" \
      --user-data "file://${UD_TMPFILE}" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${HOST_NAME}},{Key=demo,Value=${DEMO_TAG}},{Key=group,Value=${GROUP}}]" \
      --query "Instances[0].InstanceId" \
      --output text)

    NEW_IDS+=("$instance_id")
    echo "  ${HOST_NAME} (Group ${GROUP}): ${instance_id}"
  done
done
echo ""

# ─── Step 3: Wait for running + get IPs ─────────────────────────────────────
echo "── Step 3/5: Waiting for instances to be running ──"
aws ec2 wait instance-running --region "$REGION" --instance-ids "${NEW_IDS[@]}"
echo "  [OK] All running"
echo ""

IP_MAP_FILE=$(mktemp)
INSTANCE_INFO=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "${NEW_IDS[@]}" \
  --query "Reservations[].Instances[].{ID:InstanceId,IP:PublicIpAddress,Name:Tags[?Key=='Name']|[0].Value,Group:Tags[?Key=='group']|[0].Value}" \
  --output json 2>/dev/null)

echo "  Instance details:"
echo "$INSTANCE_INFO" | python3 -c "
import json, sys
for i in sorted(json.load(sys.stdin), key=lambda x: x['Name']):
    print(f\"    {i['Name']:18s}  Group {i['Group']}  {i['IP']:16s}  {i['ID']}\")
"

echo "$INSTANCE_INFO" | python3 -c "
import json, sys
for i in json.load(sys.stdin):
    print(f\"{i['Name']}:{i['IP']}\")
" > "$IP_MAP_FILE"
echo ""

# ─── Step 4: Register with Insights ─────────────────────────────────────────
echo "── Step 4/5: Registering instances with Red Hat Insights ──"

if [[ -z "$RH_ORG" || -z "$RH_AK" ]]; then
  echo "  Skipped (RH_ORG_ID / RH_ACTIVATION_KEY not set)"
  echo ""
else
  echo "  Waiting for SSH on all hosts..."
  while IFS=: read -r wname wip; do
    [[ -z "$wname" ]] && continue
    elapsed=0
    while ! ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${wip}" true 2>/dev/null; do
      elapsed=$((elapsed + 5))
      if [[ $elapsed -ge 120 ]]; then
        echo "  [FAIL] ${wname}: SSH timeout"
        break
      fi
      sleep 5
    done
  done < "$IP_MAP_FILE"
  echo "  [OK] SSH available"
  echo ""

  echo "  Waiting for cloud-init to complete..."
  while IFS=: read -r wname wip; do
    [[ -z "$wname" ]] && continue
    ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${wip}" \
      "sudo cloud-init status --wait 2>/dev/null || sleep 30" > /dev/null 2>&1 &
  done < "$IP_MAP_FILE"
  wait
  echo "  [OK] Cloud-init finished"
  echo ""

  register_one() {
    local hname="$1" hip="$2"
    local hfqdn="${hname}.${DOMAIN}"
    local attempt max_attempts=3

    for attempt in $(seq 1 $max_attempts); do
      local out
      out=$(ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${hip}" "bash -s" 2>&1 <<REGSCRPT
sudo systemctl stop rhcd.service 2>/dev/null || true
sudo systemctl disable rhcd.service 2>/dev/null || true
sudo systemctl mask rhcd.service 2>/dev/null || true
sudo systemctl stop rhsmcertd.service 2>/dev/null || true
sudo systemctl mask rhsmcertd.service 2>/dev/null || true
sudo sed -i 's/^auto_registration\s*=.*/auto_registration = 0/' /etc/rhsm/rhsm.conf 2>/dev/null || true
sudo insights-client --unregister 2>/dev/null || true
sudo subscription-manager unregister 2>/dev/null || true
sudo rm -f /etc/insights-client/machine-id /etc/insights-client/.registered
sudo rm -rf /etc/pki/consumer/* /etc/pki/entitlement/*
sudo rm -rf /var/lib/rhsm/cache/* /var/lib/rhsm/facts/*
sudo subscription-manager register --org='${RH_ORG}' --activationkey='${RH_AK}' --force 2>&1
sudo insights-client --register 2>&1
sudo mkdir -p /etc/insights-client
echo -e "---\ngroup: patching-loop" | sudo tee /etc/insights-client/tags.yaml > /dev/null
sudo systemctl unmask rhsmcertd.service 2>/dev/null || true
sudo systemctl enable --now rhsmcertd.service 2>/dev/null || true
sudo systemctl unmask insights-client.timer 2>/dev/null || true
sudo systemctl enable --now insights-client.timer 2>/dev/null || true
sudo insights-client 2>&1 | tail -1
REGSCRPT
)
      if echo "$out" | grep -q "Successfully uploaded"; then
        echo "  [OK] ${hfqdn}"
        return 0
      fi
      echo "  [RETRY ${attempt}/${max_attempts}] ${hfqdn}"
    done

    echo "  [FAIL] ${hfqdn} — could not register after ${max_attempts} attempts"
    return 1
  }

  echo "  Registering hosts (org: ${RH_ORG}, key: ${RH_AK})..."
  REG_PIDS=()
  REG_FAILURES=0
  while IFS=: read -r rname rip; do
    [[ -z "$rname" ]] && continue
    register_one "$rname" "$rip" &
    REG_PIDS+=($!)
  done < "$IP_MAP_FILE"

  for pid in "${REG_PIDS[@]}"; do wait "$pid" || REG_FAILURES=$((REG_FAILURES + 1)); done
  echo ""

  echo "  Verifying Insights registration..."
  FAILED_HOSTS=""
  while IFS=: read -r vname vip; do
    [[ -z "$vname" ]] && continue
    vresult=$(ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${vip}" \
      "sudo insights-client --status 2>&1" 2>/dev/null || echo "error")
    if echo "$vresult" | grep -q "confirms registration"; then
      echo "  [OK] ${vname}: registered"
    else
      echo "  [MISS] ${vname}: not registered — will retry"
      FAILED_HOSTS="${FAILED_HOSTS}${vname}:${vip}\n"
    fi
  done < "$IP_MAP_FILE"

  if [[ -n "$FAILED_HOSTS" ]]; then
    echo ""
    echo "  Retrying failed registrations sequentially..."
    while IFS=: read -r fname fip; do
      [[ -z "$fname" ]] && continue
      register_one "$fname" "$fip"
    done < <(echo -e "$FAILED_HOSTS")
  fi
  echo ""

  # ─── Final hard verification — no host left behind ───────────────────────
  echo "  ══ Final verification (with propagation wait) ══"
  FINAL_FAILURES=""
  while IFS=: read -r vname vip; do
    [[ -z "$vname" ]] && continue
    verified=false
    for check in 1 2 3 4 5; do
      vresult=$(ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${vip}" \
        "sudo insights-client --status 2>&1" 2>/dev/null || echo "error")
      if echo "$vresult" | grep -q "confirms registration"; then
        echo "  ✅ ${vname}: confirmed registered"
        verified=true
        break
      fi
      if [[ $check -lt 5 ]]; then
        echo "  ⏳ ${vname}: not confirmed yet (attempt ${check}/5, waiting 30s...)"
        sleep 30
      fi
    done
    if [[ "$verified" != "true" ]]; then
      echo "  ❌ ${vname}: FAILED — not registered after 5 verification attempts"
      FINAL_FAILURES="${FINAL_FAILURES} ${vname}"
    fi
  done < "$IP_MAP_FILE"
  echo ""

  rm -f "$IP_MAP_FILE"

  if [[ -n "$FINAL_FAILURES" ]]; then
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  ❌  PROVISIONING FAILED — HOSTS NOT REGISTERED          ║"
    echo "╠════════════════════════════════════════════════════════════╣"
    echo "║  The following hosts could not be verified in Insights:   ║"
    for fname in $FINAL_FAILURES; do
      printf "║    %-52s  ║\n" "$fname"
    done
    echo "║                                                          ║"
    echo "║  SSH in and check manually:                              ║"
    echo "║    sudo insights-client --status                         ║"
    echo "║    sudo subscription-manager identity                    ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    exit 1
  fi
fi

# ─── Step 5: Sync AAP inventory ─────────────────────────────────────────────
echo "── Step 5/5: Syncing AAP dynamic inventory ──"

INV_SOURCE_ID=$(curl -sk -H "Authorization: Bearer ${AAP_TOKEN_VAL}" \
  "${AAP_HOST}/api/controller/v2/inventory_sources/?name=Patching+Loop+EC2" \
  2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['results'][0]['id'] if d.get('results') else '')
" 2>/dev/null)

if [[ -n "$INV_SOURCE_ID" ]]; then
  curl -sk -X POST -H "Authorization: Bearer ${AAP_TOKEN_VAL}" \
    "${AAP_HOST}/api/controller/v2/inventory_sources/${INV_SOURCE_ID}/update/" \
    -H "Content-Type: application/json" > /dev/null 2>&1
  echo "  [OK] Inventory sync triggered (source ID: ${INV_SOURCE_ID})"
else
  echo "  [WARN] Could not find 'Patching Loop EC2' inventory source — sync manually"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║              Provisioning Complete                        ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║  ✓ 9 RHEL instances launched (3 groups × 3 hosts)       ║"
echo "║  ✓ Hostnames set via cloud-init                          ║"
echo "║  ✓ Registered with Red Hat Insights                      ║"
echo "║  ✓ AAP inventory sync triggered                          ║"
echo "║                                                          ║"
echo "║  To start the loop:                                      ║"
echo "║    ./scripts/start-loop.sh                               ║"
echo "║                                                          ║"
echo "║  To reprovision:                                         ║"
echo "║    ./scripts/provision-hosts.sh --destroy-existing       ║"
echo "╚════════════════════════════════════════════════════════════╝"
