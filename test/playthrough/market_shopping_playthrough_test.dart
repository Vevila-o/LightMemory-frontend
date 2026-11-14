// 市場買菜（market_shopping）整場模擬遊玩測試。
//
// 沒有實機/模擬器，用 widget test + 假後端（MockClient）跑完整流程：
// 進入 → 教學 → 10 題（記憶 → 選菜 → 找零，含答對/答錯/錯滿3次跳題）
// → 結算頁 → 再玩一次／退出，以及暫停選單、API 失敗等情境。
//
// 標記 [BUG] 的測試是「重現目前程式的錯誤行為」：斷言的是現在會發生的錯誤，
// 修好之後這些斷言會失敗，屆時請把斷言改成正確行為。
import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
// ignore: depend_on_referenced_packages
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:light_memory/features/game/market_shopping/pages/market_shopping_checkout_page.dart';
import 'package:light_memory/features/game/market_shopping/pages/market_shopping_game_page.dart';
import 'package:light_memory/features/game/market_shopping/pages/market_shopping_memorize_page.dart';
import 'package:light_memory/features/game/market_shopping/pages/market_shopping_play_page.dart';
import 'package:light_memory/features/game/market_shopping/pages/market_shopping_result_page.dart';
import 'package:light_memory/features/game/market_shopping/widgets/market_shopping_tutorial_dialog.dart';
import 'package:light_memory/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// 音效 plugin 假實作：audioplayers 在測試環境沒有原生端。
// AudioCache.loadPath 永遠不完成，play() 就停在那裡（不會有 timer、不會丟錯）。
// ---------------------------------------------------------------------------
class _FakeAudioPlatform extends AudioplayersPlatformInterface {
  final _events = StreamController<AudioEvent>.broadcast();

  @override
  Stream<AudioEvent> getEventStream(String playerId) => _events.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<Null>.value();
}

class _FakeGlobalAudioPlatform implements GlobalAudioplayersPlatformInterface {
  final _events = StreamController<GlobalAudioEvent>.broadcast();

  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() => _events.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<Null>.value();
}

final List<String> playedSounds = [];

class _FakeAudioCache extends AudioCache {
  @override
  Future<String> loadPath(String fileName) {
    playedSounds.add(fileName);
    return Completer<String>().future; // 永不完成
  }
}

// ---------------------------------------------------------------------------
// 假後端
// ---------------------------------------------------------------------------
const Map<String, String> kFoods = {
  'cabbage': '高麗菜',
  'cucumber': '小黃瓜',
  'egg': '雞蛋',
  'onion': '洋蔥',
  'pork': '豬肉',
  'spinach': '菠菜',
  'tofu': '豆腐',
  'tomato': '番茄',
};
const Map<String, int> kPrices = {
  'cabbage': 35,
  'cucumber': 15,
  'egg': 40,
  'onion': 20,
  'pork': 120,
  'spinach': 25,
  'tofu': 18,
  'tomato': 30,
};

class FakeQuestion {
  final int n;
  final int total;
  FakeQuestion(this.n, this.total);

  String get difficulty => n <= 4 ? 'easy' : (n <= 7 ? 'medium' : 'hard');
  int get itemCount => difficulty == 'easy' ? 2 : (difficulty == 'medium' ? 3 : 4);
  int get optionCount => difficulty == 'hard' ? 8 : 6;

  List<String> get list {
    final codes = kFoods.keys.toList();
    return List.generate(itemCount, (i) => codes[(n * 3 + i) % codes.length]);
  }

  List<String> get options {
    final codes = kFoods.keys.toList();
    final distractors = codes.where((c) => !list.contains(c)).toList();
    final all = [...list, ...distractors.take(optionCount - itemCount)];
    all.sort(); // 打散：依字母序，正確答案不會都在前面
    return all;
  }

  /// 不在購物清單上的第一個選項（拿來答錯用）
  String get wrongCode => options.firstWhere((c) => !list.contains(c));

  int get budget => difficulty == 'easy' ? 200 : (difficulty == 'medium' ? 300 : 500);
  int get spent => list.fold(0, (s, c) => s + kPrices[c]!);
  int get change => budget - spent;
  List<int> get changeOptions {
    final opts = [change, change + 10, change - 5, change + 20];
    final r = n % opts.length;
    return [...opts.sublist(r), ...opts.sublist(0, r)];
  }

  int get wrongChange => change + 10;

  Map<String, dynamic> toJson() => {
    'difficulty': difficulty,
    'current_question': n,
    'total_questions': total,
    'shopping_list': list.map((c) => {'food_code': c, 'food_name': kFoods[c]}).toList(),
    'selection_options': options.map((c) => {'food_code': c, 'food_name': kFoods[c]}).toList(),
  };
}

enum FailMode { none, http500, htmlBadGateway, network, notLoggedIn401 }

class FakeBackend {
  final int total;
  FakeBackend({this.total = 10});

  int sessionCounter = 0;
  String? sessionId;
  late FakeQuestion current;
  int itemWrong = 0;
  int changeWrong = 0;
  bool firstTry = true;
  int points = 0;
  int totalCorrect = 0;
  int firstTryCorrect = 0;
  int consecutive = 0;
  bool completed = false;

  // 可調整的失敗/延遲
  final List<FailMode> startFailures = [];
  Duration startDelay = Duration.zero;
  final List<FailMode> itemFailures = [];
  final List<FailMode> changeFailures = [];
  Duration Function(int callIndex)? itemDelay;
  FailMode historyFailure = FailMode.none;

  final List<http.Request> requests = [];
  int itemCalls = 0;

  /// 假後端發現的請求內容問題（不能在 handler 裡用 flutter_test 的 expect，會跟 pump 的 guard 衝突）
  final List<String> violations = [];
  void _check(bool ok, String msg) {
    if (!ok) violations.add(msg);
  }

