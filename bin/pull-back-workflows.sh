#!/usr/bin/env bash
# Take a cell's live changes of its workflows and functions back to git (#1597), as pull-back.sh does for the
# customization: a state machine edited (or published by hand) in the AWS console, and a function's memory or timeout
# changed there, become a branch from the commit the cell was delivered from and a pull request. Run in your clone of the
# workflows repository (workflows/workflows.json). It pushes with your own git credentials; censhare holds none.
# In the partner kit it is bin/pull-back-workflows.sh, next to bin/cell-capture.py and bin/validate.sh.
#
#   pull-back-workflows.sh --cell <console address> [--into <branch>] [--no-push]
#   pull-back-workflows.sh --from <export json> [--into <branch>] [--no-push]
#
#   --cell      the cell's Solution Console, as the Local changes tab shows it (https://<cell>/solution-console/): signs
#               you in in the browser and takes the cell's live changes (cell-capture.py --workflows)
#   --from      the same, from a file (GET /portal/workflow-changes/export), for a test or a second try
#   --into      the branch the pull request goes into (default: origin's default branch)
#   --no-push   commit on the branch in this clone, push nothing
#
# What it takes back: each changed state machine's definition, with the cell's values already turned back into the
# package's placeholders by the cell (${function:<name>}, ${bus}, ${censhare}, ${censhare-login}; the deploy's dedupe
# step taken out), into the file workflows/workflows.json names for that flow, as formatted JSON; and each changed
# function's memoryMb and timeoutSeconds into functions/functions.json. An image changed live, or an environment
# variable, is named and not taken back: the image is built from this repository, and the environment is not in it.
# Then it checks the workflows (validate.sh, PACKAGE_TYPE=workflows), commits, and pushes.
#
# Exit: 0 done (or nothing to take back), 1 refused (the reason is printed), 2 could not run. Whatever stops it after the
# branch was made puts the clone back as it was, except a failed check, stage or commit: then the branch stays checked
# out with the files, uncommitted, for you to fix and commit.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
fail()   { echo "error: $*" >&2; exit 2; }
refuse() { echo "refused: $*" >&2; exit 1; }
# keep_layout <file> <new json>: writes the new content into <file> in the file's own layout. Where a value is the same,
# its text stays as the repository has it (one-line lists, spacing), so a pull request shows only the lines that
# changed; a changed value is written in two-space JSON at its place. Seen on mba-custom: picture-metadata's short
# lists on one line came back spread over 17 lines for a one-line Comment edit. The result is checked to be the new
# content; if it is not, the whole file is written as jq would.
keep_layout() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, new_path = sys.argv[1], sys.argv[2]
new = json.load(open(new_path, encoding='utf-8'))
try:
    text = open(path, encoding='utf-8').read()
except FileNotFoundError:
    text = None
dec = json.JSONDecoder()
def ws(i):
    while i < len(text) and text[i] in ' \t\r\n': i += 1
    return i
def node(i):
    i = ws(i); c = text[i]
    if c in '{[':
        kids, j = [], ws(i + 1)
        if text[j] != ('}' if c == '{' else ']'):
            while True:
                key, at = None, ws(j)
                if c == '{':
                    key, j = dec.raw_decode(text, at); j = ws(j) + 1
                k = node(j); kids.append((key, k, at)); j = ws(k[2])
                if text[j] == ',': j += 1; continue
                break
        return (c, i, j + 1, kids)
    return ('v', i, dec.raw_decode(text, i)[1], None)
def same(a, b): return json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)
def fresh(v, at):
    line = text[text.rfind('\n', 0, at) + 1:at]
    pad = line[:len(line) - len(line.lstrip())]
    return json.dumps(v, indent=2, ensure_ascii=False).replace('\n', '\n' + pad)
def render(n, v):
    t, s, e, kids = n
    if same(json.loads(text[s:e]), v): return text[s:e]
    if t == '{' and isinstance(v, dict) and {k for k, _, _ in kids} == set(v) and len(kids) == len(v):
        parts = [(c[1], c[2], render(c, v[k])) for k, c, _ in kids]
    elif t == '{' and isinstance(v, dict) and kids:
        # Members added or taken away: the members kept keep their text, a new one is written at their indent.
        had = {k: (c, at) for k, c, at in kids}
        sep = text[kids[0][1][2]:kids[1][2]] if len(kids) > 1 else ',\n' + text[text.rfind('\n', 0, kids[0][2]) + 1:kids[0][2]]
        items = [text[had[k][1]:had[k][0][1]] + render(had[k][0], x) if k in had
                 else json.dumps(k, ensure_ascii=False) + ': ' + fresh(x, kids[0][2]) for k, x in v.items()]
        return '{' + text[s + 1:kids[0][2]] + sep.join(items) + text[kids[-1][1][2]:e - 1] + '}'
    elif t == '[' and isinstance(v, list) and len(kids) == len(v):
        parts = [(c[1], c[2], render(c, x)) for (_, c, _), x in zip(kids, v)]
    else:
        return fresh(v, s)
    out, at = [], s
    for a, b, r in parts: out += [text[at:a], r]; at = b
    return ''.join(out) + text[at:e]
