// Audit lot T : les tokens de session vivent dans flutter_secure_storage,
// plus en clair dans SharedPreferences.
import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:flutter_test/flutter_test.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:tapitask/data/api_client.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("T7 : migration — tokens clairs → secure storage, clés claires supprimées",
      () async {
    SharedPreferences.setMockInitialValues({
      "server_url": "http://srv",
      "access_token": "plain-a",
      "refresh_token": "plain-r",
    });
    FlutterSecureStorage.setMockInitialValues({});

    final client = await ApiClient.load();

    expect(client.baseUrl, "http://srv");
    expect(client.accessToken, "plain-a");
    expect(client.refreshTokenValue, "plain-r");
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString("access_token"), isNull,
        reason: "la clé claire access_token doit être supprimée");
    expect(prefs.getString("refresh_token"), isNull,
        reason: "la clé claire refresh_token doit être supprimée");
    expect(prefs.getString("server_url"), "http://srv",
        reason: "server_url reste en SharedPreferences");
    expect(await FlutterSecureStorage().read(key: "access_token"), "plain-a");
    expect(await FlutterSecureStorage().read(key: "refresh_token"), "plain-r");
  });

  test("T7 : persist — valeurs dans le store secure, round-trip load", () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    final client = ApiClient("http://srv");
    client.accessToken = "sec-a";
    client.refreshTokenValue = "sec-r";
    await client.persist();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString("server_url"), "http://srv");
    expect(prefs.containsKey("access_token"), isFalse,
        reason: "persist ne doit plus écrire les tokens en clair");
    expect(prefs.containsKey("refresh_token"), isFalse);
    expect(await FlutterSecureStorage().read(key: "access_token"), "sec-a");
    expect(await FlutterSecureStorage().read(key: "refresh_token"), "sec-r");

    final loaded = await ApiClient.load();
    expect(loaded.accessToken, "sec-a");
    expect(loaded.refreshTokenValue, "sec-r");
  });
}
