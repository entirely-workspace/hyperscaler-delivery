#!/usr/bin/env bash
# Take a cell's live changes back to git (#1207): a capture (docs/CELL-CAPTURE.md, #1206), taken from the cell with your
# Solution Console sign-in (--cell, #1421) or downloaded (the Local changes tab, or Export on the Admin Client's
# Customizations page), becomes a branch from the commit the cell runs and a pull request. Run in
# your clone of the package's repository. It pushes with your own git credentials; censhare holds none (decision 0028).
# In the partner kit it is bin/pull-back.sh, next to bin/validate.sh.
#
#   pull-back.sh --cell <console address> [--capture] [--package <vendor>/<package>] [--into <branch>] [--no-push]
#   pull-back.sh --from <capture zip> [--package <vendor>/<package>] [--into <branch>] [--no-push]
#
#   --cell      the cell's Solution Console, as the Local changes tab shows it (https://<cell>/solution-console/): signs
#               you in in the browser and takes the cell's newest capture (cell-capture.py, next to this script)
#   --capture   with --cell: capture the cell first, as Capture now in the tab
#   --package   which package the changes go into, when the cell runs more than one
#   --into      the branch the pull request goes into; a capture from a dev cell only (default: with --cell, the
#               branch the cell follows, else origin's default branch). One from a test or prod cell always goes into
#               the default branch: never a push to it.
#   --no-push   commit on the branch in this clone, push nothing
#
# What it does: checks the capture (format 1, each file what capture.json says, every path one a package may own),
# checks out the package's commit the cell runs as pullback/<cell>/<vendor>/<package>/<yyyymmdd-hhmmss>, copies each file into the package's
# source folder byte for byte, adds each file's folder to "owns", writes the hotfolder rules into settings.ingest,
# checks the package (validate.sh), commits and pushes with your own credentials. On CodeCommit it opens the pull
# request with the AWS CLI; on GitHub and GitLab (hosted or self-hosted) and any other host it names the branch and
# shows how to open the pull request (the web page, the gh or glab command), which you open and merge yourself. The branch starts from the running commit, so the pull request holds only
# the live changes, and a later change to the same file on the base is a conflict there, never lost.
#
# One capture goes into one package: on a cell that runs several, --package names it, and a second pull-back of the
# same capture is refused. The commit and the pull request name the cell, its stage and the capture's time, not who
# exported it (they land in the package's repository).
#
# Exit: 0 done (or the cell was in sync), 1 refused (the reason is printed), 2 could not run. Whatever stops it after the
# branch was made puts the clone back as it was, except a failed check of the package: then the branch stays checked
# out with the files, uncommitted, for you to fix.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
fail()   { echo "error: $*" >&2; exit 2; }
refuse() { echo "refused: $*" >&2; exit 1; }
usage()  { sed -n '8,18p' "$0" | sed 's/^# \{0,1\}//'; }
FROM="" CELL="" CAPTURE=0 PKG="" INTO="" PUSH=1
while [ $# -gt 0 ]; do
  case $1 in
    --from) FROM=${2:-}; shift 2 || fail "--from needs a file" ;;
    --cell) CELL=${2:-}; shift 2 || fail "--cell needs the cell's Solution Console address" ;;
    --capture) CAPTURE=1; shift ;;
    --package) PKG=${2:-}; shift 2 || fail "--package needs <vendor>/<package>" ;;
    --into) INTO=${2:-}; shift 2 || fail "--into needs a branch" ;;
    --no-push) PUSH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown option $1" ;;
  esac
