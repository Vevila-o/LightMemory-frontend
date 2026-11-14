import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:light_memory/core/services/new_notification_alerter.dart';
import 'package:light_memory/features/home/models/notification_model.dart';

/// 假的手機通知：記下跳了哪些通知、問了幾次權限
class _FakePresenter implements NotificationAlertPresenter {
  final List<({int id, String title, String body})> shown = [];
  int permissionRequests = 0;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return true;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    shown.add((id: id, title: title, body: body));
  }
}

AppNotification _n(int id, String message, {bool isRead = false}) =>
    AppNotification(
      id: id,
      message: message,
      type: 'comment',
      targetUrl: '/posts/1/',
      isRead: isRead,
      createdAt: null,
    );

const _tokenA = 'header.payload.signature-of-login-A';
const _tokenB = 'header.payload.signature-of-login-B';

void main() {
  late _FakePresenter presenter;
  late List<AppNotification> backend;
  late int fetchCount;
  final alerter = NewNotificationAlerter.instance;

  setUp(() {
    presenter = _FakePresenter();
    backend = [];
    fetchCount = 0;
    NewNotificationAlerter.presenter = presenter;
    NewNotificationAlerter.fetch = () async {
      fetchCount++;
      return List.of(backend);
    };
    SharedPreferences.setMockInitialValues({'access_token': _tokenA});
  });

  Future<void> login(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('access_token', token);
  }

  test('登入後第一次查：只記下起點，不把以前的舊通知跳出來，並問一次通知權限', () async {
    backend = [_n(5, '舊留言'), _n(3, '更舊的留言')];
    await alerter.check();
    expect(presenter.shown, isEmpty);
    expect(presenter.permissionRequests, 1);
  });

  test('之後有新的未讀通知：各跳一則，內容是通知文字，已讀的不跳', () async {
    backend = [_n(5, '舊留言')];
    await alerter.check();

    backend = [
      _n(8, '小玲 送給你一段語音加油'),
      _n(7, '阿明 在你的日記留言', isRead: true),
      _n(6, '小華 在你的日記留言'),
      _n(5, '舊留言'),
    ];
    await alerter.check();
    expect(presenter.shown.map((a) => a.body), [
      '小華 在你的日記留言',
      '小玲 送給你一段語音加油',
    ]);
    expect(presenter.shown.every((a) => a.title == '憶智防線'), isTrue);
    // 手機通知 id 跟每日提醒（1001）錯開、每則不同
    expect(presenter.shown.map((a) => a.id).toSet(), hasLength(2));
    expect(presenter.shown.map((a) => a.id), isNot(contains(1001)));

    // 再查一次沒有新的：不會重複跳
    await alerter.check();
    expect(presenter.shown, hasLength(2));
  });

  test('一次超過 3 則新通知：合成一則「你有 N 則新通知」', () async {
    await alerter.check();
    backend = [for (var i = 1; i <= 5; i++) _n(i, '留言 $i')];
    await alerter.check();
    expect(presenter.shown, hasLength(1));
    expect(presenter.shown.single.body, '你有 5 則新通知，點這裡查看');
  });

  test('沒登入：不打 API；之後重新登入要重新記起點，不提醒登出期間的舊通知', () async {
    backend = [_n(1, '留言 1')];
    await alerter.check();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('access_token');
    backend = [_n(2, '登出期間的留言'), _n(1, '留言 1')];
    await alerter.check();
    expect(fetchCount, 1, reason: '沒登入不該打通知 API');

    await login(_tokenA);
    await alerter.check();
    expect(presenter.shown, isEmpty);
  });

  test('換帳號登入（token 不同）：重新記起點，通知權限只問第一次', () async {
    backend = [_n(10, '帳號 A 的留言')];
    await alerter.check();

    await login(_tokenB);
    backend = [_n(12, '帳號 B 以前的留言')];
    await alerter.check();
    expect(presenter.shown, isEmpty);
    expect(presenter.permissionRequests, 1);

    backend = [_n(13, '帳號 B 的新留言'), _n(12, '帳號 B 以前的留言')];
    await alerter.check();
    expect(presenter.shown.map((a) => a.body), ['帳號 B 的新留言']);
  });

  test('API 失敗（網路斷、token 過期）：不會壞掉，下次正常再查', () async {
    await alerter.check();
    NewNotificationAlerter.fetch = () async => throw Exception('network down');
    await alerter.check();
    expect(presenter.shown, isEmpty);

    NewNotificationAlerter.fetch = () async => [_n(1, '新留言')];
    await alerter.check();
    expect(presenter.shown.map((a) => a.body), ['新留言']);
  });

  test('網頁版不支援：start() 不會開始查', () async {
    NewNotificationAlerter.isSupportedOverride = false;
    addTearDown(() => NewNotificationAlerter.isSupportedOverride = null);
    alerter.start();
    expect(alerter.isRunning, isFalse);
    expect(fetchCount, 0);
  });
}
