import "package:archive/archive.dart";
import "package:flutter_test/flutter_test.dart";
import "package:tapitask/data/windows_updater.dart";

/// Zip factice en mémoire (aucun réseau) : `ArchiveFile(name, size, content)`.
List<int> fakeZip(List<(String, List<int>)> entries) {
  final archive = Archive();
  for (final (name, content) in entries) {
    archive.addFile(ArchiveFile(name, content.length, content));
  }
  return ZipEncoder().encode(archive)!;
}

/// Spec §B.5 / R-B6 : le bat généré attend la fin de tapitask.exe, xcopy
/// vers le bon chemin, relance l'app ; la décompression pose le contenu
/// de Release\ à la racine (pas le wrapper, pas les .vcxproj).
void main() {
  test("R-B6 : le bat attend le process, xcopy vers appdir, relance", () {
    final bat = buildUpdateBat(appDir: r"C:\apps\tapitask",
        tmpDir: r"C:\apps\tapitask\update-tmp");
    // Attendre la fin de tapitask.exe (boucle tasklist).
    expect(bat, contains("tasklist"));
    expect(bat, contains("IMAGENAME eq tapitask.exe"));
    expect(bat, contains("goto wait"));
    // xcopy /E /Y /I depuis update-tmp vers le répertoire de l'app.
    expect(bat, contains(r"xcopy /E /Y /I "));
    expect(
        bat,
        contains(
            '"C:\\apps\\tapitask\\update-tmp\\*" "C:\\apps\\tapitask"'));
    // Nettoyage du tmp + relance de l'app.
    // La copie du bat laissée dans le répertoire de l'app est aussi effacée.
    expect(bat, contains(r'del "C:\apps\tapitask\run_update.bat"'));
    expect(bat, contains("rmdir /S /Q"));
    expect(bat, contains(r'start "" "C:\apps\tapitask\tapitask.exe"'));
  });

  test(
      "R-B6 : décompression — contenu du dossier Release à la racine, "
      "sans wrapper ni .vcxproj", () async {
    final zip = fakeZip([
      ("Release/tapitask.exe", [1, 2, 3]),
      ("Release/data/ICU.dat", [4, 5]),
      // Fichier parasite qui ne doit PAS atterrir dans update-tmp.
      ("Release/tapitask.vcxproj", [9]),
    ]);
    final out = extractUpdateZip(zip);
    expect(out.keys.toSet(), {"tapitask.exe", "data/ICU.dat"},
        reason: "contenu du dossier Release à la racine — pas le wrapper, "
            "pas les .vcxproj");
    expect(out["tapitask.exe"], [1, 2, 3]);
    expect(out["data/ICU.dat"], [4, 5]);
  });

  test("R-B6 : décompression — zip sans dossier Release passe tel quel",
      () async {
    // Le zip du workflow (Compress-Archive -Path . depuis Release\) a le
    // contenu à la racine : toléré, copié tel quel.
    final zip = fakeZip([
      ("tapitask.exe", [1, 2, 3]),
      ("data/ICU.dat", [4, 5]),
    ]);
    final out = extractUpdateZip(zip);
    expect(out.keys.toSet(), {"tapitask.exe", "data/ICU.dat"});
  });
}
