#!/bin/sh
# Release build of omp IDE: a universal, Developer ID signed app with the hardened runtime, in a DMG;
# notarized and stapled, and described by a Sparkle appcast item, when the environment provides what those need.
#
#   scripts/release.sh [<version> [<build>]]
#
# <version> and <build> default to MARKETING_VERSION and CURRENT_PROJECT_VERSION in App/project.yml; they apply to
# the app and the bundled ompd. Environment, all optional:
#   FEED_URL             Sparkle appcast URL baked into the app as SUFeedURL; needs SPARKLE_PUBLIC_KEY. Without it the
#                        app never starts Sparkle and has no Check for Updates… item.
#   SPARKLE_PUBLIC_KEY   EdDSA public key (base64, from Sparkle's generate_keys) baked in as SUPublicEDKey.
#   NOTARY_PROFILE       notarytool keychain profile (`xcrun notarytool store-credentials`): notarize, staple the DMG.
#   SPARKLE_KEY_FILE     EdDSA private key file (`generate_keys -x`): sign the DMG and write the appcast; needs FEED_URL.
#   DOWNLOAD_URL_PREFIX  URL the DMG is served from, for the appcast enclosure (default: FEED_URL's directory).
#   RELEASE_DIR          output directory (default ~/Library/Developer/omp-ide/release; keep it out of iCloud).
#   DERIVED_DATA         derived data (default ~/Library/Developer/omp-ide/dd-release).
# Any signing problem stops the script with an error. Skipped steps are listed at the end.
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
PROJECT="$REPO/App/OmpIDE.xcodeproj"
SCHEME="omp IDE"
APP_NAME="omp IDE"
TEAM=V8K8L3ZSD5
IDENTITY="Developer ID Application: Bella Cohen ($TEAM)"
RELEASE_DIR=${RELEASE_DIR:-$HOME/Library/Developer/omp-ide/release}
DERIVED_DATA=${DERIVED_DATA:-$HOME/Library/Developer/omp-ide/dd-release}
FEED_URL=${FEED_URL:-}
SPARKLE_PUBLIC_KEY=${SPARKLE_PUBLIC_KEY:-}
NOTARY_PROFILE=${NOTARY_PROFILE:-}
SPARKLE_KEY_FILE=${SPARKLE_KEY_FILE:-}
skipped=""

die() {
	echo "release: error: $*" >&2
	exit 1
}

step() {
	printf '\n==> %s\n' "$*"
}

skip() {
	skipped="$skipped
  - $*"
}

# Every check that a signed code object is ours and notarizable: Developer ID of the team, hardened runtime, secure
# timestamp, no get-task-allow.
check_signature() {
	info=$(codesign -dvv "$1" 2>&1) || die "not signed: $1"
	printf '%s\n' "$info" | grep -qx "Authority=$IDENTITY" || die "not signed with $IDENTITY: $1"
	printf '%s\n' "$info" | grep -qx "TeamIdentifier=$TEAM" || die "team is not $TEAM: $1"
	printf '%s\n' "$info" | grep -q '^CodeDirectory .*flags=.*runtime' || die "no hardened runtime: $1"
	printf '%s\n' "$info" | grep -q '^Timestamp=' || die "no secure timestamp: $1"
	if codesign -d --entitlements - --xml "$1" 2>/dev/null | grep -q 'get-task-allow'; then
		die "carries com.apple.security.get-task-allow: $1"
	fi
}

check_universal() {
	archs=$(lipo -archs "$1") || die "not a Mach-O file: $1"
	case " $archs " in *" arm64 "*) ;; *) die "no arm64 slice in $1 ($archs)" ;; esac
	case " $archs " in *" x86_64 "*) ;; *) die "no x86_64 slice in $1 ($archs)" ;; esac
	echo "$archs: ${1#"$EXPORT_DIR/"}"
}

