#!/bin/bash
# One GCP test VM for the current run (cloudtest/CURRENT): spot, capped, serial logging on.
# Creates the VM and follows its console in ONE deploy-exec (GCP serves no serial output once
# the instance stops), then reads the whole console back from Cloud Logging by instance id (a
# guest that powers off quickly outruns the follower) and summarizes each boot.
#
# One VM at a time, and only with the user's go-ahead (AGENTS.md "Cloud test runs"). The VM is
# NOT deleted here: that is its own step, gcp-delete.sh.
#
# usage: tools/cloudtest/gcp-run.sh <name> <machine-type> [extra gcloud flags...]
#   gcp-run.sh lb-snp n2d-standard-2 --confidential-compute-type=SEV_SNP '--min-cpu-platform=AMD\ Milan'
#   gcp-run.sh lb-sev n2d-standard-2 --confidential-compute-type=SEV
#   gcp-run.sh lb-tdx c3-standard-4  --confidential-compute-type=TDX
# Extra flags are evaluated by a shell inside the deploy container: escape spaces as above.
# CAP=<minutes> sets --max-run-duration (default 3, 5 at most). ARCH defaults to x86_64.
set -euo pipefail
[ $# -ge 2 ] || { sed -n '2,/^set -euo/p' "$0" | grep '^#' >&2; exit 2; }
N=$1 MT=$2; shift 2; EXTRA="$*"
ARCH=${ARCH:-x86_64}
CAP=${CAP:-3}
ZONE=${DEPLOY_GCP_ZONE:-asia-southeast1-b}
PROJECT=${DEPLOY_GCP_PROJECT:-lockboot}
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
C=cloudtest/$(cat cloudtest/CURRENT)
IMG=$(cat "$C/image-$ARCH.txt")
U=$C/chain/user-data.json
dx() { make -s deploy-exec CMD="$1" 2>&1 | grep -v '^WARNING' || true; }

echo "gcp instance $PROJECT $ZONE/$N" >> "$C/teardown.txt"
echo "launch $N ($MT $EXTRA), cap ${CAP}m, at $(date +%T)"
# The follower runs under an in-container timeout: stopping the host side would not stop it.
timeout $(( CAP * 60 + 20 )) make -s deploy-exec CMD="gcloud compute instances create $N --zone=$ZONE --machine-type=$MT --image=$IMG --network-interface=nic-type=GVNIC --boot-disk-type=pd-balanced --boot-disk-auto-delete --metadata-from-file=user-data=$U --metadata=serial-port-enable=true,serial-port-logging-enable=true $EXTRA --maintenance-policy=TERMINATE --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring --no-service-account --no-scopes --provisioning-model=SPOT --instance-termination-action=DELETE --max-run-duration=${CAP}m 2>&1 | grep -E '^ERROR|^ - '; gcloud compute instances describe $N --zone=$ZONE --format='value(id)' > $C/$N.id 2>/dev/null; timeout $(( CAP * 60 - 30 )) stage0/tools/publish/gcp/get-console.sh $N $ZONE --follow" > "$C/$N.follow.log" 2>&1 || true
echo "follower done at $(date +%T)"
grep -aE '^ERROR|^ - ' "$C/$N.follow.log" || true
ID=$(tr -dc 0-9 < "$C/$N.id" 2>/dev/null || true)
[ -n "$ID" ] || { echo "error: no instance id (creation failed? see $C/$N.follow.log)" >&2; exit 1; }

sleep 15    # let Cloud Logging catch up with the last lines
dx "gcloud logging read 'resource.type=gce_instance AND resource.labels.instance_id=$ID AND logName=projects/$PROJECT/logs/serialconsole.googleapis.com%2Fserial_port_1_output' --freshness=30m --order=asc --format='value(textPayload)'" > "$C/$N.cloudlog"
python3 -I - "$C/$N.cloudlog" "$C/$N.console.log" <<'PY'
import sys
# Cloud Logging splits long lines across entries: join them, then split on the literal \r\n.
raw = ''.join(l.rstrip('\n') for l in open(sys.argv[1], encoding='latin1'))
t = raw.replace('\\r\\n', '\n').replace('\\"', '"')
open(sys.argv[2], 'w', encoding='latin1').write(t)
boots = t.split('BdsDxe: loading')[1:]
print('boots: %d' % len(boots))
KEYS = ('GPT rewritten', 'data_reinit', 'stage1: boot disk', 'stage1: exec stage2', 'boot 1:',
        '[persist]', '[integrity]', '[resize]', '[attest]', 'PIVOT_TEST=', 'Memory Encryption Features')
for i, b in enumerate(boots, 1):
    print('-- boot %d: %s' % (i, 'payload ran' if '=== pivot-init' in b else 'no payload'))
    for l in b.split('\n'):
        if any(k in l for k in KEYS):
            print('   ' + l.strip()[:160])
PY
echo "console: $C/$N.console.log"
echo "instance: $(dx "gcloud compute instances describe $N --zone=$ZONE --format='value(status)' 2>&1 | tail -1")"
echo "next: tools/cloudtest/gcp-delete.sh $N"
