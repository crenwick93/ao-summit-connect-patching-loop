#!/usr/bin/env bash
set -eo pipefail

# Stop the patching loop gracefully.
# Creates a stop flag file that fire_next_group.yml checks before firing the next webhook.
# The current cycle will complete, but no new cycle will start.
#
# Usage:
#   ./scripts/stop-loop.sh

STOP_FLAG="/tmp/patching-loop-stop"

echo "=== Stopping Patching Loop ==="
touch "$STOP_FLAG"
echo "Stop flag created: $STOP_FLAG"
echo ""
echo "The current patching cycle will complete normally."
echo "After it finishes, fire_next_group.yml will see the stop flag and NOT trigger the next group."
echo ""
echo "To restart: ./scripts/start-loop.sh [GROUP]"
echo "  (start-loop.sh automatically removes the stop flag)"
