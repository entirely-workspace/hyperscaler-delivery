#!/usr/bin/env bash
# Publish a partner's customization package to a cell's intake, or roll the cell back to one already published (#345),
# and store it in a customer's package store (#780). The one script for every path: a partner's CI runs it (the
# hyperscaler-partner-publish GitHub action keeps a copy its CI compares with this one), and a customer's activations
# (lib/customer-customization-stack.ts) run it to place a stored package into a cell. Everything a cell runs is
# checked and signed by the cell itself (its intake): this script only delivers the package and reports the cell's
# answer.
#
#   publish.sh check    the checks that need no access to the cell (run before the job gets the cell's credentials)
#   publish.sh run      upload, send the request, wait for the result
#   publish.sh store    store this commit's package once in the customer's package store (#780), send nothing
#
# The package store (#780), PACKAGES_BUCKET, keyed by digest:
#   <vendor>/packages/<hex>/files/<path>, manifest.json   the package, written once, never replaced
#   <vendor>/packages/<hex>/<stage>-result.json           the stage cell's last answer for it (test's is acceptance)
#   <vendor>/versions/<package>/<commit>.json             the commit's digest
#   <vendor>/packages/<hex>/prod-approval.json            the customer's approval for prod (#781), written once
#   <vendor>/prod/<package>/current.json, history/...     prod's release: what runs, and every promotion
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
#   STAGE           the stage this run publishes for; names the answer kept in the store
#   OUTCOME_FILE    where to write what happened, as JSON, for whoever reports the result (#646, #781): status
#                   (published, activated, refused, superseded, failed, timeout), version, package, files, digest,
#                   activation, reason, validator, error, supersededBy. Empty: none written
# and, under GitHub, GITHUB_REF, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, GITHUB_STEP_SUMMARY, GITHUB_OUTPUT; under CodeBuild,
# CODEBUILD_BUILD_NUMBER for the request's id.
#
# Exit: 0 published, activated or superseded, 1 refused by the cell, 2 a check here failed, 3 no answer in time.
set -uo pipefail

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

# tip: the commit BRANCH points at now, or nothing when it cannot be read.
tip() {
  local t=""
  if [ -n "${REPOSITORY:-}" ]; then
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
    [ "${GITHUB_ACTIONS:-}" = true ] || [ -n "${CODEBUILD_BUILD_ID:-}" ] \
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
[ -n "${FROM_STORE:-}" ] && [ "$MODE" = run ] && from_store

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

# ---- the package and the request, checked before anything is sent
[ -f customization.json ] || fail "no customization.json here ($(pwd)); set working-directory to the folder that has it"
jq -e 'type == "object"' customization.json >/dev/null 2>&1 || fail "customization.json is not a JSON object"
VENDOR=$(jq -r '.vendor // empty' customization.json)
PACKAGE=$(jq -r '.package // empty' customization.json)
SOURCE=$(jq -r '.source // empty' customization.json)
[[ "$VENDOR" =~ $NAME_RE ]] || fail "customization.json: \"vendor\" must be lower-case [a-z0-9_-], not '$VENDOR'"
[[ "$PACKAGE" =~ $NAME_RE ]] || fail "customization.json: \"package\" must be lower-case [a-z0-9_-], not '$PACKAGE'"
case "$ACTIVATE" in next-boot|now) ;; *) fail "activate must be next-boot or now, not '$ACTIVATE'" ;; esac
if [ "$ACTIVATE" = now ] && [ -z "${REASON//[[:space:]]/}" ]; then
  fail "activate: now restarts the customer's server: give a reason"