done
[ -n "$FROM" ] || [ -n "$CELL" ] || { usage >&2; fail "usage: --cell <console address> or --from <capture zip> is needed"; }
[ -z "$FROM" ] || [ -z "$CELL" ] || { usage >&2; fail "usage: --cell or --from, not both"; }
[ "$CAPTURE" = 0 ] || [ -n "$CELL" ] || { usage >&2; fail "usage: --capture goes with --cell"; }
[ -n "$CELL" ] || [ -f "$FROM" ] || fail "no such capture: $FROM"
for t in git jq python3; do command -v "$t" >/dev/null || fail "$t is needed"; done
[ -z "$CELL" ] || [ -f "$HERE/cell-capture.py" ] || fail "cell-capture.py is not next to $0"
# The kit ships the validator next to this script; this repository keeps it in scripts/.
for V in "$HERE/validate-customization.py" "$HERE/../validate-customization.py"; do [ -f "$V" ] && break; done
[ -f "$V" ] || fail "validate-customization.py is not next to $0"
[ -z "$FROM" ] || FROM=$(cd "$(dirname "$FROM")" && pwd)/$(basename "$FROM")
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || fail "run it in your clone of the package's repository"
cd "$TOP" || exit 2
[ -z "$(git status --porcelain)" ] || fail "this clone has uncommitted changes: commit or stash them first"

W=$(mktemp -d) || exit 2
# Once the branch exists (step 3), any way out but a commit, or the failed package check that keeps the files for the
# developer, takes the clone back to where it was and drops the branch (#1354 review).
BR="" ORIG="" UNDO=0
cleanup() {
  if [ "$UNDO" = 1 ]; then
    git reset -q --hard && git checkout -q "$ORIG" && git branch -q -D "$BR" \
      && echo "the clone is back on $ORIG; $BR is removed" >&2
  fi
  rm -rf "$W"
}
trap cleanup EXIT

# 0. From the cell (#1421): the newest capture, with the developer's own sign-in, into this run's folder. Only once the
# clone is clean, so nobody signs in for a run that cannot go on.
if [ -n "$CELL" ]; then
  args=(--cell "$CELL" --out "$W/cell.zip" --follows "$W/follows.json"); [ "$CAPTURE" = 1 ] && args+=(--capture)
  python3 -I "$HERE/cell-capture.py" "${args[@]}"; rc=$?
  case $rc in
    0) FROM="$W/cell.zip" ;;
    3) exit 0 ;;   # in sync: nothing to pull back (said by cell-capture.py)
    *) exit "$rc" ;;
  esac
fi

# 1. The capture: read and checked in full before anything is touched. -I: nothing in the clone may change what
# Python imports. own_ok is the validator's, the rule the cell's boot and the publish apply.
python3 -I - "$FROM" "$W" "$V" <<'PY' || exit $?
import hashlib, importlib.util, json, os, posixpath, re, stat, sys, zipfile
src, out, validator = sys.argv[1:4]
def refuse(m): print('refused: ' + m, file=sys.stderr); sys.exit(1)
spec = importlib.util.spec_from_file_location('validator', validator); v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
LAYOUT = 'censhare-Custom/censhare-Server/'
try:
    z = zipfile.ZipFile(src)
except (zipfile.BadZipFile, OSError) as e:
    refuse(f'{src} is not a capture zip: {e}')
