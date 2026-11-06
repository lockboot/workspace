# lockboot:deploy -- cloud publish/launch tooling for the stage0/tools/publish scripts.
#
# Dev-only (built locally, never published): aws CLI v2 + coldsnap (EBS direct-API snapshot
# upload, ec2/create.sh) + gcloud (gcp/*.sh) + gh (release-mode download/attestation) + jq/curl/
# unzip/tar. Built and run via the workspace Makefile (`make deploy-shell`), which mounts the
# workspace at /src and bind-mounts individual credential files read-only -- credentials are never
# baked in here and should never live under /src (where every lockboot:build container, and every
# build.rs it runs, can read them).
#
# Every download is pinned by sha256. Pins were checked when set (2026-11-05):
#   aws CLI   -- GPG "Good signature" on both zips from key FB5D B77F D5C1 18B8 0511 ADA8 A631
#                0ACC 4672 475C (the copy in AWS's install docs; the keyserver copy is stale/expired)
#   gh        -- matches upstream checksums.txt + `gh attestation verify --repo cli/cli`
#   gcloud    -- no upstream signature; trust-on-first-use over HTTPS from dl.google.com
#   coldsnap  -- crates.io, `cargo install --locked` (the crate's packaged Cargo.lock)

# ---- coldsnap (Rust; built, not downloaded -- upstream ships no binaries) ----
FROM rust:1.99.1-slim-bookworm@sha256:ed2c95ca377d6571b124b05e75e01207973ded639dce7d5542eb7bcd797e32aa AS coldsnap
ARG COLDSNAP_VERSION=0.12.0
RUN cargo install --locked --root /out "coldsnap@${COLDSNAP_VERSION}"

# ---- runtime ----
FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
ARG TARGETARCH

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl unzip tar gzip jq less && \
    rm -rf /var/lib/apt/lists/*

ARG AWSCLI_VERSION=2.39.4
ARG AWSCLI_SHA256_amd64=5153610ddd5dff13d43b2965c92d58f16e9f3f54164eea76d3abb29f38787597
ARG AWSCLI_SHA256_arm64=76e4ac0f82b5b1ec68dfc747705fa3298c05e22648e5503f1869f0d035ad57bb
RUN set -eu; \
    case "${TARGETARCH}" in amd64) a=x86_64 s="${AWSCLI_SHA256_amd64}" ;; arm64) a=aarch64 s="${AWSCLI_SHA256_arm64}" ;; *) exit 1 ;; esac; \
    curl -fsSLo /tmp/awscli.zip "https://awscli.amazonaws.com/awscli-exe-linux-${a}-${AWSCLI_VERSION}.zip"; \
    echo "${s}  /tmp/awscli.zip" | sha256sum -c -; \
    unzip -q /tmp/awscli.zip -d /tmp; \
    /tmp/aws/install -i /opt/aws-cli -b /usr/local/bin; \
    rm -rf /tmp/awscli.zip /tmp/aws

ARG GCLOUD_VERSION=592.0.0
ARG GCLOUD_SHA256_amd64=2d841a23a681ab94486af6841e5f1cd123cd300fb8c4be6ba5b51350fca3d50b
ARG GCLOUD_SHA256_arm64=ba588759c4c42122a8c14536009738c0f0030989ca75788235f9956555e44f4d
RUN set -eu; \
    case "${TARGETARCH}" in amd64) a=x86_64 s="${GCLOUD_SHA256_amd64}" ;; arm64) a=arm s="${GCLOUD_SHA256_arm64}" ;; *) exit 1 ;; esac; \
    curl -fsSLo /tmp/gcloud.tgz "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-${GCLOUD_VERSION}-linux-${a}.tar.gz"; \
    echo "${s}  /tmp/gcloud.tgz" | sha256sum -c -; \
    tar -xzf /tmp/gcloud.tgz -C /opt; \
    ln -s /opt/google-cloud-sdk/bin/gcloud /opt/google-cloud-sdk/bin/gsutil /usr/local/bin/; \
    rm /tmp/gcloud.tgz

ARG GH_VERSION=2.103.3
ARG GH_SHA256_amd64=4c806978ffce1cec70853302a56d70ac6da4f19bae7adca4e1a8ab00633dd91d
ARG GH_SHA256_arm64=ee32df2323c8847f5fac6cb6b4b69ca75828e9329a8f22f677021f7b3306ce63
RUN set -eu; \
    case "${TARGETARCH}" in amd64) s="${GH_SHA256_amd64}" ;; arm64) s="${GH_SHA256_arm64}" ;; *) exit 1 ;; esac; \
    curl -fsSLo /tmp/gh.tgz "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    echo "${s}  /tmp/gh.tgz" | sha256sum -c -; \
    tar -xzf /tmp/gh.tgz -C /tmp; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" /usr/local/bin/gh; \
    rm -rf /tmp/gh.tgz "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}"

COPY --from=coldsnap /out/bin/coldsnap /usr/local/bin/coldsnap

# $HOME is a per-run tmpfs (CLI caches only, gone on exit). Credentials are individual host files
# bind-mounted read-only under /creds by the Makefile; nothing persists in the container.
ENV HOME=/home/deploy \
    AWS_PAGER= \
    CLOUDSDK_CORE_DISABLE_USAGE_REPORTING=true \
    CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK=true \
    GH_NO_UPDATE_NOTIFIER=1
COPY --chmod=0755 entry.sh /usr/local/bin/deploy-entry
WORKDIR /src
ENTRYPOINT ["/usr/local/bin/deploy-entry"]
