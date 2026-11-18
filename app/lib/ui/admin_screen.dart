import "package:material_ui/material_ui.dart";

import "../data/api_client.dart";
import "../state/app_state.dart";
import "../l10n/s.dart";

/// Écran d'administration (visible si is_admin) :
/// lister, créer, désactiver/réactiver, promouvoir, réinitialiser un mot de passe.
class AdminScreen extends StatefulWidget {
  final AppState state;
  const AdminScreen({super.key, required this.state});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  List<dynamic>? _users;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final users = await widget.state.api.getList("/admin/users");
      setState(() => _users = users);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _createUser() async {
    final email = TextEditingController();
    final password = TextEditingController();
    final isAdmin = ValueNotifier(false);
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.createAccount),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: email,
                decoration: InputDecoration(labelText: S.email)),
            TextField(
                controller: password,
                decoration:
                    InputDecoration(labelText: S.password),
                obscureText: true),
            ValueListenableBuilder(
              valueListenable: isAdmin,
              builder: (context, v, _) => SwitchListTile(
                title: Text("Admin"),
                value: v,
                onChanged: (nv) => isAdmin.value = nv,
              ),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () async {
              try {
                await widget.state.api.post("/admin/users", {
                  "email": email.text.trim(),
                  "password": password.text,
                  "is_admin": isAdmin.value,
                });
                if (context.mounted) Navigator.pop(context);
                await _load();
              } on ApiException catch (e) {
                setState(() => _error = e.message);
              }
            },
            child: Text(S.create),
          ),
        ],
      ),
    );
  }

  Future<void> _resetPassword(String userId) async {
    final password = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.resetPassword),
        content: TextField(
            controller: password,
            decoration: InputDecoration(labelText: S.newPassword),
            obscureText: true),
        actions: [
          FilledButton(
            onPressed: () async {
              try {
                await widget.state.api
                    .patch("/admin/users/$userId", {"password": password.text});
                if (context.mounted) Navigator.pop(context);
              } on ApiException catch (e) {
                setState(() => _error = e.message);
              }
            },
            child: Text(S.apply),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(S.administration)),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.person_add),
        label: Text(S.createAccount),
        onPressed: _createUser,
      ),
      body: _users == null
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _users!.length,
              itemBuilder: (context, i) {
                final u = _users![i];
                return ListTile(
                  leading: Icon(
                    u["is_active"] ? Icons.person : Icons.person_off,
                    color: u["is_active"] ? null : Colors.red,
                  ),
                  title: Text(u["email"]),
                  subtitle: Text(
                      "${u["is_admin"] ? "admin · " : ""}${u["is_active"] ? S.active : S.disabled}"),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) async {
                      try {
                        if (action == "toggle") {
                          await widget.state.api.patch(
                              "/admin/users/${u["id"]}",
                              {"is_active": !(u["is_active"] as bool)});
                        } else if (action == "admin") {
                          await widget.state.api.patch(
                              "/admin/users/${u["id"]}",
                              {"is_admin": !(u["is_admin"] as bool)});
                        } else if (action == "reset") {
                          await _resetPassword(u["id"]);
                        }
                        await _load();
                      } on ApiException catch (e) {
                        setState(() => _error = e.message);
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: "toggle",
                        child: Text(u["is_active"]
                            ? S.deactivate
                            : S.activate),
                      ),
                      PopupMenuItem(
                        value: "admin",
                        child: Text(u["is_admin"]
                            ? S.demoteAdmin
                            : S.promoteAdmin),
                      ),
                      PopupMenuItem(
                        value: "reset",
                        child: Text(S.resetPassword),
                      ),
                    ],
                  ),
                );
              },
            ),
      bottomSheet: _error == null
          ? null
          : Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
    );
  }
}
