#!/usr/bin/env bash
# lockboot branch-ruleset governance -- one canonical ruleset, applied to every repo.
#
# The policy IS this script; there is no JSON on disk. `sync` creates/updates the
# ruleset on each repo, `check` fails on drift. Needs `gh` authenticated with admin on
# the target repos, plus `jq`.
#
#   tools/rulesets.sh show  [repo...]   # print the desired ruleset JSON (no API calls)
#   tools/rulesets.sh check [repo...]   # drift-check (exit 1 on drift)   -- default
#   tools/rulesets.sh sync  [repo...]   # create/update to match the policy
#
# Policy -- structural rules identical on every repo, a per-repo CI gate on top:
#   * require a PR to the default branch (0 approvals: solo maintainer), no force-push,
#     no branch deletion
#   * NO required-linear-history -- merge commits are the workflow (linear history would
#     forbid them and force squash/rebase)
#   * repo admins may bypass (so a red/flaky CI can't lock you out entirely)
#   * required status checks per repo (below). Convention: `ci` (fmt + clippy + test) and
#     `build-x86_64` / `build-aarch64`. `.github` has no CI, so no checks.
#
# Release policy -- on repos that cut releases (those with a release-tag pattern below):
#   * a second ruleset, lockboot-release-tags, on the repo's release tags: creation,
#     update (move), and deletion are restricted, so only a repo admin (bypass) can cut a
#     release tag and nobody can move or delete one. Other tags are unrestricted.
#   * immutable releases: once published, a release's assets and tag are locked, and GitHub
#     signs a release attestation (`gh release verify` / `verify-asset`). Title, notes, and
#     the prerelease/latest flags stay editable; a bad release is deprecated (or deleted --
#     its tag name can never be reused), not changed. Applies to releases published after
#     it is enabled.
set -euo pipefail

ORG=lockboot
RULESET_NAME=lockboot-main
TAG_RULESET_NAME=lockboot-release-tags
REPOS=(stage0 stage1 stage2 vaportpm .github workspace)

# GitHub repo name -> release-tag ref pattern (empty = the repo cuts no releases: no tag
# ruleset, no immutable-releases setting). Every release repo uses plain `v*` (one product per
# repo); must match the tags each release workflow triggers on.
release_tag_pattern() {
  case "$1" in
    stage0|stage1|stage2|vaportpm) echo "refs/tags/v*" ;;
    .github|workspace)             echo "" ;;
    *) return 1 ;;
  esac
}

# GitHub repo name -> required check contexts (space-separated; empty = no CI gate).
required_checks() {
  case "$1" in
    stage0|stage1|stage2) echo "ci build-x86_64 build-aarch64" ;;
    vaportpm)             echo "ci" ;;
    .github|workspace)    echo "" ;;   # no CI workflows -> structural protection only
    *) return 1 ;;
  esac
}

for t in gh jq; do command -v "$t" >/dev/null || { echo "missing required tool: $t" >&2; exit 1; }; done

