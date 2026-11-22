import "package:flutter/foundation.dart";
import "package:material_ui/material_ui.dart";

import "../data/update_service.dart";
import "../l10n/s.dart";
import "../platform/update_opener_web.dart"
    if (dart.library.io) "../platform/update_opener_stub.dart";

/// Dialog compact « Mises à jour » (spec §B.4).
/// - « App {appVersion} » + (si dispo) « {latest} disponible — {notes} »
///   + bouton « Mettre à jour » (Windows §B.5 / Android §B.6 ; sur web,
///   lien cliquable vers la page release — sans url_launcher).
/// - « Serveur {serverVersion} » + (si requis) « mise à jour serveur
///   requise » (texte, pas d'action : le serveur se met à jour sur l'infra).
class UpdateDialog extends StatelessWidget {
  final UpdateInfo info;
  final VoidCallback? onUpdate;
  const UpdateDialog({super.key, required this.info, this.onUpdate});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(S.updates),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("App ${info.clientCurrent}"),
          if (info.clientAvailable) ...[
            Text("${info.latest} ${S.updateAvailable}"),
            if (info.notes.isNotEmpty) Text(info.notes),
          ],
          // Section serveur : seulement quand une version latest est connue
          // (neutre = aucune des deux parties évaluées à afficher).
          if (info.latest.isNotEmpty) ...[
            Text("${S.serverLabel} ${info.serverVersion ?? "—"}"),
            if (info.serverRequired) Text(S.serverUpdateRequired),
          ],
        ],
      ),
      actions: [
        if (kIsWeb)
          GestureDetector(
            onTap: () => openReleasePage(kReleasePageUrl),
            child: Text(
              S.openRelease,
              style: const TextStyle(
                  color: Colors.blue,
                  decoration: TextDecoration.underline),
            ),
          )
        else if (info.clientAvailable)
          TextButton(
              onPressed: onUpdate, child: Text(S.updateButton)),
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text(S.close)),
      ],
    );
  }
}
