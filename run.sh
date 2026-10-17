#!/bin/sh

# Run requests under ./collections.
#
# Usage:
#   ./run.sh [-n] <collection | collection/folder | collection/folder/request>
#   ./run.sh -l [target]
#
#   -l  list requests instead of running them
#   -n  dry run, print curl commands instead of sending them
#
# Requests run in sorted order; prefix names (01-login.sh) to control it.
# ONLY=1 works as usual: ONLY=1 ./run.sh my-collection

set -eu

root=$(cd "$(dirname "$0")" && pwd)
collections=$root/collections

usage() {
  sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
}

list=
while getopts ln opt; do
  case $opt in
  l) list=1 ;;
  n) DRY_RUN=1 && export DRY_RUN ;;
  *) usage ;;
  esac
done
shift $((OPTIND - 1))

if [ $# -gt 1 ]; then
  echo "Unexpected arguments: $*" >&2
  echo "run.sh takes one target. Put curl options such as CurlOptionGlobal in the collection's _env.sh." >&2
  exit 1
fi

target=${1:-}
if [ -z "$target" ] && [ -z "$list" ]; then
  usage
fi
target=${target%/}

# Print request files for $1 (relative to collections/), one per line.
find_requests() {
  p=$collections/$1
  if [ -d "$p" ]; then
    find "$p" -type f -name '*.sh' ! -name '_*' | sort
  elif [ -f "$p.sh" ]; then
    printf '%s\n' "$p.sh"
  elif [ -f "$p" ]; then
    printf '%s\n' "$p"
  else
    echo "Not found: $1" >&2
    return 1
  fi
}

files=$(find_requests "$target") || exit 1
[ -n "$files" ] || {
  echo "No requests found in: ${target:-collections}" >&2
  exit 1
}

if [ -n "$list" ]; then
  printf '%s\n' "$files" | sed "s|^$collections/||; s|\.sh\$||"
  exit 0
fi

failed=0
for f in $files; do
  rel=${f#"$collections"/}
  printf '==> %s\n' "${rel%.sh}" >&2
  sh "$f" || failed=1
  printf '\n'
done
exit "$failed"
