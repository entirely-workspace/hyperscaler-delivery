#!/usr/bin/env bash
# pull-images.sh [<functions.json>, default functions/functions.json]
#
# A function's image may be in the customer's own registry, by digest (#1412): "image": "ghcr.io/acme/x@sha256:...".
# This pulls each such image for linux/arm64 before the kit checks the images (deliver.sh, publish.sh store), so the
# check reads it like an image built in the run, and publish.sh pushes it into censhare's ECR like one.
#
# It runs in the customer's CI with that run's own registry login (docker login before the kit's step): censhare never
# sees the login, and nothing at censhare contacts the customer's registry. An image built in the run (a plain name) is
# left alone, and a reference without a digest is left for the check, which refuses it.
#
# Exit: 0 every reference pulled (or none to pull), 1 one could not be pulled (named), 2 could not run.
set -uo pipefail
MANIFEST=${1:-functions/functions.json}
[ -f "$MANIFEST" ] || exit 0
refs=$(jq -r '[.functions[]?.image | select(type == "string" and contains("/") and contains("@sha256:"))] | unique | .[]' "$MANIFEST" 2>/dev/null) \
  || { echo "error: $MANIFEST is not a functions.json the kit can read" >&2; exit 2; }
[ -n "$refs" ] || exit 0
command -v docker >/dev/null || { echo "error: docker is needed to pull the functions' images" >&2; exit 2; }
rc=0
while IFS= read -r ref; do
  if err=$(docker pull --platform linux/arm64 -q "$ref" 2>&1 >/dev/null); then
    echo "pulled $ref"
  else
    echo "error: could not pull $ref: sign in to its registry before the kit's step (docker login), and check that the digest exists: ${err:-no reason given}" >&2
    rc=1
  fi
done <<< "$refs"
exit "$rc"
