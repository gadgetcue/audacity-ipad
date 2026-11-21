#!/usr/bin/env bash
# sign.sh <path/to/SoundCue.app>
# Signs the app in place with an Apple certificate + provisioning profile taken from env:
#   IOS_CERT_P12_BASE64, IOS_CERT_PASSWORD, IOS_PROFILE_BASE64
set -euo pipefail
APP="$1"
T="$(mktemp -d)"
KC="$T/sign.keychain-db"
KCPW="$(uuidgen)"
echo "$IOS_CERT_P12_BASE64" | base64 --decode > "$T/cert.p12"
echo "$IOS_PROFILE_BASE64" | base64 --decode > "$T/profile.mobileprovision"
security create-keychain -p "$KCPW" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KCPW" "$KC"
security import "$T/cert.p12" -k "$KC" -P "${IOS_CERT_PASSWORD:-}" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" > /dev/null
# shellcheck disable=SC2046
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
security cms -D -i "$T/profile.mobileprovision" > "$T/profile.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$T/profile.plist" > "$T/ent.plist"
APPID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$T/profile.plist")"
TEAM="${APPID%%.*}"
PROFILE_BUNDLE="${APPID#*.}"
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
if [[ "$PROFILE_BUNDLE" == "*" ]]; then
  /usr/libexec/PlistBuddy -c "Set :application-identifier $TEAM.$BUNDLE" "$T/ent.plist"
elif [[ "$PROFILE_BUNDLE" != "$BUNDLE" ]]; then
  echo "Profile is for $PROFILE_BUNDLE; changing the app's bundle id from $BUNDLE to match"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PROFILE_BUNDLE" "$APP/Info.plist"
fi
cp "$T/profile.mobileprovision" "$APP/embedded.mobileprovision"
ID="$(security find-identity -v -p codesigning "$KC" | awk 'NR==1{print $2}')"
if [[ -z "$ID" || "$ID" == "0" ]]; then echo "No code signing identity found in the .p12"; exit 1; fi
codesign --force --sign "$ID" --entitlements "$T/ent.plist" --generate-entitlement-der "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Signed for team $TEAM with: $(security find-identity -v -p codesigning "$KC" | awk -F'"' 'NR==1{print $2}')"
echo "Profile expires: $(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$T/profile.plist")"
security delete-keychain "$KC" || true
rm -rf "$T"