with z:
    names = [i for i in z.infolist() if not i.filename.endswith('/')]
    for i in names:
        n = i.filename
        if n != 'capture.json' and not (n.startswith(LAYOUT + 'app/') and '..' not in n.split('/') and '\\' not in n):
            refuse(f'the zip holds {n}, outside the capture layout')
        if stat.S_ISLNK(i.external_attr >> 16):
            refuse(f'the zip holds a link, {n}')
    try:
        cap = json.loads(z.read('capture.json'))
    except KeyError:
        refuse('the zip has no capture.json')
    except ValueError as e:
        refuse(f'capture.json is not JSON: {e}')
    if not isinstance(cap, dict) or cap.get('format') != 1:
        refuse(f'capture.json is format {cap.get("format") if isinstance(cap, dict) else "?"}; this pull-back reads format 1: use the kit of the edition the cell runs')
    files = cap.get('files') or []
    listed, owners = set(), []
    for f in files:
        p = f.get('path') if isinstance(f, dict) else None
        if not isinstance(p, str) or not re.match(r'^app/[^/]', p) or p.endswith('/') or '//' in p \
                or posixpath.normpath(p) != p or '..' in p.split('/'):
            refuse(f'{p!r} is not a path below censhare-Server/app')
        if f.get('change') not in ('changed', 'added'):
            refuse(f'{p}: change "{f.get("change")}" is not one format 1 writes')
        # The file's folder, the way packages own command configuration. A file own_ok allows on its own (the EventBridge
        # publisher's two command files, whose folder is the edition's) can't be delivered yet: the publish, the
        # intake and the boot take only folders in owns. Refused here rather than by the package's check later.
        d = posixpath.dirname(p)
        if p.startswith('app/masterdata/'):
            # A package carries master data only with "touchesMasterdata": true, which changes how every cell activates
            # it. That is the package owner's call, not a pull-back's (#1354 review).
            refuse(f'{p} is master data: a package carries it only with "touchesMasterdata": true, which a pull-back '
                   f'does not switch on. Add it to the package by hand')
        if d in ('app/masterdata', 'app/assets'):
            refuse(f'{p} sits directly in {d}: pulling it back would own the whole of {d}, on every cell the package '
                   f'reaches. Move it into a folder of its own in the package by hand')
        if v.own_ok(d):
            owner = d
        elif p in ('app/modules/event_forward_eventbridge/publish.xml', 'app/modules/event_forward_eventbridge/publish-masterdata.xml'):
            refuse(f'{p} can be owned only as a file, and owns takes folders today: switch it on in the package by hand, '
                   f'or on each cell in the Admin Client, until the cell takes a file in owns')
        elif v.own_ok(p):
            refuse(f'{p} sits directly in {d}, which no package may own: it stays the cell\'s')
        else:
            refuse(f'{p} is in no path a package may own; it stays the cell\'s')
        try:
            b = z.read(LAYOUT + p)
        except KeyError:
            refuse(f'{p} is in capture.json but not in the zip')
        if hashlib.sha256(b).hexdigest() != f.get('sha256') or len(b) != f.get('size'):
            refuse(f'{p} in the zip does not match capture.json (sha256 or size)')
        dest = os.path.join(out, 'files', p)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, 'wb') as fh:
            fh.write(b)
        listed.add(LAYOUT + p); owners.append(owner)
    extra = [i.filename for i in names if i.filename != 'capture.json' and i.filename not in listed]
    if extra:
        refuse(f'the zip holds files capture.json has not listed: {", ".join(extra)}')
json.dump(cap, open(os.path.join(out, 'capture.json'), 'w'))
open(os.path.join(out, 'owners'), 'w').write(''.join(o + '\n' for o in owners))   # one a line: a folder may hold a space
PY
C="$W/capture.json"
cell=$(jq -r '.cell // ""' "$C"); stage=$(jq -r '.stage // ""' "$C"); at=$(jq -r '.capturedAt // ""' "$C")
[[ "$cell" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || refuse "capture.json names no cell"
case $stage in dev|test|prod) ;; *) refuse "capture.json names no stage (dev, test or prod), but '$stage'" ;; esac
[[ "$at" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2}) ]] || refuse "capture.json has no capturedAt"
# To the second: two captures of one cell in the same minute are two pull-backs (#1354 review).
when="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}-${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}"
if [ "$(jq -r '(.files // []) | length' "$C")" = 0 ] && [ "$(jq -r '.settings // {} | length' "$C")" = 0 ]; then
  echo "$cell is in sync with its release ($at): nothing to pull back"; exit 0
fi

# 2. The package, and the commit the cell runs.
names=$(jq -r '.release.packages[]?.name' "$C")
[ -n "$names" ] || refuse "$cell runs no package: there is no commit to start from. Add the files to a package by hand"
if [ -z "$PKG" ]; then
  [ "$(printf '%s\n' "$names" | wc -l | tr -d ' ')" = 1 ] || refuse "$cell runs several packages; name one with --package: $(echo $names)"
  PKG=$names
