#!/usr/bin/env bash
set -eo pipefail

# Provision 9 EC2 instances for the patching loop demo.
# 3 groups (A, B, C) × 3 hosts each.
# All tagged with demo=patching-loop and group=A|B|C.
#
# Usage:
#   ./scripts/provision-hosts.sh
#
# Prerequisites:
#   - AWS CLI configured (or .env with AWS credentials)
#   - Base AMI available in the target region

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

REGION="${AWS_REGION:-eu-west-1}"
AMI="${AWS_BASE_AMI_ID:?AWS_BASE_AMI_ID must be set in .env}"
INSTANCE_TYPE="${AWS_INSTANCE_TYPE:-t3.micro}"
SUBNET="${AWS_SUBNET_ID:?AWS_SUBNET_ID must be set in .env}"
SG="${AWS_SECURITY_GROUP_ID:?AWS_SECURITY_GROUP_ID must be set in .env}"
KEY_PAIR="${AWS_KEY_PAIR_NAME:-patching-loop}"

declare -A GROUPS
GROUPS[A]="patch-loop-a1 patch-loop-a2 patch-loop-a3"
GROUPS[B]="patch-loop-b1 patch-loop-b2 patch-loop-b3"
GROUPS[C]="patch-loop-c1 patch-loop-c2 patch-loop-c3"

echo "=== Provisioning Patching Loop Hosts ==="
echo "  Region:        $REGION"
echo "  AMI:           $AMI"
echo "  Instance type: $INSTANCE_TYPE"
echo "  Subnet:        $SUBNET"
echo "  Security Group:$SG"
echo "  Key pair:      $KEY_PAIR"
echo ""

for GROUP in A B C; do
  for HOST_NAME in ${GROUPS[$GROUP]}; do
    echo "Launching $HOST_NAME (Group $GROUP)..."
    INSTANCE_ID=$(aws ec2 run-instances \
      --region "$REGION" \
      --image-id "$AMI" \
      --instance-type "$INSTANCE_TYPE" \
      --key-name "$KEY_PAIR" \
      --subnet-id "$SUBNET" \
      --security-group-ids "$SG" \
      --associate-public-ip-address \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$HOST_NAME},{Key=demo,Value=patching-loop},{Key=group,Value=$GROUP}]" \
      --query 'Instances[0].InstanceId' \
      --output text)
    echo "  → $INSTANCE_ID"
  done
done

echo ""
echo "Waiting for all instances to be running..."
aws ec2 wait instance-running \
  --region "$REGION" \
  --filters "Name=tag:demo,Values=patching-loop" "Name=instance-state-name,Values=pending,running"

echo ""
echo "=== All 9 instances launched ==="
echo ""

echo "Instance details:"
aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:demo,Values=patching-loop" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value, Group:Tags[?Key==`group`]|[0].Value, ID:InstanceId, IP:PublicIpAddress, State:State.Name}' \
  --output table

echo ""
echo "Waiting for SSH to be available..."
for IP in $(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:demo,Values=patching-loop" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PublicIpAddress' \
  --output text); do
  echo -n "  $IP: "
  for i in $(seq 1 30); do
    if nc -z -w 2 "$IP" 22 2>/dev/null; then
      echo "SSH ready ✓"
      break
    fi
    if [[ $i -eq 30 ]]; then
      echo "timeout (may need more time)"
    fi
    sleep 5
  done
done

echo ""
echo "=== Provisioning Complete ==="
echo "9 hosts ready across 3 groups (A/B/C)."
echo "Next steps:"
echo "  1. Run CaC:  ./ansible_deployment/scripts/cac-apply.sh"
echo "  2. Start:    ./scripts/start-loop.sh"
