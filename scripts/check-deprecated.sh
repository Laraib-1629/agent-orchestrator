#!/usr/bin/env bash
# Fails if any @deprecated JSDoc tag is missing a cutoff marker (v<ver> or removeBy=<date>).
# Policy: without a cutoff, deprecation becomes permanent. See issue #1430.
set -euo pipefail
bad=$(grep -rn --include='*.ts' --include='*.tsx' '@deprecated' packages | grep -Ev '@deprecated[[:space:]]+(v[0-9]|removeBy=)' || true)
if [ -n "$bad" ]; then
  echo "Found @deprecated without cutoff marker (v<ver> or removeBy=<date>):"
  echo "$bad"
  exit 1
fi
