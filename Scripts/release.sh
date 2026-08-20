#!/bin/bash
# Release HealthCheck : build Release non signé, ditto vers staging propre,
# signature Developer ID (Hardened Runtime, retry timestamp), DMG dans
# release/, notarisation (profil trousseau AppliMacVincentGithub), staple.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HealthCheck"
SCHEME="HealthCheck"
IDENTITY="${IDENTITY:-Developer ID Application: Vincent LAURIAT (KFLACS69T9)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AppliMacVincentGithub}"
RELEASE_DIR="$ROOT/release"
STAGING="$ROOT/build/release-staging"
DERIVED="$ROOT/build/DerivedData"

VERSION=$(grep 'MARKETING_VERSION' "$ROOT/project.yml" | head -1 | sed 's/[^0-9.]//g')
DMG="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"

echo "── HealthCheck $VERSION ──"

cd "$ROOT"
xcodegen generate

echo "── Build Release (signature différée) ──"
xcodebuild -scheme "$SCHEME" -configuration Release -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO build | grep -E "BUILD (SUCCEEDED|FAILED)"

APP_SRC="$DERIVED/Build/Products/Release/$APP_NAME.app"
[ -d "$APP_SRC" ] || { echo "app introuvable : $APP_SRC" >&2; exit 1; }

echo "── Staging propre (sans xattrs) ──"
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto --norsrc --noextattr --noacl "$APP_SRC" "$STAGING/$APP_NAME.app"
APP="$STAGING/$APP_NAME.app"

sign() {
    # Le serveur de timestamp Apple est parfois indisponible : 5 tentatives.
    local target="$1"
    for attempt in 1 2 3 4 5; do
        if codesign --force --options runtime --timestamp \
            --entitlements "$ROOT/HealthCheck/HealthCheck.entitlements" \
            --sign "$IDENTITY" "$target" 2>&1; then
            return 0
        fi
        echo "  signature échouée (tentative $attempt), retry dans 5 s…"
        sleep 5
    done
    return 1
}

echo "── Signature ──"
sign "$APP"
codesign --verify --deep --strict "$APP"
echo "  signature vérifiée"

echo "── DMG ──"
mkdir -p "$RELEASE_DIR"
rm -f "$DMG"
DMG_SRC="$ROOT/build/dmg-src"
rm -rf "$DMG_SRC"
mkdir -p "$DMG_SRC"
cp -R "$APP" "$DMG_SRC/"
ln -s /Applications "$DMG_SRC/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_SRC" -ov -format UDZO "$DMG" -quiet
echo "  $DMG"

echo "── Notarisation (peut prendre quelques minutes) ──"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "── Staple ──"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "── Vérification indépendante ──"
spctl -a -t exec -vv "$APP" 2>&1 | tail -2

echo "── Terminé : $DMG ──"
