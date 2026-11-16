import "dart:io";

import "package:flutter_local_notifications/flutter_local_notifications.dart";

import "../data/database.dart";

/// Local alerts (Android): one notification when items are due today.
/// Enabled per user via the "alerts" setting; silent otherwise.
class AlertService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> ensureInitialized() async {
    if (_initialized || !Platform.isAndroid) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings("@mipmap/ic_launcher"),
        ),
      );
      // Android 13+ : la permission POST_NOTIFICATIONS doit être demandée
      // à l'exécution, sinon la notification est silencieusement supprimée.
      final impl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await impl?.requestNotificationsPermission();
      _initialized = true;
    } catch (_) {}
  }

  static Future<void> notifyDueToday(List<LocalItem> due) async {
    if (!_initialized || due.isEmpty) return;
    const channel = AndroidNotificationDetails(
      "tapitask_due",
      "Échéances du jour",
      channelDescription: "Rappel des items dus aujourd'hui",
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );
    await _plugin.show(
      id: 1001,
      title: "${due.length} à faire aujourd'hui",
      body: due.take(3).map((i) => "• ${i.label}").join("\n"),
      notificationDetails: const NotificationDetails(android: channel),
    );
  }
}
