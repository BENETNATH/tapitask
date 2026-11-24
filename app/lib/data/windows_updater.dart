import "dart:async";
import "dart:io";

import "package:archive/archive.dart";
import "package:http/http.dart" as http;
import "package:path/path.dart" as p;

import "update_service.dart";

/// Self-update Windows (spec §B.5) : un exe ne peut pas se remplacer en
/// cours d'exécution → on écrit le contenu du zip dans
/// `<appdir>\update-tmp\` + un bat qui, une fois tapitask.exe arrêté,
/// copie, nettoie, relance, et s'efface. L'app lance le bat détaché puis
/// `exit(0)`. Tant que le bat n'a pas tourné, rien n'est modifié.

/// Contenu du bat de mise à jour (généré en Dart, testable sans Windows).
String buildUpdateBat({required String appDir, required String tmpDir}) {
  return '''
@echo off
rem Attente de la fin de tapitask.exe (boucle tasklist).
:wait
tasklist /FI "IMAGENAME eq tapitask.exe" 2>NUL | find /I "tapitask.exe" >NUL
if not errorlevel 1 (
  timeout /t 1 /nobreak >NUL
  goto wait
)
rem Copie du contenu de update-tmp vers le repertoire de l'app
rem (sans backslash final avant la guillemet fermante : piège de quoting cmd).
xcopy /E /Y /I "$tmpDir\\*" "$appDir"
del "$appDir\\run_update.bat"
rem `del %~f0` est STRICTEMENT la derniere ligne non vide : une ligne apres
rem l'effacement du bat n'est jamais executee (cmd perd le fichier de
rem commandes). Le dossier update-tmp subsiste : un rmdir apres del %~f0
rem reproduirait le meme bug.
start "" "$appDir\\tapitask.exe"
del "%~f0"
''';
}

/// Décompression du zip de release : le contenu du dossier `Release\`
/// (si présent) est ramené à la racine, les fichiers `.vcxproj` sont
/// exclus. Un zip sans wrapper (contenu à la racine) passe tel quel.
Map<String, List<int>> extractUpdateZip(List<int> zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes);
  final out = <String, List<int>>{};
  for (final f in archive.files) {
    var name = f.name;
    if (name.endsWith("/")) continue;  // entrée dossier
    if (name.startsWith("Release/")) name = name.substring("Release/".length);
    if (name.isEmpty || name.endsWith(".vcxproj")) continue;
    out[name] = f.content as List<int>;
  }
  return out;
}

/// Orchestration : téléchargement → update-tmp → bat → lancement détaché
/// → exit(0). À n'appeler que sur Windows (bouton du dialog §B.4).
Future<void> runSelfUpdate(UpdateInfo info) async {
  final windowsUrl = info.windowsUrl;
  if (windowsUrl == null) {
    throw StateError("pas d'asset Windows pour la MAJ");
  }
  final appDir = p.dirname(Platform.resolvedExecutable);
  final tmpDir = p.join(appDir, "update-tmp");
  final dir = Directory(tmpDir);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  final zipBytes = await http.readBytes(Uri.parse(windowsUrl));
  for (final entry in extractUpdateZip(zipBytes).entries) {
    final file = File(p.join(tmpDir, entry.key));
    file.parent.createSync(recursive: true);
    await file.writeAsBytes(entry.value);
  }
  final bat = File(p.join(tmpDir, "run_update.bat"));
  bat.writeAsStringSync(buildUpdateBat(appDir: appDir, tmpDir: tmpDir));
  // Le bat est détaché : il tourne après notre exit(0), quand tapitask.exe
  // n'est plus dans tasklist.
  final proc = await Process.start("cmd", ["/c", bat.path],
      mode: ProcessStartMode.detached);
  unawaited(proc.exitCode);
  exit(0);
}