fi
[[ "$WAIT_MINUTES" =~ ^[0-9]{1,3}$ ]] || fail "wait-minutes must be a number of minutes, not '$WAIT_MINUTES'"
WAIT_SECONDS=$((10#$WAIT_MINUTES * 60))
# The cell only accepts requests from its stage branch (its publish role trusts nothing else); say so here. Storing is
# not publishing to a cell: the publisher role's OIDC trust names the ref that may store (#779).
if [ "$MODE" != store ] && [ -n "${GITHUB_REF:-}" ] && [ "$GITHUB_REF" != "refs/heads/$BRANCH" ]; then
  fail "only $BRANCH publishes or rolls back (this is $GITHUB_REF)"
fi

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
  REQUEST=$(jq -nc --arg a "$ACTIVATE" --arg r "$REASON" \
    '{action: "publish", activate: $a} + (if $r == "" then {} else {reason: $r} end)')
  WHAT="publish $VENDOR/$PACKAGE $DIGEST @ $ID from the store (${#FILES[@]} files)"
  [ "${STAGE:-}" = prod ] && prod_gate
else
  git rev-parse --git-dir >/dev/null 2>&1 || fail "not a git checkout: the version published is the commit"
  [ -z "$(git status --porcelain)" ] || { git status --short >&2; fail "the working tree has changes: only a commit is published"; }
  ID=$(git rev-parse HEAD)
  # Storing is not publishing: no stage branch to be the tip of.
  [ "$MODE" = store ] || current "before the upload"
  [ -n "$SOURCE" ] || fail "customization.json: \"source\" names the folder with censhare-Server's app/ (e.g. censhare-Custom/censhare-Server)"
  case "/$SOURCE/" in */../*|*/./*|//*) fail "customization.json: \"source\" must be a folder inside the repository, not '$SOURCE'" ;; esac
  [ -d "$SOURCE" ] || fail "customization.json: \"source\" folder '$SOURCE' does not exist"
  # Tracked files only: what the commit holds, never build output or files left in the checkout. NUL-separated, so
  # any file name arrives as it is.
  FILES=()
  # Sorted bytewise, not by the locale's collation: the digest below must be the same on every machine (#750 review).
  while IFS= read -r -d '' f; do FILES+=("$f"); done < <(git ls-files -z -- customization.json "$SOURCE" | LC_ALL=C sort -z)
  [ "${#FILES[@]}" -gt 1 ] || fail "the source folder '$SOURCE' has no committed files"
  # A committed symlink would upload whatever it points to on the runner, inside the repository or not.
  links=$(git ls-files -s -- customization.json "$SOURCE" | awk '$1 == "120000" {sub(/^[^\t]*\t/, ""); print}')
  [ -z "$links" ] || fail "the package has symlinks, which are not published: $(echo "$links" | tr '\n' ' ')"
  # The package digest: the SHA-256 of "<sha256>  <path>" per file, sorted by path. What the commit's package is,
  # whatever the order of upload; the release build stores the package under it (#645, slice 2).
  DIGEST="sha256:$(sha256 "${FILES[@]}" | sha256 | cut -d' ' -f1)"
  REQUEST=$(jq -nc --arg a "$ACTIVATE" --arg r "$REASON" \
    '{action: "publish", activate: $a} + (if $r == "" then {} else {reason: $r} end)')
  WHAT="publish $VENDOR/$PACKAGE @ $ID (${#FILES[@]} files)"
fi
echo "$WHAT, activate: $ACTIVATE${REASON:+ ($REASON)}"
[ "$MODE" = check ] && exit 0
case "$MODE" in run|store) ;; *) fail "usage: publish.sh check|run|store" ;; esac
[ "$MODE" = store ] || [ -n "${BUCKET:-}" ] || fail "bucket is required"

BASE="incoming/$VENDOR/$PACKAGE/$ID"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# upload: the <key>\0<file>\0 pairs on stdin, $PARALLEL at a time, each only if the key is not there yet (If-None-Match:
# *; see __put above). Returns once every upload has ended, and fails if any did. The action's upload.py does it in one
# process where the credentials are in the environment; one AWS CLI process per file works everywhere.
upload() {
  if [ -n "${UPLOAD_PY:-}" ] && command -v python3 >/dev/null && [ -n "${AWS_ACCESS_KEY_ID:-}" ] \
     && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] && [ -n "${AWS_REGION:-${AWS_DEFAULT_REGION:-}}" ] && [ -z "${AWS_CA_BUNDLE:-}" ] \
     && [ -z "${CELL_PROFILE:-}" ] && [ -z "${HTTPS_PROXY:-}${https_proxy:-}${ALL_PROXY:-}${all_proxy:-}" ]; then
    BUCKET="$BUCKET" PARALLEL="$PARALLEL" python3 "$UPLOAD_PY"
  else
    BUCKET="$BUCKET" CELL_PROFILE="${CELL_PROFILE:-}" xargs -0 -n 2 -P "$PARALLEL" bash "$0" __put
  fi
}

# store_package (publish.sh store): the files, then the manifest, which is what says the package is complete, then the
# commit's pointer. Written once: a second run finds them there (412) and changes nothing.
store_package() {
  [ -n "${PACKAGES_BUCKET:-}" ] || fail "PACKAGES_BUCKET is required to store"
  [ -z "$VERSION" ] || fail "store stores a commit, not a version (VERSION)"
  local at="$VENDOR/packages/${DIGEST#sha256:}"
  for f in "${FILES[@]}"; do printf '%s\0%s\0' "$at/files/$f" "$f"; done | ( BUCKET=$PACKAGES_BUCKET CELL_PROFILE= upload ) \
    || fail "the package could not be stored"
  sha256 "${FILES[@]}" | jq -R -s --arg c "$ID" --arg d "$DIGEST" --arg v "$VENDOR" --arg p "$PACKAGE" \
    '{vendor: $v, package: $p, commit: $c, digest: $d,
      files: [split("\n")[] | select(length > 0) | capture("^(?<sha256>[0-9a-f]{64})  (?<path>.*)$")]}' > "$TMP/manifest.json"
  jq -n --arg d "$DIGEST" '{digest: $d}' > "$TMP/version.json"
  printf '%s\0%s\0%s\0%s\0' "$at/manifest.json" "$TMP/manifest.json" "$VENDOR/versions/$PACKAGE/$ID.json" "$TMP/version.json" \
    | ( BUCKET=$PACKAGES_BUCKET CELL_PROFILE= upload ) || fail "the package's manifest could not be stored"
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
if [ "$MODE" = store ]; then store_package; exit 0; fi

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

if [ -z "$VERSION" ] && answer; then
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
  send "$([ -z "$VERSION" ] && echo 1 || echo 0)"
fi

# A stored package's answer must be its own: a success names the version it published or activated. One for another
# version was left in that folder for another request, and is never kept as this stage's answer or prod's release.
if [ -n "${FROM_STORE:-}" ]; then
  case "$(jq -r '.status // empty' "$TMP/result.json")" in published|activated)
    [ "$(jq -r '.version // empty' "$TMP/result.json")" = "$STORE_COMMIT" ] \
      || fail "the answer in $BASE is for $(jq -r '.version // "no version"' "$TMP/result.json"), not $STORE_COMMIT; nothing recorded" ;;
  esac
fi
keep_answer
[ "${STAGE:-}" = prod ] && [ -n "${FROM_STORE:-}" ] && release
STATUS=$(jq -r '.status // "unknown"' "$TMP/result.json")
output status "$STATUS"
outcome "$STATUS" --arg activation "$(jq -r '.activation // empty' "$TMP/result.json")" \
  --arg reason "$(jq -r '.reason // empty' "$TMP/result.json")" --argjson validator "$(jq -c '.validator // []' "$TMP/result.json")"
output version "$(jq -r '.version // empty' "$TMP/result.json")"
jq -r '"status:     \(.status)", (if .version then "version:    \(.version)" else empty end),
       (if .activation then "activation: \(.activation)" else empty end), (if .note then "note:       \(.note)" else empty end),
       (if .reason then "reason:     \(.reason)" else empty end), (.validator // [] | .[] | "  \(.)")' "$TMP/result.json"
case "$STATUS" in
  published|activated)
    summary "### ✅ $WHAT" "" "$(jq -r '[.status, .activation // empty, .note // empty] | join(" — ")' "$TMP/result.json")"
    exit 0 ;;
  *)
    summary "### ❌ $WHAT" "" "**Refused by the cell:** $(jq -r '.reason // "no reason given"' "$TMP/result.json")" "" \
            '```' "$(jq -r '.validator // [] | .[]' "$TMP/result.json")" '```'
    echo "${E}the cell refused: $(jq -r '.reason // "no reason given"' "$TMP/result.json")" >&2
    exit 1 ;;
esac