fi
grep -qxF -- "$PKG" <<<"$names" || refuse "$cell does not run $PKG, but: $(echo $names)"
[ "$(printf '%s\n' "$names" | wc -l | tr -d ' ')" = 1 ] \
  || echo "note: $cell runs several packages; all of this capture's changes go into $PKG" >&2
[[ "$PKG" =~ ^[a-z0-9_-]+/[a-z0-9_-]+$ ]] || refuse "$PKG is not <vendor>/<package>"
REV=$(jq -r --arg p "$PKG" '.release.packages[] | select(.name == $p) | .commit' "$C" | head -1)
[[ "$REV" =~ ^[0-9a-f]{40}$ ]] || refuse "capture.json names no commit for $PKG"
git cat-file -e "$REV^{commit}" 2>/dev/null || git fetch -q origin "$REV" 2>/dev/null \
  || refuse "the commit $cell runs for $PKG, $REV, is not in this repository: is it the package's clone?"
# The package's folder at that commit: the customization.json with its vendor and package.
DIR=""
while IFS= read -r f; do
  [ "$(git show "$REV:$f" 2>/dev/null | jq -r '"\(.vendor)/\(.package)"' 2>/dev/null)" = "$PKG" ] && { DIR=$(dirname "$f"); break; }
done < <(git ls-tree -r --name-only "$REV" | grep -E '(^|/)customization\.json$')
[ -n "$DIR" ] || refuse "no customization.json of $PKG at $REV"

# 3. The branch and where its pull request goes.
DEFAULT=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null); DEFAULT=${DEFAULT#origin/}
[ -n "$DEFAULT" ] || DEFAULT=$(git ls-remote --symref origin HEAD 2>/dev/null | sed -n 's#^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$#\1#p')
DEFAULT=${DEFAULT:-main}
# The branch a dev cell follows (#1207 slice 3), when cell-capture.py read it from the customer API: the base unless
# --into names one. Only when the binding names origin's repository, and origin has that branch with the commit the
# cell runs on it (a failed delivery from another branch can be the newest report, #1467 review). Anything else is
# said, and the default branch stays the base, as before: a followed branch never turns a pull-back into a refusal.
URL=$(git config --get remote.origin.url)
# A repository's path without its host: https://host/acme/custom.git, git@host:acme/custom and codecommit://p@name give
# acme/custom, acme/custom and name. A plain name stays as it is.
repo_path() {
  local x=${1%/}; x=${x%.git}
  case $x in
    *://*) x=${x#*://}; x=${x#*@}; case $x in */*) x=${x#*/} ;; esac ;;
    *@*:*) x=${x#*:} ;;
  esac
  printf '%s' "$x" | tr 'A-Z' 'a-z'
}
# Whether the binding names the repository at path $2: the whole path when the binding has an owner (other-org/custom
# is not acme/custom, #1467 review), else the last segment.
same_repo() {
  local b p; b=$(repo_path "$1"); p=$(repo_path "$2")
  [ -n "$b" ] && [ -n "$p" ] || return 1
  case $b in */*) [ "$p" = "$b" ] || [ "${p%/"$b"}" != "$p" ] ;; *) [ "${p##*/}" = "$b" ] ;; esac
}
FOLLOWS=""
if [ "$stage" = dev ] && [ -z "$INTO" ] && [ -s "$W/follows.json" ]; then
  f_err=$(jq -r '.error // ""' "$W/follows.json"); f_repo=$(jq -r '.repository // ""' "$W/follows.json"); f_branch=$(jq -r '.branch // ""' "$W/follows.json")
  if [ -n "$f_err" ]; then echo "note: which branch $cell follows could not be read ($f_err): into $DEFAULT" >&2
  elif [ -z "$f_branch" ]; then echo "note: $cell follows no branch yet: into $DEFAULT" >&2
  elif ! same_repo "$f_repo" "$URL"; then
    echo "note: $cell follows $f_repo / $f_branch, not this repository: into $DEFAULT (name a branch with --into)" >&2
  elif ! git fetch -q origin "refs/heads/$f_branch:refs/remotes/origin/$f_branch" 2>/dev/null; then
    echo "note: $cell follows $f_branch, which origin no longer has: into $DEFAULT (name a branch with --into)" >&2
  elif ! git merge-base --is-ancestor "$REV" "refs/remotes/origin/$f_branch"; then
    echo "note: $cell follows $f_branch, which does not hold the commit it runs: into $DEFAULT (name a branch with --into)" >&2
  else
    FOLLOWS=$f_branch; echo "into $FOLLOWS, the branch $cell follows"
  fi
