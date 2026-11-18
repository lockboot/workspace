#!/bin/bash
# Delete one test VM and list what is still running. Run it as soon as gcp-run.sh reports the
# instance stopped, as its own announced step (AGENTS.md "Cloud test runs").
# usage: tools/cloudtest/gcp-delete.sh <name>
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 <name>" >&2; exit 2; }
ZONE=${DEPLOY_GCP_ZONE:-asia-southeast1-b}
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
make -s deploy-exec CMD="gcloud compute instances delete $1 --zone=$ZONE --quiet 2>&1 | tail -1; echo \"instances left: \$(gcloud compute instances list --format='value(name)' | tr '\n' ' ')\"" 2>&1 | grep -v '^WARNING'
