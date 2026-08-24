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
BUILD=$(grep 'CURRENT_PROJECT_VERSION' "$ROOT/project.yml" | head -1 | sed 's/[^0-9]//g')
DMG="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"

# ── Sparkle ──
APPCAST="$ROOT/appcast.xml"
FEED_URL="https://raw.githubusercontent.com/vincentlauriat/HealthCheck/main/appcast.xml"
DOWNLOAD_URL="https://github.com/vincentlauriat/HealthCheck/releases/download/v$VERSION/$APP_NAME-$VERSION.dmg"
MIN_SYSTEM_VERSION="15.0"
# La clé privée EdDSA vit dans le trousseau sous ce compte plutôt que sous le
# compte par défaut, déjà occupé par la clé d'un autre logiciel. generate_keys
# et sign_update ont besoin de --account pour la retrouver.
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-HealthCheck}"

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

sign_nested() {
    # Les composants internes de Sparkle ne reçoivent PAS les entitlements de
    # l'app : Installer.xpc a justement pour rôle d'installer hors du bac à
    # sable, et lui coller com.apple.security.app-sandbox le briserait. Chacun
    # garde donc les siens, d'où les options passées par l'appelant.
    local target="$1"
    shift
    [ -e "$target" ] || { echo "composant Sparkle introuvable : $target" >&2; exit 1; }
    for attempt in 1 2 3 4 5; do
        if codesign --force --options runtime --timestamp "$@" \
            --sign "$IDENTITY" "$target" 2>&1; then
            return 0
        fi
        echo "  signature échouée (tentative $attempt), retry dans 5 s…"
        sleep 5
    done
    return 1
}

echo "── Signature ──"
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
[ -d "$SPARKLE_FW" ] || { echo "Sparkle.framework absent du bundle : build incohérent" >&2; exit 1; }
# Du plus imbriqué vers l'extérieur : signer l'app scelle le bundle, donc tout
# ce qu'elle contient doit déjà être signé. Sparkle 2 utilise Versions/B.
# `--deep` est proscrit pour signer (la vérification plus bas, elle, l'accepte).
echo "  Sparkle : composants imbriqués"
sign_nested "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
sign_nested "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
sign_nested "$SPARKLE_FW/Versions/B/Autoupdate"
sign_nested "$SPARKLE_FW/Versions/B/Updater.app"
sign_nested "$SPARKLE_FW"

sign "$APP"
codesign --verify --deep --strict "$APP"
echo "  signature vérifiée"

# Un $(PRODUCT_BUNDLE_IDENTIFIER) non substitué passerait codesign, spctl et la
# notarisation sans broncher : ça ne casserait qu'au moment où un utilisateur
# clique « Rechercher les mises à jour… ». On le vérifie sur le binaire signé.
ENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
for service in spks spki; do
    case "$ENTS" in
        *"fr.vincentlauriat.healthcheck-$service"*) ;;
        *) echo "entitlement mach-lookup manquant ou non substitué : -$service" >&2; exit 1 ;;
    esac
done
echo "  entitlements Sparkle vérifiés"

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

# Le staple réécrit le DMG : signer avant produirait une signature que Sparkle
# rejetterait chez l'utilisateur final. Donc appcast strictement après.
echo "── Appcast ──"
SIGN_UPDATE=$(find "$DERIVED/SourcePackages/artifacts" -type f -name sign_update 2>/dev/null \
    | grep -v old_dsa_scripts | head -1)
[ -n "$SIGN_UPDATE" ] || { echo "sign_update introuvable (paquet Sparkle non résolu ?)" >&2; exit 1; }
SIGNATURE=$("$SIGN_UPDATE" --account "$SPARKLE_KEY_ACCOUNT" -p "$DMG")
[ -n "$SIGNATURE" ] || { echo "sign_update n'a rien renvoyé (clé absente du trousseau ?)" >&2; exit 1; }
LENGTH=$(stat -f%z "$DMG")
python3 "$ROOT/Scripts/update_appcast.py" \
    --appcast "$APPCAST" \
    --title "$APP_NAME" \
    --feed-url "$FEED_URL" \
    --short-version "$VERSION" \
    --version "$BUILD" \
    --minimum-system-version "$MIN_SYSTEM_VERSION" \
    --url "$DOWNLOAD_URL" \
    --signature "$SIGNATURE" \
    --length "$LENGTH"

echo "── Vérification indépendante ──"
spctl -a -t exec -vv "$APP" 2>&1 | tail -2

echo "── Terminé : $DMG ──"
echo "   Reste à faire à la main : téléverser le DMG sur la release GitHub"
echo "   v$VERSION, puis commiter et pousser appcast.xml sur main — le flux"
echo "   pointe sur main, une mise à jour n'est visible qu'une fois poussée."
