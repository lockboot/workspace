#!/usr/bin/env bash
# Idempotent AWS IAM setup for Lock.Boot deploys. Run once by an account admin (e.g. root inside
# `make deploy-shell LOGIN=aws`); re-run any time to converge the account back to this definition.
#
# Creates / converges:
#   - IAM user  (default `lockboot`): console sign-in + passkey MFA only. Its permissions are
#     SignInLocalDevelopmentAccess (for `aws login`) and sts:AssumeRole on the deploy role, nothing else.
#   - IAM role  (default `lockboot-deploy`): trusted only by that user, with MFA required. Holds the
#     least privilege the stage0 publish scripts need (tools/publish/{ec2,cleanup.sh}): EC2 + EBS
#     direct API in any region, plus objects in a list of S3 buckets.
#   - The EC2 Spot service-linked role (AWS normally creates it on first spot launch, but that needs
#     iam:CreateServiceLinkedRole, which the deploy role deliberately does not have).
#
# Not done here (needs a browser, and keeps the password out of shell history): giving the user a
# console password and registering its passkey as MFA. IAM users cannot sign in passwordless --
# the passkey is the second factor -- and `aws login` is console sign-in, so both are required.
# The script warns when either is missing.
#
# Every setting can be overridden by a flag or an environment variable (flag wins).
set -euo pipefail

ACCOUNT="${LOCKBOOT_AWS_ACCOUNT:-182712153326}"
USER_NAME="${LOCKBOOT_AWS_USER:-lockboot}"
ROLE_NAME="${LOCKBOOT_AWS_ROLE:-lockboot-deploy}"
BUCKETS="${LOCKBOOT_AWS_BUCKETS:-lockboot-ap-southeast-1}"
# Tag stage0 tools/publish/ec2/launch.sh puts on every instance; Start/Stop/Reboot need it.
INSTANCE_TAG="${LOCKBOOT_AWS_INSTANCE_TAG:-Project=lockboot}"
USER_POLICY="${LOCKBOOT_AWS_USER_POLICY:-assume-${ROLE_NAME}}"
ROLE_POLICY="${LOCKBOOT_AWS_ROLE_POLICY:-deploy}"
DRY_RUN=0

usage() {
  cat <<EOF
usage: $0 [options]

  --account ID        AWS account to configure; refuses to run against any other ($ACCOUNT)  [LOCKBOOT_AWS_ACCOUNT]
  --user NAME         IAM user that signs in with a passkey ($USER_NAME)                       [LOCKBOOT_AWS_USER]
  --role NAME         deploy role the user assumes ($ROLE_NAME)                                [LOCKBOOT_AWS_ROLE]
  --buckets B[,B..]   S3 buckets the role may read/write objects in ($BUCKETS)  [LOCKBOOT_AWS_BUCKETS]
  --instance-tag K=V  only instances with this tag may be started/stopped/rebooted ($INSTANCE_TAG)  [LOCKBOOT_AWS_INSTANCE_TAG]
  --user-policy NAME  inline policy name on the user ($USER_POLICY)                         [LOCKBOOT_AWS_USER_POLICY]
  --role-policy NAME  inline policy name on the role ($ROLE_POLICY)                                  [LOCKBOOT_AWS_ROLE_POLICY]
  --dry-run           print the policies and the changes that would be made; change nothing
  -h, --help          this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --account)     ACCOUNT="$2"; shift 2 ;;
    --user)        USER_NAME="$2"; shift 2 ;;
    --role)        ROLE_NAME="$2"; shift 2 ;;
    --buckets)     BUCKETS="$2"; shift 2 ;;
    --instance-tag) INSTANCE_TAG="$2"; shift 2 ;;
    --user-policy) USER_POLICY="$2"; shift 2 ;;
    --role-policy) ROLE_POLICY="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log() { echo ">> $*" >&2; }
die() { echo "!! $*" >&2; exit 1; }
# Mutating calls go through `change`, so --dry-run shows them without making them.
change() {
  if [ "$DRY_RUN" = 1 ]; then echo "   would run: $*" >&2; else "$@" >/dev/null; fi
}

command -v aws >/dev/null || die "aws CLI not found"
command -v jq  >/dev/null || die "jq not found"

caller=$(aws sts get-caller-identity --output json) || die "not signed in to AWS"
caller_acct=$(jq -r .Account <<<"$caller")
[ "$caller_acct" = "$ACCOUNT" ] \
  || die "signed in to account $caller_acct, expected $ACCOUNT (pass --account to change)"
log "signed in as $(jq -r .Arn <<<"$caller")"

USER_ARN="arn:aws:iam::${ACCOUNT}:user/${USER_NAME}"
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"

user_doc=$(jq -nc --arg role "$ROLE_ARN" '{
  Version: "2012-10-17",
  Statement: [{Effect: "Allow", Action: "sts:AssumeRole", Resource: $role}]}')

trust_doc=$(jq -nc --arg user "$USER_ARN" '{
  Version: "2012-10-17",
  Statement: [{Effect: "Allow", Principal: {AWS: $user}, Action: "sts:AssumeRole",
               Condition: {Bool: {"aws:MultiFactorAuthPresent": "true"}}}]}')

