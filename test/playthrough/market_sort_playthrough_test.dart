// 整理菜籃（market_sort）完整遊玩流程測試（QA 用）
//
// 用 widget test 模擬長者實際操作：從遊戲首頁點「執行功能」進入 → 倒數 →
// 28 題拖曳作答（含答對、答錯、閒置提示）→ 送出成績 → 結算頁 →
// 再玩一次／退出遊戲，以及暫停選單、玩法教學、API 失敗、小螢幕版面。
//
// 測試名稱以「BUG重現」開頭的，是「確認 bug 存在」的測試：
// 斷言的是目前（有問題的）行為，bug 修好後這些測試會失敗，屆時改成斷言正確行為即可。

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:light_memory/main.dart';
import 'package:light_memory/core/constants/api_constants.dart';
import 'package:light_memory/core/services/audio_service.dart' as core_audio;
import 'package:light_memory/features/game/market_sort/controllers/market_sort_game_controller.dart';
import 'package:light_memory/features/game/market_sort/models/game_rule.dart';
import 'package:light_memory/features/game/market_sort/models/market_sort_item.dart';
import 'package:light_memory/features/game/market_sort/models/market_sort_item_attributes.dart';
import 'package:light_memory/features/game/market_sort/models/market_sort_item_pool.dart';
import 'package:light_memory/features/game/market_sort/models/trial_result.dart';
import 'package:light_memory/features/game/market_sort/services/market_sort_answer_judge.dart';
import 'package:light_memory/features/game/market_sort/services/market_sort_api_service.dart';
import 'package:light_memory/features/game/market_sort/widgets/rule_badge.dart';
import 'package:light_memory/features/game/market_sort/widgets/tutorial_modal.dart';
import 'package:light_memory/features/game/market_sort/widgets/result_history_chart.dart';
import 'package:light_memory/features/game/widgets/game_pause.dart';
import '../support/test_home_screen.dart';
import 'package:light_memory/screens/market_sort_game_screen.dart';
import 'package:light_memory/screens/market_sort_result_screen.dart';

// ───────────────────────── 假資料與共用工具 ─────────────────────────

const _submitUrl = '${ApiConstants.serverUrl}/api/games/market-sort/submit/';
const _configUrl = '${ApiConstants.serverUrl}/api/games/market-sort/config/';

String _okBody({
  int current = 82,
  int highest = 90,
  List<int> recent = const [60, 70, 75, 80],
  String tier = 'good',
}) => jsonEncode({
  'success': true,
  'data': {
    'current_score': current,
    'highest_score': highest,
    'recent_scores': recent,
    'encouragement_tier': tier,
  },
  'error': null,
});

/// 每個測試可以換掉送出成績的回應方式
typedef SubmitHandler = Future<http.Response> Function(http.Request req);

class _Backend {
  final List<http.Request> submits = [];
  final List<http.Request> others = [];
  SubmitHandler onSubmit = (_) async =>
      http.Response(_okBody(), 200, headers: _jsonHeaders);

  /// config/ 回的題數；null 時 config/ 跟其他網址一樣回 404（前端要照原本 28 題）
  int? configTotal;

  MockClient client() => MockClient((req) async {
    if (req.url.toString() == _configUrl && configTotal != null) {
      return http.Response(
        jsonEncode({
          'success': true,
          'data': {'total_questions': configTotal},
          'error': null,
        }),
        200,
        headers: _jsonHeaders,
      );
    }
    if (req.url.toString() == _submitUrl) {
      submits.add(req);
      return onSubmit(req);
    }
    others.add(req);
    return http.Response(
      jsonEncode({
        'success': false,
        'data': null,
        'error': {'code': 'NOT_FOUND', 'message': 'not found'},
      }),
      404,
      headers: _jsonHeaders,
    );
  });

  List<Map<String, dynamic>> questionsOf(int submitIndex) {
    final body = jsonDecode(submits[submitIndex].body) as Map<String, dynamic>;
    return (body['questions'] as List).cast<Map<String, dynamic>>();
  }
}

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

/// 每個籃子在畫面上的文字（BasketRow 顯示 "label emoji"）
const Map<Object, String> _basketText = {
  ItemCategory.vegetable: '蔬菜 🥬',
  ItemCategory.fruit: '水果 🍎',
  ItemCategory.meatEgg: '肉蛋 🍗',
  ItemColor.red: '紅色 🔴',
  ItemColor.green: '綠色 🟢',
  ItemColor.yellow: '黃色 🟡',
  ItemFreshness.raw: '生食 🥗',
  ItemFreshness.cooked: '熟食 🍳',
};

List<Object> _valuesFor(GameRule rule) {
  switch (rule) {
    case GameRule.species:
      return ItemCategory.values;
    case GameRule.color:
      return ItemColor.values;
    case GameRule.freshness:
      return ItemFreshness.values;
  }
}

/// 擋掉 audioplayers 的 platform channel（測試環境沒有原生端），其他 channel 照常
void _stubPlatformChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.allMessagesHandler = (channel, handler, message) {
    if (channel.startsWith('xyz.luan/audioplayers')) {
      return Future.value(
        const StandardMethodCodec().encodeSuccessEnvelope(null),
      );
    }
    if (handler != null) return handler(message);
    return null;
  };
}

