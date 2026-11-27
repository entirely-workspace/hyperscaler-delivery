#!/usr/bin/env bash
# Publish a partner's customization package to a cell's intake, or roll the cell back to one already published (#345),
# and store it in a customer's package store (#780). The one script for every path: a delegated partner pipeline runs
# its own copy, next to deliver.sh in its repository (docs/RUNBOOK.md, #779 and #826), and a customer's activations
# (lib/customer-customization-stack.ts) run it to place a stored package into a cell. The hyperscaler-partner-publish
# GitHub action carries the kit's copy, byte for byte (its CI fails when a kit release changes it, #1110), and publishes
# straight to a cell (#346) without storing. Everything a cell runs is checked and signed by the cell itself (its
# intake): this script only delivers the package and reports the cell's answer.
#
#   publish.sh check    the checks that need no access to the cell (run before the job gets the cell's credentials)
#   publish.sh run      upload, send the request, wait for the result
#   publish.sh store    store this commit's package once in the customer's package store (#780), send nothing
#
# The package store (#780), PACKAGES_BUCKET, keyed by digest:
#   <vendor>/packages/<hex>/files/<path>, manifest.json   the package, written once, never replaced
#   <vendor>/packages/<hex>/stored-by/<role>.json         who stored it, written once before the manifest; a publisher
#                                                         role may write only its own name (decision 0023)
#   <vendor>/packages/<hex>/<stage>-result.json           the stage cell's last answer for it (test's is acceptance)
#   <vendor>/versions/<package>/<commit>.json             a customization commit's digest and its package's type (#762)
#   <vendor>/versions/_workflows/<package>/<commit>.json  a workflows commit's (#1101 review): apart, so the Control
#                                                         Center's version list never reads them (no package starts with _)
#   <vendor>/versions/_functions/<package>/<commit>.json  a functions commit's (#674), apart for the same reason
#   <vendor>/packages/<hex>/prod-approval.json            the customer's approval for prod (#781), written once
#   <vendor>/prod/<package>/current.json, history/...     prod's release: what runs, and every promotion
#   <vendor>/prod/_<type>/<package>/current.json, history/...  a workflows or functions package's prod release (#1478)
# A run with FROM_STORE=<digest> (and STORE_VENDOR) publishes a stored package instead of a checkout: from an empty
# folder, every file checked against the manifest and the digest recomputed before anything is sent.
#
# Inputs, as environment variables:
#   BRANCH          the stage branch that publishes (default main): only its tip is published
#   REPOSITORY      a CodeCommit repository (#645; censhare's stacks no longer host any): its BRANCH tip is read
#                   with `aws codecommit get-branch`. Without it, from GitHub's API (GITHUB_REPOSITORY, GH_TOKEN),
#                   else from origin
#   EVENT           push: started by the branch update itself; overtaken by a newer update, it ends green, sends nothing
#   BUCKET          the cell's customizations bucket                                                            (run)
#   CELL_PROFILE    the AWS CLI profile for the cell (its publish role); empty: the default credentials         (run)
#   ACTIVATE        next-boot (default) or now
#   REASON          why now; required with ACTIVATE=now
#   VERSION         empty: publish this commit. A commit: roll back to that version, already published
#   WAIT_MINUTES    how long to wait for the cell's answer (default 10)
#   PACKAGES_BUCKET the customer's package store (the caller's own credentials, never CELL_PROFILE)
#   FROM_STORE      sha256:<hex>, the stored package to publish (run); STORE_VENDOR its vendor
#   PACKAGE_TYPE    censhare-custom, workflows (#762) or functions (#674). Without it: workflows/workflows.json makes it
#                   workflows, functions/functions.json alone functions, else censhare-custom; a folder with both
#                   customization.json and workflows/workflows.json must say which. A workflows package is checked and stored (store, check); its manifest in
#                   the store says "type": "workflows" (a manifest without "type" is censhare-custom's). It reaches a cell
#                   only from the store (#1071): run with FROM_STORE, with PACKAGE_TYPE=workflows (the workflows
#                   activation sets it), into the cell's incoming-workflows/ for its workflows deployer, every activation
#                   with the whole package. An activation of one type refuses a stored package of the other.
#                   functions (#674): functions/functions.json and each function's container image, which the
#                   customer's CI built (the kit builds nothing): checked by the functions validator, each image pushed
#                   into censhare's ECR (<CUSTOMER>/<vendor>-functions), which scans it (the customer stack records
#                   each scan in the store when it ends; the activation hands them to the cell, which decides, #1422),
#                   and stored with
#                   functions/images.json, each image's repository and digest; like a workflows package it
#                   reaches a cell only from the store, run with FROM_STORE and PACKAGE_TYPE=functions (the functions
#                   activation, #674 step 3), into the cell's incoming-functions/ for its functions deployer (step 5).
#                   The images are build output; functions.json must be committed
#   SCAN_WAIT_SECONDS  the functions activation's wait for an image's scan to be recorded (#1422), 300 by default
#   RELEASE_WAIT_SECONDS  on test, how long in all a workflows activation waits for the functions of its release
#                   (#1477, release_gate), 1800 by default; the customer stack sets it, and RELEASE_WAIT_MAX_SECONDS,
#                   the most a start may ask for within the project's build timeout
#   FUNCTIONS_PATHS store, functions: what they are built from, as git pathspecs (#1477); everything but workflows/ by
#                   default. The last commit that changed them is what the commit's workflows wait for on test, and,
#                   since #1546, a commit with no change there stores no functions package: it points at that last
#                   change's. Too narrow a value (functions/ while shared code lives in lib/) keeps the old image running
#   FROM_COMMIT     run, workflows on test: the commit whose row was promoted, which must have stored FROM_STORE
#                   (#1546). The release gate waits for its functions; without it, the package manifest's commit
#   SWITCH          run, workflows (#1559) or functions (#1560): <name>:<version>:pin|unpin, one workflow's or function's live alias moved to a version
#                   the stage published before (pin), or back to its package's (unpin). The customer API alone sets it
#                   (activation-gate.sh). Only a switch request is sent, no package files, and no gate runs: the API
#                   checked the version. Its answer (switched) is not kept as the stage's deploy answer. Every other
#                   workflows or functions run carries the stage's pins of its type (<vendor>/pins/<stage>/<type>/), so a
#                   deploy keeps a pinned one where it was switched to; pins that cannot be read send nothing
#   STORE_POINTER   no: store without the commit's version pointer (a delivery to the extra dev cells, #1189)
#   STAGE           the stage this run publishes for, or the cell's id for an extra dev cell (#1189); names the answer
#                   kept in the store
#   OUTCOME_FILE    where to write what happened, as JSON, for whoever reports the result (#646, #781): status
#                   (published, activated, refused, superseded, failed, timeout), version, package, files, digest,
#                   activation, reason, validator, error, supersededBy. Empty: none written
# and, under GitHub, GITHUB_REF, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, GITHUB_STEP_SUMMARY, GITHUB_OUTPUT; under CodeBuild,
# CODEBUILD_BUILD_NUMBER for the request's id.
#
# Exit: 0 published, activated or superseded, 1 refused by the cell, 2 a check here failed, 3 no answer in time.
set -uo pipefail
# This script's own path, resolved once (#1403 review): it calls itself again (__put) after push_images has changed into
# its staging folder, where a relative $0 no longer names it.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

MODE="${1:-}"
PARALLEL=16   # uploads at a time

# publish.sh __put <key> <file>: one upload (BUCKET and CELL_PROFILE from the environment).
if [ "$MODE" = __put ]; then
  for attempt in 1 2 3 4 5; do
    out=$(aws ${CELL_PROFILE:+--profile "$CELL_PROFILE"} s3api put-object --bucket "$BUCKET" --key "$2" --body "$3" \
            --if-none-match '*' 2>&1 >/dev/null) && exit 0
    # The cell lets nothing be overwritten; an object already there is this commit's (an earlier attempt of this run).
    case "$out" in *PreconditionFailed*|*"(412)"*) exit 0 ;; esac
    # Another upload of the same key is in flight (409, e.g. a retry while an earlier attempt still uploads): retry.
    case "$out" in *ConditionalRequestConflict*) [ "$attempt" -lt 5 ] && { sleep "$attempt"; continue; } ;; esac
    break
  done
  echo "error: upload of $2 failed: $out" >&2
  exit 1
fi
BRANCH="${BRANCH:-main}"
ACTIVATE="${ACTIVATE:-next-boot}"
REASON="${REASON:-}"
VERSION="${VERSION:-}"
WAIT_MINUTES="${WAIT_MINUTES:-10}"
EVENT="${EVENT:-${GITHUB_EVENT_NAME:-}}"
RUN="${GITHUB_RUN_ID:-${CODEBUILD_BUILD_NUMBER:-local}}-${GITHUB_RUN_ATTEMPT:-1}"
# CodeBuild numbers builds per project: the dev and prod activations of a cell that is several stages would share a
# request folder, and one would read the other's answer. The stage keeps them apart.
[ -z "${GITHUB_RUN_ID:-}" ] && [ -n "${CODEBUILD_BUILD_NUMBER:-}" ] && [ -n "${STAGE:-}" ] && RUN="$STAGE-$RUN"
NAME_RE='^[a-z0-9][a-z0-9_-]*$'
COMMIT_RE='^[0-9a-f]{40}$'   # a version is stored under the full commit; a short one would never be found

