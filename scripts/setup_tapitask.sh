#!/usr/bin/env bash
# Tapitask — Build assisté des clients (Linux / macOS / WSL).
# Produit dans dist/ : l'exécutable Windows (zip), l'APK Android, la webapp.
set -euo pipefail

ask()  { read -rp "$1 " v; echo "$v"; }
ok()   { echo -e "\e[32m✔ $1\e[0m"; }
warn() { echo -e "\e[33m⚠ $1\e[0m"; }
fail() { echo -e "\e[31m✘ $1\e[0m"; exit 1; }

cd "$(dirname "$0")/.."
ROOT=$(pwd)
DIST="$ROOT/dist"
mkdir -p "$DIST"

echo "=========================================="
echo "   Tapitask — build des clients"
echo "=========================================="

command -v flutter >/dev/null || fail "Flutter introuvable. Installe-le : https://docs.flutter.dev/get-started/install"
flutter --version | head -2

# --- Initialisation (plateformes + nom + widget + icônes) ------------------
if [ ! -d "app/windows" ] || [ ! -d "app/android" ]; then
  echo "==> Initialisation des plateformes..."
  bash scripts/init_flutter.sh
else
  ok "Plateformes déjà initialisées"
  (cd app && flutter pub get >/dev/null && dart run build_runner build --delete-conflicting-outputs >/dev/null)
fi

# --- Questions -------------------------------------------------------------
BUILD_WIN=$(ask "Builder l'exécutable Windows ? (nécessite Windows + VS Build Tools) [O/n] :")
BUILD_APK=$(ask "Builder l'APK Android ? [O/n] :")
BUILD_WEB=$(ask "Builder la webapp ? [O/n] :")
BUILD_WIN=${BUILD_WIN:-O}; BUILD_APK=${BUILD_APK:-O}; BUILD_WEB=${BUILD_WEB:-O}

cd app

# --- Android : keystore de signature (une seule fois) ----------------------
if [ "${BUILD_APK,,}" = "o" ]; then
  if [ ! -f android/key.properties ] && command -v keytool >/dev/null; then
    KS=$(ask "Créer un keystore de signature pour l'APK ? (recommandé, sinon signature debug) [O/n] :")
    KS=${KS:-O}
    if [ "${KS,,}" = "o" ]; then
      KS_PATH=$(ask "Chemin du keystore [../tapitask.keystore] :"); KS_PATH=${KS_PATH:-../tapitask.keystore}
      KS_PASS=$(openssl rand -hex 16)
      keytool -genkeypair -v -keystore "$KS_PATH" -alias tapitask \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -storepass "$KS_PASS" -keypass "$KS_PASS" \
        -dname "CN=Tapitask, O=Tapitask" >/dev/null 2>&1
      cat > android/key.properties <<EOF
storeFile=$(cd "$(dirname "$KS_PATH")" && pwd)/$(basename "$KS_PATH")
storePassword=$KS_PASS
keyPassword=$KS_PASS
keyAlias=tapitask
EOF
      ok "Keystore créé : $KS_PATH (mot de passe dans android/key.properties — NE PAS COMMITER)"
    fi
  fi
  if [ -f android/key.properties ]; then
    # Branche signingConfig release du build.gradle si pas déjà fait
    grep -q key.properties android/app/build.gradle 2>/dev/null || warn "Ajoute la config de signature dans android/app/build.gradle (voir app/README.md)"
  fi
fi

# --- Builds ----------------------------------------------------------------
if [ "${BUILD_APK,,}" = "o" ]; then
  echo "==> flutter build apk --release..."
  flutter build apk --release
  cp build/app/outputs/flutter-release/app-release.apk "$DIST/Tapitask.apk"
  ok "APK : dist/Tapitask.apk"
fi

if [ "${BUILD_WEB,,}" = "o" ]; then
  echo "==> flutter build web --release..."
  flutter build web --release
  cp -r build/web "$DIST/tapitask-web"
  ok "Webapp : dist/tapitask-web/ (à servir derrière Caddy/nginx)"
fi

if [ "${BUILD_WIN,,}" = "o" ]; then
  if [ "$(uname -s)" != "MINGW"* ] && [ "$(uname -s)" != "MSYS"* ] && [ "$(uname -s)" != "CYGWIN"* ]; then
    warn "Le build Windows doit être lancé SUR Windows. Utilise plutôt scripts\\setup_tapitask.ps1 (PowerShell)."
  else
    echo "==> flutter build windows --release..."
    flutter build windows --release
    (cd build/windows/x64/runner/Release && zip -qr "$DIST/Tapitask-windows.zip" .)
    ok "Windows : dist/Tapitask-windows.zip (contient tapitask.exe + DLLs)"
  fi
fi

echo ""
echo "=========================================="
ok "Builds terminés — artefacts dans dist/"
echo "=========================================="
ls -la "$DIST" 2>/dev/null || true
echo ""
echo "Installation :"
echo "  Windows : dézippe Tapitask-windows.zip → tapitask.exe (icône « T » dans le systray)"
echo "  Android  : installe Tapitask.apk, ajoute le widget Tapitask sur l'écran d'accueil"
