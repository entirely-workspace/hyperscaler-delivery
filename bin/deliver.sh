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
# SOURCE_REPOSITORY (#1189): the repository's name, as the customer's CodeCommit template sets it. With it, each start says
# where the push came from (SOURCE_REPOSITORY, SOURCE_BRANCH), which the Solution Console shows.
#
# The extra dev cells (#1189), DEV_CELLS=yes (the CodeCommit template's branches build, as the publisher role of its
# delegation to the extra dev cells): instead of a stage, the package goes to every extra dev cell that follows this
# repository and branch, as the customer API keeps them in the store (_cells/<cell>/source.json), activated now. When
# none follows them (a record of a cell no longer in the customer stack's list of extra dev cells is skipped), it ends
# green before the commit is checked or anything is stored. A store it cannot read fails it. Stored without the commit's version pointer (STORE_POINTER=no):
# nothing is promoted from an extra dev cell. A stage's start that a customer stack from before #1189 refuses for
# SOURCE_REPOSITORY and SOURCE_BRANCH fails, saying to deploy that stack first.
#
# The same as flags, for any other CI or a one-off run (#936); a flag wins over its variable:
#
#   deliver.sh --customer <id> --packages-bucket <bucket> [--stage dev|test] [--activate next-boot|now] [--reason <why>]
#              [--branch <branch>] [--wait-minutes <n>] [--region <region>] [--publisher-role <arn>]
#              [--dev-cells --source-repository <name>]
#
# --publisher-role signs in as that role with the CI's OIDC token in AWS_WEB_IDENTITY_TOKEN_FILE (the AWS CLI's own web
# identity sign-in). Without it, the credentials already in the environment are used, as the Action and the GitLab
# template set them.
#
# Before anything is stored, the package is checked as the cell's intake checks it (validate.sh, next to this script in
# the kit): a package the cell would refuse is never stored. Without validate.sh next to it (an older copy in a
# repository's tools/, #826), the cell alone checks it.
#
# An automations repository's workflows (#762: workflows/workflows.json, which names their vendor and package) are a
# package of their own type: checked by the workflow validator, stored with "type": "workflows" in the manifest, and
# activated by their own type's activation, <customer>-<vendor>-<stage>-activate-workflows (#1071), whose cell builds
# and deploys them; it can take longer than a customization's, so WAIT_MINUTES defaults to 40 for them. A repository
# with both customization.json and workflows/workflows.json says which it delivers with PACKAGE_TYPE (censhare-custom
# or workflows).
#
# Its functions (#674: functions/functions.json, with their vendor and package, and each function's zip, which the CI
# built before this step: the kit builds nothing) are a package of their own type too: checked by the functions
# validator, stored with "type": "functions", and activated by their own activation, <customer>-<vendor>-<stage>-
# activate-functions (#674), whose cell signs and deploys them; WAIT_MINUTES defaults to 40 for them as well. Its
# delegation names "functions" in its types. A repository with both functions/ and workflows/ delivers the functions
# first and waits for the cell's answer, then the workflows (which may call them), in one run (#674 step 6); a failed
# functions delivery stops the workflows. PACKAGE_TYPE=functions or workflows delivers one of them only.
#
# Exit: 0 the cell published or activated it (every cell, for the extra dev cells), a newer push superseded this one, or
# no extra dev cell follows this branch; 1 an activation failed or a cell refused (or would refuse: the check before
# storing), 2 not sent.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
fail() { echo "error: $*" >&2; exit 2; }
usage() { sed -n '/^#   deliver.sh --customer/,/^#              \[--dev-cells/p' "$0" | sed 's/^# \{0,1\}//'; }
ROLE=
ARGS=("$@")   # as given: a repository with functions and workflows delivers each in a run of its own (below)
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dev-cells) DEV_CELLS=yes; shift ;;
    --customer|--packages-bucket|--stage|--activate|--reason|--branch|--wait-minutes|--region|--publisher-role|--source-repository)
      [ $# -ge 2 ] || fail "$1 needs a value"
      case "$1" in
        --customer) CUSTOMER=$2 ;; --packages-bucket) PACKAGES_BUCKET=$2 ;; --stage) STAGE=$2 ;;
        --activate) ACTIVATE=$2 ;; --reason) REASON=$2 ;; --branch) BRANCH=$2 ;; --wait-minutes) WAIT_MINUTES=$2 ;;
        --region) export AWS_REGION=$2 AWS_DEFAULT_REGION=$2 ;; --publisher-role) ROLE=$2 ;; --source-repository) SOURCE_REPOSITORY=$2 ;;
      esac
      shift 2 ;;
    *) usage >&2; fail "unknown argument '$1'" ;;
  esac