case "$INSTANCE_TAG" in ?*=?*) ;; *) die "--instance-tag must be KEY=VALUE (got '$INSTANCE_TAG')" ;; esac

# The calls tools/publish/ec2/{create,launch}.sh and cleanup.sh make, plus Start/Stop/Reboot for
# hand-testing. Start/Stop/Reboot only reach instances carrying INSTANCE_TAG; that scoping holds
# because CreateTags can tag an instance only as part of RunInstances (so the role cannot tag an
# instance it did not launch), otherwise only images and snapshots (create.sh). Buckets are
# comma-separated.
perms_doc=$(jq -nc --arg buckets "$BUCKETS" --arg acct "$ACCOUNT" \
    --arg tagk "${INSTANCE_TAG%%=*}" --arg tagv "${INSTANCE_TAG#*=}" '
  ($buckets | split(",")) as $b | ("arn:aws:ec2:*:" + $acct + ":instance/*") as $inst | {
  Version: "2012-10-17",
  Statement: [
    {Sid: "Ec2Ebs", Effect: "Allow", Resource: "*",
     Action: ["ec2:DescribeImages", "ec2:DescribeSnapshots", "ec2:DescribeInstances",
              "ec2:DescribeRegions", "ec2:RegisterImage", "ec2:DeregisterImage",
              "ec2:ModifyImageAttribute", "ec2:DeleteSnapshot", "ec2:ModifySnapshotAttribute",
              "ec2:RunInstances", "ec2:TerminateInstances", "ec2:GetConsoleOutput",
              "ebs:StartSnapshot", "ebs:PutSnapshotBlock", "ebs:CompleteSnapshot"]},
    {Sid: "TagImagesSnapshots", Effect: "Allow", Action: "ec2:CreateTags",
     Resource: ["arn:aws:ec2:*::image/*", "arn:aws:ec2:*::snapshot/*"]},  # EC2 ARNs carry no account here
    {Sid: "TagInstancesAtLaunch", Effect: "Allow", Action: "ec2:CreateTags", Resource: $inst,
     Condition: {StringEquals: {"ec2:CreateAction": "RunInstances"}}},
    {Sid: "PowerTaggedInstances", Effect: "Allow", Resource: $inst,
     Action: ["ec2:StartInstances", "ec2:StopInstances", "ec2:RebootInstances"],
     Condition: {StringEquals: {("aws:ResourceTag/" + $tagk): $tagv}}},
    {Sid: "Bucket", Effect: "Allow", Action: "s3:ListBucket",
     Resource: [$b[] | "arn:aws:s3:::" + .]},
    {Sid: "Objects", Effect: "Allow",
     Action: ["s3:GetObject", "s3:PutObject", "s3:PutObjectAcl", "s3:DeleteObject"],
     Resource: [$b[] | "arn:aws:s3:::" + . + "/*"]}]}')

if [ "$DRY_RUN" = 1 ]; then
  log "user policy ($USER_POLICY):";  jq . <<<"$user_doc" >&2
  log "role trust policy:";           jq . <<<"$trust_doc" >&2
  log "role policy ($ROLE_POLICY):";  jq . <<<"$perms_doc" >&2
fi

# --- user ----------------------------------------------------------------------------------------
if aws iam get-user --user-name "$USER_NAME" >/dev/null 2>&1; then
  log "user $USER_NAME exists"
else
  log "creating user $USER_NAME"
  change aws iam create-user --user-name "$USER_NAME"
fi
aws iam get-login-profile --user-name "$USER_NAME" >/dev/null 2>&1 \
  || log "WARNING: $USER_NAME has no console password (IAM > Users > $USER_NAME > Security credentials > Console access)"
[ "$(aws iam list-mfa-devices --user-name "$USER_NAME" --query 'length(MFADevices)' --output text 2>/dev/null)" -gt 0 ] 2>/dev/null \
  || log "WARNING: $USER_NAME has no MFA device; register a passkey (same page)"

log "user $USER_NAME: attach SignInLocalDevelopmentAccess, put inline policy $USER_POLICY"
change aws iam attach-user-policy --user-name "$USER_NAME" \
  --policy-arn arn:aws:iam::aws:policy/SignInLocalDevelopmentAccess
change aws iam put-user-policy --user-name "$USER_NAME" --policy-name "$USER_POLICY" \
  --policy-document "$user_doc"

# --- role ----------------------------------------------------------------------------------------
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  log "role $ROLE_NAME exists: updating trust policy"
  change aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$trust_doc"
else
  log "creating role $ROLE_NAME"
  change aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$trust_doc" \
    --description "Lock.Boot deploy (assumed by IAM user ${USER_NAME} with MFA)"
fi
log "role $ROLE_NAME: put inline policy $ROLE_POLICY"
change aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "$ROLE_POLICY" \
  --policy-document "$perms_doc"

# --- spot service-linked role --------------------------------------------------------------------
if aws iam get-role --role-name AWSServiceRoleForEC2Spot >/dev/null 2>&1; then
  log "spot service-linked role exists"
else
  log "creating spot service-linked role"
  change aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
fi

if [ "$DRY_RUN" = 1 ]; then log "dry run: nothing changed"; else log "done: $ROLE_ARN"; fi
