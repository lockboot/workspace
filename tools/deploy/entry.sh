#!/usr/bin/env bash
# lockboot:deploy entrypoint: browser login (passkey/MFA on the IdP side) to ONLY the clouds asked
# for, then a shell (or $DEPLOY_CMD), then sign-out on exit. All tokens live in the tmpfs $HOME, so
# they are gone when the container stops; the sign-out additionally revokes what can be revoked.
#
#   DEPLOY_LOGIN = aws | gcp | both | (empty: no login, tools only)
#
# AWS: `aws login --remote` (console sign-in -> temporary creds, auto-refreshed, <= 12 h; needs the
#   SignInLocalDevelopmentAccess policy). Profile `login` holds the session; `default` exposes it via
#   credential_process so the CLI, coldsnap, and the publish scripts all pick it up with no
#   AWS_PROFILE. Exit: `aws logout --all` (deletes the cache; issued STS creds just expire).
#   With DEPLOY_AWS_ROLE set (Makefile default), `default` is that role assumed from the session.
# GCP: `gcloud auth login --no-launch-browser`. Exit: `gcloud auth revoke --all` (revokes the
#   refresh token server-side -- it does not expire on its own without Cloud Identity session control).
set -uo pipefail

want_aws=0 want_gcp=0
case "${DEPLOY_LOGIN:-}" in
  "")   ;;
  aws)  want_aws=1 ;;
  gcp)  want_gcp=1 ;;
  both) want_aws=1 want_gcp=1 ;;
  *)    echo "deploy: LOGIN must be aws, gcp, or both (got '${DEPLOY_LOGIN}')" >&2; exit 2 ;;
esac

logged_aws=0 logged_gcp=0
signout() {
  trap - EXIT INT TERM HUP
  if [ "$logged_gcp" = 1 ]; then
    echo ">> deploy: revoking gcloud credentials"
    gcloud auth revoke --all --quiet || echo "!! gcloud auth revoke failed -- revoke at https://myaccount.google.com/permissions" >&2
  fi
  if [ "$logged_aws" = 1 ]; then
    echo ">> deploy: aws logout"
    aws logout --all || echo "!! aws logout failed (creds still expire within the session limit)" >&2
  fi
}
trap signout EXIT
trap 'exit 130' INT TERM HUP

if [ "$want_aws" = 1 ]; then
  mkdir -p "$HOME/.aws"
  # DEPLOY_AWS_ROLE set: `default` = that role, assumed from the login session (role creds are
  # cached + refreshed by the CLI). Empty: `default` = the login session itself (root/admin use).
  # The role hop goes via a credential_process profile so it does not depend on source_profile
  # understanding `aws login` sessions directly.
  if [ -n "${DEPLOY_AWS_ROLE:-}" ]; then
    default_from=deploy
    role_profiles="
[profile login-creds]
credential_process = aws configure export-credentials --profile login --format process

[profile deploy]
region = ${AWS_REGION}
role_arn = ${DEPLOY_AWS_ROLE}
role_session_name = lockboot-deploy
source_profile = login-creds
"
  else
    default_from=login role_profiles=""
  fi
  cat > "$HOME/.aws/config" <<EOF
[profile login]
region = ${AWS_REGION}
${role_profiles}
[default]
region = ${AWS_REGION}
credential_process = aws configure export-credentials --profile ${default_from} --format process
EOF
  echo ">> deploy: AWS sign-in (open the URL in a browser, paste the code back)"
  aws login --remote --profile login || exit 1
  logged_aws=1
  aws sts get-caller-identity --output table || exit 1
fi

if [ "$want_gcp" = 1 ]; then
  echo ">> deploy: GCP sign-in (open the URL in a browser, paste the code back)"
  gcloud auth login --no-launch-browser --quiet || exit 1
  logged_gcp=1
  gcloud auth list
  gcloud config list 2>/dev/null
fi

if [ -n "${DEPLOY_CMD:-}" ]; then
  bash -c 'eval "$DEPLOY_CMD"'
else
  bash -l
fi
