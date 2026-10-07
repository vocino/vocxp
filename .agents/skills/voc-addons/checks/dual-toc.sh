#!/usr/bin/env bash
# Principle 11: every addon ships a Retail toc and a Forever toc.
# For each <Name>.toc that is not itself a Forever toc,
# <Name>_Forever.toc must exist beside it.
#
# Run: bash checks/dual-toc.sh <repo-dir>
# Exit nonzero on violation. Fast, dependency-free.
set -u

dir="${1:-.}"
fail=0
found=0
for toc in "$dir"/*.toc; do
  [ -e "$toc" ] || continue
  base="$(basename "$toc" .toc)"
  case "$base" in
    *_Forever) continue ;;
  esac
  found=1
  if [ ! -f "$dir/${base}_Forever.toc" ]; then
    echo "missing Forever toc: $dir/${base}_Forever.toc"
    fail=1
  fi
done
if [ "$found" -eq 0 ]; then
  echo "no retail tocs found in $dir"
  fail=1
fi
if [ "$fail" -eq 0 ]; then
  echo "OK: dual tocs present."
fi
exit "$fail"
