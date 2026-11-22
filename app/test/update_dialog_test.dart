import "package:flutter_test/flutter_test.dart";
import "package:material_ui/material_ui.dart";
import "package:tapitask/data/update_service.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/ui/update_dialog.dart";

/// Spec §B.4 / R-B5 : le dialog « Mises à jour » affiche les deux versions,
/// le bouton, et le texte « mise à jour serveur requise » ; sans
/// disponibilité → pas de bouton, pas de texte de serveur.
void main() {
  Future<void> pumpDialog(WidgetTester tester, UpdateInfo info) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
      home: Scaffold(body: Center(child: UpdateDialog(info: info))),
    ));
  }

  testWidgets("R-B5 : dispo + serveur requis — versions, bouton, texte",
      (tester) async {
    await pumpDialog(
        tester,
        UpdateInfo(
          clientAvailable: true,
          latest: "0.4.0",
          clientCurrent: "0.3.0",
          notes: "nouvelle feature",
          windowsUrl: "https://gh.io/tapitask-v0.4.0-windows-x64.zip",
          apkUrl: "https://gh.io/tapitask-v0.4.0-android.apk",
          serverRequired: true,
          serverVersion: "0.2.0",
        ));
    expect(find.text("App 0.3.0"), findsOneWidget);
    expect(find.text("0.4.0 ${S.updateAvailable}"), findsOneWidget);
    expect(find.text("nouvelle feature"), findsOneWidget);
    expect(find.text(S.updateButton), findsOneWidget);
    expect(find.text("Serveur 0.2.0"), findsOneWidget);
    expect(find.text(S.serverUpdateRequired), findsOneWidget);
  });

  testWidgets("R-B5 : neutre (rien de dispo) — pas de bouton, pas de serveur",
      (tester) async {
    await pumpDialog(
        tester,
        const UpdateInfo(
          clientAvailable: false,
          latest: "",
          clientCurrent: "0.3.0",
          serverRequired: false,
        ));
    expect(find.text("App 0.3.0"), findsOneWidget);
    expect(find.text(S.updateButton), findsNothing);
    expect(find.textContaining(S.serverLabel), findsNothing);
    expect(find.text(S.serverUpdateRequired), findsNothing);
  });

  testWidgets("R-B5 : client à jour, serveur en retard — pas de bouton",
      (tester) async {
    await pumpDialog(
        tester,
        const UpdateInfo(
          clientAvailable: false,
          latest: "0.3.0",
          clientCurrent: "0.3.0",
          serverRequired: true,
          serverVersion: "0.2.0",
        ));
    expect(find.text(S.updateButton), findsNothing,
        reason: "bouton seulement si MAJ client disponible");
    expect(find.text("Serveur 0.2.0"), findsOneWidget,
        reason: "le serveur en retard est signalé même sans MAJ client");
    expect(find.text(S.serverUpdateRequired), findsOneWidget);
  });
}
