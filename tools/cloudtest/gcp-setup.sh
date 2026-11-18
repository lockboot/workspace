#!/bin/bash
# Start a GCP cloud test run: snapshot what the PCR replay needs, build the netboot bundle
# (UKI + packed stage2, pinned by sha256), upload it, and create the stage0 image. The run lives
# in cloudtest/<id>/ (gitignored); every created cloud resource is recorded in its teardown.txt.
#
# Creates cloud resources: run it only with the user's go-ahead (AGENTS.md "Cloud test runs").
# Needs an open deploy shell (`make deploy-shell-gcp`) and built artifacts:
#   make -C stage0 build-<arch>; make -C stage1 build-<arch> deploy-bin
#   make -C stage2 pack-<arch> INIT_PAYLOAD=pivot-init
# Do not run a stage0 make target between this and the end of the run: it re-mints the Secure
# Boot keys, and the image created here is built from the current ones.
#
# usage: tools/cloudtest/gcp-setup.sh [arch]            (default x86_64)
set -euo pipefail
die() { echo "error: $*" >&2; exit 1; }

ARCH=${1:-x86_64}
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
BUCKET=${CLOUDTEST_BUCKET:-lockboot-test}      # public-read over plain http (stage0 has no TLS)
PROJECT=${DEPLOY_GCP_PROJECT:-lockboot}
DEPLOY=stage1/target/x86_64-unknown-linux-musl/debug/lockboot-deploy
UKI=stage1/tools/build-uki/$ARCH/linux.efi
S2=stage2/build/$ARCH/pack/stage2
S0=stage0/build/$ARCH
S0_FILES=(BOOTX64.EFI boot.disk PK.cer KEK.cer db.cer dbx.esl stage0.replay.json os-release)
for f in "$DEPLOY" "$UKI" "$S2" "${S0_FILES[@]/#/$S0/}" \
         "stage1/tools/build-uki/$ARCH/stage1.replay.json" stage2/tools/stage2.replay.json; do
    [ -e "$f" ] || die "missing $f (build it first; see the header of this script)"
done
dx() { make -s deploy-exec CMD="$1" 2>&1 | grep -v '^WARNING' || true; }

R=$(head -c6 /dev/urandom | od -An -tx1 | tr -d ' \n')
C=cloudtest/$R
mkdir -p "$C/replay"
echo "$R" > cloudtest/CURRENT
: > "$C/teardown.txt"

# What the replay reads, as it is now: a later stage0 build has different keys.
cp "${S0_FILES[@]/#/$S0/}" "stage1/tools/build-uki/$ARCH/stage1.replay.json" \
   stage2/tools/stage2.replay.json "$C/replay/"
{
    echo "run $R, $(date -u +%Y-%m-%dT%H:%M:%SZ), $ARCH"
    for r in stage0 stage1 stage2; do
        echo "$r $(git -C $r rev-parse --abbrev-ref HEAD) $(git -C $r rev-parse --short HEAD)$(git -C $r diff --quiet HEAD || echo ' +uncommitted')"
    done
    grep '^BUILD_ID=' "$S0/os-release"
    sha256sum "$UKI" "$S2"
} > "$C/README.txt"

BASE=http://storage.googleapis.com/$BUCKET/test/$R/chain
"$DEPLOY" create --arch "$ARCH" --uki "$UKI" --stage2 "$S2" --base-url "$BASE" --out "$C/chain"
"$DEPLOY" validate "$C/chain/user-data.json"

GS=gs://$BUCKET/test/$R/chain/$ARCH
dx "gcloud storage cp $C/chain/$ARCH/linux.efi $C/chain/$ARCH/stage2 $GS/ >/dev/null 2>&1 && echo uploaded to $GS"
for f in linux.efi stage2; do echo "gcp gcsobject $PROJECT $GS/$f" >> "$C/teardown.txt"; done
for hop in _stage1 _stage2; do
    url=$(jq -r ".$hop.$ARCH.payload.url" "$C/chain/user-data.json")
    pin=$(jq -r ".$hop.$ARCH.payload.sha256" "$C/chain/user-data.json")
    [ "$(curl -sf "$url" | sha256sum | cut -d' ' -f1)" = "$pin" ] \
        || die "$hop: $url does not serve the pinned bytes"
    echo "served and pinned: $hop ${pin:0:16}"
done

dx "stage0/tools/publish/gcp/create.sh --private --manifest $C/teardown.txt $ARCH 2>$C/create-$ARCH.err > $C/image-$ARCH.txt; echo create.sh rc=\$?"
[ -s "$C/image-$ARCH.txt" ] || die "no image created (see $C/create-$ARCH.err)"
echo "run $R: image $(cat "$C/image-$ARCH.txt")"
echo "teardown: $C/teardown.txt"