done
# publish.sh reads these too: a value given only as a flag must reach it (#684).
export CUSTOMER PACKAGES_BUCKET ACTIVATE REASON
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
WAIT_GIVEN=${WAIT_MINUTES:-}
# A plain repository or branch name, as the customer API keeps them (#1189).
PLAIN='^[A-Za-z0-9][A-Za-z0-9._/-]*$'
# To the extra dev cells the name must be plain: a cell follows it, by that name. A main delivery only reports it for
# the Deployments tab, so a name that is not plain (CodeCommit allows _custom) is left out there, never a failure.
if [ -n "${SOURCE_REPOSITORY:-}" ] && ! [[ "$SOURCE_REPOSITORY" =~ $PLAIN ]]; then
  [ "${DEV_CELLS:-}" = yes ] && fail "SOURCE_REPOSITORY must be a plain repository name, not '$SOURCE_REPOSITORY'"
  echo "note: '$SOURCE_REPOSITORY' is not a plain repository name: not reported with this delivery"
  SOURCE_REPOSITORY=
fi
case "${DEV_CELLS:-}" in
  ''|no) DEV_CELLS= ;;
  yes) [ -z "${STAGE:-}" ] || [ "$STAGE" = dev ] || fail "the extra dev cells are no stage: leave STAGE out with DEV_CELLS=yes"
       [ -n "${SOURCE_REPOSITORY:-}" ] || fail "DEV_CELLS=yes needs SOURCE_REPOSITORY: the cells follow a repository and branch"
       # An extra dev cell takes a push at once, so a push shows without a restart by hand.
       ACTIVATE=${ACTIVATE:-now} REASON=${REASON:-a push to an extra dev cell}
       # Stored without the commit's version pointer: nothing is promoted from an extra dev cell (publish.sh).
       export STORE_POINTER=no ;;
  *) fail "DEV_CELLS must be yes or left out, not '$DEV_CELLS'" ;;