  final List<Map<String, dynamic>> history = [
    {'score': 55, 'accuracy': 40.0, 'played_at': '2026-10-20T09:00:00Z'},
    {'score': 70, 'accuracy': 60.0, 'played_at': '2026-10-21T09:00:00Z'},
    {'score': 82, 'accuracy': 66.67, 'played_at': '2026-10-22T09:00:00Z'},
  ];

  MockClient client() => MockClient(_handle);

  http.Response _json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

  http.Response _ok(Map<String, dynamic> data) => _json({'success': true, 'data': data, 'error': null});

  Future<http.Response> _fail(FailMode m) async {
    switch (m) {
      case FailMode.http500:
        return _json({
          'success': false,
          'data': null,
          'error': {'code': 'INTERNAL_ERROR', 'message': '伺服器錯誤'},
        }, 500);
      case FailMode.htmlBadGateway:
        return http.Response('<html><body>502 Bad Gateway</body></html>', 502);
      case FailMode.network:
        throw http.ClientException('Failed host lookup');
      case FailMode.notLoggedIn401:
        return _json({'detail': '身分認證資訊未提供。'}, 401);
      case FailMode.none:
        throw StateError('unreachable');
    }
  }

  void _advance() {
    current = FakeQuestion(current.n + 1, total);
    itemWrong = 0;
    changeWrong = 0;
    firstTry = true;
  }

  Map<String, dynamic> _completion(bool lastCorrect) {
    completed = true;
    final accuracy = double.parse((firstTryCorrect / total * 100).toStringAsFixed(2));
    history.add({
      'score': points,
      'accuracy': accuracy,
      'played_at': DateTime.utc(2026, 10, 26, 10, sessionCounter).toIso8601String(),
    });
    return {
      'is_correct': lastCorrect,
      'retry': false,
      'is_completed': true,
      'accuracy': accuracy,
      'raw_score': points,
      'total_correct': totalCorrect,
      'first_try_correct_count': firstTryCorrect,
      'consecutive_correct': consecutive,
      'difficulty_upgraded': false,
    };
  }

  Future<http.Response> _handle(http.Request req) async {
    requests.add(req);
    final path = req.url.path;
    _check(
      req.headers['Authorization'] == 'Bearer test-token',
      'Authorization header 錯誤：${req.headers['Authorization']}',
    );

    if (req.method == 'POST' && path.endsWith('/api/games/market-shopping/sessions/')) {
      if (startDelay > Duration.zero) await Future.delayed(startDelay);
      if (startFailures.isNotEmpty) {
        final m = startFailures.removeAt(0);
        if (m != FailMode.none) return _fail(m);
      }
      sessionCounter++;
      sessionId = '48b8015b-c982-4311-0000-00000000000$sessionCounter';
      current = FakeQuestion(1, total);
      itemWrong = changeWrong = points = totalCorrect = firstTryCorrect = consecutive = 0;
      firstTry = true;
      completed = false;
      return _ok({'session_id': sessionId, ...current.toJson()});
    }

    if (req.method == 'POST' && path.contains('/item-answers/')) {
      final callIndex = itemCalls++;
      _check(path.contains('/sessions/$sessionId/'), '送到錯的 session：$path（目前 $sessionId）');
      // 先依「送出當下」的狀態算好回應，再模擬網路延遲
      final Future<http.Response> Function() respond;
      if (itemFailures.isNotEmpty && itemFailures.first != FailMode.none) {
        final m = itemFailures.removeAt(0);
        respond = () => _fail(m);
      } else {
        if (itemFailures.isNotEmpty) itemFailures.removeAt(0);
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        _check(body['reaction_time_ms'] is int, 'reaction_time_ms 不是 int');
        final selected = (body['selected_food_codes'] as List).cast<String>().toSet();
        final q = current;
        final Map<String, dynamic> data;
        if (selected.length == q.list.length && selected.containsAll(q.list)) {
          data = {
            'is_correct': true,
            'is_completed': false,
            'budget': q.budget,
            if (q.difficulty != 'hard') 'spent_amount': q.spent,
            if (q.difficulty == 'hard')
              'purchased_items': q.list.map((c) => {'food_name': kFoods[c], 'price': kPrices[c]}).toList(),
            'change_options': q.changeOptions,
          };
        } else {
          itemWrong++;
          firstTry = false;
          consecutive = 0;
          if (itemWrong < 3) {
            data = {
              'is_correct': false,
              'retry': true,
              'wrong_count': itemWrong,
              'remaining_attempts': 3 - itemWrong,
              'error_type': 'mixed_item_error',
            };
          } else if (q.n >= total) {
            // 最後一題選菜錯滿3次：整場結束（model 註解描述的情境）
            data = {..._completion(false), 'wrong_count': 3, 'remaining_attempts': 0};
          } else {
            _advance();
            data = {
              'is_correct': false,
              'retry': false,
              'wrong_count': 3,
              'remaining_attempts': 0,
              'error_type': 'mixed_item_error',
              'next_question': current.toJson(),
            };
          }
        }
        final resp = _ok(data);
        respond = () async => resp;
      }
      final d = itemDelay?.call(callIndex) ?? Duration.zero;
      if (d > Duration.zero) await Future.delayed(d);
      return respond();
    }

    if (req.method == 'POST' && path.contains('/change-answers/')) {
      _check(path.contains('/sessions/$sessionId/'), '送到錯的 session：$path（目前 $sessionId）');
      if (changeFailures.isNotEmpty) {
        final m = changeFailures.removeAt(0);
        if (m != FailMode.none) return _fail(m);
      }
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final amount = body['selected_amount'] as int;
      final q = current;
      Map<String, dynamic> data;
      if (amount == q.change) {
        totalCorrect++;
        consecutive++;
        if (firstTry) firstTryCorrect++;
        points += firstTry ? 10 : 6;
        if (q.n >= total) {
          data = _completion(true);
        } else {
          _advance();
          data = {'is_correct': true, 'retry': false, 'is_completed': false, 'next_question': current.toJson()};
        }
      } else {
        changeWrong++;
        firstTry = false;
        consecutive = 0;
        if (changeWrong < 3) {
          data = {
            'is_correct': false,
            'retry': true,
            'is_completed': false,
            'wrong_count': changeWrong,
            'remaining_attempts': 3 - changeWrong,
            'error_type': 'change_too_low',
          };
        } else if (q.n >= total) {
          data = _completion(false);
        } else {
          _advance();
          data = {'is_correct': false, 'retry': false, 'is_completed': false, 'next_question': current.toJson()};
        }
      }
      return _ok(data);
    }

    if (req.method == 'GET' && path.endsWith('/api/games/market-shopping/history/')) {
      if (historyFailure != FailMode.none) return _fail(historyFailure);
      return _json({'success': true, 'data': history, 'error': null});
    }

    // 其他（例如退出後首頁/通知頁）一律回空資料
    return _json({'success': true, 'data': [], 'error': null});
  }
}

