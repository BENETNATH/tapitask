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
///
/// 1.2 (prod3) : StatefulWidget — le dialog est la source UNIQUE de l'état
/// de téléchargement (`_updating`) et d'erreur (`_error`). Avant, `updating`
/// était capturé à la construction de la route : le setState du parent ne
/// reconstruisait pas le dialog → pas de spinner, bouton non désactivé,
/// erreur jamais affichée.
class UpdateDialog extends StatefulWidget {
  final UpdateInfo info;
  /// Fenêtre du téléchargement/dépatch (Windows §B.5 / Android §B.6).
  final Future<void> Function()? onUpdate;
  const UpdateDialog({super.key, required this.info, this.onUpdate});

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _updating = false;
  String? _error;

  Future<void> _runUpdate() async {
    final update = widget.onUpdate;
    if (update == null || _updating) return;
    setState(() {
      _updating = true;
      _error = null;
    });
    try {
      await update();
    } catch (e) {
      // L'ancienne version reste intacte ; l'erreur s'affiche DANS le
      // dialog (le parent n'a plus d'état à pousser).
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(S.updates),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("App ${widget.info.clientCurrent}"),
          if (widget.info.clientAvailable) ...[
            Text("${widget.info.latest} ${S.updateAvailable}"),
            if (widget.info.notes.isNotEmpty) Text(widget.info.notes),
          ],
          // Section serveur : seulement quand une version latest est connue
          // (neutre = aucune des deux parties évaluées à afficher).
          if (widget.info.latest.isNotEmpty) ...[
            Text("${S.serverLabel} ${widget.info.serverVersion ?? "—"}"),
            if (widget.info.serverRequired) Text(S.serverUpdateRequired),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text("${S.updateError} : $_error",
                style: const TextStyle(color: Colors.red)),
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
        else if (widget.info.clientAvailable)
          // C1.5 : bouton désactivé + spinner pendant le téléchargement.
          TextButton(
              onPressed: _updating ? null : _runUpdate,
              child: _updating
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(S.updateButton)),
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text(S.close)),
      ],
    );
  }
}
