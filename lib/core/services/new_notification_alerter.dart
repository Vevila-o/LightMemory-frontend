import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/home/models/notification_model.dart';
import '../../features/home/services/notification_service.dart';
import 'local_notifications.dart';
import 'token_storage.dart';

/// 真正跳出手機通知的那一層，抽出來是為了測試時換成假的
abstract class NotificationAlertPresenter {
  /// 跟使用者要通知權限；沒給回傳 false
  Future<bool> requestPermission();

  Future<void> show({
    required int id,
    required String title,
    required String body,
  });
}

/// 新通知提醒（簡易版，不是後端推播）：
/// App 開著、或剛切到背景還沒被系統暫停時，每 [interval] 向後端查一次通知列表，
/// 有新的未讀通知（親友留言、語音加油…）就跳一則手機通知，點了打開通知頁。
///
/// - 不需要 Firebase 推播設定，只用手機本地通知（跟每日提醒同一個 plugin）
/// - App 完全關掉、或在背景太久被系統暫停時查不到，打開 App 時會馬上補查一次
/// - 每次登入（換 token）先記下目前最新的通知 id 當起點，只提醒之後的新通知，
///   不會一登入就把以前的舊通知全部跳出來
/// - 網頁版不支援（[isSupported] 是 false）
class NewNotificationAlerter with WidgetsBindingObserver {
  NewNotificationAlerter._();

  static final NewNotificationAlerter instance = NewNotificationAlerter._();

  static const Duration interval = Duration(seconds: 30);

  /// 點通知時的 payload，App 收到就打開通知頁
  static const String payload = 'notifications';
  static const String title = '憶智防線';

  /// 一次最多各別跳幾則，超過就合成一則「你有 N 則新通知」
  static const int maxSeparateAlerts = 3;

  /// 手機通知的 id：跟每日提醒（1001）錯開
  static const int _summaryAlertId = 1999999;
  static int alertIdFor(AppNotification n) => 2000000 + n.id % 1000000;

  static const String _keyLastId = 'notification_alert_last_id';
  static const String _keyLogin = 'notification_alert_login';
  static const String _keyAsked = 'notification_alert_permission_asked';

  @visibleForTesting
  static NotificationAlertPresenter presenter =
      LocalNotificationAlertPresenter();

  @visibleForTesting
  static Future<List<AppNotification>> Function() fetch = () =>
      NotificationService().getNotifications();

  @visibleForTesting
  static bool? isSupportedOverride;

  static bool get isSupported =>
      isSupportedOverride ??
      (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS));

  Timer? _timer;
  bool _checking = false;

  bool get isRunning => _timer != null;

  /// App 啟動時呼叫一次；之後自己每 [interval] 查一次，App 回到前景時也會馬上查
  void start() {
    if (!isSupported || _timer != null) return;
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(interval, (_) => unawaited(check()));
    unawaited(check());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(check());
  }

  /// 查一次新通知。沒登入就什麼都不做（並清掉起點，下次登入重新記）；
  /// 任何錯誤都只記錄，不影響 App
  Future<void> check() async {
    if (_checking) return;
    _checking = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = await TokenStorage.getAccessToken();
      if (token == null || token.isEmpty) {
        await prefs.remove(_keyLastId);
        await prefs.remove(_keyLogin);
        return;
      }

      final list = await fetch();
      final latestId = list.fold<int>(0, (m, n) => n.id > m ? n.id : m);
      final lastId = prefs.getInt(_keyLastId);
      // 只存 token 結尾（簽章的一段）用來分辨是不是同一次登入，不另存整個 token
      final login = token.length > 16 ? token.substring(token.length - 16) : token;

      if (lastId == null || prefs.getString(_keyLogin) != login) {
        // 這次登入第一次查：記下起點，不提醒以前的通知
        await prefs.setInt(_keyLastId, latestId);
        await prefs.setString(_keyLogin, login);
        await _askPermissionOnce(prefs);
        return;
      }

      final fresh =
          list.where((n) => n.id > lastId && !n.isRead).toList()
            ..sort((a, b) => a.id.compareTo(b.id));
      if (latestId > lastId) await prefs.setInt(_keyLastId, latestId);
      if (fresh.isEmpty) return;

      if (fresh.length <= maxSeparateAlerts) {
        for (final n in fresh) {
          await presenter.show(id: alertIdFor(n), title: title, body: n.message);
        }
      } else {
        await presenter.show(
          id: _summaryAlertId,
          title: title,
          body: '你有 ${fresh.length} 則新通知，點這裡查看',
        );
      }
    } catch (e) {
      debugPrint('[NewNotificationAlerter] 查新通知失敗：$e');
    } finally {
      _checking = false;
    }
  }

  /// 登入後第一次查通知時跟使用者要通知權限，只問一次（拒絕了就不再煩他）
  Future<void> _askPermissionOnce(SharedPreferences prefs) async {
    if (prefs.getBool(_keyAsked) == true) return;
    await prefs.setBool(_keyAsked, true);
    await presenter.requestPermission();
  }
}

/// 用 flutter_local_notifications 跳通知的實作
class LocalNotificationAlertPresenter implements NotificationAlertPresenter {
  static const String _channelId = 'new_notifications';
  static const String _channelName = '新通知';

  @override
  Future<bool> requestPermission() => LocalNotifications.requestPermission();

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    await LocalNotifications.ensureInitialized();
    await LocalNotifications.plugin.show(
      id: id,
      title: title,
      body: body,
      payload: NewNotificationAlerter.payload,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: '親友留言、語音加油等新通知',
          importance: Importance.high,
          priority: Priority.high,
        ),
        // App 開著的時候也要跳橫幅
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentList: true,
          presentSound: true,
        ),
      ),
    );
  }
}