fi
if [ "$stage" = dev ]; then BASE=${INTO:-${FOLLOWS:-$DEFAULT}}
else
  [ -z "$INTO" ] || [ "$INTO" = "$DEFAULT" ] || refuse "a capture from a $stage cell goes into $DEFAULT, by a pull request; not into $INTO"
  BASE=$DEFAULT
fi
# The pull request holds only the live changes when the commit the cell runs is on its base (#1354 review): a dev cell
# that delivers from another branch names it with --into.
git fetch -q origin "refs/heads/$BASE:refs/remotes/origin/$BASE" 2>/dev/null || refuse "origin has no branch $BASE"
git merge-base --is-ancestor "$REV" "refs/remotes/origin/$BASE" \
  || refuse "the commit $cell runs, $REV, is not on $BASE: a pull request into $BASE would carry other commits too. Name the branch the cell delivers from with --into"
# One capture, one package: a capture already pulled back, into any package, is not taken again.
BR="pullback/$cell/$PKG/$when"
done_as=$( { git for-each-ref --format='%(refname:short)' "refs/heads/pullback/$cell/"
             [ "$PUSH" = 0 ] || git ls-remote --heads origin "refs/heads/pullback/$cell/*" 2>/dev/null | sed 's#.*refs/heads/##'
           } | grep -E "^pullback/$cell/.+/$when\$" | head -1)
if [ -n "$done_as" ]; then
  [ "$done_as" = "$BR" ] && refuse "the branch $BR already exists: this capture was pulled back"
  p=${done_as#pullback/$cell/}; refuse "this capture was already pulled back into ${p%/$when} ($done_as): a capture's changes go into one package"
fi
ORIG=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)
git checkout -q -b "$BR" "$REV" || fail "could not create $BR from $REV"
UNDO=1

# 4. The files, owns and the hotfolder rules into the package.
python3 -I - "$W" "$DIR" "$PKG" <<'PY' || exit $?
import json, os, shutil, sys
w, d, pkg = sys.argv[1:4]
cap = json.load(open(os.path.join(w, 'capture.json')))
spec_path = os.path.join(d, 'customization.json')
spec = json.load(open(spec_path, encoding='utf-8'))
source = os.path.join(d, spec['source'])
for f in cap.get('files') or []:
    dest = os.path.join(source, f['path'])
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.copyfile(os.path.join(w, 'files', f['path']), dest)
    print(f'{f["change"]:8} {f["path"]}')
owns = spec.get('owns') if isinstance(spec.get('owns'), list) else []
added = []
for o in open(os.path.join(w, 'owners')).read().splitlines():
    if not any(o == x or o.startswith(x + '/') for x in owns if isinstance(x, str)):
        owns.append(o); added.append(o); print(f'owns     {o}')
spec['owns'] = owns
# The boot installs an owned folder by mirroring it (customizations.sh, _cz_mirror): every cell the package reaches gets
# exactly the package's files there, and loses its own (#1354 review). Said here and in the pull request.
if added:
    print('note: delivery replaces each of these folders on every cell the package reaches: a file there that the package '
          'does not hold is removed, live edits made on a test or prod cell included', file=sys.stderr)
open(os.path.join(w, 'new-owns'), 'w').write(''.join(o + '\n' for o in added))
ing = (cap.get('settings') or {}).get('ingest')
ingest = False
if ing:
    if ing.get('unreadable') or ing.get('rules') is None:
        print(f'warning: the cell could not read its hotfolder rules; they are not pulled back', file=sys.stderr)
    elif ing.get('package') not in (None, pkg):
        print(f'warning: the hotfolder rules replace those of {ing["package"]}, not {pkg}; pull them back into that package', file=sys.stderr)
    else:
        if not isinstance(spec.get('settings'), dict):   # absent, or "settings": null
            spec['settings'] = {}
        spec['settings']['ingest'] = ing['rules']; ingest = True; print('settings settings.ingest (the hotfolder rules)')
