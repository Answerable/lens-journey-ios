#!/usr/bin/env bash
# Proves the debug-attestation boundary of the LensJourney package (0.4.0):
#   1. The core product, built alone in Release, contains no DebugAttestationProvider symbol (binary check, with a control
#      that the opt-in product's object DOES contain the provider, so the search cannot pass by looking in the wrong place).
#   2. An app OUTSIDE the package, linking only the core product, cannot make a debug attestation: `.debug(challenge:)`,
#      `DebugAttestationProvider()`, forging a `RestrictedAttestation` and reading one all fail to compile, each for the expected reason. A control
#      target using the core product compiles, so a failure is the access rule and not a broken fixture.
#   3. An app that links the opt-in product `LensJourneyDebugAttestation` builds and runs in Debug AND Release.
#   scripts/check-debug-attestation-boundary.sh
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir "$work/lens-journey-ios"
# A copy named like the package, so the fixture's dependency identity does not depend on where this checkout lives.
tar -C "$repo" --exclude=.build --exclude=.git --exclude=.swiftpm -cf - . | tar -C "$work/lens-journey-ios" -xf -
cp -R "$repo/scripts/consumer-fixture" "$work/fixture"
fail=0
pass() { echo "  PASS $1"; }
bad()  { echo "  FAIL $1"; fail=1; }

# --- 1. binary check -------------------------------------------------------------------------------------------------------------------
core="$work/core-scratch"; opt="$work/opt-scratch"
( cd "$work/lens-journey-ios" && swift build -c release --product LensJourney --scratch-path "$core" >/dev/null 2>&1 ) || { echo "core release build failed"; exit 2; }
( cd "$work/lens-journey-ios" && swift build -c release --product LensJourneyDebugAttestation --scratch-path "$opt" >/dev/null 2>&1 ) || { echo "debug product release build failed"; exit 2; }
core_o="$(cd "$work/lens-journey-ios" && swift build -c release --scratch-path "$core" --show-bin-path)/LensJourney.o"
opt_o="$(cd "$work/lens-journey-ios" && swift build -c release --scratch-path "$opt" --show-bin-path)/LensJourneyDebugAttestation.o"
[ -f "$core_o" ] && [ -f "$opt_o" ] || { echo "no build output ($core_o / $opt_o)"; exit 2; }
core_strings="$(strings -a "$core_o")"; opt_strings="$(strings -a "$opt_o")"
if grep -qx 'DebugAttestationProvider' <<<"$opt_strings"; then pass "control: the opt-in product's Release object contains DebugAttestationProvider"
else bad "control: the opt-in product's object does not contain them, so the binary check proves nothing"; fi
if grep -q 'DebugAttestationProvider' <<<"$core_strings"; then bad "the core Release object contains DebugAttestationProvider"; else pass "the core Release object has no DebugAttestationProvider"; fi
# (The payload case and wire field are short strings the optimizer inlines, so a binary search for them would be unreliable; part 2 proves
# the case and the constructor are absent at the API level instead.)

# --- 2. consumer outside the package, core product only --------------------------------------------------------------------------------
fx() { ( cd "$work/fixture" && swift build -c "${2:-debug}" --scratch-path "$work/fx-scratch" --target "$1" 2>&1 ); }
out="$(fx Control)" && pass "control target (core product only) compiles" || { bad "control target does not compile, so the failures below prove nothing"; echo "$out" | tail -5; }
expect_fail() { # <target> <description> <required text in the compiler output>
  local o; o="$(fx "$1")"; local rc=$?
  if [ $rc -ne 0 ] && grep -q "$3" <<<"$o"; then pass "$2 does not compile ($3)"
  elif [ $rc -eq 0 ]; then bad "$2 COMPILES against the core product"
  else bad "$2 failed, but not for the expected reason ($3)"; echo "$o" | grep error | head -3; fi
}
expect_fail FailDebugCase "a custom provider returning .debug(challenge:)" "has no member 'debug'"
expect_fail FailDebugProvider "DebugAttestationProvider without the opt-in product" "cannot find 'DebugAttestationProvider' in scope"
expect_fail FailRestrictedInit "forging a RestrictedAttestation" "inaccessible due to 'package' protection level"
expect_fail FailRestrictedPattern "reading a RestrictedAttestation" "inaccessible due to 'package' protection level"

# --- 3. opt-in product works in Debug and Release ------------------------------------------------------------------------------------
for cfg in debug release; do
  o="$( cd "$work/fixture" && swift run -c "$cfg" --scratch-path "$work/fx-scratch-$cfg" DebugLinked 2>&1 )"
  if grep -qx 'AttestationPayload.restricted(<redacted>)' <<<"$o"; then pass "app linking LensJourneyDebugAttestation builds and runs in $cfg"; else bad "linked debug product does not work in $cfg"; echo "$o" | tail -5; fi
done
[ $fail = 0 ] && echo "ok" || { echo "FAILED"; exit 1; }
