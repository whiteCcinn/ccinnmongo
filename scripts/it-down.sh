#!/usr/bin/env bash
# Removes the integration-test containers started by it-up.sh.
set -euo pipefail
docker ps -a --format '{{.Names}}' | grep '^grove-it-' | xargs -r docker rm -f