# The desired ruleset JSON for one repo.
desired() {
  local repo=$1 checks ctx='[]'
  checks=$(required_checks "$repo") || { echo "unknown repo: $repo" >&2; return 1; }
  [ -n "$checks" ] && ctx=$(printf '%s\n' $checks | jq -R '{context: .}' | jq -s .)
  jq -n --arg name "$RULESET_NAME" --argjson checks "$ctx" '
    {
      name: $name,
      target: "branch",
      enforcement: "active",
      conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
      # Repo admins bypass (actor_id 5 = the built-in Admin repository role).
      bypass_actors: [ { actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always" } ],
      rules: (
        [ { type: "deletion" },
          { type: "non_fast_forward" },
          { type: "pull_request", parameters: {
              required_approving_review_count: 0,
              dismiss_stale_reviews_on_push: false,
              require_code_owner_review: false,
              require_last_push_approval: false,
              required_review_thread_resolution: false } } ]
        + ( if ($checks | length) > 0
            then [ { type: "required_status_checks", parameters: {
                     strict_required_status_checks_policy: false,
                     required_status_checks: $checks } } ]
            else [] end )
      )
    }'
}

# The desired release-tag ruleset JSON for one repo (only called when it has a pattern).
desired_tags() {
  local pattern
  pattern=$(release_tag_pattern "$1") || { echo "unknown repo: $1" >&2; return 1; }
  jq -n --arg name "$TAG_RULESET_NAME" --arg pattern "$pattern" '
    {
      name: $name,
      target: "tag",
      enforcement: "active",
      conditions: { ref_name: { include: [$pattern], exclude: [] } },
      # Repo admins bypass: the only actor that can cut (create) a release tag.
      bypass_actors: [ { actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always" } ],
      rules: [ { type: "creation" }, { type: "update" }, { type: "deletion" },
               { type: "non_fast_forward" } ]
    }'
}

# ruleset_id <repo> [name]  (name defaults to the branch ruleset)
ruleset_id() { gh api "repos/$ORG/$1/rulesets" --jq ".[] | select(.name==\"${2:-$RULESET_NAME}\") | .id" 2>/dev/null | head -1; }

# Governance-relevant projection of a ruleset, for drift comparison. Ignores GitHub-added
# metadata (id/_links/source/created_at) and param defaults we don't pin.
salient() {
  jq -S '{
    enforcement,
    target,
    include:        ([.conditions.ref_name.include[]?] | sort),
    linear_history: ([.rules[]?.type] | any(. == "required_linear_history")),
    rule_types:     ([.rules[]?.type] | sort),
    checks:         ([.rules[]? | select(.type=="required_status_checks")
                      | .parameters.required_status_checks[]?.context] | sort)
  }'
}

# upsert_ruleset <repo> <name> <payload>: create or update the named ruleset.
upsert_ruleset() {
  local repo=$1 name=$2 payload=$3 id
  id=$(ruleset_id "$repo" "$name")
  if [ -n "$id" ]; then
    printf '%s' "$payload" | gh api "repos/$ORG/$repo/rulesets/$id" -X PUT --input - >/dev/null
    echo "  $repo: updated ruleset $name ($id)"
  else
    printf '%s' "$payload" | gh api "repos/$ORG/$repo/rulesets" -X POST --input - >/dev/null
    echo "  $repo: created ruleset $name"
  fi
}

immutable_enabled() { gh api "repos/$ORG/$1/immutable-releases" --jq .enabled 2>/dev/null; }

sync_one() {
  local repo=$1 payload pattern
  payload=$(desired "$repo") || return 1
  upsert_ruleset "$repo" "$RULESET_NAME" "$payload"
  pattern=$(release_tag_pattern "$repo")
  if [ -n "$pattern" ]; then
    upsert_ruleset "$repo" "$TAG_RULESET_NAME" "$(desired_tags "$repo")"
    gh api -X PUT "repos/$ORG/$repo/immutable-releases" >/dev/null
    echo "  $repo: immutable releases enabled"
  fi
  # Remove any other (legacy, differently-named) branch rulesets so exactly one canonical policy
  # governs the default branch -- e.g. the old main-protect / protect-main this migration replaces.
  gh api "repos/$ORG/$repo/rulesets" \
    --jq ".[] | select(.name != \"$RULESET_NAME\" and .target == \"branch\") | .id" 2>/dev/null |
    while read -r oid; do
      [ -n "$oid" ] || continue
      gh api -X DELETE "repos/$ORG/$repo/rulesets/$oid" >/dev/null 2>&1 &&
        echo "  $repo: removed legacy branch ruleset $oid"
    done
}

# check_ruleset <repo> <name> <desired-json>: print drift (if any) for one ruleset; 1 on drift.
check_ruleset() {
  local repo=$1 name=$2 want got id
  want=$(printf '%s' "$3" | salient)
  id=$(ruleset_id "$repo" "$name")
  if [ -z "$id" ]; then echo "      no '$name' ruleset"; return 1; fi
  got=$(gh api "repos/$ORG/$repo/rulesets/$id" | salient)
  [ "$want" = "$got" ] && return 0
  echo "      $name:"; diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/        /'
  return 1
}

check_one() {
  local repo=$1 desired_json pattern legacy report rc=0
  desired_json=$(desired "$repo") || return 2
  pattern=$(release_tag_pattern "$repo")
  report=$(
    check_ruleset "$repo" "$RULESET_NAME" "$desired_json" || echo FAIL
    legacy=$(gh api "repos/$ORG/$repo/rulesets" \
      --jq "[.[] | select(.name != \"$RULESET_NAME\" and .target == \"branch\").name] | join(\", \")" 2>/dev/null)
    [ -n "$legacy" ] && { echo "      legacy branch ruleset(s) to remove: $legacy"; echo FAIL; }
    if [ -n "$pattern" ]; then
      check_ruleset "$repo" "$TAG_RULESET_NAME" "$(desired_tags "$repo")" || echo FAIL
      [ "$(immutable_enabled "$repo")" = "true" ] || { echo "      immutable releases: not enabled"; echo FAIL; }
    fi
  )
  if printf '%s\n' "$report" | grep -qx FAIL; then
    echo "  DRIFT $repo:"; printf '%s\n' "$report" | grep -vx FAIL
    rc=1
  else
    echo "  ok    $repo"
  fi
  return $rc
}

cmd=${1:-check}; shift || true
targets=("$@"); [ ${#targets[@]} -eq 0 ] && targets=("${REPOS[@]}")

case "$cmd" in
  show)  for r in "${targets[@]}"; do
           echo "== $r ==" >&2; desired "$r"
           if [ -n "$(release_tag_pattern "$r")" ]; then desired_tags "$r"; echo "(+ immutable releases)" >&2; fi
         done ;;
  sync)  echo "sync rulesets ($RULESET_NAME) onto: ${targets[*]}"; for r in "${targets[@]}"; do sync_one "$r"; done ;;
  check) echo "check rulesets ($RULESET_NAME) on: ${targets[*]}"; rc=0; for r in "${targets[@]}"; do check_one "$r" || rc=1; done; exit $rc ;;
  *)     echo "usage: $0 {sync|check|show} [repo...]" >&2; exit 2 ;;
esac