esac
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
# 0a. The extra dev cells (#1189): which of them follow this repository and branch now. None: nothing to do, green, in
# a few seconds, before anything about the commit is checked. A record it cannot read fails the build: it never counts
# as "none follows it".
TARGETS=("$STAGE")
if [ -n "$DEV_CELLS" ]; then
  [ -z "$TAG" ] || fail "the extra dev cells follow a branch, not a tag"
  if ! [[ "$BRANCH" =~ $PLAIN ]]; then echo "the branch '$BRANCH' is no plain name, so no cell can follow it: nothing delivered"; exit 0; fi
  keys=$(aws s3api list-objects-v2 --bucket "$PACKAGES_BUCKET" --prefix _cells/ --query 'Contents[].Key' --output text 2>"$TMP/err") \
    || fail "could not read which cells follow $SOURCE_REPOSITORY / $BRANCH: $(tr '\n' ' ' < "$TMP/err")"
  # The customer's extra dev cells now (the customer stack's list): a removed cell keeps its record, and is skipped.
  current=$(aws ssm get-parameter --name "/censhare/customer/$CUSTOMER/dev-cells" --query Parameter.Value --output text 2>"$TMP/err") \
    && jq -e 'type == "array"' <<<"$current" >/dev/null 2>&1 \
    || fail "could not read the customer's extra dev cells (/censhare/customer/$CUSTOMER/dev-cells): $(tr '\n' ' ' < "$TMP/err")(is the customer stack deployed with #1189?)"
  TARGETS=()
  for key in $keys; do
    [[ "$key" =~ ^_cells/([a-z0-9][a-z0-9-]*)/source\.json$ ]] || continue
    cell=${BASH_REMATCH[1]}
    jq -e --arg c "$cell" 'index($c) != null' <<<"$current" >/dev/null || { echo "skipped $cell: no longer one of the customer's extra dev cells (its record stays)"; continue; }
    aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$key" "$TMP/source.json" >/dev/null 2>"$TMP/err" \
      || fail "could not read what $cell follows: $(tr '\n' ' ' < "$TMP/err")"
    # Only the customer API writes these: one that is not JSON is damaged, and fails the build, never "not followed".
    jq -e 'type == "object"' "$TMP/source.json" >/dev/null 2>&1 || fail "could not read what $cell follows: $key is not a JSON object"
    [ "$(jq -r '.repository // empty' "$TMP/source.json")" = "$SOURCE_REPOSITORY" ] \
      && [ "$(jq -r '.branch // empty' "$TMP/source.json")" = "$BRANCH" ] && TARGETS+=("$cell")
  done
  if [ ${#TARGETS[@]} = 0 ]; then echo "no cell follows $SOURCE_REPOSITORY / $BRANCH: nothing delivered"; exit 0; fi
  echo "following $SOURCE_REPOSITORY / $BRANCH: ${TARGETS[*]}"
fi
# The package's type, from the commit's files; publish.sh and validate.sh are told it, so all three agree.
in_commit() { git cat-file -e "HEAD:./$1" 2>/dev/null; }
# Functions and workflows in one automations repository: the functions first, in a run of their own (workflows may call
# them), then the workflows here. A failed functions run stops the workflows (its exit code is this run's).
if [ -z "${PACKAGE_TYPE:-}" ] && in_commit functions/functions.json && ! in_commit customization.json; then
  if in_commit workflows/workflows.json; then
    echo "functions and workflows: the functions first"
    PACKAGE_TYPE=functions bash "$0" ${ARGS[@]+"${ARGS[@]}"} || exit $?
    echo "then the workflows"
    PACKAGE_TYPE=workflows
  else
    PACKAGE_TYPE=functions
  fi
fi
case "${PACKAGE_TYPE:-}" in
  "") if in_commit customization.json && in_commit workflows/workflows.json; then
        fail "the commit has both customization.json and workflows/workflows.json: set PACKAGE_TYPE to censhare-custom or workflows"
      elif in_commit workflows/workflows.json; then PACKAGE_TYPE=workflows; else PACKAGE_TYPE=censhare-custom; fi ;;
  censhare-custom|workflows|functions) ;;
  *) fail "PACKAGE_TYPE must be censhare-custom, workflows or functions, not '$PACKAGE_TYPE'" ;;
esac
export PACKAGE_TYPE
# Building and deploying the workflows or functions stack takes longer than a customization's intake: unless given,
# wait longer (signing comes first for functions).
[ "$PACKAGE_TYPE" != censhare-custom ] && [ -z "$WAIT_GIVEN" ] && WAIT_MINUTES=40
# The extra dev cells take customizations only (#1189): they have no workflows or functions activation, so neither is
# stored for them either (a functions package stored without a pointer would reach no cell).
if [ -n "$DEV_CELLS" ] && [ "$PACKAGE_TYPE" != censhare-custom ]; then
  echo "the extra dev cells take customization packages only, not $PACKAGE_TYPE: nothing delivered"
  exit 0
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
# Workflows: the workflows/ folder, and the function names they may call (functions/functions.json, or a functions.json
# at the root), which are not stored with them.
# Functions: functions/functions.json as committed and the zips the CI built, which no commit holds, so they are checked
# where they are (publish.sh store checks them again, and that functions.json is the commit's).
if [ "$PACKAGE_TYPE" = functions ]; then
  [ -f "$HERE/validate.sh" ] || fail "validate.sh is not next to $0: functions are not stored unchecked"
  git diff --quiet HEAD -- functions/functions.json 2>/dev/null || fail "functions/functions.json differs from the commit: commit it first"
  # An image from the customer's own registry (#1412) is pulled first, with this run's registry login, so the check
  # reads it like one built in the run.
  [ -f "$HERE/pull-images.sh" ] || fail "pull-images.sh is not next to $0: an image from a registry cannot be pulled"
  bash "$HERE/pull-images.sh" functions/functions.json
  case $? in
    0) ;;
    1) echo "error: a function's image could not be pulled from its registry (above): nothing was stored" >&2; exit 1 ;;
    *) fail "the functions' images could not be pulled (above): nothing was stored" ;;
  esac
  echo "checking the functions and their images (the validator of kit $(cat "$HERE/../VERSION" 2>/dev/null || echo "this repository's"); the cell's own check decides)"
  bash "$HERE/validate.sh" .
  case $? in
    0) ;;
    1) echo "error: the functions do not pass the cell's checks (above): nothing was stored" >&2; exit 1 ;;
    *) fail "the functions could not be checked (above): nothing was stored" ;;
  esac
