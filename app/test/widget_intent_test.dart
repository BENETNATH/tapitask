import "package:flutter_test/flutter_test.dart";

import "package:tapitask/state/widget_intent.dart";

const valid = "0f8fad5b-3c46-46e6-8f5d-7c1b2a9f3f77";

void main() {
  group("validateQuickAddUri", () {
    test("1. null → null", () {
      expect(validateQuickAddUri(null, {valid}), isNull);
    });

    test("2. tapitask://home → null", () {
      expect(validateQuickAddUri(Uri.parse("tapitask://home"), {valid}), isNull);
    });

    test("3. mauvais scheme → null", () {
      expect(
          validateQuickAddUri(
              Uri.parse("https://evil/quickadd?list=$valid"), {valid}),
          isNull);
    });

    test("4. mauvais path → null", () {
      expect(
          validateQuickAddUri(
              Uri.parse("tapitask://home?list=$valid"), {valid}),
          isNull);
    });

    test("5. quickadd sans list → \"\"", () {
      expect(validateQuickAddUri(Uri.parse("tapitask://quickadd"), {valid}),
          "");
    });

    test("6. list vide → null", () {
      expect(validateQuickAddUri(Uri.parse("tapitask://quickadd?list="), {valid}),
          isNull);
    });

    test("7. UUID valide dans le set → id renvoyé", () {
      expect(
          validateQuickAddUri(
              Uri.parse("tapitask://quickadd?list=$valid"), {valid}),
          valid);
    });

    test("8. UUID valide hors set → null", () {
      expect(
          validateQuickAddUri(
              Uri.parse("tapitask://quickadd?list=$valid"),
              {"autre-liste"}),
          isNull);
    });

    test("9. UUID majuscule, set en minuscule (casse stricte) → null", () {
      expect(
          validateQuickAddUri(
              Uri.parse("tapitask://quickadd?list=${valid.toUpperCase()}"),
              {valid}),
          isNull);
    });

    test("10. formats invalides → null", () {
      final bad = [
        "abc",
        "12345678-1234-1234-1234-12345678901",
        "not-a-uuid",
        "a" * 35,
      ];
      for (final v in bad) {
        expect(
            validateQuickAddUri(Uri.parse("tapitask://quickadd?list=$v"), {v}),
            isNull,
            reason: "rejette $v");
      }
    });

    test("11. UUID valide + param superflu ignoré → id renvoyé", () {
      expect(
          validateQuickAddUri(
              Uri.parse("tapitask://quickadd?list=$valid&evil=1"), {valid}),
          valid);
    });

    test("12. set vide → null", () {
      expect(
          validateQuickAddUri(
              Uri.parse("tapitask://quickadd?list=$valid"), {}),
          isNull);
    });
  });
}
