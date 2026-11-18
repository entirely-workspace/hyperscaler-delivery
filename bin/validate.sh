#!/usr/bin/env bash
# Check a customization package before it is delivered (#936): the same checks the cell's intake runs on it
# (scripts/validate-customization.py, lambda/customization-intake), on the partner's own checkout. No AWS, no network.
# In the partner kit it is bin/validate.sh, next to bin/validate-customization.py; deliver.sh runs it before it stores
# anything, so a package the cell would refuse fails in the partner's CI and never reaches the store.
#
#   validate.sh [<folder with customization.json or workflows/>, default .] [validator options, e.g. --strict-fields]
#
# What it can't check here, the cell still does: the edition's censhare assets a variant replaces (the intake has the
# edition's index; here a missing checksum is only a warning), the customer's settings and secrets, and collisions with
# the cell's other packages.
#
# A workflows package (#762), a folder with workflows/workflows.json, is checked by the workflow validator instead: the
# deploy's own checks (lib/workflow-validate-cli.ts; in the kit compiled into lib/, with the event schemas in
# docs/events/), which needs Node. PACKAGE_TYPE (censhare-custom or workflows) says which when the folder has both.
#
# Exit: 0 passes (warnings are printed), 1 refused (the reasons are printed), 2 could not check.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=.
[ $# -gt 0 ] && [ "${1#-}" = "$1" ] && { DIR=$1; shift; }
case "${1:-}" in -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
fail() { echo "error: $*" >&2; exit 2; }
case "${PACKAGE_TYPE:-}" in
  "") if [ -f "$DIR/customization.json" ] && [ -f "$DIR/workflows/workflows.json" ]; then
        fail "$DIR has both customization.json and workflows/workflows.json: set PACKAGE_TYPE to censhare-custom or workflows"
      elif [ -f "$DIR/workflows/workflows.json" ]; then TYPE=workflows; else TYPE=censhare-custom; fi ;;
  censhare-custom|workflows) TYPE=$PACKAGE_TYPE ;;
  *) fail "PACKAGE_TYPE must be censhare-custom or workflows, not '$PACKAGE_TYPE'" ;;
esac
if [ "$TYPE" = workflows ]; then
  [ $# = 0 ] || fail "the workflow validator takes no options ($*)"
  [ -f "$DIR/workflows/workflows.json" ] || fail "no workflows/workflows.json in $DIR"
  command -v node >/dev/null || fail "node is needed to check workflows"
  # The kit ships it compiled next to bin/; this repository runs the TypeScript.
  if [ -f "$HERE/../lib/workflow-validate-cli.js" ]; then
    node "$HERE/../lib/workflow-validate-cli.js" "$DIR"
  elif [ -f "$HERE/../../lib/workflow-validate-cli.ts" ]; then
    abs=$(cd "$DIR" && pwd) && (cd "$HERE/../.." && node --require ts-node/register lib/workflow-validate-cli.ts "$abs")
  else
    fail "the workflow validator is not next to $0"
  fi
  rc=$?
  [ "$rc" -le 1 ] && exit "$rc"
  exit 2
fi
# The kit ships the validator next to this script; this repository keeps it in scripts/.
for V in "$HERE/validate-customization.py" "$HERE/../validate-customization.py"; do [ -f "$V" ] && break; done
[ -f "$V" ] || fail "validate-customization.py is not next to $0"
command -v python3 >/dev/null || fail "python3 is needed to check the package"
[ -f "$DIR/customization.json" ] || fail "no customization.json in $DIR"
# -I: the validator reads the partner's files, and nothing in the checkout may change what Python imports.
python3 -I "$V" "$DIR" "$@"
rc=$?
[ "$rc" -le 1 ] && exit "$rc"
exit 2
