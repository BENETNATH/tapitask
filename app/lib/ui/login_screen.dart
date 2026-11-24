import "package:material_ui/material_ui.dart";

import "../data/api_client.dart";
import "../state/app_state.dart";
import "../l10n/s.dart";

class LoginScreen extends StatefulWidget {
  final AppState state;
  const LoginScreen({super.key, required this.state});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _totp = TextEditingController();
  final _server = TextEditingController();
  bool _register = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _server.text = widget.state.api.baseUrl;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(S.accountAndServer)),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _server,
              decoration: InputDecoration(
                  labelText: S.serverUrl, hintText: "https://checklists.mondomaine.fr"),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _email,
              decoration: InputDecoration(labelText: S.email),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _password,
              decoration: InputDecoration(labelText: S.password),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _totp,
              decoration: InputDecoration(
                  labelText: S.totpCode, hintText: S.emailOptional),
              keyboardType: TextInputType.number,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () async => _submit(),
              child: Text(_register ? S.createAccount : S.login),
            ),
            TextButton(
              onPressed: () => setState(() => _register = !_register),
              child: Text(_register
                  ? S.haveAccount
                  : "Je n'ai pas de compte"),
            ),
            TextButton(
              onPressed: _acceptInvite,
              child: Text(S.haveInviteCode),
            ),
            TextButton(
              onPressed: _verifyEmail,
              child: Text(S.verifyEmail),
            ),
          ],
        ),
      ),
    );
  }

  /// Avertissement http:// (audit lot T) : login/register/invitation
  /// n'avancent qu'après confirmation explicite.
  Future<bool> _confirmInsecure() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.insecureServerTitle),
        content: Text(S.insecureServerBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(S.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(S.ok)),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<bool> _applyServerUrl() async {
    final url = _server.text.trim().replaceAll(RegExp(r"/$"), "");
    if (url.startsWith("http://") && !await _confirmInsecure()) return false;
    widget.state.api.baseUrl = url;
    return true;
  }

  Future<void> _acceptInvite() async {
    final code = await _promptInviteCode();
    if (code == null || code.trim().isEmpty) return;
    final api = widget.state.api;
    if (!await _applyServerUrl()) return;
    try {
      if (api.accessToken == null || api.accessToken!.isEmpty) {
        // 1.4 (prod3) : sans session le POST part sans token → s'arrêter si
        // le submit échoue (l'erreur est déjà affichée par _submit).
        final ok = await _submit(silent: true);
        if (!ok) return;
      }
      await api.post("/lists/invites/${code.trim()}/accept", {});
      await widget.state.sync.fullSync();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(S.listAdded)));
        Navigator.pushReplacementNamed(context, "/home");
      }
    } on ApiException catch (e) {
      setState(() => _error = "Invitation refusée : ${e.message}");
    } catch (e) {
      setState(() => _error = S.loginFailed(e));
    }
  }

  Future<void> _verifyEmail() async {
    final code = await _promptCode(S.codeFromEmail);
    if (code == null || code.trim().isEmpty) return;
    // C1.7 : l'URL saisie doit être appliquée AVANT le POST (comme _submit)
    // — sinon le code part vers l'ancienne URL (ou une URL vide → crash
    // ArgumentError, dorénavant attrapé ci-dessous).
    if (!await _applyServerUrl()) return;
    try {
      await widget.state.api
          .post("/auth/verify-email", {"token": code.trim()});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(S.emailVerified)));
      }
    } on ApiException catch (e) {
      setState(() => _error = "Vérification échouée : ${e.message}");
    } catch (e) {
      // C1.7 : non-Apex (ArgumentError, http.ClientException, …) → message,
      // pas de crash.
      setState(() => _error = S.loginFailed(e));
    }
  }

  Future<String?> _promptCode(String title) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text("Valider")),
        ],
      ),
    );
  }

  Future<String?> _promptInviteCode() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.inviteCode),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: S.pasteCode),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text("Valider")),
        ],
      ),
    );
  }

  /// 1.4 (prod3) : renvoie `true` si la session est ouverte et le profil
  /// chargé. `reloadProfile(required: true)` : un profil non chargé laisse
  /// `email` sur le compte PRÉCÉDENT → pas de purge → fuite des données A
  /// dans le sync B. Échec → erreur affichée, ni purge ni fullSync.
  Future<bool> _submit({bool silent = false}) async {
    final api = widget.state.api;
    if (!await _applyServerUrl()) return false;
    try {
      if (_register) {
        await api.register(_email.text.trim(), _password.text);
      } else {
        await api.login(_email.text.trim(), _password.text,
            totpCode: _totp.text.trim().isEmpty ? null : _totp.text.trim());
      }
    } on EmailVerificationRequired {
      // C1.7 (A1) : register 202 — on reste sur l'écran, pas de navigation,
      // pas de fullSync, aucun token persisté.
      setState(() => _error = S.emailVerificationSent);
      return false;
    } catch (e) {
      setState(() => _error = S.loginFailed(e));
      return false;
    }
    await api.persist();
    try {
      // Le profil d'abord (C2.8 : c'est lui qui donne l'email du compte
      // pour détecter un changement de compte), puis purge éventuelle des
      // données locales du précédent, PUIS le pull.
      await widget.state.reloadProfile(required: true);
      await widget.state.onAccountSwitch();
      // Fresh login: pull everything, start realtime, reload the profile
      // (admin flag + feature settings) instead of waiting for a restart.
      await widget.state.sync.fullSync();
      await widget.state.sync.listenRealtime();
      await widget.state.refreshAfterLogin();
      if (mounted && !silent) Navigator.pushReplacementNamed(context, "/home");
    } catch (e) {
      setState(() => _error = S.loginFailed(e));
      return false;
    }
    return true;
  }

  @override
  // 3.2 (prod3) : contrôleurs jamais disposés.
  void dispose() {
    _email.dispose();
    _password.dispose();
    _totp.dispose();
    _server.dispose();
    super.dispose();
  }
}