open(os.path.join(w, 'ingest'), 'w').write('yes' if ingest else '')
# Only when it changed: json.dump reformats a hand-written file, which alone would make a commit (#1354 review).
if added or ingest:
    with open(spec_path, 'w', encoding='utf-8') as fh:
        json.dump(spec, fh, indent=2, ensure_ascii=False); fh.write('\n')
PY
if ! PACKAGE_TYPE=censhare-custom bash "$HERE/validate.sh" "$DIR" > "$W/check" 2>&1; then
  cat "$W/check" >&2
  UNDO=0   # the files stay for the developer to fix
  refuse "the package does not pass its check with these changes (above). They are on $BR, not committed: fix and commit there"
fi
git add -A -- "$DIR" || fail "could not stage the changes"
if git diff --cached --quiet; then
  UNDO=0; git checkout -q "$ORIG" && git branch -q -D "$BR"
  echo "nothing differs from $REV: the package already holds these changes (pulled back before, the cell not yet on that release)"; exit 0
fi
TITLE="Live changes from $cell ($stage), captured $at"
BODY=$(jq -r --arg rev "$REV" --arg pkg "$PKG" --rawfile owns "$W/new-owns" --rawfile ingest "$W/ingest" '
  "Pulled back from a capture of \(.cell) (\(.stage)), taken \(.capturedAt), on top of \($rev), the commit of \($pkg) the cell ran.\n\n"
  + ([.files[]? | "- \(.change) `\(.path)`"] + (if $ingest == "yes" then ["- the hotfolder rules (settings.ingest)"] else [] end) | join("\n"))
  + (if ($owns | length) > 0 then
      "\n\nAdded to `owns`: " + ([$owns | split("\n")[] | select(length > 0) | "`\(.)`"] | join(", "))
      + ". Delivery replaces each of these folders on every cell the package reaches: a file there that the package does not hold is removed, live edits made on a test or prod cell included."
    else "" end)
  + "\n\nAfter the merge and the next delivery, the cell owns these paths through the package and reads in sync again."' "$C")
git commit -q -m "$TITLE" -m "$BODY" || fail "could not commit"
UNDO=0
echo "committed on $BR (from $REV)"
if [ "$PUSH" = 0 ]; then
  echo "not pushed (--no-push): git push -u origin $BR, then open a pull request into $BASE"; exit 0
fi
git push -q -u origin "$BR" || refuse "could not push $BR; it is committed in this clone"
# The pull request: pull-back opens it itself only on CodeCommit in the customer's account. GitHub and GitLab, hosted or
# self-hosted, are the customer's own (#1467): pull-back pushes the branch and says how to open the pull request there,
# with the web page and the CLI command, and runs neither.
HOST=${URL#*://}; HOST=${HOST#*@}; HOST=${HOST%%/*}; HOST=${HOST%%:*}
case $URL in
  codecommit::*|codecommit://*|*git-codecommit.*.amazonaws.com/v1/repos/*|*git-codecommit-fips.*.amazonaws.com/v1/repos/*) TOOL=codecommit ;;
  *git-codecommit.*.amazonaws.com.cn/v1/repos/*) TOOL=codecommit ;;
  *) TOOL="" ;;
esac
if [ "$TOOL" = codecommit ] && command -v aws >/dev/null; then
  # The repository in the customer's own account, with the developer's AWS credentials (decision 0028: never censhare's).
  # https://git-codecommit.<region>.amazonaws.com/v1/repos/<name>, ssh://…, or git-remote-codecommit's
  # codecommit::<region>://[<profile>@]<name> and codecommit://[<profile>@]<name>.
  CC_REGION="" CC_PROFILE="" CC_NAME=""
  case $URL in
    codecommit:*)
      rest=${URL#codecommit:}; rest=${rest#:}
      case $rest in *://*) CC_REGION=${rest%%://*}; rest=${rest#*://} ;; *) rest=${rest#//} ;; esac
      case $rest in *@*) CC_PROFILE=${rest%%@*}; CC_NAME=${rest#*@} ;; *) CC_NAME=$rest ;; esac ;;
    *) CC_REGION=${HOST#git-codecommit.}; CC_REGION=${CC_REGION#git-codecommit-fips.}; CC_REGION=${CC_REGION%.cn}; CC_REGION=${CC_REGION%.amazonaws.com}
       CC_NAME=${URL##*/v1/repos/}; CC_NAME=${CC_NAME%/} ;;
  esac
  # No region in the address: where git-remote-codecommit pushed (botocore: AWS_DEFAULT_REGION, then the profile's),
  # AWS_REGION only last (#1467 review).
  if [ -z "$CC_REGION" ]; then
    CC_REGION=${AWS_DEFAULT_REGION:-}
    [ -n "$CC_REGION" ] || CC_REGION=$(aws configure get region ${CC_PROFILE:+--profile "$CC_PROFILE"} 2>/dev/null)
    [ -n "$CC_REGION" ] || CC_REGION=${AWS_REGION:-}
  fi
  if [[ "$CC_REGION" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] && [[ "$CC_NAME" =~ ^[A-Za-z0-9._-]{1,100}$ ]]; then
    TARGETS=$(jq -cn --arg r "$CC_NAME" --arg s "$BR" --arg d "$BASE" '[{repositoryName: $r, sourceReference: $s, destinationReference: $d}]')
    # CodeCommit takes a description of at most 10,240 characters.
    ID=$(aws codecommit create-pull-request --region "$CC_REGION" ${CC_PROFILE:+--profile "$CC_PROFILE"} --title "$TITLE" \
      --description "${BODY:0:10000}" --targets "$TARGETS" --query pullRequest.pullRequestId --output text) && [[ "$ID" =~ ^[0-9]+$ ]] && {
      case $CC_REGION in   # the console of the region's partition
        cn-*) CONSOLE=https://console.amazonaws.cn ;;
        us-gov-*) CONSOLE=https://console.amazonaws-us-gov.com ;;
        *) CONSOLE=https://$CC_REGION.console.aws.amazon.com ;;
      esac
      echo "$CONSOLE/codesuite/codecommit/repositories/$CC_NAME/pull-requests/$ID/details?region=$CC_REGION"
      exit 0; }
  else
    echo "note: origin is CodeCommit, but its region or repository could not be told from $URL (set AWS_REGION)" >&2
  fi
