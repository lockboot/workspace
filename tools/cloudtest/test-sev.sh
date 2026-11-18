#!/bin/bash
# The release gate on GCP SEV (n2d-standard-2), one VM: launch and capture, delete, check.
# Needs a run (gcp-setup.sh) and an open `make deploy-shell-gcp`. One VM at a time, with the
# user's go-ahead (AGENTS.md "Cloud test runs").
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
./gcp-run.sh lb-sev n2d-standard-2 --confidential-compute-type=SEV; rc=$?
./gcp-delete.sh lb-sev
[ $rc -eq 0 ] || exit $rc
exec ./check-run.py lb-sev ../pcr-replay/platforms/gcp/gcp-n2d-standard-2-sev.replay.json