out = None
if text is not None:
    try:
        root = node(0)
        out = text[:root[1]] + render(root, new) + text[root[2]:]
        if not same(json.loads(out), new): out = None
    except (ValueError, IndexError):
        out = None
if out is None:
    out = json.dumps(new, indent=2, ensure_ascii=False) + '\n'
open(path + '.new', 'w', encoding='utf-8').write(out)
PY
  [ -f "$1.new" ] && mv "$1.new" "$1"
}
usage()  { sed -n '8,15p' "$0" | sed 's/^# \{0,1\}//'; }
FROM="" CELL="" INTO="" PUSH=1
while [ $# -gt 0 ]; do
  case $1 in
    --from) FROM=${2:-}; shift 2 || fail "--from needs a file" ;;
    --cell) CELL=${2:-}; shift 2 || fail "--cell needs the cell's Solution Console address" ;;
    --into) INTO=${2:-}; shift 2 || fail "--into needs a branch" ;;
    --no-push) PUSH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown option $1" ;;
  esac
done
[ -n "$FROM" ] || [ -n "$CELL" ] || { usage >&2; fail "usage: --cell <console address> or --from <export json> is needed"; }
[ -z "$FROM" ] || [ -z "$CELL" ] || { usage >&2; fail "usage: --cell or --from, not both"; }
[ -n "$CELL" ] || [ -f "$FROM" ] || fail "no such file: $FROM"
for t in git jq python3; do command -v "$t" >/dev/null || fail "$t is needed"; done
[ -z "$CELL" ] || [ -f "$HERE/cell-capture.py" ] || fail "cell-capture.py is not next to $0"
[ -f "$HERE/validate.sh" ] || fail "validate.sh is not next to $0"
[ -z "$FROM" ] || FROM=$(cd "$(dirname "$FROM")" && pwd)/$(basename "$FROM")
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || fail "run it in your clone of the workflows repository"
cd "$TOP" || exit 2
[ -f workflows/workflows.json ] || fail "no workflows/workflows.json here: run it in your clone of the workflows repository"
[ -z "$(git status --porcelain)" ] || fail "this clone has uncommitted changes: commit or stash them first"

W=$(mktemp -d) || exit 2
BR="" ORIG="" UNDO=0
cleanup() {
  if [ "$UNDO" = 1 ] && [ -n "$BR" ]; then
    if git checkout -q -f "$ORIG" 2>/dev/null && git branch -q -D "$BR" 2>/dev/null; then
      echo "the clone is back on $ORIG; $BR was removed" >&2
    else
      echo "could not put the clone back on $ORIG: it is on $(git symbolic-ref -q --short HEAD || git rev-parse --short HEAD)" >&2
    fi
  fi
  rm -rf "$W"
}
trap cleanup EXIT

# 1. The cell's live changes.
X="$W/export.json"
if [ -n "$CELL" ]; then
  python3 "$HERE/cell-capture.py" --cell "$CELL" --out "$X" --workflows; rc=$?
  [ "$rc" = 3 ] && { echo "nothing to take back: the cell's workflows and functions run as they were delivered (or only an image or an alias differs)"; exit 0; }
  [ "$rc" = 0 ] || exit "$rc"
else
  cp "$FROM" "$X" || exit 2
fi
jq -e 'type == "object" and (.flows | type == "array") and (.functions | type == "array")' "$X" >/dev/null 2>&1 \
  || fail "the live changes are not in the form this kit reads (flows and functions)"

# 2. Where the branch starts: the commit the cell was delivered from, so the pull request holds the live changes alone.
COMMIT=$(jq -r '.commit // ""' "$X")
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || refuse "the cell does not say which commit it was delivered from: deliver from this repository once, then try again"
git cat-file -e "$COMMIT^{commit}" 2>/dev/null || git fetch -q origin 2>/dev/null
git cat-file -e "$COMMIT^{commit}" 2>/dev/null || refuse "this clone does not have $COMMIT, the commit the cell was delivered from: is it a clone of the repository the cell follows?"
CELLNAME=$(jq -r '.cell // "cell"' "$X" | tr -c 'a-z0-9-\n' '-')
STAMP=$(date -u +%Y%m%d-%H%M%S)
ORIG=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)
BR="pullback/$CELLNAME/workflows/$STAMP"
# A second run in the same second (or a branch left from a failed check) gets its own name.
n=2; while git rev-parse -q --verify "refs/heads/$BR" >/dev/null; do BR="pullback/$CELLNAME/workflows/$STAMP-$n"; n=$((n + 1)); done
git checkout -q -b "$BR" "$COMMIT" || { BR=""; fail "could not make a branch from $COMMIT"; }
UNDO=1