/// 收集畫面上發生的所有 Flutter 錯誤（overflow、setState after dispose 等），
/// 不讓第一個錯誤就中斷測試，最後統一斷言
class _ErrorSink {
  final List<String> errors = [];
  FlutterExceptionHandler? _old;
  void attach() {
    _old = FlutterError.onError;
    FlutterError.onError = (e) {
      // 當下就轉成文字（之後 widget 被移除再 toString 會再丟錯）
      String first;
      try {
        first = e.exceptionAsString().split('\n').first;
      } catch (_) {
        first = e.exception.runtimeType.toString();
      }
      String? loc;
      try {
        loc = RegExp(
          r'lib/[^\s:]+\.dart:\d+',
        ).firstMatch(e.toString())?.group(0);
      } catch (_) {}
      errors.add(loc == null ? first : '$first  @$loc');
    };
  }

  void detach() => FlutterError.onError = _old;

  List<String> get summaries => List.unmodifiable(errors);
}

/// 畫面設定：預設一般手機 360x780（1080x2340 @3x）
void _setSurface(WidgetTester tester, Size logical, {double dpr = 3}) {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = logical * dpr;
  addTearDown(tester.view.reset);
}

/// 以 App 真正的 onGenerateRoute 建立 MaterialApp，首頁放 TestHomeScreen
Future<void> _pumpApp(WidgetTester tester, {Widget? home}) async {
  late RouteFactory appRoutes;
  late ThemeData theme;
  await tester.pumpWidget(
    Builder(
      builder: (ctx) {
        final app = const MyApp().build(ctx) as MaterialApp;
        appRoutes = app.onGenerateRoute!;
        theme = app.theme!;
        return const SizedBox();
      },
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      onGenerateRoute: appRoutes,
      home: home ?? const TestHomeScreen(),
    ),
  );
  await tester.pump();
}

/// 從遊戲首頁點「執行功能」進入整理菜籃
Future<void> _enterFromHome(WidgetTester tester) async {
  await tester.tap(find.text('執行功能'));
  await tester.pump(); // push
  await tester.pump(const Duration(milliseconds: 800)); // 轉場動畫
  expect(find.byType(MarketSortGameScreen), findsOneWidget);
}

/// 跑完 3-2-1 倒數
Future<void> _finishCountdown(WidgetTester tester) async {
  expect(find.text('準備開始'), findsOneWidget);
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
  await tester.pump();
  expect(find.text('準備開始'), findsNothing);
}

GameRule _currentRule(WidgetTester tester) {
  final texts = tester
      .widgetList<Text>(
        find.descendant(
          of: find.byType(RuleBadge),
          matching: find.byType(Text),
        ),
      )
      .map((t) => t.data)
      .toList();
  return GameRule.values.firstWhere((r) => texts.contains(r.label));
}

MarketSortItem _currentItem(WidgetTester tester) {
  final cardTexts = tester
      .widgetList<Text>(
        find.descendant(
          of: find.byWidgetPredicate((w) => w is Draggable<MarketSortItem>),
          matching: find.byType(Text),
        ),
      )
      .map((t) => t.data)
      .toSet();
  return marketSortItemPool.firstWhere((i) => cardTexts.contains(i.name));
}

String _progressText(WidgetTester tester) {
  final f = find.textContaining(RegExp(r'^\d+/\d+$'));
  return tester.widget<Text>(f).data!;
}

/// 把畫面中間的商品拖進指定籃子
Future<void> _dragItemTo(WidgetTester tester, Object bucketValue) async {
  final from = tester.getCenter(
    find.byWidgetPredicate((w) => w is Draggable<MarketSortItem>),
  );
  final to = tester.getCenter(find.text(_basketText[bucketValue]!));
  final g = await tester.startGesture(from);
  await tester.pump();
  await g.moveBy(const Offset(0, 30));
  await tester.pump();
  await g.moveTo(to);
  await tester.pump();
  await g.up();
  await tester.pump();
}

/// 一題的作答紀錄（用來和送出的 payload 比對）
class _Answered {
  final int number;
  final GameRule rule;
  final MarketSortItem item;
  final bool correct;
  _Answered(this.number, this.rule, this.item, this.correct);
}

/// 等目前題目進入可作答狀態（鎖定最長 2 秒）後作答，再等 700ms 閃爍結束
Future<_Answered> _answerCurrent(
  WidgetTester tester, {
  required bool correct,
  bool waitIdleFirst = false,
}) async {
  await tester.pump(const Duration(milliseconds: 2100));
  final number = int.parse(_progressText(tester).split('/').first);
  final rule = _currentRule(tester);
  final item = _currentItem(tester);

  if (waitIdleFirst) {
    // 5 秒沒動作要出現閒置提示
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('請把商品拖到正確的籃子裡！'), findsOneWidget);
  }

  final right = item.valueFor(rule)!;
  final target = correct
      ? right
      : _valuesFor(rule).firstWhere((v) => v != right);
  await _dragItemTo(tester, target);
  // 閃爍 700ms
  await tester.pump(const Duration(milliseconds: 750));
  return _Answered(number, rule, item, correct);
}

/// 依作答紀錄算出「理想上」送給後端的 questions
List<Map<String, dynamic>> _expectedPayload(List<_Answered> answered) {
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < answered.length; i++) {
    final a = answered[i];
    final prev = i == 0 ? null : answered[i - 1].rule;
    final isRepeat = i == 0 || prev == a.rule;
    out.add({
      'question_index': a.number,
      'is_correct': a.correct,
      'trial_type': isRepeat ? 'repeat' : 'switch',
      // 拖到的籃子值和上一題規則的屬性值型別不同，persistent 不可能成立（見 BUG 測試）
      'error_type': a.correct ? null : 'random',
    });
  }
  return out;
}