# The EdDSA public key (base64) of a Sparkle private key file: base64 of the 32-byte seed (`generate_keys -x`), or of
# the older 64-byte private key followed by the 32-byte public key.
public_key_of() {
	KEY_FILE=$1 xcrun swift - <<'EOF'
import CryptoKit
import Foundation
let text = try String(contentsOfFile: ProcessInfo.processInfo.environment["KEY_FILE"]!, encoding: .utf8)
guard let key = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { exit(1) }
switch key.count {
case 32: print(try Curve25519.Signing.PrivateKey(rawRepresentation: key).publicKey.rawRepresentation.base64EncodedString())
case 96: print(key.suffix(32).base64EncodedString())
default: exit(1)
}
EOF
}

[ $# -le 2 ] || die "usage: scripts/release.sh [<version> [<build>]]"
if [ -n "$FEED_URL" ] && [ -z "$SPARKLE_PUBLIC_KEY" ]; then
	die "FEED_URL needs SPARKLE_PUBLIC_KEY: Sparkle does not install updates it cannot verify"
fi
if [ -n "$SPARKLE_KEY_FILE" ]; then
	[ -n "$FEED_URL" ] || die "SPARKLE_KEY_FILE needs FEED_URL (and SPARKLE_PUBLIC_KEY): the appcast is for an app that reads it"
	[ -r "$SPARKLE_KEY_FILE" ] || die "SPARKLE_KEY_FILE is not readable: $SPARKLE_KEY_FILE"
	derived=$(public_key_of "$SPARKLE_KEY_FILE") || die "SPARKLE_KEY_FILE is not a Sparkle EdDSA private key"
	[ "$derived" = "$SPARKLE_PUBLIC_KEY" ] ||
		die "SPARKLE_KEY_FILE does not match SPARKLE_PUBLIC_KEY: the app would reject every update it signs"
fi
security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\"" || die "signing identity not in the keychain: $IDENTITY"

step "Generating the Xcode project"
xcodegen generate --spec "$REPO/App/project.yml"

build_setting() {
	xcodebuild -project "$PROJECT" -target "$APP_NAME" -configuration Release -showBuildSettings 2>/dev/null |
		awk -v key="$1" '$1 == key && $2 == "=" { print $3; exit }'
}
VERSION=${1:-$(build_setting MARKETING_VERSION)}
BUILD=${2:-$(build_setting CURRENT_PROJECT_VERSION)}
[ -n "$VERSION" ] && [ -n "$BUILD" ] || die "could not read MARKETING_VERSION/CURRENT_PROJECT_VERSION; pass them"
echo "omp IDE $VERSION ($BUILD)"

ARCHIVE="$RELEASE_DIR/omp-IDE-$VERSION.xcarchive"
EXPORT_DIR="$RELEASE_DIR/export"
APP="$EXPORT_DIR/$APP_NAME.app"
DMG="$RELEASE_DIR/omp-IDE-$VERSION.dmg"
mkdir -p "$RELEASE_DIR"
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$DMG"

step "Archiving the Release configuration (universal)"
xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
	-destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED_DATA" \
	-skipPackagePluginValidation -skipMacroValidation \
	MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
	SPARKLE_FEED_URL="$FEED_URL" SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_KEY"

step "Exporting with Developer ID"
options="$RELEASE_DIR/ExportOptions.plist"
cat >"$options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>$IDENTITY</string>
	<key>teamID</key>
	<string>$TEAM</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" -exportOptionsPlist "$options"
rm -f "$options"
[ -d "$APP" ] || die "the export holds no $APP_NAME.app"

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# Every Mach-O in the bundle: the app, ompd, Sparkle's framework and its helpers.
find "$APP" -type f -print | while IFS= read -r file; do
	case $(file -b "$file") in *Mach-O*) check_signature "$file" ;; esac
done
plist="$APP/Contents/Library/LaunchAgents/com.omp-ide.ompd.plist"
[ -f "$plist" ] || die "no LaunchAgent plist at ${plist#"$APP/"}"
program=$(plutil -extract BundleProgram raw "$plist") || die "the LaunchAgent plist has no BundleProgram"
[ "$program" = "Contents/MacOS/ompd" ] || die "the LaunchAgent runs $program, not Contents/MacOS/ompd"
plutil -extract AssociatedBundleIdentifiers xml1 -o - "$plist" | grep -q '<string>com.omp-ide.app</string>' ||
	die "the LaunchAgent plist is not associated with com.omp-ide.app"
