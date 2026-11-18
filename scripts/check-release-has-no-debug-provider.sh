#!/usr/bin/env bash
# Builds the package in Debug and in Release and checks the linked library object: DebugAttestationProvider must be in the Debug build (the control, so
# the search cannot pass by looking in the wrong place) and must NOT be in the Release build.
#   scripts/check-release-has-no-debug-provider.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
has() { # <configuration> -> exit 0 when the built LensJourney object contains the symbol
  local object n
  swift build -c "$1" >/dev/null 2>&1
  object="$(swift build -c "$1" --show-bin-path)/LensJourney.o"
  [ -f "$object" ] || { echo "no build output at $object"; exit 2; }
  n="$(strings -a "$object" | grep -c 'DebugAttestationProvider' || true)"
  [ "${n:-0}" -gt 0 ]
}
fail=0
if has debug; then echo "  PASS Debug build contains DebugAttestationProvider (control)"; else echo "  FAIL control: the Debug build does not contain it, so this check proves nothing"; fail=1; fi
if has release; then echo "  FAIL Release build contains DebugAttestationProvider"; fail=1; else echo "  PASS Release build does not contain DebugAttestationProvider"; fi
[ $fail = 0 ] && echo "ok" || { echo "FAILED"; exit 1; }
