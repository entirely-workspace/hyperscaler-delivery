#!/usr/bin/env bash
# build-images.sh [<functions.json>, default functions/functions.json]
#
# A delivery with no CI of its own to build the functions' images (#1526): a CodeCommit repository's build, deployed with
# Functions=yes (lib/customer-codecommit-stack.ts), which sets BUILD_IMAGES=yes for deliver.sh. Elsewhere the customer's
# CI builds each image before the kit's step (GitHub, GitLab), and this does not run.
#
# Each image functions.json names plainly ("image": "checks") is built once, for linux/arm64 (the cells' platform), from
# its folder next to functions.json, functions/<image>/, with its Dockerfile, and tagged with that name, as the customer's
# CI would leave it: the kit then checks it and pushes it into censhare's ECR like any image built in the run. An image
# named by digest from a registry ("ghcr.io/acme/x@sha256:...") is left to pull-images.sh.
#
# functions/build.sh, when there is one, runs first, from the repository's root: what the images need that a commit
# does not hold (a Java function's package, say).
#
# Exit: 0 every image built (or none to build), 1 one could not be built (named), 2 could not run.
set -uo pipefail
MANIFEST=${1:-functions/functions.json}
[ -f "$MANIFEST" ] || exit 0
names=$(jq -r '[.functions[]?.image | select(type == "string" and (contains("/") | not))] | unique | .[]' "$MANIFEST" 2>/dev/null) \
  || { echo "error: $MANIFEST is not a functions.json the kit can read" >&2; exit 2; }
[ -n "$names" ] || exit 0
DIR=$(dirname "$MANIFEST")
# Every name a plain folder name, before anything runs: the name is a path below functions/.
bad=0
while IFS= read -r n; do
  [[ "$n" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] && [[ "$n" != *..* ]] \
    || { echo "error: the image \"$n\" is not a folder name next to $MANIFEST (lower case letters, digits, . _ -, at most 64, as functions.json allows): it cannot be built" >&2; bad=1; }
done <<< "$names"
[ "$bad" = 0 ] || exit 1
command -v docker >/dev/null || { echo "error: docker is needed to build the functions' images (a CodeCommit build: deploy its stack with Functions=yes)" >&2; exit 2; }
if [ -f "$DIR/build.sh" ]; then
  echo "running $DIR/build.sh first"
  bash "$DIR/build.sh" || { echo "error: $DIR/build.sh failed (above): no image was built" >&2; exit 1; }
fi
rc=0
while IFS= read -r n; do
  if [ ! -f "$DIR/$n/Dockerfile" ]; then
    echo "error: $n: there is no $DIR/$n/Dockerfile to build it from" >&2; rc=1; continue
  fi
  if docker build --platform linux/arm64 -t "$n" "$DIR/$n"; then
    echo "built $n from $DIR/$n"
  else
    echo "error: $n: could not be built from $DIR/$n (above)" >&2; rc=1
  fi
done <<< "$names"
exit "$rc"
