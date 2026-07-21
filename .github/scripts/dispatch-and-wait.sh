#!/usr/bin/env bash
#
# Dispatch a target repo's workflow and block until that run completes.
#
# Usage: dispatch-and-wait.sh <org> <repo> <ref> [workflow]
#   workflow defaults to build.yaml
#
# Requires the gh CLI, authenticated via GH_TOKEN in the environment
# (an installation token with Actions: read+write on <org>/<repo>).
#
# Exits non-zero if the target run concludes in failure, so the calling
# GitHub Actions job fails and its `needs:` dependents are skipped.

set -euo pipefail

ORG="${1:?org required}"
REPO="${2:?repo required}"
REF="${3:?ref required}"
WF="${4:-build.yaml}"

# Newest existing run id, so we can tell OUR freshly-dispatched run apart.
before=$(gh run list -R "$ORG/$REPO" --workflow "$WF" --limit 1 \
           --json databaseId --jq '.[0].databaseId // 0')
echo "Latest $REPO run before dispatch: $before"

gh workflow run "$WF" -R "$ORG/$REPO" --ref "$REF"
echo "Dispatched $WF on $ORG/$REPO@$REF; locating the new run…"

rid="$before"
for _ in $(seq 1 40); do
  rid=$(gh run list -R "$ORG/$REPO" --workflow "$WF" --branch "$REF" \
          --event workflow_dispatch --limit 1 \
          --json databaseId --jq '.[0].databaseId // 0')
  if [ "$rid" != "0" ] && [ "$rid" != "$before" ]; then break; fi
  sleep 6
done

if [ "$rid" = "0" ] || [ "$rid" = "$before" ]; then
  echo "::error::Could not find a dispatched run for $ORG/$REPO on $REF"
  exit 1
fi

echo "Watching $ORG/$REPO run $rid"
gh run watch "$rid" -R "$ORG/$REPO" --interval 15 --exit-status
