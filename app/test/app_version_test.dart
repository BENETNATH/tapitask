import "package:flutter_test/flutter_test.dart";
import "package:tapitask/data/app_version.dart";

/// Spec §B.2 / R-B3 : la version consommée par les comparaisons vient de
/// `String.fromEnvironment('APP_VERSION')` (injecté via --dart-define au
/// build release), pas du pubspec (figé en 0.1.0). Sans --dart-define —
/// cas d'un `flutter test` local — la valeur est le défaut 'dev'.
void main() {
  test("R-B3 : défaut 'dev' sans --dart-define APP_VERSION", () {
    expect(appVersion, "dev");
    expect(appVersion, isNot("0.1.0"));
  });
}
