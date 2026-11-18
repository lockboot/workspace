#!/bin/bash
# The release gate on GCP TDX (c3-standard-4), one VM: launch and capture, delete, check.
# Needs a run (gcp-setup.sh) and an open `make deploy-shell-gcp`. One VM at a time, with the
# user's go-ahead (AGENTS.md "Cloud test runs").
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
./gcp-run.sh lb-tdx c3-standard-4 --confidential-compute-type=TDX; rc=$?
./gcp-delete.sh lb-tdx
[ $rc -eq 0 ] || exit $rc
exec ./check-run.py lb-tdx ../pcr-replay/platforms/gcp/gcp-c3-standard-4-tdx.replay.json
