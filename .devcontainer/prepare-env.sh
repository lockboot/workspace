#!/usr/bin/env bash
# Runs on the HOST (devcontainer initializeCommand) before the container starts.
# Emits a per-machine compose OVERRIDE carrying this box's identity + the gids
# that actually own the docker socket and /dev/kvm, so nothing machine-specific
# is committed. We write a *.yml override (NOT a .env) on purpose, so editor
# tooling - e.g. the Python extension's dotenv handling - doesn't try to adopt it.
set -eu
cd "$(dirname "$0")"
umask 077

host_uid=$(id -u)
host_gid=$(id -g)
docker_gid=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo "$host_gid")
kvm_gid=$(stat -c '%g' /dev/kvm 2>/dev/null || echo "$host_gid")

cat > docker-compose.host.yml <<EOF
# Generated per-host by prepare-env.sh (devcontainer initializeCommand).
# Not committed - regenerated on every container start; merged over
# docker-compose.yml via the devcontainer's dockerComposeFile list.
services:
  workspace:
    build:
      args:
        USER_UID: "${host_uid}"   # bake a passwd/group entry matching this host
        USER_GID: "${host_gid}"   # so the runtime uid below resolves to a name
    user: "${host_uid}:${host_gid}"
    group_add:
      - "${docker_gid}"   # gid owning /var/run/docker.sock
      - "${kvm_gid}"      # gid owning /dev/kvm
EOF

echo "prepare-env.sh: wrote docker-compose.host.yml (uid:gid=${host_uid}:${host_gid}, docker=${docker_gid}, kvm=${kvm_gid})"