// ---------------------------------------------------------------------------
// 測試工具
// ---------------------------------------------------------------------------
class ErrorLog {
  final List<String> errors = [];
  final List<String> details = [];
  final List<String> unreachable = [];
  String stage = '';
  List<String> get overflows => errors.where((e) => e.contains('overflowed')).toList();
  @override
  String toString() => errors.join('\n-----\n');
}

/// 收集 FlutterError（例如 RenderFlex overflow）跟未捕捉的非同步錯誤，
/// 不讓第一個錯誤就中斷整場遊玩。
Future<ErrorLog> runGame(WidgetTester tester, FakeBackend fake, Future<void> Function(ErrorLog log) body) async {
  final log = ErrorLog();
  final original = FlutterError.onError;
  FlutterError.onError = (d) {
    log.errors.add('[${log.stage}] ${d.exceptionAsString()}');
    final full = d.toString().split('\n');
    log.details.add(
      '[${log.stage}]\n${full.where((l) => l.contains('relevant error-causing') || l.contains('.dart:') || l.contains('overflowed')).take(4).join('\n')}',
    );
  };
  final done = Completer<void>();
  // App 程式裡沒被接住的非同步錯誤（例如 setState after dispose）會落到這個 zone，
  // 記錄下來而不是直接讓測試中斷；測試本身的失敗則透過 done 往外丟。
  runZonedGuarded(
    () {
      http
          .runWithClient(() => body(log), fake.client)
          .then(
            (_) {
              if (!done.isCompleted) done.complete();
            },
            onError: (Object e, StackTrace s) {
              // ignore: avoid_print
              print(
                '測試中斷於 [${log.stage}]\n錯誤：${log.errors.join('\n')}\n點不到：${log.unreachable.join('\n')}\n${log.details.toSet().join('\n')}',
              );
              if (!done.isCompleted) done.completeError(e, s);
            },
          );
    },
    (e, s) {
      log.errors.add('[uncaught async] $e');
    },
  );
  try {
    await done.future;
  } finally {
    FlutterError.onError = original;
  }
  expect(fake.violations, isEmpty, reason: '假後端收到的請求有問題');
  return log;
}

void drain(WidgetTester tester, ErrorLog log) {
  Object? e;
  while ((e = tester.takeException()) != null) {
    log.errors.add(e.toString());
  }
}

void setScreen(WidgetTester tester, Size logical) {
  tester.view.physicalSize = logical * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Widget harness() => MaterialApp(
  theme: AppTheme.lightTheme,
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MarketShoppingGamePage())),
          child: const Text('進入市場買菜'),
        ),
      ),
    ),
  ),
);

Future<void> enterGame(WidgetTester tester) async {
  await tester.pumpWidget(harness());
  await tester.tap(find.text('進入市場買菜'));
  await tester.pump(); // initState → startGame
  await tester.pump(const Duration(milliseconds: 400)); // route 動畫 + http
  await tester.pump(const Duration(milliseconds: 400)); // 教學 dialog 動畫
}

Future<void> settle(WidgetTester tester, [int ms = 300]) async {
  await tester.pump();
  await tester.pump(Duration(milliseconds: ms));
}

/// 走完教學三頁（「下一頁 →」×2、「開始遊戲 →」）
Future<void> walkTutorial(WidgetTester tester) async {
  expect(find.byType(MarketShoppingTutorialDialog), findsOneWidget);
  expect(find.text('第一步'), findsOneWidget);
  await tester.tap(find.text('下一頁 →'));
  await settle(tester);
  expect(find.text('第二步'), findsOneWidget);
  // 測試「上一頁」箭頭
  await tester.tap(find.byIcon(Icons.arrow_back));
  await settle(tester);
  expect(find.text('第一步'), findsOneWidget);
  await tester.tap(find.text('下一頁 →'));
  await settle(tester);
  await tester.tap(find.text('下一頁 →'));
  await settle(tester);
  expect(find.text('第三步'), findsOneWidget);
  await tester.tap(find.text('開始遊戲 →'));
  await settle(tester);
  expect(find.byType(MarketShoppingTutorialDialog), findsNothing);
}

Future<void> closeTutorialWithX(WidgetTester tester) async {
  expect(find.byType(MarketShoppingTutorialDialog), findsOneWidget);
  await tester.tap(find.descendant(of: find.byType(MarketShoppingTutorialDialog), matching: find.byIcon(Icons.close)));
  await settle(tester);
  expect(find.byType(MarketShoppingTutorialDialog), findsNothing);
}