/// 玩完全部 28 題；[wrongAt] 指定哪些題號故意答錯，[idleAt] 先等閒置提示再作答
Future<List<_Answered>> _playAll(
  WidgetTester tester, {
  Set<int> wrongAt = const {},
  Set<int> idleAt = const {},
}) async {
  final answered = <_Answered>[];
  for (var q = 1; q <= 28; q++) {
    expect(_progressText(tester), '$q/28', reason: '第 $q 題題號顯示錯誤');
    answered.add(
      await _answerCurrent(
        tester,
        correct: !wrongAt.contains(q),
        waitIdleFirst: idleAt.contains(q),
      ),
    );
  }
  return answered;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'access_token': 'test'});
    _stubPlatformChannels();
    // 遊戲內音效在測試環境無法播放（AudioCache 需要 path_provider 原生端），
    // 這裡關掉，避免 unawaited 的播放錯誤污染測試結果。實機不受影響。
    core_audio.AudioService.setEnabled(false);
  });

  // ───────────────────────── 1. 完整遊玩流程 ─────────────────────────

  testWidgets('完整流程：首頁進入 → 28 題（答對/答錯/閒置）→ 結算頁 → 再玩一次 → 暫停退出', (tester) async {
    _setSurface(tester, const Size(360, 780));
    final backend = _Backend();
    final sink = _ErrorSink()..attach();
    try {
      await http.runWithClient(() async {
        await _pumpApp(tester);
        await _enterFromHome(tester);

        // 第一次進入遊戲時沒有自動出現教學（見報告）
        expect(find.byType(TutorialModal), findsNothing);

        await _finishCountdown(tester);
        expect(_progressText(tester), '1/28');
        expect(_currentRule(tester), GameRule.freshness); // 第一階段生熟

        final wrongAt = {2, 6, 11, 16, 17, 20, 25, 28};
        final answered = await _playAll(tester, wrongAt: wrongAt, idleAt: {3});

        // 前三階段固定，第四階段 13 題
        expect(
          answered.take(5).every((a) => a.rule == GameRule.freshness),
          isTrue,
        );
        expect(
          answered.skip(5).take(5).every((a) => a.rule == GameRule.species),
          isTrue,
        );
        expect(
          answered.skip(10).take(5).every((a) => a.rule == GameRule.color),
          isTrue,
        );

        // 送出中 → 回應 → 結算頁
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        expect(backend.submits, hasLength(1), reason: '只應送出一次成績');

        final req = backend.submits.single;
        expect(req.headers['Authorization'], 'Bearer test');
        expect(req.headers['Content-Type'], startsWith('application/json'));
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['is_complete'], isTrue);
        expect(body['session_id'], isA<String>());
        final qs = backend.questionsOf(0);
        expect(qs, hasLength(28));
        final expected = _expectedPayload(answered);
        for (var i = 0; i < 28; i++) {
          final got = Map.of(qs[i])..remove('reaction_time_ms');
          expect(got, expected[i], reason: '第 ${i + 1} 題 payload 不符');
          expect(qs[i]['reaction_time_ms'], isA<int>());
          expect(qs[i]['reaction_time_ms'] as int, greaterThanOrEqualTo(0));
        }
        expect(
          qs.where((q) => q['is_correct'] == true).length,
          28 - wrongAt.length,
        );

        // 結算頁
        expect(find.byType(MarketSortResultScreen), findsOneWidget);
        expect(find.text('成績結算'), findsOneWidget);
        expect(find.text('很好！'), findsOneWidget); // tier = good
        expect(find.text('82'), findsWidgets);
        expect(find.text('90'), findsOneWidget);
        expect(find.byType(ResultHistoryChart), findsOneWidget);
        expect(find.text('本次'), findsOneWidget);
        expect(find.text('前4次'), findsOneWidget);

        // 再玩一次 → 新的一局重新倒數，從 1/28 開始
        await tester.tap(find.text('再玩一次'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        expect(find.byType(MarketSortResultScreen), findsNothing);
        await _finishCountdown(tester);
        expect(_progressText(tester), '1/28');

        // 暫停 → 退出遊戲：應回到首頁（堆疊最底層）
        await tester.pump(const Duration(milliseconds: 2100));
        await tester.tap(find.text('選單'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(GamePause), findsOneWidget);
        await tester.tap(find.text('退出遊戲'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        expect(find.byType(MarketSortGameScreen), findsNothing);
        expect(find.byType(TestHomeScreen), findsOneWidget);
        expect(backend.submits, hasLength(1), reason: '中途退出不應再送一次完整成績');
      }, backend.client);
    } finally {
      sink.detach();
    }
    expect(sink.summaries, isEmpty, reason: sink.summaries.join('\n'));
  });

  // ───────────────────────── Demo 模式（12 月複賽）─────────────────────────

  testWidgets('Demo 模式：config/ 給 3 題 → 只出前 3 題、送出 3 題 → 結算頁 80 分；重新開始也維持 3 題', (tester) async {
    _setSurface(tester, const Size(360, 780));
    final backend = _Backend()
      ..configTotal = 3
      ..onSubmit = (_) async => http.Response(
        _okBody(current: 80, highest: 80, recent: const [], tier: 'good'),
        201,
        headers: _jsonHeaders,
      );
    final sink = _ErrorSink()..attach();
    try {
      await http.runWithClient(() async {
        await _pumpApp(tester);
        await _enterFromHome(tester);
        await _finishCountdown(tester);
        expect(_progressText(tester), '1/3');

        // 玩一題後按「重新開始」：新的一局一樣只有 3 題
        await _answerCurrent(tester, correct: true);
        expect(_progressText(tester), '2/3');
        await tester.pump(const Duration(milliseconds: 2100));
        await tester.tap(find.text('選單'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('重新開始'));
        await tester.pump();
        await _finishCountdown(tester);
        expect(_progressText(tester), '1/3');

        final answered = <_Answered>[];
        for (var q = 1; q <= 3; q++) {
          expect(_progressText(tester), '$q/3');
          answered.add(await _answerCurrent(tester, correct: q != 2));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));

        expect(backend.submits, hasLength(1));
        final body = jsonDecode(backend.submits.single.body) as Map<String, dynamic>;
        expect(body['is_complete'], isTrue);
        final qs = backend.questionsOf(0);
        expect(qs.map((q) => q['question_index']), [1, 2, 3]);
        expect(answered.every((a) => a.rule == GameRule.freshness), isTrue,
            reason: '照原本順序取前 3 題（第一階段生熟）');
        expect(find.byType(MarketSortResultScreen), findsOneWidget);
        expect(find.text('80'), findsWidgets);
      }, backend.client);
    } finally {
      sink.detach();
    }
    expect(sink.summaries, isEmpty, reason: sink.summaries.join('\n'));
  });

  // ───────────────────────── 2. 暫停選單各按鈕 ─────────────────────────

  testWidgets('暫停選單：繼續遊戲／玩法教學／重新開始／Android 返回鍵關閉選單', (tester) async {
    _setSurface(tester, const Size(360, 780));
    final backend = _Backend();
    final sink = _ErrorSink()..attach();
    try {
      await http.runWithClient(() async {
        await _pumpApp(tester, home: const MarketSortGameScreen());
        await _finishCountdown(tester);

        // 先答 3 題
        for (var i = 0; i < 3; i++) {
          await _answerCurrent(tester, correct: true);
        }
        await tester.pump(const Duration(milliseconds: 2100));
        expect(_progressText(tester), '4/28');

        Future<void> openMenu() async {
          await tester.tap(find.text('選單'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(GamePause), findsOneWidget);
        }

        // 繼續遊戲 → 倒數後回到同一題
        await openMenu();
        await tester.tap(find.text('繼續遊戲'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await _finishCountdown(tester);
        expect(_progressText(tester), '4/28');

        // 玩法教學 → 教學彈窗兩頁 → 開始遊戲 → 倒數
        await tester.pump(const Duration(milliseconds: 2100));
        await openMenu();
        await tester.tap(find.text('玩法教學'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(TutorialModal), findsOneWidget);
        expect(find.text('怎麼玩'), findsOneWidget);
        await tester.tap(find.text('下一頁 →'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        expect(find.text('遊戲共分四階段'), findsOneWidget);
        await tester.tap(find.byIcon(Icons.arrow_back));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        expect(find.text('怎麼玩'), findsOneWidget);
        await tester.tap(find.text('下一頁 →'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        await tester.tap(find.text('開始遊戲 →'));
        await tester.pump();
        expect(find.byType(TutorialModal), findsNothing);
        await _finishCountdown(tester);
        expect(_progressText(tester), '4/28');

        // 教學彈窗的 X 關閉
        await tester.pump(const Duration(milliseconds: 2100));
        await openMenu();
        await tester.tap(find.text('玩法教學'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byIcon(Icons.close));
        await tester.pump();
        await _finishCountdown(tester);

        // Android 返回鍵關掉暫停選單 → 視為繼續遊戲（會倒數）
        await tester.pump(const Duration(milliseconds: 2100));
        await openMenu();
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(GamePause), findsNothing);
        await _finishCountdown(tester);
        expect(_progressText(tester), '4/28');

        // 重新開始 → 回到 1/28，之後還能正常玩完並送出 28 題
        await tester.pump(const Duration(milliseconds: 2100));
        await openMenu();
        await tester.tap(find.text('重新開始'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await _finishCountdown(tester);
        expect(_progressText(tester), '1/28');
        expect(_currentRule(tester), GameRule.freshness);

        final answered = await _playAll(tester, wrongAt: {1, 27});
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        expect(backend.submits, hasLength(1));
        final qs = backend.questionsOf(0);
        expect(
          qs.map((q) => q['question_index']),
          List.generate(28, (i) => i + 1),
        );
        expect(qs.where((q) => q['is_correct'] == false).length, 2);
        expect(answered.length, 28);
        expect(find.byType(MarketSortResultScreen), findsOneWidget);
      }, backend.client);
    } finally {
      sink.detach();
    }
    // 教學彈窗的 2px 溢出由獨立的 BUG重現 測試涵蓋，這裡排除
    final others = sink.summaries
        .where((e) => !e.contains('tutorial_modal.dart'))
        .toList();
    expect(others, isEmpty, reason: others.join('\n'));
  });

  // ───────────────────────── 3. 結算頁「退出遊戲」 ─────────────────────────

  testWidgets('結算頁「退出遊戲」回到首頁', (tester) async {
    _setSurface(tester, const Size(360, 780));
    final sink = _ErrorSink()..attach();
    try {
      // 首頁在堆疊最底層，結算頁疊在上面（退出是 popUntil isFirst，首頁要存在才有地方回）
      await _pumpApp(tester);
      tester.state<NavigatorState>(find.byType(Navigator)).push(
        MaterialPageRoute(
          builder: (_) => MarketSortResultScreen(
            result: MarketSortSubmitResult(
              currentScore: 40,
              highestScore: 95,
              recentScores: const [],
              encouragementTier: 'keep_trying',
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('沒關係再加油！'), findsOneWidget);
      // 第一次玩（沒有歷史分數）時不顯示圖表
      expect(find.byType(ResultHistoryChart), findsNothing);
      await tester.tap(find.text('退出遊戲'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.byType(TestHomeScreen), findsOneWidget);
      expect(find.byType(MarketSortResultScreen), findsNothing);
    } finally {
      sink.detach();
    }
    expect(sink.summaries, isEmpty, reason: sink.summaries.join('\n'));
  });

  testWidgets('結算頁「退出遊戲」直接回到最底層的主畫面（popUntil isFirst）', (tester) async {
    _setSurface(tester, const Size(360, 780));
    // 模擬真實 App：主畫面 → 結算頁（主畫面是堆疊最底層）
    await _pumpApp(tester, home: const Scaffold(body: Text('主畫面')));
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(
      MaterialPageRoute(
        builder: (_) => MarketSortResultScreen(
          result: MarketSortSubmitResult(
            currentScore: 70,
            highestScore: 80,
            recentScores: const [50],
            encouragementTier: 'good',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    await tester.tap(find.text('退出遊戲'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byType(MarketSortResultScreen), findsNothing);
    expect(find.text('主畫面'), findsOneWidget);
    expect(nav.canPop(), isFalse);
  });

  // ───────────────────────── 4. API 失敗處理 ─────────────────────────

  testWidgets('送出成績 500 → 顯示重試 SnackBar → 按重試成功 → 結算頁', (tester) async {
    _setSurface(tester, const Size(360, 780));
    final backend = _Backend();
    var call = 0;
    backend.onSubmit = (req) async {
      call++;
      if (call == 1) {
        return http.Response(
          jsonEncode({
            'success': false,
            'data': null,
            'error': {'code': 'SERVER_ERROR', 'message': '伺服器錯誤'},
          }),
          500,
          headers: _jsonHeaders,
        );
      }
      if (call == 2) {
        throw http.ClientException('Connection refused');
      }
      return http.Response(_okBody(tier: 'great'), 200, headers: _jsonHeaders);
    };
    final sink = _ErrorSink()..attach();
    try {
      await http.runWithClient(() async {
        await _pumpApp(tester, home: const MarketSortGameScreen());
        await _finishCountdown(tester);
        await _playAll(tester);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        expect(find.text('成績送出失敗，請確認網路後再試一次'), findsOneWidget);
        expect(find.byType(MarketSortResultScreen), findsNothing);

        // 第 1 次重試：網路錯誤
        await tester.tap(find.text('重試'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(backend.submits, hasLength(2));
        expect(find.text('成績送出失敗，請確認網路後再試一次'), findsWidgets);

        // 第 2 次重試：成功
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.text('重試').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(backend.submits, hasLength(3));
        // 三次送出的 session_id 要相同（避免後端重複記錄）
        final ids = backend.submits
            .map((r) => jsonDecode(r.body)['session_id'])
            .toSet();
        expect(ids, hasLength(1));
        expect(find.byType(MarketSortResultScreen), findsOneWidget);
        expect(find.text('非常棒！'), findsOneWidget);
        // SnackBar 不應帶到結算頁（10 秒長的 SnackBar 由 ScaffoldMessenger 管）
        await tester.pump(const Duration(seconds: 11));
      }, backend.client);
    } finally {
      sink.detach();
    }
    expect(sink.summaries, isEmpty, reason: sink.summaries.join('\n'));
  });

  testWidgets('BUG重現：送出失敗的 SnackBar 被滑掉後畫面卡死（選單按不到、不能作答、沒有重試入口）', (
    tester,
  ) async {
    _setSurface(tester, const Size(360, 780));
    final backend = _Backend()
      ..onSubmit = (_) async =>
          http.Response('<html>502 Bad Gateway</html>', 502);
    final sink = _ErrorSink()..attach();
    try {
      await http.runWithClient(() async {
        await _pumpApp(tester, home: const MarketSortGameScreen());
        await _finishCountdown(tester);
        await _playAll(tester);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('成績送出失敗，請確認網路後再試一次'), findsOneWidget);

        // Flutter 3.44：有 action 的 SnackBar 預設 persist=true，duration 10 秒不會生效，
        // 一直等也還在（好事：重試按鈕不會自己消失）
        for (var i = 0; i < 150; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('重試'), findsOneWidget);

        // 但長者若把 SnackBar 往下滑掉（預設 dismissDirection = down），重試入口就沒了
        await tester.fling(find.byType(SnackBar), const Offset(0, 300), 1000);
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('重試'), findsNothing);
        expect(find.byType(MarketSortResultScreen), findsNothing);

        // 選單按鈕被 AbsorbPointer 吃掉（phase 停在 resolved）
        await tester.tap(find.text('選單'), warnIfMissed: false);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(GamePause), findsNothing);

        // 等再久也不會自己恢復
        await tester.pump(const Duration(seconds: 30));
        expect(backend.submits, hasLength(1));
        expect(find.byType(MarketSortGameScreen), findsOneWidget);
        expect(_progressText(tester), '28/28');
      }, backend.client);
    } finally {
      sink.detach();
    }
    expect(sink.summaries, isEmpty, reason: sink.summaries.join('\n'));
  });

  testWidgets('沒有登入 token / 後端回傳非預期資料 → 顯示錯誤 SnackBar，不 crash', (tester) async {
    SharedPreferences.setMockInitialValues({}); // 沒有 token
    _setSurface(tester, const Size(360, 780));
    final backend = _Backend();
    var call = 0;
    backend.onSubmit = (_) async {
      call++;
      // 分數是小數、recent_scores 是 null：fromJson 的 `as int` / `as List` 會丟 TypeError
      return http.Response(
        jsonEncode({
          'success': true,
          'data': {
            'current_score': 82.5,
            'highest_score': 90,
            'recent_scores': null,
            'encouragement_tier': 'good',
          },
        }),
        200,
        headers: _jsonHeaders,
      );
    };
    final sink = _ErrorSink()..attach();
    try {
      await http.runWithClient(() async {
        await _pumpApp(tester, home: const MarketSortGameScreen());
        await _finishCountdown(tester);
        await _playAll(tester);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        // 沒 token 時不會打 API
        expect(backend.submits, isEmpty);
        expect(find.text('成績送出失敗，請確認網路後再試一次'), findsOneWidget);

        // 補上 token 再按重試 → 後端回非預期格式
        SharedPreferences.setMockInitialValues({'access_token': 'test'});
        await tester.tap(find.text('重試'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(call, 1);
        expect(find.byType(MarketSortResultScreen), findsNothing);
        expect(find.text('成績送出失敗，請確認網路後再試一次'), findsWidgets);
        await tester.pump(const Duration(seconds: 11));
      }, backend.client);
    } finally {
      sink.detach();
    }
    expect(sink.summaries, isEmpty, reason: sink.summaries.join('\n'));
  });

  testWidgets('送出成績時離開畫面（Android 返回鍵）不會 setState after dispose', (
    tester,
  ) async {
    _setSurface(tester, const Size(360, 780));
    final backend = _Backend();
    final gate = Completer<http.Response>();
    backend.onSubmit = (_) => gate.future;
    final sink = _ErrorSink()..attach();
    try {
      await http.runWithClient(() async {
        await _pumpApp(tester);
        await _enterFromHome(tester);
        await _finishCountdown(tester);
        await _playAll(tester);
        await tester.pump();
        expect(backend.submits, hasLength(1));
        // 回應還沒回來就按返回鍵
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        expect(find.byType(TestHomeScreen), findsOneWidget);
        gate.complete(http.Response(_okBody(), 200, headers: _jsonHeaders));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        // 已經離開，不應再跳到結算頁
        expect(find.byType(MarketSortResultScreen), findsNothing);
      }, backend.client);
    } finally {
      sink.detach();
    }
    expect(sink.summaries, isEmpty, reason: sink.summaries.join('\n'));
  });

  testWidgets('遊戲進行中按 Android 返回鍵會直接離開遊戲（沒有 PopScope／確認）', (tester) async {
    _setSurface(tester, const Size(360, 780));
    final backend = _Backend();
    final sink = _ErrorSink()..attach();
    try {
      await http.runWithClient(() async {
        await _pumpApp(tester);
        await _enterFromHome(tester);
        // 倒數中按返回
        await tester.pump(const Duration(milliseconds: 500));
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump(const Duration(seconds: 4)); // 讓倒數的 Future 跑完
        expect(find.byType(MarketSortGameScreen), findsNothing);

        // 作答閃爍 700ms 期間按返回
        await _enterFromHome(tester);
        await _finishCountdown(tester);
        await tester.pump(const Duration(milliseconds: 2100));
        final item = _currentItem(tester);
        await _dragItemTo(tester, item.valueFor(_currentRule(tester))!);
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump(const Duration(seconds: 3));
        expect(find.byType(MarketSortGameScreen), findsNothing);

        // 可作答狀態（閒置計時器跑著）按返回
        await _enterFromHome(tester);
        await _finishCountdown(tester);
        await tester.pump(const Duration(milliseconds: 2100));
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump(const Duration(seconds: 6));
        expect(find.byType(MarketSortGameScreen), findsNothing);
        expect(backend.submits, isEmpty);
      }, backend.client);
    } finally {
      sink.detach();
    }
    expect(sink.summaries, isEmpty, reason: sink.summaries.join('\n'));
  });

  // ───────────────────────── 5. 小螢幕版面 ─────────────────────────

  /// 檢查目前畫面上每個籃子標籤是否完整落在螢幕內
  List<String> basketsOutOfScreen(WidgetTester tester, Size screen) {
    final out = <String>[];
    for (final entry in _basketText.entries) {
      final f = find.text(entry.value);
      if (f.evaluate().isEmpty) continue;
      final r = tester.getRect(f);
      if (r.left < 0 ||
          r.top < 0 ||
          r.right > screen.width ||
          r.bottom > screen.height) {
        out.add('${entry.value} @ $r');
      }
    }
    return out;
  }

  for (final size in const [Size(360, 780), Size(412, 915)]) {
    testWidgets(
      '版面：${size.width.toInt()}x${size.height.toInt()} 三種規則＋閒置提示＋結算頁皆不溢出、籃子都在畫面內',
      (tester) async {
        _setSurface(tester, size);
        final backend = _Backend();
        final sink = _ErrorSink()..attach();
        final problems = <String>[];
        try {
          await http.runWithClient(() async {
            await _pumpApp(tester, home: const MarketSortGameScreen());
            await _finishCountdown(tester);
            for (var q = 1; q <= 16; q++) {
              await tester.pump(const Duration(milliseconds: 2100));
              problems.addAll(
                basketsOutOfScreen(tester, size).map((e) => 'Q$q 籃子超出：$e'),
              );
              expect(_progressText(tester), '$q/28');
              await _answerCurrent(
                tester,
                correct: true,
                waitIdleFirst: q == 1 || q == 6 || q == 11,
              );
            }
          }, backend.client);
          await _pumpApp(
            tester,
            home: MarketSortResultScreen(
              result: MarketSortSubmitResult(
                currentScore: 100,
                highestScore: 100,
                recentScores: const [0, 35, 100, 64],
                encouragementTier: 'great',
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
        } finally {
          sink.detach();
        }
        problems.addAll(sink.summaries);
        expect(problems, isEmpty, reason: problems.join('\n'));
      },
    );
  }

  testWidgets('BUG重現：教學彈窗第 1 頁在固定 320x600 容器內溢出（與螢幕大小無關）', (tester) async {
    _setSurface(tester, const Size(412, 915));
    final sink = _ErrorSink()..attach();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TutorialModal(onClose: () {})),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
    } finally {
      sink.detach();
    }
    expect(
      sink.summaries,
      contains(
        allOf(
          contains('RenderFlex overflowed'),
          contains('tutorial_modal.dart'),
        ),
      ),
    );
  });

  testWidgets('BUG重現：360x640 遊戲頁直向空間不足，底部溢出（籃子仍可拖到，勉強可玩）', (tester) async {
    const size = Size(360, 640);
    _setSurface(tester, size);
    final backend = _Backend();
    final sink = _ErrorSink()..attach();
    try {
      await http.runWithClient(() async {
        await _pumpApp(tester, home: const MarketSortGameScreen());
        await _finishCountdown(tester);
        // 三個規則各玩到：1~5 生熟、6~10 種類、11~15 顏色
        for (var q = 1; q <= 16; q++) {
          expect(_progressText(tester), '$q/28');
          await _answerCurrent(tester, correct: true);
        }
      }, backend.client);
    } finally {
      sink.detach();
    }
    // ignore: avoid_print
    print('[360x640] ${sink.summaries.toSet()}');
    expect(
      sink.summaries,
      contains(
        allOf(
          contains('RenderFlex overflowed'),
          contains('market_sort_game_screen.dart'),
        ),
      ),
    );
  });

  testWidgets('BUG重現：320x568 遊戲頁溢出約 54px，籃子標籤被擠出畫面（看不到哪個籃子是哪一類）', (
    tester,
  ) async {
    const size = Size(320, 568);
    _setSurface(tester, size);
    final backend = _Backend();
    final sink = _ErrorSink()..attach();
    late List<String> outside;
    try {
      await http.runWithClient(() async {
        await _pumpApp(tester, home: const MarketSortGameScreen());
        await _finishCountdown(tester);
        await tester.pump(const Duration(milliseconds: 2100));
        outside = basketsOutOfScreen(tester, size);
        // 拖到還看得到的 🧺 圖示上仍然可以作答（DragTarget 包含整個籃子）
        final item = _currentItem(tester);
        final label = find.text(
          _basketText[item.valueFor(_currentRule(tester))!]!,
        );
        final lx = tester.getCenter(label).dx;
        final baskets = find.text('🧺').evaluate().toList();
        Offset? target;
        for (final e in baskets) {
          final c = tester.getCenter(find.byWidget(e.widget));
          if ((c.dx - lx).abs() < 30) target = c;
        }
        expect(target, isNotNull);
        expect(target!.dy, lessThan(size.height));
        final from = tester.getCenter(
          find.byWidgetPredicate((w) => w is Draggable<MarketSortItem>),
        );
        final g = await tester.startGesture(from);
        await tester.pump();
        await g.moveBy(const Offset(0, 30));
        await tester.pump();
        await g.moveTo(target);
        await tester.pump();
        await g.up();
        await tester.pump(const Duration(milliseconds: 750));
        await tester.pump(const Duration(milliseconds: 2100));
        expect(_progressText(tester), '2/28');
      }, backend.client);
    } finally {
      sink.detach();
    }
    // ignore: avoid_print
    print('[320x568] ${sink.summaries.toSet()} 超出畫面的籃子標籤：$outside');
    expect(outside, isNotEmpty);
    expect(
      sink.summaries,
      contains(
        allOf(
          contains('RenderFlex overflowed'),
          contains('market_sort_game_screen.dart'),
        ),
      ),
    );
  });

  testWidgets('BUG重現：長輩常用的大字體（系統字級 1.3 倍）時，共用「選單」按鈕在 96px 欄位內往右溢出', (
    tester,
  ) async {
    const size = Size(360, 780);
    _setSurface(tester, size);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final backend = _Backend();
    final sink = _ErrorSink()..attach();
    final outside = <String>{};
    try {
      await http.runWithClient(() async {
        await _pumpApp(tester, home: const MarketSortGameScreen());
        await _finishCountdown(tester);
        for (var q = 1; q <= 11; q++) {
          await tester.pump(const Duration(milliseconds: 2100));
          outside.addAll(basketsOutOfScreen(tester, size));
          await _answerCurrent(tester, correct: true, waitIdleFirst: q == 1);
        }
      }, backend.client);
    } finally {
      sink.detach();
    }
    // ignore: avoid_print
    print(
      '[360x780 @1.3x 字] errors=${sink.summaries.toSet()} 超出畫面的籃子標籤：$outside',
    );
    // 遊戲本體（商品、籃子）在 360x780 放得下
    expect(outside, isEmpty);
    expect(
      sink.summaries,
      contains(
        allOf(contains('overflowed'), contains('game_menu_button.dart')),
      ),
    );
    expect(
      sink.summaries.where((e) => !e.contains('game_menu_button.dart')),
      isEmpty,
    );
  });

  testWidgets('BUG重現：拖曳後沒放進任何籃子，閒置提示再也不會出現（idle timer 被取消後沒重啟）', (
    tester,
  ) async {
    _setSurface(tester, const Size(360, 780));
    final backend = _Backend();
    await http.runWithClient(() async {
      await _pumpApp(tester, home: const MarketSortGameScreen());
      await _finishCountdown(tester);
      await tester.pump(const Duration(milliseconds: 2100));
      // 拖到畫面空白處放開
      final from = tester.getCenter(
        find.byWidgetPredicate((w) => w is Draggable<MarketSortItem>),
      );
      final g = await tester.startGesture(from);
      await tester.pump();
      await g.moveBy(const Offset(0, 30));
      await tester.pump();
      await g.moveTo(const Offset(20, 200));
      await tester.pump();
      await g.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(_progressText(tester), '1/28');
      // 再等 20 秒都沒有提示
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('請把商品拖到正確的籃子裡！'), findsNothing);
    }, backend.client);
  });

  // ───────────────────────── 6. 邏輯層 bug 重現 ─────────────────────────

  test('BUG重現：persistent（沿用舊規則）錯誤永遠判定不出來', () {
    // 籃子的值永遠是「當題規則」的 enum，上一題規則的屬性值是另一種 enum，
    // 兩者用 == 比較永遠不相等，所以 error_type 只會是 random。
    var persistentCount = 0;
    var switchWrongCount = 0;
    for (final item in marketSortItemPool) {
      for (final cur in GameRule.values) {
        if (item.isExcludedFor(cur)) continue;
        for (final prev in GameRule.values) {
          if (prev == cur) continue;
          for (final bucket in _valuesFor(cur)) {
            if (bucket == item.valueFor(cur)) continue;
            switchWrongCount++;
            final j = judgeAnswer(
              item: item,
              currentRule: cur,
              selectedBucketValue: bucket,
              trialType: TrialType.switchType,
              previousRule: prev,
            );
            if (j.errorType == ErrorType.persistent) persistentCount++;
          }
        }
      }
    }
    expect(switchWrongCount, greaterThan(0));
    expect(persistentCount, 0);
  });

  test('BUG重現：暫停後繼續（或重新開始）時，反應時間會多算進鎖定時間', () async {
    // 第一題是生熟（1 秒鎖定）。進入可作答後馬上「暫停→繼續」，
    // 畫面會重新呼叫 startQuestion()；Stopwatch.reset() 不會停止計時，
    // 所以鎖定期間也被算進 reaction_time_ms。
    final c = MarketSortGameController(random: Random(1));
    c.startQuestion();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(c.phase, QuestionPhase.interactive);

    c.startQuestion(); // 模擬 _resumeWithCountdown → _startCurrentQuestion
    expect(c.phase, QuestionPhase.locked);
    await Future<void>.delayed(const Duration(milliseconds: 1050));
    expect(c.phase, QuestionPhase.interactive);

    // 一進入可作答就立刻答（真實反應時間 ≈ 0）
    c.resolveQuestion(c.currentItem.valueFor(c.currentRule)!);
    final rt = c.results.single.reactionTimeMs;
    c.dispose();
    expect(
      rt,
      greaterThanOrEqualTo(1000),
      reason: '反應時間應接近 0ms，實際卻是 ${rt}ms（含鎖定的 1 秒）',
    );
  });

  test('第四階段可能出現只有 1 題的規則段（設計是每組 2~3 題）', () {
    // 13 題用 2/3 題一組拆，若前面湊到 12 題，最後一組只剩 1 題
    var singleRunSeeds = 0;
    for (var seed = 0; seed < 500; seed++) {
      final c = MarketSortGameController(random: Random(seed));
      final rules = <GameRule>[];
      for (var i = 0; i < 28; i++) {
        rules.add(c.currentRule);
        c.moveToNextQuestion();
      }
      c.dispose();
      final stage4 = rules.sublist(15);
      final runs = <int>[];
      for (var i = 0; i < stage4.length; i++) {
        if (i == 0 || stage4[i] != stage4[i - 1]) {
          runs.add(1);
        } else {
          runs[runs.length - 1]++;
        }
      }
      if (runs.contains(1)) singleRunSeeds++;
    }
    // ignore: avoid_print
    print('500 個亂數種子中，第四階段出現單題規則段的次數：$singleRunSeeds');
    expect(singleRunSeeds, greaterThan(0));
  });
}
