import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 手機本地通知的共用入口：每日提醒（[ReminderService]）跟新通知提醒
/// （[NewNotificationAlerter]）用同一個 plugin，初始化、權限、點通知的處理都放這裡，
/// 避免兩邊各自 initialize 把對方的「點通知」處理蓋掉。
class LocalNotifications {
  LocalNotifications._();

  static final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();

  /// 使用者點了手機通知（App 開著或在背景時）；參數是通知的 payload
  static void Function(String? payload)? onTap;

  static Future<void>? _initializing;

  /// 只會真的初始化一次；失敗的話下次再試
  static Future<void> ensureInitialized() {
    return _initializing ??= _initialize().catchError((Object e) {
      _initializing = null;
      throw e;
    });
  }

  static Future<void> _initialize() async {
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // 權限等需要時才要（設定頁打開提醒、或登入後第一次查新通知），不要一打開 App 就跳詢問
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        debugPrint('[LocalNotifications] 點了通知：${response.payload}');
        onTap?.call(response.payload);
      },
    );
  }

  /// 跟使用者要通知權限；沒給回傳 false（已經決定過的話不會再跳詢問）
  static Future<bool> requestPermission() async {
    await ensureInitialized();
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      return await android.requestNotificationsPermission() ?? false;
    }
    final ios = plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (ios != null) {
      return await ios.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    }
    return false;
  }
}
