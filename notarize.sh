#!/usr/bin/env bash
# Developer ID signing + notarization + stapling for the Notchling .app bundle.
#
# Run every phase boundary (working agreement). Requires:
#   DEVELOPER_ID_APP   e.g. "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE     a stored `notarytool` keychain profile name
#                      (created once: `xcrun notarytool store-credentials`)
#
# We deliberately never pipe curl|bash or otherwise dodge Gatekeeper.
set -euo pipefail

APPDIR="${1:-build/Notchling.app}"
ENTITLEMENTS="Resources/Notchling.entitlements"

if [[ ! -d "$APPDIR" ]]; then
  echo "error: app bundle not found at $APPDIR (run: make app)" >&2
  exit 1
fi

if [[ -z "${DEVELOPER_ID_APP:-}" || -z "${NOTARY_PROFILE:-}" ]]; then
  cat >&2 <<'EOF'
error: notarization credentials missing.

This environment has no Developer ID identity, so notarization cannot run here.
To notarize on a machine that does, set:

  export DEVELOPER_ID_APP="Developer ID Application: NAME (TEAMID)"
  export NOTARY_PROFILE="notchling"     # from `xcrun notarytool store-credentials`

then re-run: ./notarize.sh build/Notchling.app
EOF
  exit 2
fi

echo "==> Hardened-runtime signing with $DEVELOPER_ID_APP"
codesign --force --deep --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$DEVELOPER_ID_APP" "$APPDIR"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APPDIR"

ZIP="$(dirname "$APPDIR")/$(basename "$APPDIR" .app).zip"
echo "==> Zipping for submission -> $ZIP"
/usr/bin/ditto -c -k --keepParent "$APPDIR" "$ZIP"

echo "==> Submitting to Apple notary service"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling ticket"
xcrun stapler staple "$APPDIR"
xcrun stapler validate "$APPDIR"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APPDIR" || true

echo "Done: $APPDIR notarized and stapled."
