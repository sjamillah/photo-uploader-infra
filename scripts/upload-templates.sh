#!/usr/bin/env bash
# Upload the child templates under this commit, then point the deployment file
# at them. That second commit is what Git sync deploys, which is how the root
# stack never sees a half-uploaded set.
#
#   scripts/upload-templates.sh <bucket> <sha>
set -euo pipefail

BUCKET="${1:?usage: upload-templates.sh <bucket> <sha>}"
SHA="${2:?missing commit sha}"
DEPLOYMENT_FILE="${DEPLOYMENT_FILE:-deployments/main.yaml}"

pinned="$(sed -nE 's|^  TemplateVersion: ||p' "$DEPLOYMENT_FILE")"

# Upload unless the templates are already sitting where main.yaml will look for
# them and nothing has changed since. Asking S3 rather than tracking it in the
# repository means an emptied or recreated bucket fixes itself on the next run.
if aws s3 ls "s3://$BUCKET/$pinned/vpc.yaml" >/dev/null 2>&1 &&
   git diff --quiet HEAD~1 HEAD -- templates/; then
  echo "already staged at $pinned"
  exit 0
fi

# Everything in templates/ is a nested child, so there is nothing to exclude.
# main.yaml lives at the repository root and Git sync reads it from there.
aws s3 sync templates/ "s3://$BUCKET/$SHA/" \
  --exclude "*" --include "*.yaml" --no-progress

# Only the commit goes into the file. The bucket comes from Parameter
# Store at deploy time, so the account id stays out of the repository.
sed -i -E "s|^(  TemplateVersion: ).*|\1$SHA|" "$DEPLOYMENT_FILE"

if git diff --quiet "$DEPLOYMENT_FILE"; then
  echo "already pointing at $SHA"
  exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git commit -qm "Point main stack at templates from $SHA [skip ci]" -- "$DEPLOYMENT_FILE"
git push

echo "pointed at $SHA"
