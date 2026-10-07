#!/usr/bin/env bash
# voc-addons check: settings apply live (principle 4).
# Fails if Lua sources call ReloadUI: changing a setting must never
# require a reload. (Slash-command convenience reloads during development
# do not belong in shipped code either.)

set -u
dir="${1:?usage: no-reloadui.sh <repo-dir>}"
fail=0

while IFS= read -r f; do
  if grep -nE '(^|[^_a-zA-Z])ReloadUI\s*\(' "$f" >/dev/null; then
    echo "ReloadUI call in $f:"
    grep -nE '(^|[^_a-zA-Z])ReloadUI\s*\(' "$f" | head -5
    fail=1
  fi
done < <(find "$dir" -name '*.lua' -not -path '*/.git/*' -not -path '*/tests/*' -not -path '*/.reference/*')

if [ "$fail" -eq 1 ]; then
  echo "FAIL: settings must apply live; remove ReloadUI."
  exit 1
fi
echo "OK: no ReloadUI."