# GitHub shows ::error:: and ::notice:: as annotations; anywhere else they are plain lines in the log.
if [ "${GITHUB_ACTIONS:-}" = true ]; then E='::error::'; N='::notice::'; W='::warning::'; else E='error: '; N=''; W='warning: '; fi
# outcome <status> [jq args...]: the outcome so far, with this status and any --arg/--argjson fields merged in.
outcome() {
  [ -n "${OUTCOME_FILE:-}" ] || return 0
  local status=$1; shift
  jq -n --arg status "$status" --arg version "${VERSION:-${ID:-}}" --arg package "${VENDOR:-}/${PACKAGE:-}" \
     --arg digest "${DIGEST:-}" --argjson files "${#FILES[@]}" "$@" \
     '{status: $status, version: $version, package: $package, files: $files}
      + (if $digest == "" then {} else {digest: $digest} end) + ($ARGS.named | del(.status, .version, .package, .digest))' \
     > "$OUTCOME_FILE" 2>/dev/null || true
}
FILES=()
fail() { echo "$E$*" >&2; outcome failed --arg error "$*"; exit 2; }
# sha256 <file...>: "<hash>  <file>" per file, with whichever of the two tools is there (CodeBuild has sha256sum).
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"; return 0; }
output() { [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; return 0; }

# tip: the commit BRANCH points at now, or nothing when it cannot be read. BRANCH_TIP: the caller read it already (the
# CodeCommit template reads it with its build role, before it signs in as a role of censhare's that can't, #886).
tip() {
  local t=""
  if [[ "${BRANCH_TIP:-}" =~ $COMMIT_RE ]]; then
    t=$BRANCH_TIP
  elif [ -n "${REPOSITORY:-}" ]; then
    t=$(aws codecommit get-branch --repository-name "$REPOSITORY" --branch-name "$BRANCH" \
          --query branch.commitId --output text 2>/dev/null) || t=""
  elif [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    t=$(curl -fsS -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' \
          "${GITHUB_API_URL:-https://api.github.com}/repos/$GITHUB_REPOSITORY/git/ref/heads/$BRANCH" 2>/dev/null \
        | jq -r '.object.sha // empty' 2>/dev/null) || t=""
  fi
  [ -n "$t" ] || t=$(git ls-remote --exit-code origin "refs/heads/$BRANCH" 2>/dev/null | cut -f1) || t=""
  [[ "$t" =~ $COMMIT_RE ]] && echo "$t"
  return 0
}

# current <when>: only the tip of BRANCH is published or made active again. A retried or late run carries an older
# commit: publishing it would silently roll the cell back (a rollback is asked for explicitly, with VERSION). A run
# started by the update itself and overtaken by a newer one has nothing wrong with it: the newer run publishes, so it
# ends green and sends nothing. In a job (GitHub or CodeBuild) the check must succeed; it fails closed.
current() {
  local t; t=$(tip)
  if [ -z "$t" ]; then
    [ "${GITHUB_ACTIONS:-}" = true ] || [ -n "${CODEBUILD_BUILD_ID:-}" ] || [ "${GITLAB_CI:-}" = true ] \
      && fail "could not read $BRANCH to check that $ID is its tip ($1)"
    echo "${W}could not read $BRANCH; publishing $ID without checking it is the latest (not in a job)"
    return 0
  fi
  [ "$t" = "$ID" ] && return 0
  if [ "$EVENT" = push ]; then
    echo "${N}superseded by $t, the tip of $BRANCH: its run publishes; $ID is not published ($1)"
    summary "### ⏭️ $VENDOR/$PACKAGE @ $ID superseded" "" "$BRANCH is now at $t; its run publishes. Nothing was sent for this commit."
    output superseded true
    outcome superseded --arg supersededBy "$t"
    exit 0
  fi
  fail "this run is for $ID, but $BRANCH is now at $t: run it again for the latest $BRANCH, or roll back on purpose with version: $ID"
}

# from_store: the stored package FROM_STORE into this (empty) folder, each file checked against the manifest and the
# digest recomputed from the files: what reaches a cell is exactly what was stored (#780).
from_store() {
  [[ "$FROM_STORE" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "a digest is sha256: and 64 hex digits, not '$FROM_STORE'"
  [[ "${STORE_VENDOR:-}" =~ $NAME_RE ]] || fail "STORE_VENDOR must name the package's vendor"
  [ -n "${PACKAGES_BUCKET:-}" ] || fail "PACKAGES_BUCKET is required with FROM_STORE"
  [ -z "$(ls -A)" ] || fail "FROM_STORE needs an empty folder, not $(pwd)"
  local at="$STORE_VENDOR/packages/${FROM_STORE#sha256:}" m=".store-manifest.json" n=0 path sum
  aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$at/manifest.json" "$m" >/dev/null 2>&1 \
    || fail "$FROM_STORE is not in the store for $STORE_VENDOR"
  [ "$(jq -r .digest "$m")" = "$FROM_STORE" ] || fail "the manifest at $at names another digest"
  # A manifest without a type is a customization's, stored before types (#762). Each type has its own activation (#1071):
  # the customization's (PACKAGE_TYPE=censhare-custom, or none from before #1104) takes customizations only, the
  # workflows activation (PACKAGE_TYPE=workflows) workflows packages only. Each project writes its type into its command.
  local stored_type; stored_type=$(jq -r '.type // "censhare-custom"' "$m")
  [ "$stored_type" = "${PACKAGE_TYPE:-censhare-custom}" ] \
    || fail "$FROM_STORE is a $stored_type package, and this activation takes ${PACKAGE_TYPE:-censhare-custom} packages: activate it with its own type's activation"
  STORE_COMMIT=$(jq -r '.commit // empty' "$m")
  [[ "$STORE_COMMIT" =~ $COMMIT_RE ]] || fail "the stored manifest has no full commit"
  while IFS=$'\t' read -r sum path; do
    case "/$path/" in */../*|*/./*|//*) fail "the stored manifest names a path outside the package: '$path'" ;; esac
    mkdir -p "$(dirname "$path")"
    aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$at/files/$path" "$path" >/dev/null 2>&1 || fail "stored file $path is missing"
    [ "$(sha256 "$path" | cut -d' ' -f1)" = "$sum" ] || fail "stored file $path does not match its manifest"
    n=$((n + 1))
  done < <(jq -r '.files[] | "\(.sha256)\t\(.path)"' "$m")
  rm -f "$m"
  FILES=()
  while IFS= read -r -d '' f; do FILES+=("${f#./}"); done < <(find . -type f -print0 | LC_ALL=C sort -z)
  [ "${#FILES[@]}" = "$n" ] || fail "the stored package has files its manifest does not name"
  [ "sha256:$(sha256 "${FILES[@]}" | sha256 | cut -d' ' -f1)" = "$FROM_STORE" ] || fail "the stored files do not make the digest $FROM_STORE"
  echo "fetched $FROM_STORE ($n files, commit $STORE_COMMIT) from the store"
}
# A switch (#1559) is a workflows activation's alone: refused before anything is fetched.
case "${SWITCH:+set}:${PACKAGE_TYPE:-}" in set:workflows|set:functions|:*) ;;
  *) fail "a switch moves one workflow's or function's live alias: only a workflows or functions activation takes SWITCH (#1559, #1560)" ;; esac
[ -n "${FROM_STORE:-}" ] && [ "$MODE" = run ] && from_store

# cell_reachable: an activation signs in to its stage's cell as the cell's publish role before anything is sent. A cell
# whose environment file has no `delivery` entry for this vendor has no such role (the #684 run: AccessDenied on every
# file); say so, and what fixes it, instead.
cell_reachable() {
  [ -n "${FROM_STORE:-}" ] && [ -n "${CELL_PROFILE:-}" ] || return 0
  local err entry="\"stage\": \"${STAGE:-?}\""
  # An extra dev cell's activation is named after the cell, not a stage (#1189): its entry says devCell.
  case "${STAGE:-}" in dev|test|prod|'') ;; *) entry='"devCell": true' ;; esac
  err=$(aws --profile "$CELL_PROFILE" sts get-caller-identity 2>&1 >/dev/null) && return 0
  case "$err" in
    *AccessDenied*|*NoSuchEntity*|*"not authorized"*)
      fail "the cell ${CELL:-of stage ${STAGE:-?}} does not let this activation in as ${CELL_ROLE:-its publish role}: it is not set up to take ${STORE_VENDOR}'s packages from the store. In the cell's environment file, add the partner entry {\"vendor\": \"${STORE_VENDOR}\", \"delivery\": {\"customer\": ..., $entry, \"account\": ...}} and deploy the cell (docs/RUNBOOK.md, \"A customer's package store\", step 4)" ;;
    *) fail "the cell ${CELL:-of stage ${STAGE:-?}} could not be reached as ${CELL_ROLE:-its publish role}: $(printf '%s' "$err" | tr '\n' ' ' | cut -c1-300)" ;;
  esac
}
[ "$MODE" = run ] && cell_reachable

# The fields whose meaning depends on the cell (#1095): a cell's intake from an older edition does not know them and
# would activate the package without them, silently (`parameters`, #942: the values would never be set). The next such
# field joins this list and lib/manifest-fields.ts. Kept here, so every copy of this script (a partner's kit) has it.
CELL_FIELDS='parameters'
# cell_fields_check: before anything is sent, a package that uses one of CELL_FIELDS goes only to a cell whose edition
# applies it: the list the tenant stack publishes, /censhare/customizations/<BUCKET>/manifest-fields (SSM), read with
# the cell's publish role. A cell without it, or a role that may not read it, is from an edition before #1095 (AWS's
# own error and the region are said, so a permission boundary or a runner in the wrong region is not mistaken for it).
# A rollback (VERSION) checks the version it restores, not the tip: its customization.json from this checkout, else the
# commit fetched (a depth-1 checkout lacks it), else the cell's own copy of what was sent (incoming/, kept 30 days). One
# that cannot be read at all is checked as if it named every one of CELL_FIELDS: it fails closed, but only on a cell
# that cannot apply them (review of #1111).
version_spec() {
  local prefix
  prefix=$(git rev-parse --show-prefix 2>/dev/null)
  git show "$VERSION:${prefix}customization.json" 2>/dev/null && return 0
  if git rev-parse --git-dir >/dev/null 2>&1 \
     && GIT_TERMINAL_PROMPT=0 git fetch -q --depth=1 origin "$VERSION" >/dev/null 2>&1; then
    git show "$VERSION:${prefix}customization.json" 2>/dev/null && return 0
  fi
  aws ${CELL_PROFILE:+--profile "$CELL_PROFILE"} s3api get-object --bucket "$BUCKET" \
    --key "incoming/$VENDOR/$PACKAGE/$VERSION/customization.json" "$TMP/version-spec.json" >/dev/null 2>&1 \
    && cat "$TMP/version-spec.json"
}
cell_fields_check() {
  local spec used f need="" listed="" err="" raw try region cell="${CELL:-$BUCKET}" unread=""
  if [ -z "$VERSION" ]; then
    spec=$(cat customization.json)
  elif ! spec=$(version_spec); then
    unread=" and $VERSION's customization.json could not be read (not in this checkout, not fetched, no longer in the cell's intake), so it may name it"
    echo "$VERSION's customization.json could not be read: the cell is checked for every field that depends on it ($CELL_FIELDS)"
  fi
  if [ -n "$unread" ]; then
    need=$CELL_FIELDS
  else
    # A file jq cannot read is not a package without values (review of #1111).
    used=$(jq -r '[to_entries[] | select(.value != null and .value != [] and .value != {} and .value != "") | .key] | .[]' <<< "$spec" 2>/dev/null) \
      || fail "the customization.json of ${VERSION:-this commit} is not a JSON object, so the cell's fields cannot be checked; nothing was sent"
    for f in $CELL_FIELDS; do grep -qx -- "$f" <<< "$used" && need="$need $f"; done
  fi
  [ -n "$need" ] || return 0
  # Only a cell profile names the cell's region. Without one (the GitHub action: the job's credentials are the cell's
  # role), the job's AWS_REGION is the cell's, and the machine's default profile must not outrank it (review of #1110).
  region=
  [ -n "${CELL_PROFILE:-}" ] && region=$(aws --profile "$CELL_PROFILE" configure get region 2>/dev/null || true)
  for try in 1 2 3; do
    # In the cell profile's region: a store activation's AWS_REGION is the delivery account's, and outranks the profile;
    # S3 follows a region redirect, SSM does not (review of #1095).
    listed=$(aws ${CELL_PROFILE:+--profile "$CELL_PROFILE"} ${region:+--region "$region"} ssm get-parameter --name "/censhare/customizations/$BUCKET/manifest-fields" \
               --query Parameter.Value --output text 2> "$TMP/fields.err") && break
    raw=$(tr -s '\n' ' ' < "$TMP/fields.err" | cut -c1-300)
    case "$raw" in
      *ParameterNotFound*) listed=NONE; err="no list of fields in ${region:-this region}: an edition from before #1095, or the cell is in another region (run in the cell's region)"; break ;;
      *AccessDenied*|*"not authorized"*) listed=NONE; err="its list of fields could not be read: an edition from before #1095, or a permission in the way: $raw"; break ;;
      # Only what may pass on another try is retried (review of #1111): throttling, AWS's own errors, the network.
      *Throttl*|*TooManyRequests*|*RequestLimitExceeded*|*InternalServerError*|*ServiceUnavailable*|*"Could not connect"*|*"timed out"*|*"Connection was closed"*) ;;
      *) fail "could not read ${cell}'s list of fields (which fields its edition applies): $raw; nothing was sent" ;;
    esac
    [ "$try" = 3 ] && fail "could not read ${cell}'s list of fields (which fields its edition applies): $raw; nothing was sent, try again"
    sleep "$try"
  done
  for f in $need; do
    if [ "$listed" = NONE ] || ! jq -e --arg f "$f" 'type == "array" and any(.[]; . == $f)' <<< "$listed" >/dev/null 2>&1; then
      fail "refusing: ${cell}'s cell runs an edition that cannot apply $f${err:+ ($err)}${unread}; release #1095's edition (or a later one) to it first (nothing was sent)"
    fi
  done
}

# test_gate: into test only a stored digest dev accepted, for the commit its manifest names (decision 0023). Whoever
# started the run: the Solution Console or a delegated pipeline promoting a stored version. Read before anything is sent.
# A customer without a dev stage has no dev to accept anything: the buildspec says so (DEV_STAGE=no, out of an
# override's reach), and only that exact value skips the check.
test_gate() {
  [ "${DEV_STAGE:-}" = no ] && { echo "no dev stage: test takes the stored version as it is"; return 0; }
  local at="$STORE_VENDOR/packages/${FROM_STORE#sha256:}"
  aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$at/dev-result.json" .dev-result.json >/dev/null 2>&1 \
    && case "$(jq -r '.status // empty' .dev-result.json)" in published|activated) true ;; *) false ;; esac \
    && [ "$(jq -r '.version // empty' .dev-result.json)" = "$STORE_COMMIT" ] \
    || { rm -f .dev-result.json; fail "dev has not accepted $FROM_STORE (commit $STORE_COMMIT): activate it on dev first"; }
  rm -f .dev-result.json
  echo "accepted by dev"
}

# prod_gate: into prod only a digest the test cell accepted and the customer approved (#781). Read before anything is
# sent; the same rule for a hotfix and for a rollback, which is promoting an earlier digest.
prod_gate() {
  local at="$STORE_VENDOR/packages/${FROM_STORE#sha256:}"
  aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$at/test-result.json" .test-result.json >/dev/null 2>&1 \
    && case "$(jq -r '.status // empty' .test-result.json)" in published|activated) true ;; *) false ;; esac \
    || { rm -f .test-result.json; fail "test has not accepted $FROM_STORE: promote it to test first"; }
  aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$at/prod-approval.json" .prod-approval.json >/dev/null 2>&1 \
    && [ "$(jq -r '.digest // empty' .prod-approval.json)" = "$FROM_STORE" ] \
    || { rm -f .test-result.json .prod-approval.json; fail "the customer has not approved $FROM_STORE for prod"; }
  APPROVER=$(jq -r '.approver // empty' .prod-approval.json)
  rm -f .test-result.json .prod-approval.json
  echo "accepted by test and approved for prod by $APPROVER"
}

# release_gate (#1477): a release is one commit of one vendor/package (an automations repository's functions.json and
# workflows.json name the same one). On test its workflows wait for the functions they call, and only for functions
# that changed: the commit's functions pointer (versions/_functions/<package>/<commit>.json) names the last commit that
# changed them (changedAt, written by store). The workflows go on once test has taken the functions of that commit, or
# of this one (the same code); a promotion may start both at once, so this run waits, at most RELEASE_WAIT_SECONDS of
# elapsed time (one deadline: the customer stack sets the project's timeout above it, #1488 review). An answer written
# after this build was started (the request, queue included), or that arrives while waiting, and is no acceptance
# refuses the workflows with its reason; one written before and that does not change is an earlier activation's, and is
# waited past. An acceptance counts only while those functions are what test runs (#1505 review): no other functions of
# the package stored before them were accepted after it (went_back), since test rolls functions back by promoting
# older ones and their earlier answer stays; newer ones are a release ahead, which the workflows may run on. A customization never waits (it is another
# repository's), and dev is not gated: a delivery stores and activates the functions before the workflows itself.
release_gate() {
  local limit=${RELEASE_WAIT_SECONDS:-1800} poll=${RELEASE_POLL_SECONDS:-15} changed digest c i status deadline said started
  local commits=() digests=() keys=() wants=() first=() now=() statuses=() went=() last
  [ "$TYPE" = workflows ] || return 0
  [[ "$limit" =~ ^[0-9]{1,5}$ ]] && [[ "$poll" =~ ^[1-9][0-9]{0,2}$ ]] || fail "RELEASE_WAIT_SECONDS and RELEASE_POLL_SECONDS are seconds"
  # Never past what the customer stack gave this project (RELEASE_WAIT_MAX_SECONDS, below its build timeout): a start
  # that asks for more would be stopped by CodeBuild, with no refusal kept (#1488 review).
  if [[ "${RELEASE_WAIT_MAX_SECONDS:-}" =~ ^[0-9]{1,5}$ ]] && [ "$limit" -gt "$RELEASE_WAIT_MAX_SECONDS" ]; then
    echo "${W}RELEASE_WAIT_SECONDS $limit is more than this project allows: waiting at most $RELEASE_WAIT_MAX_SECONDS"
    limit=$RELEASE_WAIT_MAX_SECONDS
  fi
  deadline=$((SECONDS + limit))
  # When this build was started: CodeBuild's start is the request, so a build queued behind another still counts an
  # answer the functions activation of the same promotion wrote meanwhile as this one's (#1488 review). Outside
  # CodeBuild, now.
  started=$(date +%s); [[ "${CODEBUILD_START_TIME:-}" =~ ^[0-9]{10,16}$ ]] && started=$((CODEBUILD_START_TIME / 1000))
  # The release is the commit promoted (#1546). Workflows a later commit did not change are the package an earlier commit
  # stored first, and its manifest names that one; the console then passes the commit of the row promoted, FROM_COMMIT,
  # which must have stored this very digest. Without it, the manifest's commit, as before.
  local gate=$STORE_COMMIT
  if [ -n "${FROM_COMMIT:-}" ]; then
    [[ "$FROM_COMMIT" =~ $COMMIT_RE ]] || fail "FROM_COMMIT is a full commit, 40 hex digits, not '$FROM_COMMIT'. Nothing was sent"
    typed_pointer workflows "$FROM_COMMIT" || fail "$FROM_COMMIT stored no workflows of $PACKAGE: promote the version it stored. Nothing was sent"
    [ "$REPLY" = "$FROM_STORE" ] || fail "$FROM_COMMIT stored the workflows $REPLY, not $FROM_STORE. Nothing was sent"
    gate=$FROM_COMMIT
  fi
  release_pointer "$gate" || return 0   # no functions stored with this commit: nothing to wait for
  read -r digest changed <<< "$REPLY"
  [[ "$changed" =~ $COMMIT_RE ]] || changed=$gate   # a pointer from before #1477: its own commit
  commits=("$gate"); digests=("$digest")
  if [ "$changed" != "$gate" ] && release_pointer "$changed"; then
    read -r digest _ <<< "$REPLY"; commits+=("$changed"); digests+=("$digest")
  fi
  for i in "${!commits[@]}"; do
    keys[i]="$STORE_VENDOR/packages/${digests[i]#sha256:}/$STAGE-result.json"
    # The answer there before anything else is read: it is an earlier activation's (#1488 review). A read that fails
    # (throttling, the network) is tried again, then refuses: an empty one would make an old refusal look new.
    first_answer "${keys[i]}"; first[i]=$REPLY
    # Written after this build was started (S3 keeps whole seconds; an answer takes the cell's round trip, so never the
    # same second): this promotion's functions activation answered already.
    if [ -n "${first[i]}" ] && [ "$(jq -r '._writtenAt // 0' <<< "${first[i]}")" -gt "$started" ]; then
      first[i]=""
    fi
    # Test's answer names the commit in that digest's own manifest: functions an earlier commit stored first with the
    # same digest keep that commit, and are these all the same (#1488 review).
    package_commit "${digests[i]}"; wants[i]=$REPLY
  done
  said=
  while :; do
    for i in "${!commits[@]}"; do
      now[i]=$(stage_answer "${keys[i]}"); status=""; [ -n "${now[i]}" ] && status=$(jq -r '.status // empty' <<< "${now[i]}"); statuses[i]=$status
      went[i]=""
      if { [ "$status" = published ] || [ "$status" = activated ]; } && [ "$(jq -r '.version // empty' <<< "${now[i]}")" = "${wants[i]}" ]; then
        if went_back "$(jq -r '._writtenAt // 0' <<< "${now[i]}")" "${digests[@]}"; then went[i]=$REPLY; continue; fi
        echo "$STAGE has taken the functions of ${commits[i]} (${digests[i]}), the last change to them as of $gate"; return 0
      fi
    done
    for i in "${!commits[@]}"; do
      if [ -n "${now[i]}" ] && [ "${now[i]}" != "${first[i]}" ]; then
        # An acceptance for another commit than the manifest's is no refusal: said as it is (#1488 review).
        case "${statuses[i]}" in published|activated)
          fail "$STAGE answered for the functions of ${commits[i]} (${digests[i]}) with commit $(jq -r '.version // "none"' <<< "${now[i]}"), not ${wants[i]}, the commit in that package's manifest. The workflows of $gate are not sent" ;;
        esac
        fail "$STAGE refused the functions of ${commits[i]} (${digests[i]}): $(jq -r '.reason // .error // .status // "no reason given"' <<< "${now[i]}"). The workflows of $gate, which call them, are not sent"
      fi
    done
    if [ "$SECONDS" -ge "$deadline" ]; then
      c=${commits[*]}; c=${c// / or of }; last=""
      # Each commit's own last answer, named by commit (#1488 review): one may have an answer while the other has none.
      for i in "${!commits[@]}"; do
        [ -z "${statuses[i]}" ] || last+="${last:+, }${commits[i]}: ${statuses[i]}${went[i]:+, but $STAGE went back to ${went[i]} since}"
      done
      fail "$STAGE has not taken the functions of $c within $limit seconds (they last changed in $changed${last:+; last answers: $last}): promote them first, or the whole release, and look at the functions activation's build on $STAGE (one that stopped before sending keeps no answer). Nothing was sent"
    fi
    [ -n "$said" ] || { echo "waiting for $STAGE to take the functions of ${commits[*]} first (they last changed in $changed), at most $((deadline - SECONDS)) more seconds"; said=1; }
    sleep "$poll"
  done
}
# went_back <writtenAt> <digest>...: 0 with REPLY the digest when test went back since writtenAt (epoch seconds) to
# functions of the package stored before the given ones (#1505 review): the newest acceptance of other functions is
# later than writtenAt, and they were stored first. Functions stored after them are a release ahead, which the workflows
# may run on, as the customer API's rollback rule has it; 1 otherwise. The package's functions are those its pointers
# name (listed within the vendor's versions/ grant, as release_pointer); a digest is stored when its first pointer was
# written: store order, not commit order (a pointer is written once; an older commit stored late counts as ahead). Each
# pointer is read once per run (it never changes): one that cannot be read refuses, as any read the gate
# depends on. An answer that cannot be read is said in the log (stage_answer) and counts as going back, so the wait
# goes on, never past it.
went_back() {
  local at=$1 prefix="$STORE_VENDOR/versions/_functions/$PACKAGE/" keys key d t a w best="" bestw=$1 mine="" err; shift
  : "${POINTER_DIGESTS:=$(mktemp)}"
  keys=$(aws s3api list-objects-v2 --bucket "$PACKAGES_BUCKET" --prefix "$prefix" --query 'Contents[].Key' --output text 2>&1) \
    || fail "the functions pointers of $PACKAGE could not be listed ($prefix): $keys"
  for key in $keys; do
    [[ "$key" == "$prefix"*.json ]] || continue
    if ! awk -v k="$key" '$1 == k { f = 1 } END { exit !f }' "$POINTER_DIGESTS"; then
      if ! err=$(aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$key" .went-back.json 2>&1 >.went-back.meta); then
        rm -f .went-back.json .went-back.meta; fail "the functions pointer $key could not be read: $err"
      fi
      d=$(jq -r '.digest // ""' .went-back.json 2>/dev/null)
      t=$(jq -r 'try (.LastModified | sub("\\+00:00$"; "Z") | fromdateiso8601) catch 0' .went-back.meta 2>/dev/null)
      rm -f .went-back.json .went-back.meta
      printf '%s %s %s\n' "$key" "${d:--}" "${t:-0}" >> "$POINTER_DIGESTS"
    fi
  done
  # When each digest was stored: its earliest pointer. The given ones' is the earliest of theirs.
  for d in "$@"; do
    t=$(awk -v d="$d" '$2 == d { print $3 }' "$POINTER_DIGESTS" | sort -n | head -1)
    [ -n "$t" ] && { [ -z "$mine" ] || [ "$t" -lt "$mine" ]; } && mine=$t
  done
  for d in $(awk '$2 ~ /^sha256:[0-9a-f]{64}$/ { print $2 }' "$POINTER_DIGESTS" | sort -u); do
    case " $* " in *" $d "*) continue ;; esac
    a=$(stage_answer "$STORE_VENDOR/packages/${d#sha256:}/$STAGE-result.json") || { REPLY="$d (its answer could not be read)"; return 0; }
    [ -n "$a" ] || continue
    case "$(jq -r '.status // empty' <<< "$a")" in published|activated) ;; *) continue ;; esac
    w=$(jq -r '._writtenAt // 0' <<< "$a")
    [ "$w" -gt "$bestw" ] && { best=$d; bestw=$w; }
  done
  [ -n "$best" ] || return 1
  t=$(awk -v d="$best" '$2 == d { print $3 }' "$POINTER_DIGESTS" | sort -n | head -1)
  [ -n "$mine" ] && [ "${t:-0}" -lt "$mine" ] || return 1
  REPLY=$best
}
# release_pointer <commit>: REPLY is "<digest> <changedAt>" of the functions that commit stored; 1 when it stored none.
# Listed first: S3 answers a read of a missing key with 404 only to a role that may list the whole bucket, and this role
# lists its vendor's versions/ alone (a read carries no s3:prefix), so a commit without functions would read as denied
# (#1488 review). A listing with the pointer as its prefix is within that grant.
release_pointer() {
  local key="$STORE_VENDOR/versions/_functions/$PACKAGE/$1.json" err
  err=$(aws s3api list-objects-v2 --bucket "$PACKAGES_BUCKET" --prefix "$key" --query 'Contents[].Key' --output text 2>&1) \
    || fail "whether $1 stored functions could not be read ($key): $err"
  tr '\t' '\n' <<< "$err" | grep -Fxq -- "$key" || return 1
  if ! err=$(aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$key" .release-pointer.json 2>&1 >/dev/null); then
    rm -f .release-pointer.json; fail "whether $1 stored functions could not be read ($key): $err"
  fi
  REPLY=$(jq -r '"\(.digest // "") \(.changedAt // "")"' .release-pointer.json 2>/dev/null); rm -f .release-pointer.json
  [[ "${REPLY%% *}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "the pointer $key names no digest"
}
# typed_pointer <type> <commit>: REPLY is the digest of the <type> package that commit stored; 1 when it stored none
# (#1546). Listed before it is read, as release_pointer is.
typed_pointer() {
  local key="$STORE_VENDOR/versions/_$1/$PACKAGE/$2.json" err
  err=$(aws s3api list-objects-v2 --bucket "$PACKAGES_BUCKET" --prefix "$key" --query 'Contents[].Key' --output text 2>&1) \
    || fail "whether $2 stored $1 could not be read ($key): $err"
  tr '\t' '\n' <<< "$err" | grep -Fxq -- "$key" || return 1
  if ! err=$(aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$key" .typed-pointer.json 2>&1 >/dev/null); then
    rm -f .typed-pointer.json; fail "whether $2 stored $1 could not be read ($key): $err"
  fi
  REPLY=$(jq -r '.digest // ""' .typed-pointer.json 2>/dev/null); rm -f .typed-pointer.json
  [[ "$REPLY" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "the pointer $key names no digest"
}
# package_commit <digest>: REPLY is the commit in a stored package's manifest (not in a subshell, so a failure stops the run). A stored package always has its manifest, so any
# error reading it is said as it is.
package_commit() {
  local err want
  if ! err=$(aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$STORE_VENDOR/packages/${1#sha256:}/manifest.json" \
      .release-manifest.json 2>&1 >/dev/null); then
    rm -f .release-manifest.json; fail "the manifest of the functions package $1 could not be read: $err"
  fi
  want=$(jq -r '.commit // empty' .release-manifest.json 2>/dev/null); rm -f .release-manifest.json
  [[ "$want" =~ $COMMIT_RE ]] || fail "the manifest of the functions package $1 has no full commit"
  REPLY=$want
}
# stage_answer <key>: a stage's kept answer in the store, compact, with _writtenAt (when S3 wrote it, epoch seconds; 0
# when the CLI does not say), or nothing when there is none yet. This role reads a missing key as AccessDenied (it may
# not list packages/), so that and a 404 are "none yet": the same GetObject grant on packages/* has just read the
# package's manifest (package_commit), so a denial here is a missing answer, not a missing grant (#1488 review). Any
# other error (throttling, the network, the key) is said in the log and returns 2 with nothing, which a poll reads as
# none yet, so a passing one does not end the wait, and the read before the wait does not take as no answer
# (first_answer, #1488 review).
stage_answer() {
  local f m err at; f=$(mktemp); m=$(mktemp)
  if err=$(aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$1" "$f" 2>&1 >"$m"); then
    at=$(jq -r 'try (.LastModified | sub("\\+00:00$"; "Z") | fromdateiso8601) catch 0' "$m" 2>/dev/null)
    jq -c --argjson at "${at:-0}" '. + {_writtenAt: $at}' "$f" 2>/dev/null
  else
    case "$err" in *NoSuchKey*|*AccessDenied*|*"(404)"*|*"Not Found"*) ;; *) echo "${W}$1 could not be read: $(head -1 <<< "$err")" >&2; rm -f "$f" "$m"; return 2 ;; esac
  fi
  rm -f "$f" "$m"
}
# first_answer <key>: REPLY is the answer there before the wait, as stage_answer reads it; a read that keeps failing
# refuses the run (not in a subshell, so the failure stops it).
first_answer() {
  local n
  for n in 1 2 3; do
    REPLY=$(stage_answer "$1") && return 0
    [ "$n" = 3 ] || sleep "${RELEASE_POLL_SECONDS:-15}"
  done
  fail "$STAGE's answer $1 could not be read (above): nothing was sent"
}

# ---- the package and the request, checked before anything is sent
# Its type (#762): which file the folder has. customization.json is a customization (censhare-custom), the package this
# script publishes to a cell; workflows/workflows.json is an automations repository's workflows, which are stored
# only, until the workflows activator (#1071) places them. A folder with both says which with PACKAGE_TYPE.
# functions/functions.json alone (#674) is an automations repository's functions; with workflows/ next to it, deliver.sh
# stores the functions first with PACKAGE_TYPE=functions, then the workflows.
case "${PACKAGE_TYPE:-}" in
  "") if [ -f customization.json ] && [ -f workflows/workflows.json ]; then
        fail "this folder has both customization.json and workflows/workflows.json: set PACKAGE_TYPE to censhare-custom or workflows"
      elif [ -f workflows/workflows.json ]; then TYPE=workflows
      elif [ ! -f customization.json ] && [ -f functions/functions.json ]; then TYPE=functions
      else TYPE=censhare-custom; fi ;;
  censhare-custom|workflows|functions) TYPE=$PACKAGE_TYPE ;;
  *) fail "PACKAGE_TYPE must be censhare-custom, workflows or functions, not '$PACKAGE_TYPE'" ;;
esac
case "$TYPE" in
  censhare-custom) MANIFEST=customization.json ;;
  workflows) MANIFEST=workflows/workflows.json ;;
  functions) MANIFEST=functions/functions.json ;;
esac
[ -f "$MANIFEST" ] || fail "no $MANIFEST here ($(pwd)); set working-directory to the folder that has it"
jq -e 'type == "object"' "$MANIFEST" >/dev/null 2>&1 || fail "$MANIFEST is not a JSON object"
VENDOR=$(jq -r '.vendor // empty' "$MANIFEST")
PACKAGE=$(jq -r '.package // empty' "$MANIFEST")
# A workflows package is the workflows/ folder; a customization names its folder.
if [ "$TYPE" = workflows ]; then SOURCE=workflows; else SOURCE=$(jq -r '.source // empty' "$MANIFEST"); fi
[[ "$VENDOR" =~ $NAME_RE ]] || fail "$MANIFEST: \"vendor\" must be lower-case [a-z0-9_-], not '$VENDOR'"
[[ "$PACKAGE" =~ $NAME_RE ]] || fail "$MANIFEST: \"package\" must be lower-case [a-z0-9_-], not '$PACKAGE'"
# A workflows package reaches a cell only from the store, by digest (#1071): never from a checkout, and never by a version
# the cell holds (the cell keeps no workflows versions; a rollback is activating the earlier digest).
if [ "$TYPE" = workflows ] && { { [ "$MODE" = run ] && [ -z "${FROM_STORE:-}" ]; } || [ -n "$VERSION" ]; }; then
  fail "a workflows package reaches a cell only from the store: deliver it (deliver.sh), or activate a stored digest (FROM_STORE)"
fi
# Functions the same way (#674 step 3): from the store only, by digest, into the cell's functions intake.
if [ "$TYPE" = functions ] && { { [ "$MODE" = run ] && [ -z "${FROM_STORE:-}" ]; } || [ -n "$VERSION" ]; }; then
  fail "a functions package reaches a cell only from the store: deliver it (deliver.sh), or activate a stored digest (FROM_STORE)"
fi
case "$ACTIVATE" in next-boot|now) ;; *) fail "activate must be next-boot or now, not '$ACTIVATE'" ;; esac
# Workflows go live when the cell deploys them, without a restart: activate and its reason do not apply (the notice below).
if [ "$ACTIVATE" = now ] && [ "$TYPE" = censhare-custom ] && [ -z "${REASON//[[:space:]]/}" ]; then
  fail "activate: now restarts the customer's server: give a reason"
fi
[[ "$WAIT_MINUTES" =~ ^[0-9]{1,3}$ ]] || fail "wait-minutes must be a number of minutes, not '$WAIT_MINUTES'"
WAIT_SECONDS=$((10#$WAIT_MINUTES * 60))
# The cell only accepts requests from its stage branch (its publish role trusts nothing else); say so here. Storing is
# not publishing to a cell: the publisher role's OIDC trust names the ref that may store (#779).
if [ "$MODE" != store ] && [ -n "${GITHUB_REF:-}" ] && [ "$GITHUB_REF" != "refs/heads/$BRANCH" ]; then
  fail "only $BRANCH publishes or rolls back (this is $GITHUB_REF)"
fi

# image_scans (the functions activation, #1422): each image's scan, as the customer stack's scan writer recorded it in
# the store when the scan ended (_scans/<repository>/<digest hex>.json), into the request: the cell decides from them,
# and reads no scan itself. A scan not recorded yet is waited for, at most SCAN_WAIT_SECONDS; then nothing is sent.
image_scans() {
  local limit=${SCAN_WAIT_SECONDS:-300} poll=${SCAN_POLL_SECONDS:-10} scans='{}' name repo digest key waited rec got
  [[ "$limit" =~ ^[0-9]{1,4}$ ]] && [[ "$poll" =~ ^[0-9]{1,3}$ ]] || fail "SCAN_WAIT_SECONDS and SCAN_POLL_SECONDS are seconds"
  [ -f functions/images.json ] || fail "the stored package has no functions/images.json"
  while IFS=$'\t' read -r name repo digest; do
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "functions/images.json: image $name has no digest"
    # Its repository without the registry: <customer>/<vendor>-functions, the vendor's own (the activation reads no other).
    repo=${repo#*/}
    [[ "$repo" == */"$VENDOR-functions" ]] || fail "functions/images.json: image $name is in $repo, not $VENDOR's repository"
    key="_scans/$repo/${digest#sha256:}.json"; waited=0
    # Before this run's temporary folder exists: a file of its own, removed below.
    got=$(mktemp)
    until aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$key" "$got" >/dev/null 2>&1; do
      if [ "$waited" -ge "$limit" ]; then
        rm -f "$got"; fail "the scan of image $name ($digest) has not ended; activate again in a few minutes. If it never ends, ECR may not scan its base: build on one it can, such as an AWS Lambda base image"
      fi
      [ "$waited" = 0 ] && echo "waiting for the scan of image $name ($digest), at most ${limit}s"
      sleep "$poll"; waited=$((waited + (poll > 0 ? poll : 1)))
    done
    rec=$(jq -ce 'select((.status | type) == "string" and (.critical | type) == "number") | {status, critical}' "$got" 2>/dev/null)
    rm -f "$got"
    [ -n "$rec" ] || fail "the scan record of image $name ($key) is not one the scan writer writes; nothing sent"
    echo "scan of image $name: $(jq -r .status <<< "$rec"), $(jq -r .critical <<< "$rec") critical"
    scans=$(jq -c --arg d "$digest" --argjson r "$rec" '. + {($d): $r}' <<< "$scans")
  done < <(jq -r 'to_entries[] | [.key, .value.repository, .value.digest] | @tsv' functions/images.json)
  REQUEST=$(jq -c --argjson s "$scans" '. + {scans: $s}' <<< "$REQUEST")
}

# stage_pins (#1559, #1560): REPLY is this stage's pinned workflows or functions (TYPE), {"<name>": <version>}: of each one's
# events under <vendor>/pins/<stage>/<type>/<name>/<time>-<request>.json (written once, by the customer API), the newest
# whose switch went through (review of #1562); a pin counts, an unpin takes it out. A newer one that did not leaves the
# one before it in place. Fails closed: a deploy without them would move a switched workflow back unasked.
stage_pins() {
  local root="$STORE_VENDOR/pins/$STAGE/$TYPE/" keys k pins='{}' names="" f n a s b off="" all
  f=$(mktemp)
  keys=$(aws s3api list-objects-v2 --bucket "$PACKAGES_BUCKET" --prefix "$root" --query 'Contents[].Key' --output text 2>&1) \
    || fail "the pins of $STAGE could not be read ($keys): nothing was sent, since a deploy without them would undo a switch"
  [ "$keys" = None ] && keys=""
  all=$(printf '%s\n' "$keys" | tr '\t' '\n')
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    while IFS= read -r k; do
      aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$k" "$f" >/dev/null 2>&1 \
        || fail "the pin $k could not be read: nothing was sent, since a deploy without it would undo a switch"
      a=$(jq -r 'if (.action == "pin" or .action == "unpin") and (.version | type) == "number" and .version >= 1 then .action else "" end' "$f" 2>/dev/null) || a=""
      [ -n "$a" ] || continue
      # Whether its switch went through: one naming itself (switch) or, a pin before that, its build, by its record; one
      # naming neither is from before switches were recorded, and counts as it did.
      s=$(jq -r 'if (.switch | type) == "string" then .switch else "" end' "$f" 2>/dev/null) || s=""
      b=$(jq -r 'if .action == "pin" and (.build | type) == "string" then .build else "" end' "$f" 2>/dev/null) || b=""
      if [ -n "$s$b" ] && ! { [[ "${s:-$b}" =~ ^[A-Za-z0-9=_-]{1,90}$ ]] && grep -qxF "${root}${n}/switched/${s:-$b}.json" <<< "$all"; }; then
        if [ "$a" = pin ]; then off="${off:+$off, }$n v$(jq -r .version "$f")"; else off="${off:+$off, }$n unpin"; fi
        continue
      fi
      [ "$a" = pin ] && pins=$(jq -c --arg n "$n" --argjson v "$(jq .version "$f")" '. + {($n): $v}' <<< "$pins")
      break
    done < <(grep -E "^${root//\//\\/}${n}/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{9}Z-[A-Za-z0-9=_-]{1,64}\.json$" <<< "$all" | LC_ALL=C sort -r)
  done < <(grep -E "^${root//\//\\/}[a-z0-9][a-z0-9_-]*/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{9}Z-[A-Za-z0-9=_-]{1,64}\.json$" <<< "$all" \
    | awk -F/ '{ print $(NF-1) }' | LC_ALL=C sort -u)
  rm -f "$f"
  names=$(jq -r 'to_entries | map("\(.key) v\(.value)") | join(", ")' <<< "$pins")
  [ -n "$names" ] && echo "pinned on $STAGE: $names (they stay on those versions)"
  [ -n "$off" ] && echo "${W}did not go through: $off (its activation did not record the switch), so each keeps the pin before it, if any: switch or unpin again"
  REPLY=$pins
}
if [ -n "$VERSION" ]; then
  [[ "$VERSION" =~ $COMMIT_RE ]] || fail "version must be the full 40-character commit of a version already published (on the commit's page, copy the full SHA), not '$VERSION'"
  ID="activate-$RUN"
  REQUEST=$(jq -nc --arg v "$VERSION" --arg a "$ACTIVATE" --arg r "$REASON" \
    '{action: "activate", version: $v, activate: $a} + (if $r == "" then {} else {reason: $r} end)')
  WHAT="roll back $VENDOR/$PACKAGE to $VERSION"
elif [ -n "${FROM_STORE:-}" ] && [ "$MODE" = run ]; then
  # Checked when it was stored and again just now; the cell knows a version by its commit.
  [ "$VENDOR" = "$STORE_VENDOR" ] || fail "the stored package is $VENDOR's, not $STORE_VENDOR's"
  ID=$STORE_COMMIT DIGEST=$FROM_STORE
  # How prod's workflows and functions go live (#1479): the package's prodRollout, which the customer stack sets on prod's
  # projects (PROD_ROLLOUT). A production cell's deployer checks it against its list and shifts each alias so, rolled back
  # by alarms; any other cell switches at once. Any other stage asks for all-at-once (#1607 review): a production cell
  # that a customer file names as dev or test switches at once for them, as dev and test do everywhere.
  ROLLOUT="all-at-once"; [ "${STAGE:-}" = prod ] && ROLLOUT=${PROD_ROLLOUT:-}
  if [ -n "${SWITCH:-}" ]; then
    [ "$TYPE" = workflows ] || [ "$TYPE" = functions ] || fail "a switch moves one workflow's or function's live alias: only a workflows or functions activation takes SWITCH (#1559, #1560)"
    # Since the review of #1562 the customer API names the event it wrote first as the last part: the switch is recorded
    # by it, a pin's or an unpin's. Without it (an older customer API), a pin's by its build.
    [[ "$SWITCH" =~ ^([a-z0-9][a-z0-9_-]{0,79}):([1-9][0-9]{0,8}):(pin|unpin)(:([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{9}Z-[A-Za-z0-9=_-]{1,64}))?$ ]] \
      || fail "SWITCH must be <workflow>:<version>:pin|unpin, not '$SWITCH'"
    SW_NAME=${BASH_REMATCH[1]} SW_VERSION=${BASH_REMATCH[2]} SW_EVENT=${BASH_REMATCH[5]} SW_PIN=false
    [ "${BASH_REMATCH[3]}" = pin ] && SW_PIN=true
  fi
  if [ -n "${SWITCH:-}" ]; then
    # One workflow's or function's live alias moved (#1559, #1560): the deployer does it with UpdateStateMachineAlias or
    # Lambda's UpdateAlias, no deploy. The commit and digest are the version's package, which the stage published it from.
    REQUEST=$(jq -nc --arg t "$TYPE" --arg c "$ID" --arg d "$DIGEST" --arg n "$SW_NAME" --argjson v "$SW_VERSION" --argjson p "$SW_PIN" \
      '{action: "switch", type: $t, commit: $c, digest: $d, name: $n, version: $v, pin: $p}')
    if [ "$SW_PIN" = true ]; then WHAT="switch $SW_NAME of $VENDOR/$PACKAGE to v$SW_VERSION on ${STAGE:-the cell} and pin it"
    else WHAT="move $SW_NAME of $VENDOR/$PACKAGE back to v$SW_VERSION on ${STAGE:-the cell}, its package's, and unpin it"; fi
  elif [ "$TYPE" = workflows ]; then
    # The cell's workflows deployer builds the workflows stack from the files and deploys it; it answers with the commit
    # as the version, as the intake does. It goes live on deploy: no next boot, so no activate or reason.
    REQUEST=$(jq -nc --arg c "$ID" --arg d "$DIGEST" --arg r "$ROLLOUT" \
      '{action: "deploy", type: "workflows", commit: $c, digest: $d} + (if $r == "" then {} else {rollout: $r} end)')
    [ "$ACTIVATE" = now ] && echo "${N}activate: now does not apply to workflows: they go live when the cell deploys them, without a restart"
    WHAT="deploy the workflows of $VENDOR/$PACKAGE $DIGEST @ $ID from the store (${#FILES[@]} files)"
  elif [ "$TYPE" = functions ]; then
    # The cell's functions deployer (#674 step 5) checks the images and their scans (image_scans, below), deploys them
    # and answers with the commit as the version, as the workflows deployer does. No restart: no activate or reason.
    REQUEST=$(jq -nc --arg c "$ID" --arg d "$DIGEST" --arg r "$ROLLOUT" \
      '{action: "deploy", type: "functions", commit: $c, digest: $d} + (if $r == "" then {} else {rollout: $r} end)')
    [ "$ACTIVATE" = now ] && echo "${N}activate: now does not apply to functions: they go live when the cell deploys them, without a restart"
    WHAT="deploy the functions of $VENDOR/$PACKAGE $DIGEST @ $ID from the store (${#FILES[@]} files)"
  else
    REQUEST=$(jq -nc --arg a "$ACTIVATE" --arg r "$REASON" \
      '{action: "publish", activate: $a} + (if $r == "" then {} else {reason: $r} end)')
    WHAT="publish $VENDOR/$PACKAGE $DIGEST @ $ID from the store (${#FILES[@]} files)"
  fi
  # A switch (#1559) takes a version the stage published already, which the customer API checked: no gate.
  [ -z "${SWITCH:-}" ] && [ "${STAGE:-}" = test ] && test_gate
  [ -z "${SWITCH:-}" ] && [ "${STAGE:-}" = prod ] && prod_gate
  # The release's order on test (#1477) and on prod (#1478): workflows wait for their functions on the same stage.
  [ -z "${SWITCH:-}" ] && { [ "${STAGE:-}" = test ] || [ "${STAGE:-}" = prod ]; } && release_gate
  # After the gates: a start they refuse waits for no scan.
  [ "$TYPE" = functions ] && [ -z "${SWITCH:-}" ] && image_scans
  # The stage's pins (#1559), after the gates too: the deployer keeps each pinned workflow's live on its pinned version.
  # Dev's and test's only: prod is never switched, and its activation may not read pins (#1478).
  if { [ "$TYPE" = workflows ] || [ "$TYPE" = functions ]; } && [ -z "${SWITCH:-}" ] && { [ "${STAGE:-}" = dev ] || [ "${STAGE:-}" = test ]; }; then
    stage_pins
    [ "$REPLY" = '{}' ] || REQUEST=$(jq -c --argjson p "$REPLY" '. + {pins: $p}' <<< "$REQUEST")
  fi
else
  git rev-parse --git-dir >/dev/null 2>&1 || fail "not a git checkout: the version published is the commit"
  # Functions and workflows take committed files only (and the built zips, checked below): untracked build output, such
  # as the functions' zips when an automations repository delivers its workflows after them, is not a change to them.
  untracked=normal; [ "$TYPE" != censhare-custom ] && untracked=no
  [ -z "$(git status --porcelain --untracked-files=$untracked)" ] \
    || { git status --short --untracked-files=$untracked >&2; fail "the working tree has changes: only a commit is published"; }
  ID=$(git rev-parse HEAD)
  # Storing is not publishing: no stage branch to be the tip of.
  [ "$MODE" = store ] || current "before the upload"
fi
if [ -n "$VERSION" ] || { [ -n "${FROM_STORE:-}" ] && [ "$MODE" = run ]; }; then :
elif [ "$TYPE" = functions ]; then
  # functions/functions.json as committed, and the zips the customer's CI built next to it (build output, so not
  # committed, and left out of the clean-tree check above only because they are not tracked): the functions validator
  # checks them and names the package's files, each zip once.
  git ls-files --error-unmatch -- "$MANIFEST" >/dev/null 2>&1 || fail "$MANIFEST is not committed: only a commit is published"
  [ "$(git ls-files -s -- "$MANIFEST" | awk '{print $1}')" != 120000 ] || fail "$MANIFEST is a symlink, which is not published"
  if [ "$MODE" = check ]; then
    # check (deliver.sh reads the branch's tip with it) needs no zips: store checks them, and deliver.sh before it.
    WHAT="the functions of $VENDOR/$PACKAGE @ $ID"
  else
    kit=$(dirname "$SELF")
    # An image from the customer's own registry (#1412), pulled with this run's registry login before the check.
    [ -f "$kit/pull-images.sh" ] || fail "pull-images.sh is not next to $SELF: an image from a registry cannot be pulled"
    bash "$kit/pull-images.sh" "$MANIFEST" || fail "a function's image could not be pulled from its registry (above): nothing was stored"
    if [ -f "$kit/../lib/function-validate-cli.js" ]; then
      listed=$(node "$kit/../lib/function-validate-cli.js" --list .)
    elif [ -f "$kit/../../lib/function-validate-cli.ts" ]; then
      here=$(pwd); listed=$(cd "$kit/../.." && node --require ts-node/register lib/function-validate-cli.ts --list "$here")
    else
      fail "the functions validator is not next to $SELF"
    fi || fail "the functions do not pass their check (above): nothing was stored"
    IMAGES=()
    while IFS= read -r i; do [ -n "$i" ] && IMAGES+=("$i"); done < <(printf '%s\n' "$listed" | tail -n +2)
    [ "${#IMAGES[@]}" -gt 0 ] || fail "the functions validator named no images"
    WHAT="store the functions of $VENDOR/$PACKAGE @ $ID (${#IMAGES[@]} image(s))"
  fi
else
  [ -n "$SOURCE" ] || fail "customization.json: \"source\" names the folder with censhare-Server's app/ (e.g. censhare-Custom/censhare-Server)"
  case "/$SOURCE/" in */../*|*/./*|//*) fail "customization.json: \"source\" must be a folder inside the repository, not '$SOURCE'" ;; esac
  [ -d "$SOURCE" ] || fail "customization.json: \"source\" folder '$SOURCE' does not exist"
  # Tracked files only: what the commit holds, never build output or files left in the checkout. NUL-separated, so
  # any file name arrives as it is.
  FILES=()
  # Sorted bytewise, not by the locale's collation: the digest below must be the same on every machine (#750 review).
  while IFS= read -r -d '' f; do FILES+=("$f"); done < <(git ls-files -z -- "$MANIFEST" "$SOURCE" | LC_ALL=C sort -z)
  [ "${#FILES[@]}" -gt 1 ] || fail "the source folder '$SOURCE' has no committed files"
  # A committed symlink would upload whatever it points to on the runner, inside the repository or not.
  links=$(git ls-files -s -- "$MANIFEST" "$SOURCE" | awk '$1 == "120000" {sub(/^[^\t]*\t/, ""); print}')
  [ -z "$links" ] || fail "the package has symlinks, which are not published: $(echo "$links" | tr '\n' ' ')"
  # The package digest: the SHA-256 of "<sha256>  <path>" per file, sorted by path. What the commit's package is,
  # whatever the order of upload; the release build stores the package under it (#645, slice 2).
  DIGEST="sha256:$(sha256 "${FILES[@]}" | sha256 | cut -d' ' -f1)"
  REQUEST=$(jq -nc --arg a "$ACTIVATE" --arg r "$REASON" \
    '{action: "publish", activate: $a} + (if $r == "" then {} else {reason: $r} end)')
  WHAT="publish $VENDOR/$PACKAGE @ $ID (${#FILES[@]} files)"
fi
# Workflows and functions go live when the cell deploys them: no next boot, so no activate to say.
if [ "$TYPE" = censhare-custom ]; then echo "$WHAT, activate: $ACTIVATE${REASON:+ ($REASON)}"; else echo "$WHAT${REASON:+ ($REASON)}"; fi
[ "$MODE" = check ] && exit 0
case "$MODE" in run|store) ;; *) fail "usage: publish.sh check|run|store" ;; esac
[ "$MODE" = store ] || [ -n "${BUCKET:-}" ] || fail "bucket is required"

BASE="incoming/$VENDOR/$PACKAGE/$ID"
# A workflows package (#1071): its own intake, and a folder of its own per activation, with every file. The cell keeps no
# workflows versions to activate again, and incoming files expire: each activation, a rollback too, brings the package.
[ "$TYPE" = workflows ] && BASE="incoming-workflows/$VENDOR/$PACKAGE/$ID-$RUN"
# A functions package (#674 step 3): the same, into the cell's functions intake.
[ "$TYPE" = functions ] && BASE="incoming-functions/$VENDOR/$PACKAGE/$ID-$RUN"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Still before anything is sent (#1095). CELL_FIELDS are customization.json's: a workflows or functions package has none.
[ "$MODE" = run ] && [ "$TYPE" = censhare-custom ] && cell_fields_check

# upload: the <key>\0<file>\0 pairs on stdin, $PARALLEL at a time, each only if the key is not there yet (If-None-Match:
# *; see __put above). Returns once every upload has ended, and fails if any did. The action's upload.py does it in one
# process where the credentials are in the environment; one AWS CLI process per file works everywhere.
upload() {
  if [ -n "${UPLOAD_PY:-}" ] && command -v python3 >/dev/null && [ -n "${AWS_ACCESS_KEY_ID:-}" ] \
     && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] && [ -n "${AWS_REGION:-${AWS_DEFAULT_REGION:-}}" ] && [ -z "${AWS_CA_BUNDLE:-}" ] \
     && [ -z "${CELL_PROFILE:-}" ] && [ -z "${HTTPS_PROXY:-}${https_proxy:-}${ALL_PROXY:-}${all_proxy:-}" ]; then
    BUCKET="$BUCKET" PARALLEL="$PARALLEL" python3 "$UPLOAD_PY"
  else
    BUCKET="$BUCKET" CELL_PROFILE="${CELL_PROFILE:-}" xargs -0 -n 2 -P "$PARALLEL" bash "$SELF" __put
  fi
}

# store_package (publish.sh store): the files, then the manifest, which is what says the package is complete, then the
# commit's pointer. Written once: a second run finds them there (412) and changes nothing.
# push_images (store, functions, #674): each image the CI built, pushed into the vendor's repository in censhare's ECR
# (<customer>/<vendor>-functions, in the account the publisher role is in), and the package staged:
# functions/functions.json as committed, and functions/images.json with each image's repository and digest. The digest
# is what the cell runs, so the package digest pins the images too. A tag per run: the repository's tags are immutable.
push_images() {
  [[ "${CUSTOMER:-}" =~ ^[a-z][a-z0-9-]*$ ]] || fail "CUSTOMER is needed to push the functions' images (the customer id)"
  command -v docker >/dev/null || fail "docker is needed to push the functions' images"
  local account region registry repo image tag digest stage
  account=$(aws sts get-caller-identity --query Account --output text) || fail "could not tell the delivery account"
  region=${AWS_REGION:-${AWS_DEFAULT_REGION:-}}; [ -n "$region" ] || fail "AWS_REGION is needed to push the functions' images"
  registry="$account.dkr.ecr.$region.amazonaws.com"; repo="$CUSTOMER/$VENDOR-functions"
  aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$registry" >/dev/null \
    || fail "could not sign in to $registry (is this pipeline delegated for functions: \"types\" in its delegation?)"
  stage="$TMP/stage"; mkdir -p "$stage/functions"; cp "$MANIFEST" "$stage/functions/functions.json"
  local images='{}' id pushed media name from
  for image in "${IMAGES[@]}"; do
    # An image from the customer's registry (#1412) is named by its last path segment (asset-check for
    # ghcr.io/acme/asset-check@sha256:...), and images.json keeps where it came from.
    name=$image; from=
    case "$image" in */*) from=$image; name=${image%@*}; name=${name##*/} ;; esac
    # The tag names the image's content (#1403 review): its name (at most 64 characters), its own ID and the commit. The
    # repository's tags are immutable, so a run-based tag was refused on a retry where the CI has no run id (GitLab);
    # a tag already there holds this very content, so it is used as it is.
    id=$(docker image inspect --format '{{.Id}}' "$image") && [[ "$id" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "could not read the ID of $image"
    # Two images with one name (two versions of one image, two registries, or one built next to one pulled) have two IDs,
    # so two tags (#1414 review).
    tag="$(printf '%s' "$name" | cut -c1-64)-${id:7:16}-${ID:0:12}"
    if pushed=$(aws ecr describe-images --repository-name "$repo" --image-ids imageTag="$tag" --query 'imageDetails[0].imageDigest' --output text 2>/dev/null) \
       && [[ "$pushed" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      echo "$image is in $repo:$tag already: its content, so it is not pushed again"
    else
      docker tag "$image" "$registry/$repo:$tag" && docker push -q "$registry/$repo:$tag" >/dev/null \
        || fail "could not push $image to $registry/$repo"
    fi
    # Lambda runs a single image, never an image index (#1403 review): a buildx build with its default provenance pushes
    # an index. Refused here, before anything is stored, rather than by the cell's deploy after the commit's package is.
    read -r digest media < <(aws ecr describe-images --repository-name "$repo" --image-ids imageTag="$tag" \
      --query 'imageDetails[0].[imageDigest,imageManifestMediaType]' --output text) \
      && [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "could not read the digest of $repo:$tag"
    case "$media" in
      *image.index*|*manifest.list*) fail "image $image was pushed as an image index ($media), and Lambda runs a single image: build it with docker buildx build --platform linux/arm64 --provenance=false (nothing was stored)" ;;
    esac
    # ECR scans the image on push; the customer stack records the scan when it ends, and the cell refuses a critical
    # finding from that record (#1422). The kit reads no scan: enhanced scanning's reads span the whole account.
    echo "pushed $image as $repo@$digest"
    images=$(jq -c --arg i "$image" --arg r "$registry/$repo" --arg d "$digest" --arg s "$from" \
      '. + {($i): ({repository: $r, digest: $d} + (if $s == "" then {} else {source: $s} end))}' <<< "$images")
  done
  jq --sort-keys . <<< "$images" > "$stage/functions/images.json"
  cd "$stage" || fail "could not stage the functions package"
  FILES=(functions/functions.json functions/images.json)
  DIGEST="sha256:$(sha256 "${FILES[@]}" | sha256 | cut -d' ' -f1)"
}

# functions_changed_at (#1477): the last commit, up to this one, that changed what the functions are built from:
# FUNCTIONS_PATHS (git pathspecs, space-separated), by default everything but workflows/ (a change elsewhere, a README
# say, only makes the workflows wait for functions that test may well have, and stores a package of its own: the safe
# side; too narrow a value is not, since #1546 a commit with no change there stores nothing). A shallow clone's oldest commit seems to
# add every file, so a last change found there is not one: it is this commit then, and the workflows wait, never the
# other way round (GitHub's checkout fetches one commit unless fetch-depth: 0; GitLab 20 by default).
functions_changed_at() {
  local c paths=() shallow
  if [ -n "${FUNCTIONS_PATHS:-}" ]; then read -ra paths <<< "$FUNCTIONS_PATHS"; else paths=(. ':(exclude)workflows'); fi
  # --first-parent: a merge that brought the change is the commit delivered and stored, not the branch commit it
  # merged, which no pointer names (#1488 review).
  c=$(git log -1 --first-parent --format=%H "$ID" -- "${paths[@]}" 2>/dev/null) || c=""
  [[ "$c" =~ $COMMIT_RE ]] || { echo "$ID"; return 0; }
  shallow=$(git rev-parse --git-path shallow 2>/dev/null)
  if [ -n "$shallow" ] && [ -f "$shallow" ] && grep -qx "$c" "$shallow"; then echo "$ID"; else echo "$c"; fi
}

# reuse_unchanged_functions (#1546): a commit that did not change its functions (CHANGED_AT names an earlier one) points
# at the package of that last change instead of storing its own. CI rebuilds the images on every commit, and a rebuild
# rarely gives the same bytes, so its own package would be another digest: one test does not run, that dev deploys again
# and the console offers to promote, though nothing in it changed. Only when that commit's package is in the store (a
# push of several commits stores the tip only) and this commit has no pointer yet (it keeps its first, store_package);
# never for the extra dev cells, which write no pointer. Returns 1 when the commit stores its own.
reuse_unchanged_functions() {
  [ -n "${CHANGED_AT:-}" ] && [ "$CHANGED_AT" != "$ID" ] && [ "${STORE_POINTER:-yes}" != no ] || return 1
  [ -n "${PACKAGES_BUCKET:-}" ] || fail "PACKAGES_BUCKET is required to store"
  local mine="$VENDOR/versions/_functions/$PACKAGE/$ID.json" last="$VENDOR/versions/_functions/$PACKAGE/$CHANGED_AT.json" err d
  if err=$(aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$mine" "$TMP/mine.json" 2>&1 >/dev/null); then return 1; fi
  case "$err" in *NoSuchKey*|*"(404)"*|*"Not Found"*) ;; *) fail "the commit's pointer could not be read: $err" ;; esac
  if ! err=$(aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$last" "$TMP/last.json" 2>&1 >/dev/null); then
    case "$err" in *NoSuchKey*|*"(404)"*|*"Not Found"*) return 1 ;; *) fail "the pointer of $CHANGED_AT could not be read: $err" ;; esac
  fi
  d=$(jq -r '.digest // empty' "$TMP/last.json" 2>/dev/null)
  [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "the pointer $last names no digest"
  # Only a package this pipeline's role stored (#1548 review): another delegation's carries that one's record, which is
  # refused once it is revoked, or is not a release branch's (#1203), and a pointer is written once. Anything that cannot
  # tell (not a role, the record unreadable) counts as another's: the commit stores its own, as before #1546.
  local me publisher=""
  me=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null) || me=""
  case "$me" in arn:aws*:sts::*:assumed-role/*/*) publisher=${me#*:assumed-role/}; publisher=${publisher%%/*} ;; esac
  if ! [[ "$publisher" =~ ^[A-Za-z0-9_.-]+$ ]] \
     || ! aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$VENDOR/packages/${d#sha256:}/stored-by/$publisher.json" "$TMP/sb.json" >/dev/null 2>&1; then
    echo "functions unchanged since $CHANGED_AT, but its package $d was stored by another pipeline: this commit stores its own"
    return 1
  fi
  jq -n --arg d "$d" --arg c "$CHANGED_AT" '{digest: $d, type: "functions", changedAt: $c}' > "$TMP/version.json"
  printf '%s\0%s\0' "$mine" "$TMP/version.json" | ( BUCKET=$PACKAGES_BUCKET CELL_PROFILE='' upload ) \
    || fail "the commit's pointer could not be stored"
  # Two runs at once: only the first pointer counts; report what it names.
  aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$mine" "$TMP/mine.json" >/dev/null 2>&1 \
    && d=$(jq -r '.digest // empty' "$TMP/mine.json" 2>/dev/null)
  echo "functions unchanged since $CHANGED_AT: $ID points at its package $d; nothing pushed or stored (FUNCTIONS_PATHS: ${FUNCTIONS_PATHS:-everything but workflows/})"
  DIGEST=$d
  outcome stored
}
store_package() {
  [ -n "${PACKAGES_BUCKET:-}" ] || fail "PACKAGES_BUCKET is required to store"
  [ -z "$VERSION" ] || fail "store stores a commit, not a version (VERSION)"
  # A package's pointer apart from the customizations' (#1101 review): the Control Center lists those, newest first, and
  # a busy automations repository would otherwise make it read through every workflows or functions push.
  local pointer="$VENDOR/versions/$PACKAGE/$ID.json"
  [ "$TYPE" = workflows ] && pointer="$VENDOR/versions/_workflows/$PACKAGE/$ID.json"
  [ "$TYPE" = functions ] && pointer="$VENDOR/versions/_functions/$PACKAGE/$ID.json"
  # One commit, one functions package (#1255 review). Its digest covers the zips the customer's CI built, and a build
  # rarely gives the same bytes twice (a zip carries its build time), so a re-run or the same commit on the next stage
  # branch makes another digest. The commit keeps the package first stored for it, which is what its pointer names and
  # what was checked then: that one is reported, and this build is not stored. A customization or workflows package is
  # committed files only, so its commit always gives the same digest and needs no such check.
  if [ "$TYPE" = functions ]; then
    local err first
    if err=$(aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$pointer" "$TMP/first.json" 2>&1 >/dev/null); then
      first=$(jq -r '.digest // empty' "$TMP/first.json" 2>/dev/null)
      [[ "$first" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "the commit's pointer $pointer names no digest"
      if [ "$first" != "$DIGEST" ]; then
        echo "$VENDOR/$PACKAGE @ $ID was stored as $first already; this build ($DIGEST) is not stored"
        DIGEST=$first
        outcome stored
        return 0
      fi
    else
      case "$err" in *NoSuchKey*|*"(404)"*|*"Not Found"*) ;; *) fail "the commit's pointer could not be read: $err" ;; esac
    fi
  fi
  local at="$VENDOR/packages/${DIGEST#sha256:}"
  for f in "${FILES[@]}"; do printf '%s\0%s\0' "$at/files/$f" "$f"; done | ( BUCKET=$PACKAGES_BUCKET CELL_PROFILE= upload ) \
    || fail "the package could not be stored"
  sha256 "${FILES[@]}" | jq -R -s --arg c "$ID" --arg d "$DIGEST" --arg v "$VENDOR" --arg p "$PACKAGE" --arg t "$TYPE" \
    '{vendor: $v, package: $p, type: $t, commit: $c, digest: $d,
      files: [split("\n")[] | select(length > 0) | capture("^(?<sha256>[0-9a-f]{64})  (?<path>.*)$")]}' > "$TMP/manifest.json"
  # The type in the pointer too: the customer API lists a vendor's customization versions from the pointers alone (#762).
  # A functions pointer names the last commit that changed them too (#1477): what the commit's workflows wait for on test.
  if [ "$TYPE" = functions ]; then
    jq -n --arg d "$DIGEST" --arg t "$TYPE" --arg c "${CHANGED_AT:-$ID}" '{digest: $d, type: $t, changedAt: $c}' > "$TMP/version.json"
  else
    jq -n --arg d "$DIGEST" --arg t "$TYPE" '{digest: $d, type: $t}' > "$TMP/version.json"
  fi
  # Who stored it, before the manifest: a revoked delegation's packages reach no cell (decision 0023). The role this runs
  # as; the store lets a publisher role write only its own name, and only records dated no later than the manifest count.
  # Not recorded (not a role, or a store that does not allow it yet): the package's publisher is unknown, which is refused
  # once any delegation of the vendor is revoked, so leaving it out gains nothing.
  local me publisher=""
  me=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null) || me=""
  case "$me" in arn:aws*:sts::*:assumed-role/*/*) publisher=${me#*:assumed-role/}; publisher=${publisher%%/*} ;; esac
  if [[ "$publisher" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    jq -n --arg p "$publisher" --argjson r "${REPORTED:-$(reported_build)}" '{publisher: $p, reported: $r}' > "$TMP/stored-by.json"
    BUCKET=$PACKAGES_BUCKET CELL_PROFILE= bash "$SELF" __put "$at/stored-by/$publisher.json" "$TMP/stored-by.json" \
      || echo "${W}who stored the package could not be recorded: it is refused once a delegation of $VENDOR is revoked" >&2
  else
    echo "${W}not running as a role: who stored the package is not recorded" >&2
  fi
  BUCKET=$PACKAGES_BUCKET CELL_PROFILE= bash "$SELF" __put "$at/manifest.json" "$TMP/manifest.json" \
    || fail "the package's manifest could not be stored"
  # A delivery to the extra dev cells (#1189, STORE_POINTER=no) stores the package but no pointer: the pointers are
  # the versions every cell lists for promotion, and nothing is promoted from an extra dev cell. Its role may not write
  # them either. The same commit pushed to the main branch later writes it then.
  if [ "${STORE_POINTER:-yes}" = no ]; then
    echo "stored without a version pointer: a delivery to the extra dev cells, never promoted"
  else
    printf '%s\0%s\0' "$pointer" "$TMP/version.json" \
      | ( BUCKET=$PACKAGES_BUCKET CELL_PROFILE= upload ) || fail "the commit's pointer could not be stored"
    # Two runs of one functions commit at once (#1255 review): both found no pointer and stored their build, and only the
    # first pointer write counts (a 412 is "already there", done). So the pointer is read again: the digest it names is
    # this commit's package, which this run reports, whichever build that was.
    if [ "$TYPE" = functions ]; then
      local now
      aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$pointer" "$TMP/pointer.json" >/dev/null 2>&1 \
        || fail "the commit's pointer could not be read back after storing"
      now=$(jq -r '.digest // empty' "$TMP/pointer.json" 2>/dev/null)
      [[ "$now" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "the commit's pointer $pointer names no digest"
      if [ "$now" != "$DIGEST" ]; then
        echo "$VENDOR/$PACKAGE @ $ID: another run stored this commit first, as $now; this build ($DIGEST) is not its package"
        DIGEST=$now
        outcome stored
        return 0
      fi
    fi
  fi
  echo "stored $VENDOR/$PACKAGE @ $ID as $DIGEST (${#FILES[@]} files)"
  outcome stored
}
# keep_answer: the stage cell's answer next to the stored package; the last one wins (#781 reads test's as acceptance).
keep_answer() {
  [ -n "${FROM_STORE:-}" ] && [ -n "${STAGE:-}" ] && [ -f "$TMP/result.json" ] || return 0
  # With the build that kept it: deliver.sh reads its own build's answer, not an earlier one for the same digest (#779).
  jq --arg b "${CODEBUILD_BUILD_ID:-}" '. + {build: $b}' "$TMP/result.json" > "$TMP/kept.json" \
    && aws s3api put-object --bucket "$PACKAGES_BUCKET" --key "$VENDOR/packages/${DIGEST#sha256:}/$STAGE-result.json" \
    --body "$TMP/kept.json" >/dev/null 2>&1 || echo "${W}the cell's answer could not be kept in the store" >&2
}
# release: prod accepted the promotion, so it is prod's release: current.json says what runs (and what it replaced),
# and a history entry, written once, every promotion. A rollback is one more promotion.
release() {
  case "$(jq -r '.status // empty' "$TMP/result.json")" in published|activated) ;; *) return 0 ;; esac
  local at="$VENDOR/prod/$PACKAGE" now previous=""
  [ "$TYPE" = censhare-custom ] || at="$VENDOR/prod/_$TYPE/$PACKAGE"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  aws s3api get-object --bucket "$PACKAGES_BUCKET" --key "$at/current.json" "$TMP/previous.json" >/dev/null 2>&1 \
    && previous=$(jq -r '.digest // empty' "$TMP/previous.json")
  # The stored package's commit: ID is the request's name by now when the cell had this commit already.
  jq -n --arg d "$DIGEST" --arg c "$STORE_COMMIT" --arg p "$PACKAGE" --arg a "$APPROVER" --arg t "$now" --arg prev "$previous" \
    --arg b "${CODEBUILD_BUILD_ID:-$RUN}" '{digest: $d, commit: $c, package: $p, approver: $a, promoted: $t, build: $b}
      + (if $prev == "" then {} else {previous: $prev} end)' > "$TMP/release.json"
  # The history entry first: it is the record that must never be missing; current.json can be written again.
  printf '%s\0%s\0' "$at/history/${now//:/}-${DIGEST:7:12}-$RANDOM$RANDOM.json" "$TMP/release.json" \
    | ( BUCKET=$PACKAGES_BUCKET CELL_PROFILE= upload ) || echo "${W}the release's history entry could not be written" >&2
  aws s3api put-object --bucket "$PACKAGES_BUCKET" --key "$at/current.json" --body "$TMP/release.json" >/dev/null 2>&1 \
    || { echo "${W}prod runs $DIGEST, but current.json could not be written" >&2; return 0; }
  echo "prod release: $DIGEST${previous:+, replaces $previous}"
}
# reported_build (#1539): where the pipeline says it built this commit, as JSON, kept with who stored it. The CI's own
# variables: GitHub's GITHUB_REPOSITORY and GITHUB_REF; GitLab's CI_PROJECT_PATH and CI_COMMIT_TAG or CI_COMMIT_BRANCH;
# the customer's CodeCommit template's SOURCE_REPOSITORY, with SOURCE_BRANCH from deliver.sh. The commit is the one
# built and stored ($ID), not the CI's own SHA, which can name another (actions/checkout with a ref of its own, #1585
# review). onMain: whether origin/main has that commit, only when the checkout can tell (origin/main fetched, not a
# shallow clone) and git answers yes or no. The pipeline's word, which the Solution Console shows as reported: who
# stored the package is what proves its ref, and nothing here allows or refuses anything. A value that is no repository
# or ref is left out. Run in the checkout: the store reads it before push_images moves into its staging folder.
reported_build() {
  local repo="" ref=""
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then repo=$GITHUB_REPOSITORY; ref=${GITHUB_REF:-}
  elif [ -n "${CI_PROJECT_PATH:-}" ]; then
    repo=$CI_PROJECT_PATH
    if [ -n "${CI_COMMIT_TAG:-}" ]; then ref="refs/tags/$CI_COMMIT_TAG"; elif [ -n "${CI_COMMIT_BRANCH:-}" ]; then ref="refs/heads/$CI_COMMIT_BRANCH"; fi
  elif [ -n "${SOURCE_REPOSITORY:-}" ]; then repo=$SOURCE_REPOSITORY; [ -n "${SOURCE_BRANCH:-}" ] && ref="refs/heads/$SOURCE_BRANCH"
  fi
  [[ "$repo" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] && [ ${#repo} -le 200 ] || repo=""
  [[ "$ref" =~ ^refs/(heads|tags)/[A-Za-z0-9._/-]+$ ]] && [ ${#ref} -le 200 ] || ref=""
  local commit=$ID on="" rc=0
  if git rev-parse -q --verify refs/remotes/origin/main >/dev/null 2>&1 && [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = false ]; then
    # 0 is yes, 1 is no; anything else (128: an object the checkout lacks) is no answer, so onMain is left out.
    git merge-base --is-ancestor "$commit" refs/remotes/origin/main 2>/dev/null || rc=$?
    case $rc in 0) on=true ;; 1) on=false ;; esac
  fi
  jq -nc --arg r "$repo" --arg f "$ref" --arg c "$commit" --arg o "$on" \
    '(if $r == "" then {} else {repository: $r} end) + (if $f == "" then {} else {ref: $f} end) + {commit: $c}
     + (if $o == "" then {} else {onMain: ($o == "true")} end)'
}
# The last change to the functions, and where the pipeline says it built, are read in the checkout, before push_images
# moves into its staging folder (#1585 review: there, git could not tell whether the commit is on main).
if [ "$MODE" = store ]; then
  REPORTED=$(reported_build)
  if [ "$TYPE" = functions ]; then CHANGED_AT=$(functions_changed_at); reuse_unchanged_functions && exit 0; push_images; fi
  store_package; exit 0
fi

# The cell's answer in BASE, once it has given one.
answer() {
  aws ${CELL_PROFILE:+--profile "$CELL_PROFILE"} s3api get-object --bucket "$BUCKET" --key "$BASE/result.json" \
    "$TMP/result.json" >/dev/null 2>&1
}

# send <with files: 1|0>: the package (when publishing), the request last (it is what makes the cell act), and the wait.
send() {
  if [ "$1" = 1 ]; then
    # The request below is only sent when the whole package is there.
    for f in "${FILES[@]}"; do printf '%s\0%s\0' "$BASE/$f" "$f"; done | upload \
      || { echo "${E}not every file was uploaded; the request was not sent" >&2; exit 2; }
    echo "uploaded ${#FILES[@]} files"
    # The upload takes a while: a newer commit merged meanwhile publishes instead, and this request is not sent.
    [ -n "${FROM_STORE:-}" ] || current "before the request"   # a stored package is no branch's tip
  fi
  printf '%s' "$REQUEST" > "$TMP/request.json"
  printf '%s\0%s\0' "$BASE/request.json" "$TMP/request.json" | upload || exit 2
  echo "request sent; waiting up to ${WAIT_SECONDS}s for the cell's answer"
  local waited=0
  until answer; do
    if [ "$waited" -ge "$WAIT_SECONDS" ]; then
      echo "${E}no answer from the cell within ${WAIT_SECONDS}s; it may still come ($BASE/result.json)" >&2
      summary "### ⏳ $WHAT" "No answer from the cell within ${WAIT_SECONDS}s."
      outcome timeout --arg error "no answer from the cell within ${WAIT_SECONDS}s"
      exit 3
    fi
    sleep 5; waited=$((waited + 5))
  done
}

# A workflows request goes into a folder of its own run (incoming-workflows/…/<commit>-<run>). One with an answer already
# is an earlier build's: CodeBuild numbers start again at 1 when the project is made again, and the folders live 30 days.
# That answer is not this run's, and the customization's "published before" path below is not for workflows (#1104 review).
if [ "$TYPE" != censhare-custom ] && answer; then
  rm -f "$TMP/result.json"
  fail "$BASE already has an answer, from an earlier build with the same number; nothing sent. Run the activation again: the next build has a folder of its own"
elif [ -z "$VERSION" ] && answer; then
  # This commit was sent before, by an earlier run (e.g. the update, and now a run by hand with activate: now) or an
  # earlier attempt of this one. A commit's publish request cannot be sent twice, so a version the cell published is
  # activated with a request of this run's own: with this run's activate and reason, and back to it after a rollback.
  case "$(jq -r '.status // empty' "$TMP/result.json")" in
    published|activated)
      VERSION=$ID; ID="activate-$RUN"; BASE="incoming/$VENDOR/$PACKAGE/$ID"
      REQUEST=$(jq -nc --arg v "$VERSION" --arg a "$ACTIVATE" --arg r "$REASON" \
        '{action: "activate", version: $v, activate: $a} + (if $r == "" then {} else {reason: $r} end)')
      WHAT="activate $VENDOR/$PACKAGE @ $VERSION (published before)"
      echo "$VERSION is published already; asking the cell to activate it (activate: $ACTIVATE)"
      rm -f "$TMP/result.json"
      send 0 ;;
    *) echo "the cell answered this commit before; a refused commit is not sent again (commit a fix):" ;;
  esac
else
  # A switch (#1559) sends its request alone: the versions are in the cell already.
  send "$([ -z "$VERSION" ] && [ -z "${SWITCH:-}" ] && echo 1 || echo 0)"
fi

# A stored package's answer must be its own: a success names the version it published or activated. One for another
# version was left in that folder for another request, and is never kept as this stage's answer or prod's release.
if [ -n "${FROM_STORE:-}" ]; then
  case "$(jq -r '.status // empty' "$TMP/result.json")" in published|activated|switched)
    [ "$(jq -r '.version // empty' "$TMP/result.json")" = "$STORE_COMMIT" ] \
      || fail "the answer in $BASE is for $(jq -r '.version // "no version"' "$TMP/result.json"), not $STORE_COMMIT; nothing recorded" ;;
  esac
fi
# A switch that went through is recorded next to its event (review of #1562): the pin or unpin counts only then, for
# the customer API and for every later deploy (stage_pins). One the cell refused records nothing. By the event it names;
# from an older customer API, a pin's by its build.
if [ -n "${SWITCH:-}" ] && [ "$(jq -r '.status // empty' "$TMP/result.json")" = switched ]; then
  sw_id=""
  if [ -n "${SW_EVENT:-}" ]; then sw_id=$SW_EVENT
  elif [ "${SW_PIN:-}" = true ] && [[ "${CODEBUILD_BUILD_ID:-}" =~ :([A-Za-z0-9-]{1,64})$ ]]; then sw_id=${BASH_REMATCH[1]}
  elif [ "${SW_PIN:-}" = true ]; then echo "${W}no build id (CODEBUILD_BUILD_ID): the switch went through, but its pin does not count until it is switched again" >&2
  fi
  if [ -n "$sw_id" ]; then
    jq -n --argjson v "$SW_VERSION" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{status: "switched", live: $v, at: $at}' > "$TMP/switched.json"
    BUCKET=$PACKAGES_BUCKET CELL_PROFILE='' bash "$SELF" __put "$STORE_VENDOR/pins/$STAGE/$TYPE/$SW_NAME/switched/$sw_id.json" "$TMP/switched.json" \
      || echo "${W}the switch went through, but could not be recorded: it does not count until it is switched again" >&2
  fi
fi
# A switch's answer is no deploy's (#1559): the stage's answer for the digest stays the deploy's, which says which
# version each workflow got.
[ -z "${SWITCH:-}" ] && keep_answer
# Each type's prod release is its own (#1478): a workflows or functions package's under prod/_<type>/<package>/, never
# the customization's prod/<package>/ (#1104 review). A switch is never prod's.
[ -z "${SWITCH:-}" ] && [ "${STAGE:-}" = prod ] && [ -n "${FROM_STORE:-}" ] && release
STATUS=$(jq -r '.status // "unknown"' "$TMP/result.json")
output status "$STATUS"
outcome "$STATUS" --arg activation "$(jq -r '.activation // empty' "$TMP/result.json")" \
  --arg reason "$(jq -r '.reason // empty' "$TMP/result.json")" --argjson validator "$(jq -c '.validator // []' "$TMP/result.json")"
output version "$(jq -r '.version // empty' "$TMP/result.json")"
jq -r '"status:     \(.status)", (if .version then "version:    \(.version)" else empty end),
       (if .activation then "activation: \(.activation)" else empty end), (if .note then "note:       \(.note)" else empty end),
       (if .reason then "reason:     \(.reason)" else empty end), (.validator // [] | .[] | "  \(.)")' "$TMP/result.json"
case "$STATUS" in
  published|activated|switched)
    summary "### ✅ $WHAT" "" "$(jq -r '[.status, .activation // empty, .note // empty] | join(" — ")' "$TMP/result.json")"
    exit 0 ;;
  *)
    summary "### ❌ $WHAT" "" "**Refused by the cell:** $(jq -r '.reason // "no reason given"' "$TMP/result.json")" "" \
            '```' "$(jq -r '.validator // [] | .[]' "$TMP/result.json")" '```'
    echo "${E}the cell refused: $(jq -r '.reason // "no reason given"' "$TMP/result.json")" >&2
    exit 1 ;;
esac