Finder optionCard(String code) => find.descendant(of: find.byType(GridView), matching: find.text(kFoods[code]!));

Future<void> selectFoods(WidgetTester tester, Iterable<String> codes) async {
  final grid = find.descendant(of: find.byType(GridView), matching: find.byType(Scrollable)).first;
  for (final c in codes) {
    tester.state<ScrollableState>(grid).position.jumpTo(0); // 先回到最上面
    await tester.pump();
    await tester.scrollUntilVisible(optionCard(c), 80, scrollable: grid);
    await tester.pump();
    await tester.tap(optionCard(c));
    await tester.pump();
  }
}

Future<void> confirmSelection(WidgetTester tester) async {
  await tester.tap(find.text('確認選好了'));
  await tester.pump(); // 送出
  await tester.pump(); // http microtasks
  await tester.pump(const Duration(milliseconds: 50));
}

bool isHittable(WidgetTester tester, Finder f) {
  final center = tester.getCenter(f);
  final result = HitTestResult();
  tester.binding.hitTestInView(result, center, tester.view.viewId);
  final ro = tester.renderObject(f);
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  return center.dy < size.height && result.path.any((e) => e.target == ro);
}

/// 點找零選項。選項若被擠出畫面（點不到），記錄下來後直接呼叫 onTap 讓遊玩繼續。
Future<void> chooseChange(WidgetTester tester, int amount, [ErrorLog? log]) async {
  final f = find.text('$amount 元').last; // 選項在資訊卡下方，取最後一個
  if (isHittable(tester, f)) {
    await tester.tap(f);
  } else {
    log?.unreachable.add('${log.stage}：「$amount 元」選項點不到（y=${tester.getCenter(f).dy.toStringAsFixed(0)}）');
    final gd = find.ancestor(of: f, matching: find.byType(GestureDetector)).first;
    tester.widget<GestureDetector>(gd).onTap!();
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> dismissSnack(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 600)); // 進場動畫
  await tester.pump(const Duration(milliseconds: 4100)); // 顯示 4 秒
  await tester.pump(const Duration(milliseconds: 600)); // 退場動畫
  await tester.pump(const Duration(milliseconds: 600));
  expect(find.byType(SnackBar), findsNothing);
}

Future<void> openPause(WidgetTester tester) async {
  await tester.tap(find.text('選單'));
  await settle(tester);
  expect(find.text('遊戲暫停'), findsOneWidget);
}

/// 一題的劇本
class QPlan {
  final int itemWrongTimes; // 選菜先答錯幾次（3 = 錯滿跳題）
  final int changeWrongTimes; // 找零先答錯幾次（3 = 錯滿跳題）
  final bool waitTimeout; // 記憶頁等 10 秒倒數結束，而不是按「我記住了」
  const QPlan({this.itemWrongTimes = 0, this.changeWrongTimes = 0, this.waitTimeout = false});
}

/// 從記憶頁開始玩一題，回傳後畫面應在下一題的記憶頁或結算頁
Future<void> playQuestion(WidgetTester tester, FakeBackend fake, QPlan plan, ErrorLog log) async {
  final q = fake.current;
  log.stage = 'Q${q.n}/${q.difficulty}/記憶頁';
  expect(find.byType(MarketShoppingMemorizePage), findsOneWidget, reason: '第${q.n}題應在記憶頁');
  expect(find.text('第 ${q.n} / ${q.total} 題'), findsOneWidget);
  for (final c in q.list) {
    expect(find.text(kFoods[c]!), findsOneWidget, reason: '記憶頁要顯示 ${kFoods[c]}');
  }

  if (plan.waitTimeout) {
    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(MarketShoppingMemorizePage), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
  } else {
    await tester.tap(find.text('我記住了！'));
    await tester.pump();
  }
  log.stage = 'Q${q.n}/${q.difficulty}/選菜頁';
  expect(find.byType(MarketShoppingPlayPage), findsOneWidget, reason: '第${q.n}題應進到選菜頁');
  expect(find.text('菜籃是空的，點選下方品項'), findsOneWidget);
  // 沒選任何東西時確認鈕要是 disabled
  final btn = tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '確認選好了'));
  expect(btn.onPressed, isNull);

  for (var i = 0; i < plan.itemWrongTimes; i++) {
    await selectFoods(tester, [q.list.first, q.wrongCode]);
    // 菜籃預覽會出現 Chip
    expect(find.byType(Chip), findsNWidgets(2));
    await confirmSelection(tester);
    if (i < 2) {
      // 答錯回饋 → 2 秒後清空重來
      expect(find.text('請稍候...'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2100));
      expect(find.byType(MarketShoppingPlayPage), findsOneWidget);
      expect(find.text('菜籃是空的，點選下方品項'), findsOneWidget);
    } else {
      await tester.pump();
      drain(tester, log);
      return; // 錯滿3次：跳下一題（或整場結束）
    }
  }

  // 先多點一個再取消，測試 toggle
  await selectFoods(tester, [q.wrongCode, q.wrongCode]);
  await selectFoods(tester, q.list);
  expect(find.byType(Chip), findsNWidgets(q.list.length));
  await confirmSelection(tester);
  log.stage = 'Q${q.n}/${q.difficulty}/找零頁';
  await tester.pump(const Duration(milliseconds: 1600));
  expect(find.byType(MarketShoppingCheckoutPage), findsOneWidget, reason: '第${q.n}題應進到找零頁');
  expect(find.text('應該要找多少錢？'), findsOneWidget);
  expect(find.text('${q.budget} 元'), findsWidgets);
  if (q.difficulty == 'hard') {
    for (final c in q.list) {
      expect(find.text(kFoods[c]!), findsOneWidget, reason: '困難模式要列出購買明細');
    }
  } else {
    expect(find.text('花了'), findsOneWidget);
  }
  for (final o in q.changeOptions) {
    expect(find.text('$o 元'), findsWidgets);
  }

  for (var i = 0; i < plan.changeWrongTimes; i++) {
    await chooseChange(tester, q.wrongChange, log);
    if (i < 2) {
      expect(find.text('再試一次看看！'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1900));
      expect(find.byType(MarketShoppingCheckoutPage), findsOneWidget);
      expect(find.text('再試一次看看！'), findsNothing);
    } else {
      await tester.pump(const Duration(milliseconds: 1900));
      await tester.pump();
      drain(tester, log);
      return;
    }
  }

  await chooseChange(tester, q.change, log);
  expect(find.byIcon(Icons.check_circle), findsOneWidget);
  await tester.pump(const Duration(milliseconds: 1900));
  await tester.pump(const Duration(milliseconds: 400));
  drain(tester, log);
}

