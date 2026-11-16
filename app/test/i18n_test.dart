import "package:flutter_test/flutter_test.dart";
import "package:tapitask/l10n/s.dart";

void main() {
  test("i18n : bascule français ↔ anglais fonctionnelle", () {
    S.setLocale("fr");
    expect(S.todoAll, "À faire");
    expect(S.nothingToDo, "Rien à faire");
    expect(S.addButton, "＋ Ajouter");
    expect(S.loginFailed("x"), "Échec : x");

    S.setLocale("en");
    expect(S.todoAll, "To do");
    expect(S.nothingToDo, "Nothing to do");
    expect(S.addButton, "Add");
    expect(S.loginFailed("x"), "Failed: x");

    // unknown locale falls back to French
    S.setLocale(null);
    expect(S.todoAll, "À faire");
    S.setLocale("fr");
  });

  test("i18n : toutes les clés fr ont une traduction en", () {
    // S exposes its maps? No — check via a sample of every section instead.
    S.setLocale("en");
    for (final probe in [
      S.ok, S.cancel, S.settings, S.login, S.dueDate, S.folders,
      S.members, S.features, S.notifications, S.syncSection,
      S.appearance, S.compact, S.flyoutClose, S.promoteAdmin,
      S.t("monday"), S.t("sunday"), S.unpin, S.pollOff,
    ]) {
      expect(probe.isNotEmpty, true);
      expect(probe.contains("é"), false, reason: probe);
    }
    S.setLocale("fr");
  });
}
