// Régression écran rouge cold-start widget (lot N).
//
// Le test ne pump pas ChecklistsApp complet (état app/DB non initialisé en
// test) : il pump un MaterialApp de même forme que l'app (home: placeholder
// + appRoutes réel importé de main.dart). L'initialRoute du MaterialApp du
// test = l'initial route que le moteur Android enverrait (même valeur dans
// le Navigator, même code framework).
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tapitask/main.dart' show appRoutes;

void main() {
  testWidgets(
      'cold start launcher (initial route "/") → home affiché, pas d\'exception',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: const Scaffold(body: Text('home')),
        routes: appRoutes,
        initialRoute: '/',
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets(
      'cold start widget (initial route "tapitask://home") → home affiché, pas d\'exception',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: const Scaffold(body: Text('home')),
        routes: appRoutes,
        initialRoute: 'tapitask://home',
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets(
      'cold start quickadd (initial route "tapitask://quickadd/<uuid>") → home affiché, pas d\'exception',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: const Scaffold(body: Text('home')),
        routes: appRoutes,
        initialRoute:
            'tapitask://quickadd/6f1c0a2e-9d3b-4e8a-b6c1-2f4d8a5e7c90',
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets(
      'configuration sans home (régress) : initial route inconnue lève',
      (tester) async {
    // Documente le bug pré-fix : sans home: (ni route "/"), le fallback
    // _routeNamed("/", allowNull: false) du moteur lève pour une initial
    // route inconnue. Échouerait si on retirait home: de l'app.
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        routes: appRoutes,
        initialRoute: 'tapitask://home',
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNotNull,
        reason: 'sans home:, une initial route inconnue doit lever');
  });
}
