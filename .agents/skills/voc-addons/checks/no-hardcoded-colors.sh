#!/usr/bin/env bash
# voc-addons check: no hardcoded colors (principle 2).
# Fails if Lua sources contain |cff hex literals or numeric CreateColor()
# calls outside the addon's palette definition file.
#
# Usage: bash no-hardcoded-colors.sh <repo-dir>
# The palette lives in exactly one file per addon: palette.lua (preferred)
# or a COLORS table defined once in main.lua. Everything else references it.

set -u
dir="${1:?usage: no-hardcoded-colors.sh <repo-dir>}"
fail=0

while IFS= read -r f; do
  base="$(basename "$f")"
  # The palette file itself may define colors.
  case "$base" in
    palette.lua|Palette.lua) continue ;;
  esac
  # |cffRRGGBB literals in strings.
  if grep -nE '\|cff[0-9a-fA-F]{6}' "$f" >/dev/null; then
    echo "hardcoded |cff color in $f:"
    grep -nE '\|cff[0-9a-fA-F]{6}' "$f" | head -5
    fail=1
  fi
  # CreateColor(r, g, b) with numeric literals.
  if grep -nE 'CreateColor\([0-9]' "$f" >/dev/null; then
    echo "numeric CreateColor in $f:"
    grep -nE 'CreateColor\([0-9]' "$f" | head -5
    fail=1
  fi
done < <(find "$dir" -name '*.lua' -not -path '*/.git/*' -not -path '*/tests/*' -not -path '*/.reference/*')

if [ "$fail" -eq 1 ]; then
  echo "FAIL: move colors into the palette file and reference them by name."
  exit 1
fi
echo "OK: no hardcoded colors."