fi
echo "pushed $BR: open a pull request from $BR into $BASE in your repository, then review and merge it there"
# How, for the host origin names: its page when it is a GitHub or a GitLab by name, and both CLIs' commands, which take
# the title and the description from the commit (--fill). Suggestions only: nothing here is run.
WEB=${URL%/}; WEB=${WEB%.git}
case $WEB in *://*) WEB=${WEB#*://}; WEB=${WEB#*@}; WEB=${WEB#*/} ;; *@*:*) WEB=${WEB#*:} ;; *) WEB="" ;; esac
if [ "$TOOL" != codecommit ] && [ -n "$HOST" ] && [ -n "$WEB" ]; then
  case $HOST in
    *github*) echo "  in the browser: https://$HOST/$WEB/compare/$BASE...$BR?expand=1" ;;
    *gitlab*) echo "  in the browser: https://$HOST/$WEB/-/merge_requests/new?merge_request%5Bsource_branch%5D=$BR&merge_request%5Btarget_branch%5D=$BASE" ;;
  esac
fi
if [ "$TOOL" != codecommit ]; then
  echo "  with GitHub's CLI: gh pr create --base $BASE --head $BR --fill"
  echo "  with GitLab's CLI: glab mr create --source-branch $BR --target-branch $BASE --fill"
fi