# 3. The definitions, into the files workflows.json names; the functions' memory and timeout into functions.json.
taken=0
while IFS= read -r f; do
  sm=$(jq -r '.name' <<<"$f")
  flow=$(sed -E 's/^cs_[a-z0-9-]+_[0-9a-f]{6}_//' <<<"$sm")
  why=$(jq -r '.refused // ""' <<<"$f")
  if [ -n "$why" ]; then echo "not taken: $flow: $why" >&2; continue; fi
  file=$(jq -r --arg n "$flow" '.flows[]? | select(.name == $n) | .definition // empty' workflows/workflows.json)
  [ -n "$file" ] || refuse "the cell runs a workflow $flow that workflows/workflows.json at $COMMIT does not have"
  case "$file" in /*|*..*) refuse "workflows.json names $file for $flow, outside workflows/" ;; esac
  # The same content in another layout is no change: the file is left as the repository has it.
  if [ -f "workflows/$file" ] && [ "$(jq -cS . "workflows/$file" 2>/dev/null)" = "$(jq -cS '.definition' <<<"$f")" ]; then
    echo "$flow: what the cell runs is what workflows/$file has"
    continue
  fi
  jq '.definition' <<<"$f" > "$W/definition.json" && keep_layout "workflows/$file" "$W/definition.json" || fail "could not write workflows/$file"
  echo "taken: $flow -> workflows/$file$(jq -r 'if .dedupe then " (its dedupe step left out: the deploy adds it)" else "" end' <<<"$f")"
  taken=$((taken + 1))
done < <(jq -c '.flows[]' "$X")
while IFS= read -r f; do
  name=$(jq -r '.name' <<<"$f")
  for n in $(jq -r '.notTaken[]? // empty' <<<"$f"); do echo "not taken: $name's $n differs on the cell (the $( [ "$n" = image ] && echo "image is built from this repository" || echo "environment is not in it"))" >&2; done
  jq -e 'has("memoryMb") or has("timeoutSeconds")' <<<"$f" >/dev/null || continue
  [ -f functions/functions.json ] || refuse "the cell has function $name changed, and this clone has no functions/functions.json"
  jq -e --arg n "$name" 'any(.functions[]?; .name == $n)' functions/functions.json >/dev/null \
    || refuse "the cell runs a function $name that functions/functions.json at $COMMIT does not have"
  jq --arg n "$name" --argjson c "$f" '.functions |= map(if .name == $n then . + ($c | {memoryMb, timeoutSeconds} | with_entries(select(.value != null))) else . end)' \
    functions/functions.json > "$W/functions.json" && keep_layout functions/functions.json "$W/functions.json" || fail "could not write functions/functions.json"
  echo "taken: $name's $(jq -r '[if has("memoryMb") then "memory" else empty end, if has("timeoutSeconds") then "timeout" else empty end] | join(" and ")' <<<"$f") -> functions/functions.json"
  taken=$((taken + 1))
done < <(jq -c '.functions[]' "$X")

if [ -z "$(git status --porcelain)" ]; then
  echo "nothing to take back: the cell's changes are what $COMMIT already has"
  exit 0
fi

# 4. The check the delivery runs, then the commit.
if ! PACKAGE_TYPE=workflows bash "$HERE/validate.sh" . >"$W/validate.log" 2>&1; then
  cat "$W/validate.log" >&2
  UNDO=0
  refuse "the workflows taken from the cell do not pass the check: they are on $BR, uncommitted, to fix"
fi
STAGE=$(jq -r '.stage // ""' "$X")
# functions/ only where the repository has one: a seeded CodeCommit workflows repository has workflows/ alone, and git
# refuses a pathspec that matches nothing (#1598 review).
paths=(workflows); [ -d functions ] && paths+=(functions)
git add -A "${paths[@]}" || { UNDO=0; fail "could not stage the changes taken from the cell: they are on $BR, uncommitted"; }
# A commit git refuses (no user.name, a hook, signing) keeps the work, as a failed stage does (#1598 review).
git commit -q -F - <<EOF || { UNDO=0; fail "could not commit: the changes taken from the cell are on $BR, uncommitted"; }
pull back the live changes of $CELLNAME's workflows${STAGE:+ ($STAGE)}

Taken from the cell's Solution Console, Local changes, Workflows, on $STAMP UTC: what was changed there in the AWS
console after the delivery of $COMMIT.
EOF
UNDO=0

# 5. Push, and the pull request to open.
BASE=$INTO
[ -n "$BASE" ] || BASE=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
[ -n "$BASE" ] || BASE=main
if [ "$PUSH" = 0 ]; then
  echo "committed on $BR; nothing pushed (--no-push). Push it and open a pull request into $BASE."
  exit 0
fi
git push -q -u origin "$BR" || fail "could not push $BR: the commit is on $BR in this clone"
URL=$(git remote get-url origin)
echo "pushed $BR. Open the pull request into $BASE:"
case "$URL" in
  *git-codecommit.*|codecommit:*)
    REPO=$(sed -E 's#.*/v1/repos/##; s#^codecommit:(//)?([^@]+@)?##' <<<"$URL")
    echo "  aws codecommit create-pull-request --title \"pull back $CELLNAME's workflows\" --targets repositoryName=$REPO,sourceReference=$BR,destinationReference=$BASE" ;;
  *) echo "  with GitHub's CLI: gh pr create --base $BASE --head $BR --fill"
     echo "  with GitLab's CLI: glab mr create --source-branch $BR --target-branch $BASE --fill" ;;
esac
