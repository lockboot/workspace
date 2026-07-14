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
set -euo pipefail

ORG=lockboot
RULESET_NAME=lockboot-main
REPOS=(stage0 stage1 stage2 vaportpm .github workspace)

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

ruleset_id() { gh api "repos/$ORG/$1/rulesets" --jq ".[] | select(.name==\"$RULESET_NAME\") | .id" 2>/dev/null | head -1; }

# Governance-relevant projection of a ruleset, for drift comparison. Ignores GitHub-added
# metadata (id/_links/source/created_at) and param defaults we don't pin.
salient() {
  jq -S '{
    enforcement,
    linear_history: ([.rules[]?.type] | any(. == "required_linear_history")),
    rule_types:     ([.rules[]?.type] | sort),
    checks:         ([.rules[]? | select(.type=="required_status_checks")
                      | .parameters.required_status_checks[]?.context] | sort)
  }'
}

sync_one() {
  local repo=$1 payload id
  payload=$(desired "$repo") || return 1
  id=$(ruleset_id "$repo")
  if [ -n "$id" ]; then
    printf '%s' "$payload" | gh api "repos/$ORG/$repo/rulesets/$id" -X PUT --input - >/dev/null
    echo "  $repo: updated ruleset ($id)"
  else
    printf '%s' "$payload" | gh api "repos/$ORG/$repo/rulesets" -X POST --input - >/dev/null
    echo "  $repo: created ruleset"
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

check_one() {
  local repo=$1 id want got
  want=$(desired "$repo" | salient) || return 2
  id=$(ruleset_id "$repo")
  if [ -z "$id" ]; then echo "  DRIFT $repo: no '$RULESET_NAME' ruleset"; return 1; fi
  got=$(gh api "repos/$ORG/$repo/rulesets/$id" | salient)
  local legacy
  legacy=$(gh api "repos/$ORG/$repo/rulesets" \
    --jq "[.[] | select(.name != \"$RULESET_NAME\" and .target == \"branch\").name] | join(\", \")" 2>/dev/null)
  if [ "$want" = "$got" ] && [ -z "$legacy" ]; then
    echo "  ok    $repo"
  else
    echo "  DRIFT $repo:"
    [ "$want" != "$got" ] && diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/      /'
    [ -n "$legacy" ] && echo "      + legacy branch ruleset(s) to remove: $legacy"
    return 1
  fi
}

cmd=${1:-check}; shift || true
targets=("$@"); [ ${#targets[@]} -eq 0 ] && targets=("${REPOS[@]}")

case "$cmd" in
  show)  for r in "${targets[@]}"; do echo "== $r ==" >&2; desired "$r"; done ;;
  sync)  echo "sync rulesets ($RULESET_NAME) onto: ${targets[*]}"; for r in "${targets[@]}"; do sync_one "$r"; done ;;
  check) echo "check rulesets ($RULESET_NAME) on: ${targets[*]}"; rc=0; for r in "${targets[@]}"; do check_one "$r" || rc=1; done; exit $rc ;;
  *)     echo "usage: $0 {sync|check|show} [repo...]" >&2; exit 2 ;;
esac
