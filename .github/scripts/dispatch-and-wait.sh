#!/usr/bin/env bash
#
# Dispatch a target repo's workflow and block until that run completes.
#
# Usage: dispatch-and-wait.sh <org> <repo> [ref] [workflow] [php]
#   ref       branch to build; empty ("") -> the repo's default branch
#   workflow  defaults to build.yaml
#   php       optional PHP-minor selector passed to the target as `-f php=<v>`
#             (e.g. 8.5); omitted or "all" -> no input passed (target builds all)
#
# Requires the gh CLI, authenticated via GH_TOKEN in the environment
# (an installation token with Actions: read+write on <org>/<repo>).
#
# Exits non-zero if the target run concludes in failure, so the calling
# GitHub Actions job fails and its `needs:` dependents are skipped.

set -euo pipefail

ORG="${1:?org required}"
REPO="${2:?repo required}"
REF="${3:-}"
WF="${4:-build.yaml}"
PHP="${5:-}"

# Branch-name history differs across repos (older ones default to `master`,
# newer ones to `main`) with no semantic meaning — don't assume either. When no
# ref is given, resolve the target's actual default branch. Run-matching filters
# by --branch, so a provided REF must be a branch (a tag/SHA would dispatch but
# never be found here -> 40-poll timeout, exit 1).
if [ -z "$REF" ]; then
  REF=$(gh repo view "$ORG/$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')
fi

run_args=(workflow run "$WF" -R "$ORG/$REPO" --ref "$REF")
php_note=""
if [ -n "$PHP" ] && [ "$PHP" != "all" ]; then
  run_args+=(-f "php=$PHP")
  php_note=" (php=$PHP)"        # only annotate the log when php is actually sent
fi

# `gh workflow run` returns no run id (the dispatch API answers 204 No Content),
# so we identify OUR run as "the newest workflow_dispatch run on $REF that did
# not exist before we dispatched". The `before` snapshot MUST use the SAME
# filters as the poll loop (same list_args) — otherwise a pre-existing older
# dispatch run could be mistaken for ours and we'd watch the wrong run.
list_args=(run list -R "$ORG/$REPO" --workflow "$WF" --branch "$REF"
           --event workflow_dispatch --limit 1 --json databaseId
           --jq '.[0].databaseId // 0')

before=$(gh "${list_args[@]}")
echo "Latest $REPO workflow_dispatch run on $REF before dispatch: $before"

gh "${run_args[@]}"
echo "Dispatched $WF on $ORG/$REPO@$REF${php_note}; locating the new run…"

rid="$before"
for _ in $(seq 1 40); do
  rid=$(gh "${list_args[@]}")
  if [ "$rid" != "0" ] && [ "$rid" != "$before" ]; then break; fi
  sleep 6
done

if [ "$rid" = "0" ] || [ "$rid" = "$before" ]; then
  echo "::error::Could not find a dispatched run for $ORG/$REPO on $REF"
  exit 1
fi

echo "Watching $ORG/$REPO run $rid"
gh run watch "$rid" -R "$ORG/$REPO" --interval 15 --exit-status
