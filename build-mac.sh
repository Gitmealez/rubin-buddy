#!/bin/sh
# Build a standalone app. Publishing requires a Developer ID and notarization.
# Local inspection: sh build-mac.sh --unsigned
# Distribution: RUBIN_SIGN_IDENTITY='Developer ID Application: ...' \
#   RUBIN_NOTARY_PROFILE='rick-notary' sh build-mac.sh
set -eu
cd "$(dirname "$0")"
MODE="${1:-signed}"
if [ "$MODE" != "--unsigned" ]; then
    : "${RUBIN_SIGN_IDENTITY:?Set a Developer ID Application identity}"
    : "${RUBIN_NOTARY_PROFILE:?Set a Keychain notarytool profile}"
fi
OUT="dist/Rick.app"
# Only replace this script's generated staging bundle.
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos13.0" Buddy.swift -o "dist/buddy-$arch"
done
lipo -create dist/buddy-arm64 dist/buddy-x86_64 -output "$OUT/Contents/MacOS/buddy"
rm -f dist/buddy-arm64 dist/buddy-x86_64
cp -R frames "$OUT/Contents/Resources/"
cp lines.txt VERSION hooks.sh state.sh session-event.py "$OUT/Contents/Resources/"
chmod +x "$OUT/Contents/Resources/"*.sh
python3 - "$OUT" <<'PY'
import plistlib, sys
from pathlib import Path
out = Path(sys.argv[1])
version = Path('VERSION').read_text().strip()
(out / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable':'buddy', 'CFBundleIdentifier':'co.desklify.rubinbuddy',
    'CFBundleName':'Rick', 'CFBundleDisplayName':'Rick', 'CFBundlePackageType':'APPL',
    'CFBundleShortVersionString':version, 'CFBundleVersion':version,
    'LSMinimumSystemVersion':'13.0', 'LSUIElement':True,
    'NSHighResolutionCapable':True,
}))
PY
if [ "$MODE" = "--unsigned" ]; then
    codesign --force --sign - "$OUT"
    printf 'Built %s for local inspection only. Not notarized; do not distribute.\n' "$OUT"
    exit 0
fi
codesign --force --options runtime --timestamp --sign "$RUBIN_SIGN_IDENTITY" "$OUT/Contents/MacOS/buddy"
codesign --force --options runtime --timestamp --sign "$RUBIN_SIGN_IDENTITY" "$OUT"
codesign --verify --deep --strict "$OUT"
ditto -c -k --keepParent "$OUT" dist/Rick-submit.zip
xcrun notarytool submit dist/Rick-submit.zip --keychain-profile "$RUBIN_NOTARY_PROFILE" --wait
xcrun stapler staple "$OUT"
xcrun stapler validate "$OUT"
spctl --assess --type execute "$OUT"
ditto -c -k --keepParent "$OUT" dist/Rick.zip
printf 'Signed and notarized: dist/Rick.zip\n'