ompd="$APP/Contents/MacOS/ompd"
codesign -dvv "$ompd" 2>&1 | grep -qx 'Identifier=com.omp-ide.ompd' || die "ompd is not signed as com.omp-ide.ompd"
# Both are sealed into the app's signature, so replacing either breaks it.
resources="$APP/Contents/_CodeSignature/CodeResources"
grep -q '<key>Library/LaunchAgents/com.omp-ide.ompd.plist</key>' "$resources" || die "the LaunchAgent plist is not sealed"
grep -q '<key>MacOS/ompd</key>' "$resources" || die "ompd is not sealed as nested code"
check_universal "$APP/Contents/MacOS/$APP_NAME"
check_universal "$ompd"
check_universal "$APP/Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle"
# Unnotarized Developer ID is rejected until notarization; report what Gatekeeper says either way.
spctl -a -vv -t exec "$APP" 2>&1 || true

step "Building the DMG"
stage=$(mktemp -d "$RELEASE_DIR/.dmg.XXXXXX")
ditto "$APP" "$stage/$APP_NAME.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$stage" -format UDZO -ov "$DMG"
rm -rf "$stage"
codesign --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
mount=$(mktemp -d /tmp/omp-ide-dmg.XXXXXX)
hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$DMG" >/dev/null
if ! codesign --verify --deep --strict "$mount/$APP_NAME.app" || [ ! -L "$mount/Applications" ]; then
	hdiutil detach "$mount" >/dev/null
	die "the DMG does not hold the signed app and the Applications link"
fi
hdiutil detach "$mount" >/dev/null
rmdir "$mount"

if [ -n "$NOTARY_PROFILE" ]; then
	step "Notarizing"
	result=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist)
	echo "$result"
	status=$(printf '%s' "$result" | plutil -extract status raw -) || die "notarytool printed no status"
	if [ "$status" != "Accepted" ]; then
		id=$(printf '%s' "$result" | plutil -extract id raw -) &&
			xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
		die "notarization ended $status"
	fi
	xcrun stapler staple "$DMG"
	xcrun stapler validate "$DMG"
	spctl -a -vv -t open --context context:primary-signature "$DMG"
else
	skip "notarization and stapling (set NOTARY_PROFILE): Gatekeeper rejects the DMG and app as unnotarized"
fi

if [ -n "$SPARKLE_KEY_FILE" ]; then
	step "Writing the appcast"
	tools="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"
	[ -x "$tools/generate_appcast" ] && [ -x "$tools/sign_update" ] || die "no Sparkle tools in $tools"
	"$tools/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$DMG"
	# generate_appcast adds an item per archive in the directory to the appcast already there (named after FEED_URL).
	appcast_dir="$RELEASE_DIR/appcast"
	mkdir -p "$appcast_dir"
	cp -f "$DMG" "$appcast_dir/"
	"$tools/generate_appcast" --ed-key-file "$SPARKLE_KEY_FILE" \
		--download-url-prefix "${DOWNLOAD_URL_PREFIX:-${FEED_URL%/*}/}" "$appcast_dir"
	echo "appcast: $appcast_dir/${FEED_URL##*/} (upload it and the DMG)"
else
	skip "Sparkle appcast (set SPARKLE_KEY_FILE, FEED_URL, SPARKLE_PUBLIC_KEY)"
fi
[ -n "$FEED_URL" ] || skip "update feed (set FEED_URL, SPARKLE_PUBLIC_KEY): this build never checks for updates"

step "Done"
echo "app: $APP ($(du -sh "$APP" | cut -f1))"
echo "dmg: $DMG ($(du -h "$DMG" | cut -f1))"
if [ -n "$skipped" ]; then
	echo "skipped:$skipped"
fi
