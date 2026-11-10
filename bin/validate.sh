#!/usr/bin/env bash
# Check a customization package before it is delivered (#936): the same checks the cell's intake runs on it
# (scripts/validate-customization.py, lambda/customization-intake), on the partner's own checkout. No AWS, no network.
# In the partner kit it is bin/validate.sh, next to bin/validate-customization.py; deliver.sh runs it before it stores
# anything, so a package the cell would refuse fails in the partner's CI and never reaches the store.
#
#   validate.sh [<folder with customization.json>, default .] [validator options, e.g. --strict-fields]
#
# What it can't check here, the cell still does: the edition's censhare assets a variant replaces (the intake has the
# edition's index; here a missing checksum is only a warning), the customer's settings and secrets, and collisions with
# the cell's other packages.
#
# Exit: 0 passes (warnings are printed), 1 refused (the reasons are printed), 2 could not check.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=.
[ $# -gt 0 ] && [ "${1#-}" = "$1" ] && { DIR=$1; shift; }
case "${1:-}" in -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
fail() { echo "error: $*" >&2; exit 2; }
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