/// 整場 10 題劇本：混合答對、選菜答錯、找零答錯、錯滿3次跳題、等倒數
const List<QPlan> kFullPlan = [
  QPlan(waitTimeout: true), // 1 首次答對，等記憶倒數
  QPlan(itemWrongTimes: 1), // 2 選菜錯1次
  QPlan(changeWrongTimes: 2), // 3 找零錯2次
  QPlan(itemWrongTimes: 3), // 4 選菜錯滿跳題
  QPlan(), // 5 medium
  QPlan(changeWrongTimes: 3), // 6 找零錯滿跳題
  QPlan(), // 7
  QPlan(), // 8 hard（購買明細）
  QPlan(itemWrongTimes: 2, changeWrongTimes: 1), // 9
  QPlan(), // 10 最後一題 → 結算
];
// 依假後端規則：首次答對 = 1,5,7,8,10 → 5題 → accuracy 50；
// 分數 = 首次答對10分×5 + 重試後答對6分×(2,3,9)=18 → 68
const int kExpectedScore = 68;
const int kExpectedAccuracy = 50;

Future<void> playAll(WidgetTester tester, FakeBackend fake, ErrorLog log, List<QPlan> plan) async {
  for (final p in plan) {
    await playQuestion(tester, fake, p, log);
  }
  await tester.pump(const Duration(milliseconds: 500)); // 結算頁 route 動畫 + 歷史成績
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUpAll(() {
    AudioplayersPlatformInterface.instance = _FakeAudioPlatform();
    GlobalAudioplayersPlatformInterface.instance = _FakeGlobalAudioPlatform();
    AudioCache.instance = _FakeAudioCache();
  });

  setUp(() {
    playedSounds.clear();
    // 第一次玩：沒有任何教學已看過的旗標
    SharedPreferences.setMockInitialValues({'access_token': 'test-token'});
  });

  for (final screen in const [('一般手機 360x780', Size(360, 780)), ('小手機 360x640', Size(360, 640))]) {
    testWidgets('完整遊玩10題 → 結算 → 再玩一次 → 暫停退出（${screen.$1}）', (tester) async {
      setScreen(tester, screen.$2);
      final fake = FakeBackend();
      final log = await runGame(tester, fake, (log) async {
        await enterGame(tester);
        drain(tester, log);
        await walkTutorial(tester);
        await tester.pump(const Duration(milliseconds: 300));
        await playAll(tester, fake, log, kFullPlan);

        // ---- 結算頁 ----
        expect(find.byType(MarketShoppingResultPage), findsOneWidget, reason: '10題後應到結算頁');
        expect(find.text('成績結算'), findsOneWidget);
        expect(find.text('$kExpectedScore'), findsWidgets, reason: '本次分數應為後端回傳的 raw_score');
        expect(find.textContaining('首次答對率 $kExpectedAccuracy%'), findsOneWidget);
        // 最高分：歷史含本次，max(55,70,82,68)=82
        expect(find.text('82'), findsWidgets);
        expect(find.text('很好！'), findsOneWidget); // 68 → good

        // 每一題的請求數量：start 1 + item/change 送出
        final starts = fake.requests.where((r) => r.url.path.endsWith('/sessions/')).length;
        expect(starts, 1);
        expect(fake.requests.where((r) => r.url.path.endsWith('/history/')).length, 1);
        expect(playedSounds, contains('audio/cashiering.mp3'));
        expect(playedSounds, contains('audio/no.mp3'));
        expect(playedSounds, contains('audio/correct.mp3'));

        // ---- 再玩一次 ----
        await tester.ensureVisible(find.text('再玩一次'));
        await tester.tap(find.text('再玩一次'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        expect(fake.sessionCounter, 2, reason: '再玩一次應開新 session');
        await closeTutorialWithX(tester);
        expect(find.byType(MarketShoppingMemorizePage), findsOneWidget);
        expect(find.text('第 1 / 10 題'), findsOneWidget);

        // 玩一題後從暫停選單退出
        await playQuestion(tester, fake, const QPlan(), log);
        expect(find.text('第 2 / 10 題'), findsOneWidget);
        await openPause(tester);
        await tester.tap(find.text('退出遊戲'));
        await settle(tester, 500);
        expect(find.text('進入市場買菜'), findsOneWidget); // 退回堆疊最底層
        expect(find.byType(MarketShoppingGamePage), findsNothing);
        drain(tester, log);
      });
      // ignore: avoid_print
      if (log.unreachable.isNotEmpty) print('[${screen.$1}] 點不到的選項：\n${log.unreachable.join('\n')}');
      // ignore: avoid_print
      if (log.errors.isNotEmpty) print('[${screen.$1}] 收集到的錯誤：\n$log\n詳細：\n${log.details.toSet().join('\n')}');
      // 除了找零頁 Column 的 overflow（已知 BUG，見下方斷言）之外，不應有其他錯誤
      final unexpected = [
        for (var i = 0; i < log.errors.length; i++)
          if (!(log.errors[i].contains('overflowed') &&
              i < log.details.length &&
              log.details[i].contains('market_shopping_checkout_page.dart')))
            log.errors[i],
      ];
      expect(unexpected, isEmpty, reason: log.toString());
      // [BUG] 找零頁是不能捲動的 Column：困難模式（4筆明細＋4個選項）在一般手機就溢出，
      // 小手機連簡單模式都溢出，而且最下面的選項點不到
      expect(log.overflows.where((e) => e.contains('/hard/')), isNotEmpty);
      if (screen.$2.height <= 640) {
        expect(log.overflows.where((e) => e.contains('/easy/')), isNotEmpty);
        expect(log.unreachable, isNotEmpty);
      } else {
        expect(log.unreachable, isEmpty);
      }
    });
  }

  // Demo 模式（12 月複賽）：admin_demo 帳號後端建立 session 回 total_questions = 3，
  // 第 3 題答完回 is_completed: true；前端照後端，不用自己判斷帳號
  testWidgets('Demo 模式：後端給 3 題 → 顯示「第 x / 3 題」、第 3 題答完到結算頁', (tester) async {
    setScreen(tester, const Size(360, 780));
    final fake = FakeBackend(total: 3);
    final log = await runGame(tester, fake, (log) async {
      await enterGame(tester);
      drain(tester, log);
      await walkTutorial(tester);
      await tester.pump(const Duration(milliseconds: 300));
      for (var n = 1; n <= 3; n++) {
        expect(find.text('第 $n / 3 題'), findsOneWidget);
        await playQuestion(tester, fake, const QPlan(), log);
      }
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(MarketShoppingResultPage), findsOneWidget, reason: '3 題後應到結算頁');
      expect(find.text('${fake.points}'), findsWidgets, reason: '分數照後端回傳');
      drain(tester, log);
    });
    expect(fake.violations, isEmpty, reason: fake.violations.join('\n'));
    expect(log.errors.where((e) => !e.contains('overflowed')), isEmpty, reason: log.toString());
  });

  testWidgets('已看過教學的旗標被忽略：每次開局都跳教學（設計如此，TutorialPreference 是死碼）', (tester) async {
    SharedPreferences.setMockInitialValues({'access_token': 'test-token', 'market_shopping_tutorial_seen': true});
    setScreen(tester, const Size(360, 780));
    final fake = FakeBackend();
    final log = await runGame(tester, fake, (log) async {
      await enterGame(tester);
      expect(find.byType(MarketShoppingTutorialDialog), findsOneWidget);
      // 教學打開時，背後還是 loading，不該開始倒數
      expect(find.byType(MarketShoppingMemorizePage), findsNothing);
      await tester.pump(const Duration(seconds: 15));
      expect(find.byType(MarketShoppingTutorialDialog), findsOneWidget);
      await closeTutorialWithX(tester);
      expect(find.byType(MarketShoppingMemorizePage), findsOneWidget);
    });
    expect(log.errors, isEmpty, reason: log.toString());
  });

  testWidgets('暫停選單：記憶頁「繼續遊戲」、選菜頁「玩法教學」、找零頁「重新開始」', (tester) async {
    setScreen(tester, const Size(360, 780));
    final fake = FakeBackend();
    final log = await runGame(tester, fake, (log) async {
      await enterGame(tester);
      await closeTutorialWithX(tester);

      // 記憶頁暫停 → 倒數停止 → 繼續遊戲 → 倒數恢復
      await tester.pump(const Duration(seconds: 3));
      await openPause(tester);
      await tester.pump(const Duration(seconds: 20));
      expect(find.byType(MarketShoppingMemorizePage), findsOneWidget, reason: '暫停中倒數不應走完');
      await tester.tap(find.text('繼續遊戲'));
      await settle(tester);
      await tester.pump(const Duration(seconds: 8));
      await tester.pump();
      expect(find.byType(MarketShoppingPlayPage), findsOneWidget, reason: '繼續後倒數應走完進到選菜');

      // 選菜頁暫停 → 玩法教學 → 關掉 → 還能作答
      await openPause(tester);
      await tester.tap(find.text('玩法教學'));
      await settle(tester);
      await closeTutorialWithX(tester);
      final q = fake.current;
      await selectFoods(tester, q.list);
      await confirmSelection(tester);
      await tester.pump(const Duration(milliseconds: 1600));
      expect(find.byType(MarketShoppingCheckoutPage), findsOneWidget);

      // 找零頁暫停 → 重新開始 → 新 session、再跳教學、回第1題
      await openPause(tester);
      await tester.tap(find.text('重新開始'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(fake.sessionCounter, 2);
      await walkTutorial(tester);
      expect(find.byType(MarketShoppingMemorizePage), findsOneWidget);
      expect(find.text('第 1 / 10 題'), findsOneWidget);
      drain(tester, log);
    });
    expect(log.errors, isEmpty, reason: log.toString());
  });

  testWidgets('[BUG] 記憶頁從暫停選單看「玩法教學」後，倒數不會恢復', (tester) async {
    setScreen(tester, const Size(360, 780));
    final fake = FakeBackend();
    final log = await runGame(tester, fake, (log) async {
      await enterGame(tester);
      await closeTutorialWithX(tester);
      await openPause(tester);
      await tester.tap(find.text('玩法教學'));
      await settle(tester);
      await closeTutorialWithX(tester);
      // 關掉教學後等了 30 秒，倒數條還是停住
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(
        find.byType(MarketShoppingMemorizePage),
        findsOneWidget,
        reason: '目前行為：倒數永遠停住（_controller 沒有 forward()），只能手動按「我記住了！」',
      );
    });
    expect(log.errors, isEmpty, reason: log.toString());
  });

  testWidgets('[BUG] 最後一題選菜錯滿3次（後端回 is_completed:true）→ 卡在選菜頁，永遠到不了結算頁', (tester) async {
    setScreen(tester, const Size(360, 780));
    final fake = FakeBackend(total: 2);
    final log = await runGame(tester, fake, (log) async {
      await enterGame(tester);
      await closeTutorialWithX(tester);
      await playQuestion(tester, fake, const QPlan(), log);
      await playQuestion(tester, fake, const QPlan(itemWrongTimes: 3), log);
      expect(fake.completed, isTrue, reason: '後端已判定整場結束');
      await tester.pump(const Duration(seconds: 10));
      expect(find.byType(MarketShoppingResultPage), findsNothing);
      expect(find.byType(MarketShoppingPlayPage), findsOneWidget);
      // 確認鈕永遠顯示「請稍候...」且 disabled
      expect(find.text('請稍候...'), findsOneWidget);
      final btn = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(btn.onPressed, isNull);
    });
    expect(log.errors, isEmpty, reason: log.toString());
  });

  testWidgets('選菜錯滿3次跳題時，玩家看不到答錯回饋（畫面直接切到下一題記憶頁）', (tester) async {
    setScreen(tester, const Size(360, 780));
    final fake = FakeBackend();
    final log = await runGame(tester, fake, (log) async {
      await enterGame(tester);
      await closeTutorialWithX(tester);
      final q = fake.current;
      await tester.tap(find.text('我記住了！'));
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await selectFoods(tester, [q.list.first, q.wrongCode]);
        await tester.tap(find.text('確認選好了'));
        await tester.pump();
        await tester.pump();
        if (i < 2) await tester.pump(const Duration(milliseconds: 2100));
      }
      // 第3次送出後同一個 frame 就已經是下一題記憶頁
      expect(find.byType(MarketShoppingPlayPage), findsNothing);
      expect(find.text('第 2 / 10 題'), findsOneWidget);
    });
    expect(log.errors, isEmpty, reason: log.toString());
  });

  testWidgets('[BUG] 選菜送出中按「重新開始」：舊請求回來後 setState after dispose，且舊 session 的下一題蓋掉新局', (tester) async {
    setScreen(tester, const Size(360, 780));
    final fake = FakeBackend();
    // 第3次送出（錯滿跳題）延遲 3 秒才回
    fake.itemDelay = (i) => i == 2 ? const Duration(seconds: 3) : Duration.zero;
    final log = await runGame(tester, fake, (log) async {
      await enterGame(tester);
      await closeTutorialWithX(tester);
      final q = fake.current;
      await tester.tap(find.text('我記住了！'));
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await selectFoods(tester, [q.list.first, q.wrongCode]);
        await tester.tap(find.text('確認選好了'));
        await tester.pump();
        await tester.pump();
        if (i < 2) await tester.pump(const Duration(milliseconds: 2100));
      }
      // 第3次還在送出中（轉圈），玩家按選單 → 重新開始
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await openPause(tester);
      await tester.tap(find.text('重新開始'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(fake.sessionCounter, 2);
      expect(find.byType(MarketShoppingTutorialDialog), findsOneWidget);
      // 舊請求回來
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      drain(tester, log);
      await closeTutorialWithX(tester);
      // 新局應該是第1題，但被舊 session 的第2題蓋掉
      expect(find.text('第 2 / 10 題'), findsOneWidget, reason: '目前行為：新局（session 2）卻顯示舊 session 的第2題');
      drain(tester, log);
    });
    // ignore: avoid_print
    print('收集到的錯誤：\n$log');
    expect(
      log.errors.any((e) => e.contains('setState() called after dispose()')),
      isTrue,
      reason: '目前行為：play page 在 await 後沒檢查 mounted 就 setState',
    );
  });

  testWidgets('[BUG] 開局 loading 中按返回離開，之後 API 失敗 → setState after dispose', (tester) async {
    setScreen(tester, const Size(360, 780));
    final fake = FakeBackend()
      ..startDelay = const Duration(seconds: 3)
      ..startFailures.add(FailMode.http500);
    final log = await runGame(tester, fake, (log) async {
      await tester.pumpWidget(harness());
      await tester.tap(find.text('進入市場買菜'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Android 返回鍵
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(MarketShoppingGamePage), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      drain(tester, log);
    });
    // ignore: avoid_print
    print('收集到的錯誤：\n$log');
    expect(log.errors.any((e) => e.contains('setState() called after dispose()')), isTrue);
  });

  for (final ui in const [('超小手機 320x568', Size(320, 568), 1.0), ('一般手機 360x780 + 系統字體 130%', Size(360, 780), 1.3)]) {
    testWidgets('UI 邊界（${ui.$1}）：教學、暫停選單、記憶/選菜/找零、結算頁', (tester) async {
      setScreen(tester, ui.$2);
      tester.platformDispatcher.textScaleFactorTestValue = ui.$3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final fake = FakeBackend(total: 1);
      final log = await runGame(tester, fake, (log) async {
        log.stage = '教學';
        await enterGame(tester);
        expect(find.byType(MarketShoppingTutorialDialog), findsOneWidget);
        final next = find.text('下一頁 →');
        if (isHittable(tester, next)) {
          await walkTutorial(tester);
        } else {
          log.unreachable.add('教學：「下一頁 →」按鈕點不到（y=${tester.getCenter(next).dy.toStringAsFixed(0)}），只能按右上角 X 關閉');
          await closeTutorialWithX(tester);
        }
        log.stage = '暫停選單';
        await openPause(tester);
        await tester.tap(find.text('繼續遊戲'));
        await settle(tester);
        log.stage = '記憶頁';
        final q = fake.current;
        await tester.tap(find.text('我記住了！'));
        await tester.pump();
        log.stage = '選菜頁';
        await selectFoods(tester, q.list);
        await confirmSelection(tester);
        log.stage = '找零頁';
        await tester.pump(const Duration(milliseconds: 1600));
        expect(find.byType(MarketShoppingCheckoutPage), findsOneWidget);
        await chooseChange(tester, q.change, log);
        log.stage = '結算頁';
        await tester.pump(const Duration(milliseconds: 1900));
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(MarketShoppingResultPage), findsOneWidget);
        drain(tester, log);
      });
      // ignore: avoid_print
      print('[${ui.$1}] 錯誤：\n$log\n點不到：${log.unreachable}\n${log.details.toSet().join('\n')}');
      expect(log.errors.where((e) => !e.contains('overflowed')), isEmpty, reason: log.toString());
      if (ui.$3 > 1.0) {
        // [BUG] 共用的「選單」按鈕在系統字體放大時橫向溢出（所有用 GameInProgressTopBar 的遊戲都會）
        expect(log.details.where((d) => d.contains('game_menu_button.dart:31')), isNotEmpty);
      } else {
        // [BUG] 教學對話框固定 420 高、不能捲動 → 超小手機「下一頁」按鈕被擠出畫面
        expect(log.details.where((d) => d.contains('market_shopping_tutorial_dialog.dart:50')), isNotEmpty);
        expect(log.unreachable.where((u) => u.contains('下一頁')), isNotEmpty);
      }
    });
  }

  group('API 失敗處理', () {
    for (final mode in const [FailMode.http500, FailMode.htmlBadGateway, FailMode.network, FailMode.notLoggedIn401]) {
      testWidgets('開局失敗（$mode）→ 錯誤畫面 → 重試成功', (tester) async {
        setScreen(tester, const Size(360, 780));
        final fake = FakeBackend()..startFailures.add(mode);
        final log = await runGame(tester, fake, (log) async {
          await enterGame(tester);
          expect(find.byIcon(Icons.wifi_off), findsOneWidget);
          expect(find.text('重試'), findsOneWidget);
          // ignore: avoid_print
          print('[$mode] 錯誤畫面訊息：${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}');
          // 錯誤畫面沒有任何返回/離開按鈕
          if (mode == FailMode.network) {
            // [BUG] replaceFirst('Exception: ') 把 'ClientException: ...' 切成 'Client...'
            expect(find.textContaining('ClientFailed host lookup'), findsOneWidget);
          }
          expect(find.byType(BackButton), findsNothing);
          expect(find.text('退出遊戲'), findsNothing);
          await tester.tap(find.text('重試'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await closeTutorialWithX(tester);
          expect(find.byType(MarketShoppingMemorizePage), findsOneWidget);
        });
        expect(log.errors, isEmpty, reason: log.toString());
      });
    }

    testWidgets('沒有登入 token → 錯誤畫面顯示請重新登入', (tester) async {
      SharedPreferences.setMockInitialValues({});
      setScreen(tester, const Size(360, 780));
      final fake = FakeBackend();
      final log = await runGame(tester, fake, (log) async {
        await enterGame(tester);
        expect(find.text('尚未登入，請重新登入'), findsOneWidget);
        expect(fake.requests, isEmpty);
      });
      expect(log.errors, isEmpty, reason: log.toString());
    });

    testWidgets('選菜/找零送出失敗 → SnackBar，可以重新送出；歷史成績失敗 → 結算頁顯示訊息', (tester) async {
      setScreen(tester, const Size(360, 780));
      final fake = FakeBackend(total: 1)
        ..itemFailures.addAll([FailMode.http500, FailMode.network])
        ..changeFailures.addAll([FailMode.htmlBadGateway])
        ..historyFailure = FailMode.http500;
      final log = await runGame(tester, fake, (log) async {
        await enterGame(tester);
        await closeTutorialWithX(tester);
        final q = fake.current;
        await tester.tap(find.text('我記住了！'));
        await tester.pump();
        await selectFoods(tester, q.list);
        await confirmSelection(tester);
        expect(find.text('送出失敗：伺服器錯誤'), findsOneWidget);
        expect(find.byType(MarketShoppingPlayPage), findsOneWidget);
        await dismissSnack(tester); // SnackBar 消失
        // 選擇還保留著，直接再按一次
        await confirmSelection(tester);
        expect(find.textContaining('送出失敗：'), findsOneWidget);
        await dismissSnack(tester);
        await confirmSelection(tester);
        await tester.pump(const Duration(milliseconds: 1600));
        expect(find.byType(MarketShoppingCheckoutPage), findsOneWidget);

        await chooseChange(tester, q.change);
        expect(find.text('送出失敗：發生錯誤（502）'), findsOneWidget);
        await dismissSnack(tester);
        await chooseChange(tester, q.change);
        await tester.pump(const Duration(milliseconds: 1900));
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(MarketShoppingResultPage), findsOneWidget);
        expect(find.text('無法載入歷史成績'), findsOneWidget);
        expect(find.text('10'), findsWidgets); // 1題首次答對=10分，最高分退回本次
        // 結算頁 → 退出遊戲
        await tester.ensureVisible(find.text('退出遊戲'));
        await tester.tap(find.text('退出遊戲'));
        await settle(tester, 500);
        expect(find.text('進入市場買菜'), findsOneWidget); // 退回堆疊最底層
        drain(tester, log);
      });
      expect(log.errors, isEmpty, reason: log.toString());
    });
  });
}
