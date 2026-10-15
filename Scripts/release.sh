#!/bin/sh
# Builds a Developer ID–signed, notarized and stapled Harbor.dmg ready to distribute.
#
# One-time setup:
#   1. Install your "Developer ID Application" certificate (Xcode ▸ Settings ▸ Accounts ▸
#      Manage Certificates ▸ + ▸ Developer ID Application).
#   2. Put your Team ID in Config/Local.xcconfig (see Config/Local.xcconfig.example).
#   3. Store notarization credentials in the keychain once:
#        xcrun notarytool store-credentials harbor-notary \
#          --apple-id you@example.com --team-id ABCDE12345 --password <app-specific-password>
#
# Then: make release   (or NOTARY_PROFILE=other-profile Scripts/release.sh)
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

NOTARY_PROFILE="${NOTARY_PROFILE:-harbor-notary}"
build="$root/build/release"
archive="$build/Harbor.xcarchive"
export_dir="$build/export"

team="$(sed -n 's/^HARBOR_DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' Config/Local.xcconfig 2>/dev/null | tail -1)"
team="${HARBOR_DEVELOPMENT_TEAM:-$team}"
if [ -z "$team" ]; then
  echo "error: set HARBOR_DEVELOPMENT_TEAM in Config/Local.xcconfig (your 10-character Team ID)." >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "error: no 'Developer ID Application' certificate in your keychain." >&2
  exit 1
fi

rm -rf "$build"
mkdir -p "$build"

echo "▸ Generating project"
xcodegen generate --quiet

echo "▸ Archiving (universal, Release)"
xcodebuild -project Harbor.xcodeproj -scheme Harbor -configuration Release \
  -archivePath "$archive" -destination 'generic/platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation \
  HARBOR_DEVELOPMENT_TEAM="$team" archive -quiet

cat > "$build/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>$team</string>
</dict>
</plist>
EOF

echo "▸ Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
  -exportOptionsPlist "$build/ExportOptions.plist" -quiet
app="$export_dir/Harbor.app"
codesign --verify --deep --strict --verbose=2 "$app"

echo "▸ Notarizing the app"
ditto -c -k --keepParent "$app" "$build/Harbor.zip"
xcrun notarytool submit "$build/Harbor.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg="$build/Harbor-$version.dmg"

echo "▸ Building $dmg"
staging="$build/dmg"
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Harbor $version" -srcfolder "$staging" -fs HFS+ -format ULFO -ov "$dmg" -quiet
codesign --sign "Developer ID Application" --timestamp "$dmg"

echo "▸ Notarizing the disk image"
xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

sha="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
echo
echo "✓ $dmg"
echo "  version $version · sha256 $sha"
echo "  Update Packaging/homebrew/harbor.rb with this version and sha256."
echo "  For Sparkle, run generate_appcast on a folder of DMGs (see README)."
