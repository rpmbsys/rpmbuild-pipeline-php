#!/usr/bin/env bash
#
# Dispatch a target repo's workflow and block until that run completes.
#
# Usage: dispatch-and-wait.sh <org> <repo> <ref> [workflow] [php]
#   workflow defaults to build.yaml
#   php      optional PHP-minor selector passed to the target as `-f php=<v>`
#            (e.g. 8.5); omitted or "all" -> no input passed (target builds all)
#
# Requires the gh CLI, authenticated via GH_TOKEN in the environment
# (an installation token with Actions: read+write on <org>/<repo>).
#
# Exits non-zero if the target run concludes in failure, so the calling
# GitHub Actions job fails and its `needs:` dependents are skipped.

set -euo pipefail

ORG="${1:?org required}"
REPO="${2:?repo required}"
REF="${3:?ref required}"          # must be a BRANCH name — see run-matching below
WF="${4:-build.yaml}"
PHP="${5:-}"

run_args=(workflow run "$WF" -R "$ORG/$REPO" --ref "$REF")
php_note=""
if [ -n "$PHP" ] && [ "$PHP" != "all" ]; then
  run_args+=(-f "php=$PHP")
  php_note=" (php=$PHP)"        # only annotate the log when php is actually sent
fi

# `gh workflow run` returns no run id (the dispatch API answers 204 No Content),
# so we identify OUR run as "the newest workflow_dispatch run on this branch that
# did not exist before we dispatched". The `before` snapshot MUST use the SAME
# filters as the poll loop (same list_args) — otherwise a pre-existing older
# dispatch run could be mistaken for ours and we'd watch the wrong run.
#
# Run-matching filters by --branch, so REF must be a branch name: tags/SHAs will
# dispatch fine but never be found here (-> 40-poll timeout, exit 1). The
# orchestrator only ever passes branches (master).
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