elif [ -f "$HERE/validate.sh" ]; then
  if [ "$PACKAGE_TYPE" = workflows ]; then
    CHECKED=(workflows functions/functions.json functions.json)
  else
    SRC=$(git show HEAD:./customization.json 2>/dev/null | jq -r '.source // empty' 2>/dev/null)
    CHECKED=(customization.json ${SRC:+"$SRC"})
  fi
  mkdir -p "$TMP/commit"
  while IFS= read -r -d '' f; do
    mkdir -p "$TMP/commit/$(dirname "$f")" && git show "HEAD:./$f" > "$TMP/commit/$f" 2>/dev/null \
      || fail "could not read $f from the commit to check it (commit your changes first)"
  done < <(git ls-files -z -- "${CHECKED[@]}")
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

# 2. Activated in the stage's cell by digest, or in each extra dev cell that follows this branch (#1189). The publisher
# role may pass FROM_STORE, ACTIVATE and REASON, and where the push came from (SOURCE_REPOSITORY, SOURCE_BRANCH). As
# JSON: the CLI's shorthand splits on commas, so a reason with one would break the call.
SRC_BRANCH=; [ -n "$TAG" ] || SRC_BRANCH=${BRANCH:-}  # a tag is no branch: reported without one
overrides=$(jq -nc --arg d "$DIGEST" --arg a "${ACTIVATE:-}" --arg r "${REASON:-}" --arg sr "${SOURCE_REPOSITORY:-}" --arg sb "$SRC_BRANCH" \
  '[{name: "FROM_STORE", value: $d}] + (if $a == "" then [] else [{name: "ACTIVATE", value: $a}] end)
     + (if $r == "" then [] else [{name: "REASON", value: $r}] end)
     + (if $sr == "" or $sb == "" then [] else [{name: "SOURCE_REPOSITORY", value: $sr}, {name: "SOURCE_BRANCH", value: $sb}] end)
     | map(. + {type: "PLAINTEXT"})')
# Test activates one at a time (the customer API's promotes and pipelines alike), and CodeBuild refuses a start over a
# project's limit instead of queueing it: while another activation runs, this one waits its turn, within WAIT_MINUTES,
# and is still the tip before each retry (else it ends as step 0 does: superseded green, otherwise refused).
# From GitHub or GitLab to the extra dev cells (#1189): each cell's own role starts it, and trusts only the branch the
# cell follows (the customer API writes that trust on each save). The pipeline's OIDC token proves the branch to AWS,
# so a pipeline edited on another branch cannot claim this one. Without a token (the CodeCommit template's branches
# build), the delegation's role starts them, as it may.
# The pipeline's own token first: GitLab's (the kit's CENSHARE_OIDC), then GitHub's, and only then a file the runner
# names (AWS_WEB_IDENTITY_TOKEN_FILE), which on a runner in Kubernetes may be the pod's own token, not the pipeline's.
oidc_source() {  # prints where the token comes from, or nothing
  if [ -n "${CENSHARE_OIDC:-}" ]; then echo gitlab
  elif [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then echo github
  elif [ -n "${AWS_WEB_IDENTITY_TOKEN_FILE:-}" ] && [ -s "$AWS_WEB_IDENTITY_TOKEN_FILE" ]; then echo file
  fi
}
oidc_token() {  # prints the pipeline's OIDC token, fetched now: GitHub's lives minutes, and a start may wait longer
  case "$OIDC_SOURCE" in
    gitlab) printf '%s' "$CENSHARE_OIDC" ;;
    github) curl -sfS -m 20 --retry 3 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" \
              | jq -er .value 2>"$TMP/err" || fail "could not get GitHub's OIDC token for the extra dev cells: $(tr '\n' ' ' < "$TMP/err")" ;;
    file) cat "$AWS_WEB_IDENTITY_TOKEN_FILE" ;;
  esac
}
OIDC_SOURCE=""
if [ -n "$DEV_CELLS" ]; then
  OIDC_SOURCE=$(oidc_source)
  # In GitHub Actions or GitLab CI the cells are started with the pipeline's token: without one, the job lacks the
  # permission to get it, which is what to fix (review of #1256), not the delegation.
  if [ -z "$OIDC_SOURCE" ] && { [ "${GITHUB_ACTIONS:-}" = true ] || [ "${GITLAB_CI:-}" = true ]; }; then
    fail "no OIDC token for the extra dev cells: give the job \`permissions: id-token: write\` (GitHub) or the kit's id_tokens CENSHARE_OIDC (GitLab)"
  fi
  if [ -n "$OIDC_SOURCE" ]; then
    me=$(aws sts get-caller-identity --query Arn --output text 2>"$TMP/err") || fail "could not read who this pipeline is: $(tr '\n' ' ' < "$TMP/err")"
    [[ "$me" =~ ^arn:(aws[a-z-]*):sts::([0-9]{12}): ]] || fail "could not read the account from $me"
    CELL_ROLE_PREFIX="arn:${BASH_REMATCH[1]}:iam::${BASH_REMATCH[2]}:role/customization-publish/censhare-cc-$CUSTOMER-$VENDOR-dc-"
  fi
