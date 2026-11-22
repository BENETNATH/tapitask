import "dart:convert";
import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => "ApiException($status): $message";
}

class ApiClient {
  String baseUrl;
  String? accessToken;
  String? refreshTokenValue;

  ApiClient(this.baseUrl);

  static Future<ApiClient> load() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString("server_url") ?? "";
    final client = ApiClient(url);
    client.accessToken = prefs.getString("access_token");
    client.refreshTokenValue = prefs.getString("refresh_token");
    return client;
  }

  Future<void> persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("server_url", baseUrl);
    await prefs.setString("access_token", accessToken ?? "");
    await prefs.setString("refresh_token", refreshTokenValue ?? "");
  }

  bool get isConfigured => baseUrl.isNotEmpty;

  Future<void> register(String email, String password) async {
    await _auth("/auth/register", {"email": email, "password": password});
  }

  Future<void> login(String email, String password,
      {String? totpCode}) async {
    await _auth("/auth/login", {
      "email": email,
      "password": password,
      if (totpCode != null) "totp_code": totpCode,
    });
  }

  Future<void> _auth(String path, Map<String, dynamic> body) async {
    final r = await _post(path, body, auth: false);
    accessToken = r["access_token"];
    refreshTokenValue = r["refresh_token"];
    await persist();
  }

  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) =>
      _post(path, body, auth: true);

  Future<Map<String, dynamic>> patch(
      String path, Map<String, dynamic> body) async {
    final r = await http.patch(Uri.parse("$baseUrl$path"),
        headers: {
          "Authorization": "Bearer $accessToken",
          "Content-Type": "application/json"
        },
        body: jsonEncode(body));
    if (r.statusCode == 401 && await _tryRefresh()) {
      return patch(path, body);
    }
    _check(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Demande de changement d'email (step-up mot de passe + 2FA éventuel).
  Future<void> changeEmail(String newEmail, String password,
      {String? totpCode}) async {
    await post("/auth/change-email", {
      "new_email": newEmail,
      "password": password,
      if (totpCode != null) "totp_code": totpCode,
    });
  }

  /// Colle le code de vérification d'un changement d'email en attente.
  Future<void> verifyEmail(String token) async {
    await post("/auth/verify-email", {"token": token});
  }

  Future<void> delete(String path) async {
    final r = await http.delete(Uri.parse("$baseUrl$path"),
        headers: {"Authorization": "Bearer $accessToken"});
    if (r.statusCode == 401 && await _tryRefresh()) {
      return delete(path);
    }
    _check(r);
  }

  Future<Map<String, dynamic>> get(String path) async {
    final r = await http.get(Uri.parse("$baseUrl$path"),
        headers: {"Authorization": "Bearer $accessToken"});
    if (r.statusCode == 401 && await _tryRefresh()) {
      return get(path);
    }
    _check(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> getList(String path) async {
    final r = await http.get(Uri.parse("$baseUrl$path"),
        headers: {"Authorization": "Bearer $accessToken"});
    if (r.statusCode == 401 && await _tryRefresh()) {
      return getList(path);
    }
    _check(r);
    return jsonDecode(r.body) as List<dynamic>;
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body,
      {required bool auth}) async {
    final headers = {"Content-Type": "application/json"};
    if (auth) headers["Authorization"] = "Bearer $accessToken";
    final r = await http.post(Uri.parse("$baseUrl$path"),
        headers: headers, body: jsonEncode(body));
    if (auth && r.statusCode == 401 && await _tryRefresh()) {
      return _post(path, body, auth: auth);
    }
    _check(r);
    // 204 sans corps (ex. verify-email) : pas de JSON à décoder.
    return r.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<bool> _tryRefresh() async {
    if (refreshTokenValue == null || refreshTokenValue!.isEmpty) return false;
    try {
      final r = await http.post(Uri.parse("$baseUrl/auth/refresh"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({"refresh_token": refreshTokenValue}));
      if (r.statusCode != 200) return false;
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      accessToken = data["access_token"];
      refreshTokenValue = data["refresh_token"];
      await persist();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _check(http.Response r) {
    if (r.statusCode >= 400) {
      var message = r.body;
      try {
        final data = jsonDecode(r.body);
        if (data is Map && data.containsKey("detail")) {
          message = data["detail"].toString();
        }
      } catch (_) {}
      throw ApiException(r.statusCode, message);
    }
  }
}
