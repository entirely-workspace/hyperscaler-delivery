#!/usr/bin/env bash
# Deliver this commit's package to a customer (#779): what a delegated partner pipeline runs, in the partner's own CI,
# once its OIDC token has become the customer's publisher role (e.g. aws-actions/configure-aws-credentials with
# role-to-assume). It stores the package in the customer's package store (publish.sh store, next to this script),
# activates it in the delegated stage's cell by digest, waits for the cell's answer and reports it. Prod is never
# delivered by a partner: it takes the customer's approval (#781).
#
# Inputs, as environment variables: CUSTOMER (the customer id), PACKAGES_BUCKET (the customer stack's output), STAGE
# (dev, the default, or test), and optionally ACTIVATE (next-boot or now) and REASON; WAIT_MINUTES (default 20); BRANCH
# (default GITHUB_REF_NAME, else main), whose tip alone is delivered, read from GitHub's API with GH_TOKEN, else origin.
#
# Exit: 0 the cell published or activated it, or a newer push superseded this one, 1 the activation failed or the cell
# refused, 2 not sent.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
STAGE=${STAGE:-dev} WAIT_MINUTES=${WAIT_MINUTES:-20} POLL_SECONDS=${POLL_SECONDS:-10}
fail() { echo "error: $*" >&2; exit 2; }
case "$STAGE" in dev|test) ;; prod) fail "prod is never delivered by a partner: it takes the customer's approval (#781)" ;; *) fail "STAGE must be dev or test, not '$STAGE'" ;; esac
[[ "${CUSTOMER:-}" =~ ^[a-z][a-z0-9-]*$ ]] || fail "CUSTOMER must be the customer id"
[ -n "${PACKAGES_BUCKET:-}" ] || fail "PACKAGES_BUCKET is required (the customer stack's PackagesBucket output)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# 0. Only the branch's tip (#782 review): a re-run or a late run of an older push would roll the stage back. publish.sh
# check reads the tip; on a push it ends green as superseded (a newer push is on its way), on any other run it refuses.
BRANCH=${BRANCH:-${GITHUB_REF_NAME:-main}} OUTCOME_FILE="$TMP/tip.json" bash "$HERE/publish.sh" check || exit 2
[ "$(jq -r '.status // empty' "$TMP/tip.json" 2>/dev/null)" = superseded ] && exit 0

# 1. Stored once, by digest: the same checks as any publish (committed files only, no symlinks).
OUTCOME_FILE="$TMP/stored.json" bash "$HERE/publish.sh" store || exit 2
DIGEST=$(jq -r .digest "$TMP/stored.json") VENDOR=$(jq -r '.package | split("/")[0]' "$TMP/stored.json")

# 2. Activated in the stage's cell by digest. The publisher role may pass FROM_STORE, ACTIVATE and REASON only. As JSON:
# the CLI's shorthand splits on commas, so a reason with one would break the call.
overrides=$(jq -nc --arg d "$DIGEST" --arg a "${ACTIVATE:-}" --arg r "${REASON:-}" \
  '[{name: "FROM_STORE", value: $d}] + (if $a == "" then [] else [{name: "ACTIVATE", value: $a}] end)
     + (if $r == "" then [] else [{name: "REASON", value: $r}] end) | map(. + {type: "PLAINTEXT"})')
project="$CUSTOMER-$VENDOR-$STAGE-activate"
build=$(aws codebuild start-build --project-name "$project" --environment-variables-override "$overrides" \
          --query build.id --output text 2>"$TMP/err") \
  || fail "could not start $project: $(tr '\n' ' ' < "$TMP/err")(is this pipeline delegated for $STAGE?)"
echo "activating $DIGEST in $STAGE ($build)"

# 3. The build's end, then the cell's answer it kept next to the package: this build's, not one an earlier activation
# of the same digest left there.
waited=0
while status=$(aws codebuild batch-get-builds --ids "$build" --query 'builds[0].buildStatus' --output text) && [ "$status" = IN_PROGRESS ]; do
  [ "$waited" -ge $((WAIT_MINUTES * 60)) ] && { echo "error: $build still running after $WAIT_MINUTES minutes" >&2; exit 1; }
  sleep "$POLL_SECONDS"; waited=$((waited + POLL_SECONDS))
done
answer=$(aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$VENDOR/packages/${DIGEST#sha256:}/$STAGE-result.json" "$TMP/result.json" >/dev/null 2>&1 \
           && jq -r --arg b "$build" 'select(.build == $b) | [.status, .reason // empty] | join(": ")' "$TMP/result.json")
echo "$STAGE: ${answer:-no answer from this build} (build $status)"
[ "$status" = SUCCEEDED ] && case "$answer" in published*|activated*) exit 0 ;; esac
exit 1
