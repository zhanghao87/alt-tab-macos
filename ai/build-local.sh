#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/DerivedData/XcodeLocal"
APP_NAME="AltTab (Developer)"
BUNDLE_ID="com.lwouis.alt-tab-macos.developer"
IDENTITY="${LOCAL_CODESIGN_IDENTITY:-AltTab Local Development}"

if [[ $# -gt 0 ]]; then
    printf 'Usage: bash ai/build-local.sh\nOptional environment: DEVELOPER_DIR, LOCAL_CODESIGN_IDENTITY\n'
    if [[ $# -eq 1 && "$1" == "--help" ]]; then exit 0; fi
    exit 2
fi
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    selected="$(xcode-select -p 2>/dev/null || true)"
    if [[ -x "$selected/usr/bin/xcodebuild" ]]; then
        export DEVELOPER_DIR="$selected"
    else
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    fi
fi
if [[ "$DEVELOPER_DIR" == *.app ]]; then export DEVELOPER_DIR="$DEVELOPER_DIR/Contents/Developer"; fi
if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    printf 'Full Xcode is required. Set DEVELOPER_DIR to its Contents/Developer directory.\n' >&2
    exit 1
fi

identity_pattern='[[:space:]]([[:xdigit:]]{40}) "([^"]+)"'
fingerprint=""
matches=0
identities="$(security find-identity -v -p codesigning)"
while IFS= read -r line; do
    if [[ "$line" =~ $identity_pattern ]]; then
        if [[ "$IDENTITY" == "${BASH_REMATCH[1]}" || "$IDENTITY" == "${BASH_REMATCH[2]}" ]]; then
            fingerprint="${BASH_REMATCH[1]}"
            matches=$((matches + 1))
        fi
    fi
done <<< "$identities"
if [[ $matches -ne 1 ]]; then
    printf 'Expected one valid signing identity for "%s"; found %s. Set LOCAL_CODESIGN_IDENTITY to its SHA-1 fingerprint. No ad-hoc fallback.\n' "$IDENTITY" "$matches" >&2
    exit 1
fi

version=""
version_pattern='^##? \[([0-9.]+)\]'
while IFS= read -r line; do
    if [[ "$line" =~ $version_pattern ]]; then version="${BASH_REMATCH[1]}-local"; break; fi
done < "$ROOT/changelog.md"
if [[ -z "$version" ]]; then printf 'No release version found in changelog.md.\n' >&2; exit 1; fi
conditions="DEBUG LOCAL_FULL_FEATURES"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
if [[ "${sdk_version%%.*}" -lt 26 ]]; then conditions="$conditions LEGACY_MACOS_SDK"; fi
printf 'Building %s %s with %s\n' "$APP_NAME" "$version" "$IDENTITY"
xcodebuild -version
xcodebuild \
    -project "$ROOT/alt-tab-macos.xcodeproj" \
    -scheme Debug \
    -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$BUILD_DIR" \
    "CODE_SIGN_IDENTITY=$fingerprint" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    "ALTTAB_BUNDLE_IDENTIFIER=$BUNDLE_ID" \
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$conditions" \
    "CURRENT_PROJECT_VERSION=$version" build

STAGING="$(mktemp -d "$BUILD_DIR/.package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/$APP_NAME.app"
ditto "$BUILD_DIR/Build/Products/Debug/AltTab.app" "$APP"
INFO="$APP/Contents/Info.plist"
plutil -insert CFBundleDisplayName -string "$APP_NAME" "$INFO"
plutil -insert AltTabLocalBuild -bool YES "$INFO"
plutil -replace SUEnableAutomaticChecks -bool NO "$INFO"
plutil -insert SUAutomaticallyUpdate -bool NO "$INFO"
plutil -remove SUPublicEDKey "$INFO"
plutil -remove SUScheduledCheckInterval "$INFO"

# Debug's build-tree rpath would load an unshipped framework instead of the embedded copy.
rpath_pattern='^[[:space:]]*path (.*) \(offset [0-9]+\)$'
otool -l "$APP/Contents/MacOS/AltTab" | while IFS= read -r line; do
    if [[ "$line" =~ $rpath_pattern ]]; then
        rpath="${BASH_REMATCH[1]}"
        if [[ "$rpath" == "$BUILD_DIR/"* ]]; then
            xcrun install_name_tool -delete_rpath "$rpath" "$APP/Contents/MacOS/AltTab"
        fi
    fi
done
if [[ -e "$APP/Contents/Resources/Localizable.strings" ]]; then
    printf 'Unexpected root English strings table would override selected languages.\n' >&2
    exit 1
fi

PROBE="$STAGING/ResourceProbe.app"
mkdir -p "$PROBE/Contents/MacOS"
ln -s "$APP/Contents/Resources" "$PROBE/Contents/Resources"
plutil -create xml1 "$PROBE/Contents/Info.plist"
# Match the app identity so asset-catalog Bundle ID collisions cannot pass this probe.
plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$PROBE/Contents/Info.plist"
plutil -insert CFBundleExecutable -string probe "$PROBE/Contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$PROBE/Contents/Info.plist"
plutil -insert CFBundleDevelopmentRegion -string en "$PROBE/Contents/Info.plist"
cat > "$STAGING/probe.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
if args[1] == "assets" {
    let bundle = Bundle(path: args[2])!
    let source = URL(fileURLWithPath: args[3])
    for url in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
        let name = url.deletingPathExtension().lastPathComponent
        if url.pathExtension == "dataset" {
            guard let asset = NSDataAsset(name: name, bundle: bundle) else { fatalError("Missing data asset: \(name)") }
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("info.json"))) as! NSDictionary
            let actual = try JSONSerialization.jsonObject(with: asset.data) as! NSDictionary
            precondition(expected.isEqual(actual), "Mismatched data asset: \(name)")
        } else if url.pathExtension == "imageset" {
            precondition(bundle.image(forResource: name) != nil, "Missing image asset: \(name)")
        }
    }
    print("PASS: compiled ShortcutRecorder images and style data")
} else {
    let expected = try JSONSerialization.jsonObject(with: Data(args[2].utf8)) as! [String: String]
    for (key, value) in expected {
        let actual = Bundle.main.localizedString(forKey: key, value: key, table: nil)
        guard actual == value else {
            FileHandle.standardError.write(Data("Localization mismatch [\(args[1])]: \(key) -> \(actual), expected \(value)\n".utf8))
            exit(1)
        }
    }
    print("PASS: \(args[1]) resolves \(expected.count) translated strings")
}
SWIFT
xcrun swiftc "$STAGING/probe.swift" -o "$PROBE/Contents/MacOS/probe"
"$PROBE/Contents/MacOS/probe" assets \
    "$APP/Contents/Resources/ShortcutRecorder_ShortcutRecorder.bundle" \
    "$ROOT/vendor/ShortcutRecorder/Sources/ShortcutRecorder/Images.xcassets"
locale_count=0
for locale in "$ROOT"/resources/l10n/*.lproj; do
    [[ -d "$locale" ]] || continue
    name="$(basename "$locale" .lproj)"
    table="$(plutil -convert json -o - "$locale/Localizable.strings")"
    "$PROBE/Contents/MacOS/probe" "$name" "$table" -AppleLanguages "($name)"
    locale_count=$((locale_count + 1))
done
if [[ $locale_count -eq 0 ]]; then printf 'No localization catalogs found.\n' >&2; exit 1; fi

codesign --force --sign "$fingerprint" --timestamp=none --options runtime \
    --entitlements "$ROOT/alt_tab_macos.entitlements" "$APP"
ARCHIVE="$STAGING/AltTab-Developer-xcode.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
ditto -x -k "$ARCHIVE" "$STAGING/unpacked"
codesign --verify --deep --strict "$STAGING/unpacked/$APP_NAME.app"
codesign --verify --strict \
    --test-requirement "=identifier \"$BUNDLE_ID\" and certificate leaf = H\"$fingerprint\"" \
    "$STAGING/unpacked/$APP_NAME.app"
rm -rf "$BUILD_DIR/$APP_NAME.app"
mv "$APP" "$BUILD_DIR/$APP_NAME.app"
mv -f "$ARCHIVE" "$BUILD_DIR/AltTab-Developer-xcode.zip"
printf '\nApp: %s\nZIP: %s\nVerified %s languages and the fixed signing identity. No application was installed.\n' \
    "$BUILD_DIR/$APP_NAME.app" "$BUILD_DIR/AltTab-Developer-xcode.zip" "$locale_count"