fi
cell_credentials() {  # cell_credentials <cell>: prints its own role's key, secret and session, or fails naming why
  local c tries=0
  # The token from a file, never on a command line another process could read; fetched now, as it lives minutes.
  oidc_token > "$TMP/jwt" && chmod 600 "$TMP/jwt" || exit 2
  until c=$(aws sts assume-role-with-web-identity --role-arn "$CELL_ROLE_PREFIX$1" --role-session-name "deliver-$1" \
              --web-identity-token "file://$TMP/jwt" --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>"$TMP/err"); do
    # AccessDenied: the role's trust names another branch than the cell's record, or a trust saved a moment ago is not
    # applied yet by IAM (review of #1256): tried again a few times first. Anything else (an expired or invalid token,
    # an issuer AWS cannot reach, throttling) is said as it is.
    grep -q AccessDenied "$TMP/err" || fail "could not sign in as $1's own role: $(tr '\n' ' ' < "$TMP/err")"
    if [ $((tries += 1)) -gt 3 ]; then
      fail "$1's own role does not trust $SOURCE_REPOSITORY / $BRANCH: $(tr '\n' ' ' < "$TMP/err")(its record says it follows this branch, so its role is behind: save its source again in its Solution Console)"
    fi
    echo "$1's own role refused the sign-in; trying again (a source saved just now takes a few seconds)" >&2
    sleep $((POLL_SECONDS > 0 ? 5 : 0))
  done
  printf '%s' "$c"
}
start() {  # start <stage or cell>: prints the build id
  local project="$CUSTOMER-$VENDOR-$1-activate" waited=0 o=$overrides b key="" secret="" session=""
  if [ -n "$OIDC_SOURCE" ]; then
    local c; c=$(cell_credentials "$1") || exit 2
    read -r key secret session <<<"$c"
  fi
  # A workflows package has its own activation (#1071): the same gates, its cell's workflows deployer instead of the intake.
  [ "$PACKAGE_TYPE" = workflows ] && project="$project-workflows"
  # And a functions package (#674): its activation carries it to the cell's functions deployer, which signs and deploys it.
  [ "$PACKAGE_TYPE" = functions ] && project="$project-functions"
  # The cell role's credentials exported in the subshell, never on a command line another process could read.
  until b=$( [ -z "$key" ] || export AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$secret" AWS_SESSION_TOKEN="$session"
             aws codebuild start-build --project-name "$project" --environment-variables-override "$o" \
              --query build.id --output text 2>"$TMP/err"); do
    # A stage's start that says where the push came from is refused by a customer stack from before #1189: that stack
    # must be deployed first (RUNBOOK, rollout order), not worked around here.
    if [ -z "$DEV_CELLS" ] && [ -n "${SOURCE_REPOSITORY:-}" ] && grep -q AccessDenied "$TMP/err"; then
      fail "could not start $project: $(tr '\n' ' ' < "$TMP/err")(is this pipeline delegated for $1? If it is, its customer stack may be older than this deliver.sh, which reports SOURCE_REPOSITORY and SOURCE_BRANCH: ask censhare to deploy the customer stack)"
    fi
    grep -q AccountLimitExceededException "$TMP/err" \
      || fail "could not start $project: $(tr '\n' ' ' < "$TMP/err")(is this pipeline delegated for ${DEV_CELLS:+the extra dev cells, and is }$1${DEV_CELLS:+ one of them}$([ "$PACKAGE_TYPE" != censhare-custom ] && echo ", and for $PACKAGE_TYPE: \"types\" in its delegation or the customer file")?)"
    [ "$waited" -ge $((WAIT_MINUTES * 60)) ] && fail "another activation of $project still runs after $WAIT_MINUTES minutes: try again later"
    [ "$waited" = 0 ] && echo "another activation of $project runs; waiting for it to end" >&2
    sleep "$POLL_SECONDS"; waited=$((waited + (POLL_SECONDS > 0 ? POLL_SECONDS : 1)))
    tip >&2
  done
  printf '%s' "$b"
}
BUILDS=() STARTED=()
for t in "${TARGETS[@]}"; do
  build=$(start "$t") || { rc=$?; [ ${#STARTED[@]} = 0 ] || echo "error: started before that, not waited for: ${STARTED[*]}" >&2; exit "$rc"; }
  # Superseded while it waited (tip ended it green): the newer push delivers; what started already runs on.
  [ -n "$build" ] || { [ ${#STARTED[@]} = 0 ] || echo "started before that, not waited for: ${STARTED[*]}"; exit 0; }
  STARTED+=("$t") BUILDS+=("$build")
  echo "activating $DIGEST in $t ($build)"
done
TARGETS=("${STARTED[@]}")

# 3. Each build's end, then the cell's answer it kept next to the package: this build's, not one an earlier activation
# of the same digest left there.
rc=0
for i in "${!TARGETS[@]}"; do
  t=${TARGETS[$i]} build=${BUILDS[$i]} waited=0
  while status=$(aws codebuild batch-get-builds --ids "$build" --query 'builds[0].buildStatus' --output text 2>"$TMP/err") \
        && [ "$status" = IN_PROGRESS ]; do
    [ "$waited" -ge $((WAIT_MINUTES * 60)) ] && { echo "error: $build still running after $WAIT_MINUTES minutes" >&2; rc=1; continue 2; }
    sleep "$POLL_SECONDS"; waited=$((waited + POLL_SECONDS))
  done
  # A read that failed is said as it is, not as a build with no answer. The run signs in once, for an hour, and functions
  # then workflows may wait longer than that (#1277 review): the cell goes on, so say where its answer is.
  if [ -z "$status" ]; then
    if grep -q -E 'ExpiredToken|RequestExpired|security token included in the request is expired' "$TMP/err"; then
      echo "error: $t: the sign-in for this run expired while waiting for $build (it lasts an hour). The cell goes on" \
        "without it: its answer is in the Solution Console's Deployments tab" >&2
    else
      echo "error: $t: could not read the build $build: $(tr '\n' ' ' < "$TMP/err")" >&2
    fi
    rc=1; continue
  fi
  answer=$(aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$VENDOR/packages/${DIGEST#sha256:}/$t-result.json" "$TMP/result.json" >/dev/null 2>&1 \
             && jq -r --arg b "$build" 'select(.build == $b) | [.status, .reason // empty] | join(": ")' "$TMP/result.json")
  echo "$t: ${answer:-no answer from this build} (build $status)"
  # skipped: an extra dev cell set to another branch while this push was on its way (dev-cell-gate.sh), not a failure.
  [ "$status" = SUCCEEDED ] && case "$answer" in published*|activated*|skipped*) continue ;; esac
  rc=1
done
exit "$rc"
