import "package:material_ui/material_ui.dart";
import "package:flutter/services.dart";

import "../data/api_client.dart";
import "../state/app_state.dart";
import "../l10n/s.dart";

/// Partage d'une liste : invitations par code, membres directs par email,
/// gestion des rôles (viewer / editor) y compris après coup.
class ShareScreen extends StatefulWidget {
  final AppState state;
  final String listId;
  const ShareScreen({super.key, required this.state, required this.listId});

  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  List<dynamic>? _members;
  String? _inviteCode;
  final _email = TextEditingController();
  String _role = "viewer";
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    try {
      final members =
          await widget.state.api.getList("/lists/${widget.listId}/members");
      setState(() => _members = members);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _createInvite() async {
    setState(() => _busy = true);
    try {
      final result =
          await widget.state.api.post("/lists/${widget.listId}/invites", {
        "hours": 48,
      });
      setState(() => _inviteCode = result["invite_id"]);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _addMember() async {
    if (_email.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.state.api.post("/lists/${widget.listId}/members", {
        "email": _email.text.trim(),
        "role": _role,
      });
      _email.clear();
      await _loadMembers();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _changeRole(String userId, String role) async {
    try {
      await widget.state.api
          .patch("/lists/${widget.listId}/members/$userId", {"role": role});
      await _loadMembers();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _removeMember(String userId) async {
    try {
      await widget.state.api
          .delete("/lists/${widget.listId}/members/$userId");
      await _loadMembers();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(S.shareList)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text("Invitation par code",
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface)),
          const SizedBox(height: 4),
          Text(S.generateCodeHelp,
              style: TextStyle(color: scheme.outline, fontSize: 13)),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.link),
                label: Text(S.generateCode),
                onPressed: _busy ? null : _createInvite,
              ),
              const SizedBox(width: 12),
              if (_inviteCode != null)
                Expanded(
                  child: InkWell(
                    onTap: () {
                      Clipboard.setData(
                          ClipboardData(text: _inviteCode ?? ""));
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(S.codeCopied)));
                    },
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10)),
                      child: Text(
                        _inviteCode!,
                        style: const TextStyle(
                            fontFamily: "monospace", fontSize: 12),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const Divider(height: 32),
          Text("Ajouter directement par email",
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: scheme.onSurface)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _email,
                  decoration: InputDecoration(
                    labelText: S.memberEmail,
                    isDense: true,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _role,
                items: const [
                  DropdownMenuItem(value: "viewer", child: Text("Viewer")),
                  DropdownMenuItem(value: "editor", child: Text("Editor")),
                ],
                onChanged: (v) => setState(() => _role = v ?? "viewer"),
              ),
              IconButton(
                tooltip: S.addMember,
                icon: Icon(Icons.person_add, color: scheme.primary),
                onPressed: _busy ? null : _addMember,
              ),
            ],
          ),
          const Divider(height: 32),
          Text("Membres",
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: scheme.onSurface)),
          const SizedBox(height: 4),
          if (_members == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            )
          else if (_members!.isEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(S.noMembers,
                  style: TextStyle(color: scheme.outline, fontSize: 13)),
            )
          else
            ..._members!.map((m) {
              final role = m["role"] as String? ?? "viewer";
              final isOwner = role == "owner";
              return Card(
                elevation: 0,
                margin: const EdgeInsets.symmetric(vertical: 3),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                child: ListTile(
                  leading: Icon(
                      isOwner ? Icons.stars : Icons.person,
                      color: isOwner ? scheme.primary : scheme.outline),
                  title: Text(m["email"] ?? ""),
                  subtitle: isOwner
                      ? Text(S.roleOwner)
                      : Text("rôle : $role"),
                  trailing: isOwner
                      ? null
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DropdownButton<String>(
                              value: role,
                              underline: const SizedBox.shrink(),
                              items: const [
                                DropdownMenuItem(
                                    value: "viewer", child: Text("Viewer")),
                                DropdownMenuItem(
                                    value: "editor", child: Text("Editor")),
                              ],
                              onChanged: (v) {
                                if (v != null && v != role) {
                                  _changeRole(m["user_id"], v);
                                }
                              },
                            ),
                            IconButton(
                              tooltip: S.remove,
                              icon: Icon(Icons.person_remove,
                                  color: scheme.error),
                              onPressed: () => _removeMember(m["user_id"]),
                            ),
                          ],
                        ),
                ),
              );
            }),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_error!,
                  style: TextStyle(color: scheme.error)),
            ),
        ],
      ),
    );
  }
}
