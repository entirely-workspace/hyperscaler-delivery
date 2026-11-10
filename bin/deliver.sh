#!/usr/bin/env bash
# Deliver this commit's package to a customer (#779): what a delegated partner pipeline runs, in the partner's own CI,
# once its OIDC token has become the customer's publisher role (e.g. aws-actions/configure-aws-credentials with
# role-to-assume). It stores the package in the customer's package store (publish.sh store, next to this script),
# activates it in the delegated stage's cell by digest, waits for the cell's answer and reports it. Prod is never
# delivered by a partner: it takes the customer's approval (#781).
#
# Inputs, as environment variables: CUSTOMER (the customer id), PACKAGES_BUCKET (the customer stack's output), STAGE
# (dev, the default, or test), and optionally ACTIVATE (next-boot or now) and REASON; WAIT_MINUTES (default 20); BRANCH,
# whose tip alone is delivered: by default the CI's own branch (GitHub's GITHUB_REF_NAME on a branch, GitLab's
# CI_COMMIT_BRANCH, CodeBuild's CODEBUILD_WEBHOOK_HEAD_REF), else main. The tip is read from BRANCH_TIP when the build
# read it already (the CodeCommit template, before it signs in as the publisher role), else GitHub's API with GH_TOKEN,
# else origin. EVENT=push (GitHub's GITHUB_EVENT_NAME, GitLab's CI_PIPELINE_SOURCE) lets a push overtaken by a newer one
# end green. A run on a tag (a delegation may name refs/tags/...) has no tip to compare with: it is delivered as it is,
# so a re-run after the tag was moved delivers the commit it named then (a delegation names one exact tag).
#
# The same as flags, for any other CI or a one-off run (#936); a flag wins over its variable:
#
#   deliver.sh --customer <id> --packages-bucket <bucket> [--stage dev|test] [--activate next-boot|now] [--reason <why>]
#              [--branch <branch>] [--wait-minutes <n>] [--region <region>] [--publisher-role <arn>]
#
# --publisher-role signs in as that role with the CI's OIDC token in AWS_WEB_IDENTITY_TOKEN_FILE (the AWS CLI's own web
# identity sign-in). Without it, the credentials already in the environment are used, as the Action and the GitLab
# template set them.
#
# Before anything is stored, the package is checked as the cell's intake checks it (validate.sh, next to this script in
# the kit): a package the cell would refuse is never stored. Without validate.sh next to it (an older copy in a
# repository's tools/, #826), the cell alone checks it.
#
# Exit: 0 the cell published or activated it, or a newer push superseded this one, 1 the activation failed or the cell
# refused (or would refuse: the check before storing), 2 not sent.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
fail() { echo "error: $*" >&2; exit 2; }
usage() { sed -n '/^#   deliver.sh --customer/,/^#              \[--branch/p' "$0" | sed 's/^# \{0,1\}//'; }
ROLE=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --customer|--packages-bucket|--stage|--activate|--reason|--branch|--wait-minutes|--region|--publisher-role)
      [ $# -ge 2 ] || fail "$1 needs a value"
      case "$1" in
        --customer) CUSTOMER=$2 ;; --packages-bucket) PACKAGES_BUCKET=$2 ;; --stage) STAGE=$2 ;;
        --activate) ACTIVATE=$2 ;; --reason) REASON=$2 ;; --branch) BRANCH=$2 ;; --wait-minutes) WAIT_MINUTES=$2 ;;
        --region) export AWS_REGION=$2 AWS_DEFAULT_REGION=$2 ;; --publisher-role) ROLE=$2 ;;
      esac
      shift 2 ;;
    *) usage >&2; fail "unknown argument '$1'" ;;
  esac
done
if [ -n "$ROLE" ]; then
  [[ "$ROLE" =~ ^arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$ ]] || fail "--publisher-role must be a role ARN"
  [ -n "${AWS_WEB_IDENTITY_TOKEN_FILE:-}" ] && [ -s "$AWS_WEB_IDENTITY_TOKEN_FILE" ] \
    || fail "--publisher-role signs in with the CI's OIDC token: set AWS_WEB_IDENTITY_TOKEN_FILE to the file that holds it"
  # Keys in the environment would win over the role (the AWS CLI's order), and the package would go out as someone else.
  [ -z "${AWS_ACCESS_KEY_ID:-}" ] || fail "--publisher-role and AWS_ACCESS_KEY_ID both given: use one"
  # So would a profile in the runner's ~/.aws files (role_arn, credential_process): those come before web identity.
  # Neither file is read, so the region comes from --region or AWS_REGION.
  [ -n "${AWS_REGION:-${AWS_DEFAULT_REGION:-}}" ] || fail "--publisher-role needs --region (or AWS_REGION): the AWS config file is not read"
  export AWS_ROLE_ARN=$ROLE AWS_ROLE_SESSION_NAME=${AWS_ROLE_SESSION_NAME:-censhare-deliver} \
    AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
  unset AWS_PROFILE
