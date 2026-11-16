#!/usr/bin/env bash
# Tapitask — initialisation du client Flutter.
# À lancer une seule fois, depuis le dossier app/ :
#   bash ../scripts/init_flutter.sh
set -euo pipefail

cd "$(dirname "$0")/../app"

PROJECT=tapitask
ORG=com.tapitask

command -v flutter >/dev/null || { echo "flutter introuvable dans le PATH"; exit 1; }

echo "==> Génération des dossiers plateforme ($PROJECT / $ORG)"
flutter create . --project-name "$PROJECT" --org "$ORG" --platforms=windows,android,web

echo "==> Application du nom Tapitask (Android)"
MANIFEST=android/app/src/main/AndroidManifest.xml
python3 - "$MANIFEST" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('android:label="checklists"', 'android:label="Tapitask"')
s = s.replace('android:label="tapitask"', 'android:label="Tapitask"')
open(p, "w").write(s)
PYEOF

echo "==> Permission INTERNET (obligatoire en release)"
python3 - "$MANIFEST" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
perm = '<uses-permission android:name="android.permission.INTERNET"/>'
if "INTERNET" not in s:
    s = s.replace("<application", perm + "\n    <application", 1)
    open(p, "w").write(s)
PYEOF

echo "==> Déclaration du widget Android (receiver)"
python3 - "$MANIFEST" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
receiver = '''    <receiver android:name=".ListWidgetProvider" android:exported="false">
        <intent-filter>
            <action android:name="android.appwidget.action.APPWIDGET_UPDATE" />
        </intent-filter>
        <meta-data
            android:name="android.appwidget.provider"
            android:resource="@xml/list_widget_info" />
    </receiver>'''
if "ListWidgetProvider" not in s:
    s = s.replace("</application>", receiver + "\n</application>")
open(p, "w").write(s)
PYEOF

echo "==> Copie du provider Kotlin du widget"
KDIR=android/app/src/main/kotlin/com/example/checklists
DEST_DIR=android/app/src/main/kotlin/$ORG/$PROJECT
if [ -d "$KDIR" ]; then
  mkdir -p "$DEST_DIR"
  mv "$KDIR/ListWidgetProvider.kt" "$DEST_DIR/"
  sed -i "s/package com.example.checklists/package $ORG.$PROJECT/" "$DEST_DIR/ListWidgetProvider.kt"
  rmdir "$KDIR" 2>/dev/null || true
fi

echo "==> Ressources du widget (layout + xml)"
mkdir -p android/app/src/main/res/layout android/app/src/main/res/xml
[ -f android/app/src/main/res/layout/list_widget.xml ] || echo "ERREUR: layout manquant"

echo "==> Chaîne widget_title"
python3 - <<'PYEOF'
import os
p = "android/app/src/main/res/values/strings.xml"
os.makedirs(os.path.dirname(p), exist_ok=True)
s = open(p).read() if os.path.exists(p) else "<resources>\n</resources>\n"
if "widget_title" not in s:
    s = s.replace("</resources>", '    <string name="widget_title">Tapitask</string>\n</resources>')
open(p, "w").write(s)
PYEOF

echo "==> Dépendances + génération Drift"
flutter pub get
dart run build_runner build --delete-conflicting-outputs

echo ""
echo "Terminé. Pour lancer :"
echo "  flutter run -d windows     # tray + app de bureau"
echo "  flutter run -d android     # app + widget Android"
echo "  flutter run -d chrome      # webapp"
