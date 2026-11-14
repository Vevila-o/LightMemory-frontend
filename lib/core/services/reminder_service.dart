import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'local_notifications.dart';

/// 每日提醒的設定：開關與時間（只存在這支手機，不存後端）
class ReminderSettings {
  final bool enabled;
  final TimeOfDay time;

  const ReminderSettings({required this.enabled, required this.time});

  /// 預設關閉；第一次打開時是晚上 8:00
  static const ReminderSettings defaults = ReminderSettings(
    enabled: false,
    time: TimeOfDay(hour: 20, minute: 0),
  );
}

/// 真正排程通知的那一層，抽出來是為了測試時換成假的
abstract class ReminderScheduler {
  Future<void> init();

  /// 跟使用者要通知權限；沒給回傳 false
  Future<bool> requestPermission();

  /// 每天 [time] 跳一則提醒（會先取消舊的再排）
  Future<void> scheduleDaily(TimeOfDay time);

  Future<void> cancel();
}

/// 每日提醒：使用者在設定頁選時間，每天那個時間跳一則手機通知，點了打開 App。
///
/// - 用手機本地通知（flutter_local_notifications），不需要後端，也不需要網路
/// - 設定存在 shared_preferences，App 每次啟動時（[init]）依設定重新排程
/// - 網頁版不支援（[isSupported] 是 false），設定頁會把開關停用
class ReminderService {
  ReminderService._();

  static const String _keyEnabled = 'reminder_enabled';
  static const String _keyHour = 'reminder_hour';
  static const String _keyMinute = 'reminder_minute';

  static const String title = '憶智防線';
  static const String body = '今天也來動動腦吧！寫一篇聲影日記或玩一場遊戲 🌱';

  /// 測試時換成假的排程器
  @visibleForTesting
  static ReminderScheduler scheduler = LocalNotificationScheduler();

  /// 測試時可以強制當成支援／不支援的平台
  @visibleForTesting
  static bool? isSupportedOverride;

  /// 只有 Android、iOS 手機 App 支援；網頁版、桌面版不支援
  static bool get isSupported =>
      isSupportedOverride ??
      (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS));

  /// App 啟動時呼叫：初始化通知，若之前開啟過提醒就重新排程。
  /// 任何錯誤都只記錄，不能擋住 App 啟動
  static Future<void> init() async {
    if (!isSupported) return;
    try {
      await scheduler.init();
      final settings = await load();
      if (settings.enabled) await scheduler.scheduleDaily(settings.time);
    } catch (e) {
      debugPrint('[ReminderService] 初始化失敗：$e');
    }
  }

  static Future<ReminderSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final defaults = ReminderSettings.defaults;
    return ReminderSettings(
      enabled: prefs.getBool(_keyEnabled) ?? defaults.enabled,
      time: TimeOfDay(
        hour: prefs.getInt(_keyHour) ?? defaults.time.hour,
        minute: prefs.getInt(_keyMinute) ?? defaults.time.minute,
      ),
    );
  }

  static Future<void> _save(ReminderSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnabled, settings.enabled);
    await prefs.setInt(_keyHour, settings.time.hour);
    await prefs.setInt(_keyMinute, settings.time.minute);
  }

  /// 打開提醒：先要通知權限，沒給就不打開，回傳 false
  static Future<bool> enable(TimeOfDay time) async {
    if (!isSupported) return false;
    final granted = await scheduler.requestPermission();
    if (!granted) return false;
    await scheduler.scheduleDaily(time);
    await _save(ReminderSettings(enabled: true, time: time));
    return true;
  }

  /// 關閉提醒：取消排程，時間保留（下次打開沿用）
  static Future<void> disable() async {
    final current = await load();
    if (isSupported) await scheduler.cancel();
    await _save(ReminderSettings(enabled: false, time: current.time));
  }

  /// 改時間：已打開的話立刻用新時間重新排程
  static Future<void> updateTime(TimeOfDay time) async {
    final current = await load();
    if (current.enabled && isSupported) await scheduler.scheduleDaily(time);
    await _save(ReminderSettings(enabled: current.enabled, time: time));
  }

  /// 給長輩看的時間：「晚上 8:00」「上午 9:30」
  static String formatTime(TimeOfDay time) {
    final h = time.hour;
    final String period;
    if (h < 5) {
      period = '凌晨';
    } else if (h < 12) {
      period = '上午';
    } else if (h < 13) {
      period = '中午';
    } else if (h < 18) {
      period = '下午';
    } else {
      period = '晚上';
    }
    final hour12 = h % 12 == 0 ? 12 : h % 12;
    final minute = time.minute.toString().padLeft(2, '0');
    return '$period $hour12:$minute';
  }

  /// 下一次提醒的時間：今天這個時間還沒到就是今天，已經過了就是明天
  static tz.TZDateTime nextInstanceOf(TimeOfDay time, tz.TZDateTime now) {
    var scheduled = tz.TZDateTime(
      now.location,
      now.year,
      now.month,
      now.day,
      time.hour,
      time.minute,
    );
    if (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }
}

/// 用 flutter_local_notifications 排程的實作
class LocalNotificationScheduler implements ReminderScheduler {
  static const int _notificationId = 1001;
  static const String _channelId = 'daily_reminder';
  static const String _channelName = '每日提醒';

  FlutterLocalNotificationsPlugin get _plugin => LocalNotifications.plugin;
  bool _initialized = false;

  @override
  Future<void> init() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (e) {
      // 取不到手機時區時用台灣時間
      debugPrint('[ReminderService] 取得時區失敗，改用 Asia/Taipei：$e');
      tz.setLocalLocation(tz.getLocation('Asia/Taipei'));
    }
    await LocalNotifications.ensureInitialized();
    _initialized = true;
  }

  @override
  Future<bool> requestPermission() async {
    await init();
    return LocalNotifications.requestPermission();
  }

  @override
  Future<void> scheduleDaily(TimeOfDay time) async {
    await init();
    await _plugin.cancel(id: _notificationId);
    await _plugin.zonedSchedule(
      id: _notificationId,
      title: ReminderService.title,
      body: ReminderService.body,
      scheduledDate: ReminderService.nextInstanceOf(
        time,
        tz.TZDateTime.now(tz.local),
      ),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: '每天固定時間提醒寫日記或玩遊戲',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      // 不用精準鬧鐘（不需要額外權限），誤差幾分鐘可以接受
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      // 每天同一個時間重複
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  @override
  Future<void> cancel() async {
    await init();
    await _plugin.cancel(id: _notificationId);
  }
}