fi
STAGE=${STAGE:-dev} WAIT_MINUTES=${WAIT_MINUTES:-20} POLL_SECONDS=${POLL_SECONDS:-10}
case "$STAGE" in dev|test) ;; prod) fail "prod is never delivered by a partner: it takes the customer's approval (#781)" ;; *) fail "STAGE must be dev or test, not '$STAGE'" ;; esac
[[ "$WAIT_MINUTES" =~ ^[0-9]+$ ]] || fail "WAIT_MINUTES (--wait-minutes) must be a whole number of minutes, not '$WAIT_MINUTES'"
[[ "${CUSTOMER:-}" =~ ^[a-z][a-z0-9-]*$ ]] || fail "CUSTOMER must be the customer id"
[ -n "${PACKAGES_BUCKET:-}" ] || fail "PACKAGES_BUCKET is required (the customer stack's PackagesBucket output)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# 0. Only the branch's tip (#782 review, #886 for other CIs): a re-run or a late run of an older push would roll the
# stage back. publish.sh check reads the tip; on a push it ends green as superseded (a newer push is on its way), on any
# other run it refuses. Checked again before each start that had to wait (step 2): a newer push may have activated
# meanwhile. A tag is delivered as it is: it has no tip to check against.
if [[ "${GITHUB_REF:-}" == refs/tags/* ]] || [ -n "${CI_COMMIT_TAG:-}" ]; then
  TAG=yes; echo "a tag: delivered as it is (a tag has no tip to check against)"
else
  TAG=
  if [ -z "${BRANCH:-}" ]; then
    if [[ "${GITHUB_REF:-}" == refs/heads/* ]]; then BRANCH=$GITHUB_REF_NAME
    elif [ -n "${CI_COMMIT_BRANCH:-}" ]; then BRANCH=$CI_COMMIT_BRANCH
    elif [ -n "${CODEBUILD_WEBHOOK_HEAD_REF:-}" ]; then BRANCH=${CODEBUILD_WEBHOOK_HEAD_REF#refs/heads/}
    else BRANCH=main; fi
  fi
  [ -n "${EVENT:-}" ] || { [ "${CI_PIPELINE_SOURCE:-}" = push ] && EVENT=push; }
fi
tip() {
  [ -n "$TAG" ] && return 0
  rm -f "$TMP/tip.json"
  BRANCH=$BRANCH EVENT=${EVENT:-${GITHUB_EVENT_NAME:-}} OUTCOME_FILE="$TMP/tip.json" bash "$HERE/publish.sh" check || exit 2
  [ "$(jq -r '.status // empty' "$TMP/tip.json" 2>/dev/null)" = superseded ] && exit 0
  return 0
}
tip

# 1a. Checked as the cell's intake checks it, before anything is stored: a refused package never reaches the store.
# Exactly the files publish.sh stores (customization.json and the source folder's committed files, as the commit has
# them): not the working tree's other folders or ignored files, and no export-ignore or export-subst in the way.
if [ -f "$HERE/validate.sh" ]; then
  SRC=$(git show HEAD:./customization.json 2>/dev/null | jq -r '.source // empty' 2>/dev/null)
  mkdir -p "$TMP/commit"
  while IFS= read -r -d '' f; do
    mkdir -p "$TMP/commit/$(dirname "$f")" && git show "HEAD:./$f" > "$TMP/commit/$f" 2>/dev/null \
      || fail "could not read $f from the commit to check it (commit your changes first)"
  done < <(git ls-files -z -- customization.json ${SRC:+"$SRC"})
  KIT=$(cat "$HERE/../VERSION" 2>/dev/null || echo "this repository's")
  echo "checking the package as the cell's intake does (the validator of kit $KIT; the cell's own check decides)"
  bash "$HERE/validate.sh" "$TMP/commit"
  case $? in
    0) ;;
    1) echo "error: the package does not pass the cell's checks (above): nothing was stored" >&2; exit 1 ;;
    *) fail "the package could not be checked (above): nothing was stored" ;;
  esac
else
  echo "validate.sh is not next to $0: the cell alone checks the package"
fi

# 1. Stored once, by digest: the same checks as any publish (committed files only, no symlinks).
OUTCOME_FILE="$TMP/stored.json" bash "$HERE/publish.sh" store || exit 2
DIGEST=$(jq -r .digest "$TMP/stored.json") VENDOR=$(jq -r '.package | split("/")[0]' "$TMP/stored.json")

# 2. Activated in the stage's cell by digest. The publisher role may pass FROM_STORE, ACTIVATE and REASON only. As JSON:
# the CLI's shorthand splits on commas, so a reason with one would break the call.
overrides=$(jq -nc --arg d "$DIGEST" --arg a "${ACTIVATE:-}" --arg r "${REASON:-}" \
  '[{name: "FROM_STORE", value: $d}] + (if $a == "" then [] else [{name: "ACTIVATE", value: $a}] end)
     + (if $r == "" then [] else [{name: "REASON", value: $r}] end) | map(. + {type: "PLAINTEXT"})')
project="$CUSTOMER-$VENDOR-$STAGE-activate"
# Test activates one at a time (the customer API's promotes and pipelines alike), and CodeBuild refuses a start over a
# project's limit instead of queueing it: while another activation runs, this one waits its turn, within WAIT_MINUTES,
# and is still the tip before each retry (else it ends as step 0 does: superseded green, otherwise refused).
waited=0
until build=$(aws codebuild start-build --project-name "$project" --environment-variables-override "$overrides" \
                --query build.id --output text 2>"$TMP/err"); do
  grep -q AccountLimitExceededException "$TMP/err" \
    || fail "could not start $project: $(tr '\n' ' ' < "$TMP/err")(is this pipeline delegated for $STAGE?)"
  [ "$waited" -ge $((WAIT_MINUTES * 60)) ] && fail "another activation of $project still runs after $WAIT_MINUTES minutes: try again later"
  [ "$waited" = 0 ] && echo "another activation of $project runs; waiting for it to end"
  sleep "$POLL_SECONDS"; waited=$((waited + (POLL_SECONDS > 0 ? POLL_SECONDS : 1)))
  tip
done
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
