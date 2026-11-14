// 來去菜市場（go_to_market）完整遊玩 QA 測試
//
// 沒有實機／模擬器，用 widget test 模擬玩家：遊戲首頁 → 教學 → 20 題 → 結算 →
// 再玩一次／退出／暫停選單，並測 API 失敗（500、斷線、逾時、401）時不會當掉或卡住。
//
// 命名規則：
// - 一般測試：斷言「正確行為」，通過代表沒問題。
// - 名稱以 [BUG] 開頭：斷言「目前的錯誤行為」會重現，通過代表 bug 仍然存在
//   （修好之後這些測試會失敗，屆時改成斷言正確行為即可）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:light_memory/features/game/go_to_market/pages/go_to_market_entry_page.dart';
import 'package:light_memory/features/game/go_to_market/pages/go_to_market_game_page.dart';
import 'package:light_memory/features/game/go_to_market/pages/go_to_market_tutorial_page.dart';
import 'package:light_memory/features/game/go_to_market/widgets/market_result_dialog.dart';
import '../support/test_home_screen.dart';

// ───────────────────────── 畫面文字 ─────────────────────────
const kExposeText = '注意看！記住魚出現的位置！';
const kAnswerText = '請點擊剛剛魚出現的位置！';
const kRetryBtn = '重看題目';
const kNextQBtn = '進入下一題';
const kScoreLabel = '本次分數';

const quadrants = ['q1', 'q2', 'q3', 'q4'];

// ───────────────────────── 假後端 ─────────────────────────
class FakeMarketBackend {
  int? failStatus; // 所有請求回這個 status
  bool networkError = false; // 丟 ClientException
  bool hang = false; // 永遠不回應（觸發 4 秒 timeout）
  Duration answerDelay = Duration.zero; // answer API 延遲
  Map<String, dynamic>? roundDataOverride; // 覆寫 round 的 data
  int totalQuestions = 20; // config/ 回的題數（admin_demo 是 3）

  final List<String> calls = [];
  final List<Map<String, dynamic>> answers = [];
  int startCalls = 0;
  int finishCalls = 0;

  int _sessionSeq = 0;
  String? session;
  int q = 1;
  String stage = 'basic';
  int correctStreak = 0;
  int wrongInQ = 0;
  int score = 0;

  String targetFor(int q, String stage) =>
      stage == 'basic' ? 'center' : quadrants[q % 4];

  String get currentTarget => targetFor(q, stage);

  http.Response _ok(Object? data) => http.Response(
    jsonEncode({'success': true, 'data': data, 'error': null}),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  Future<http.Response> handle(http.Request req) async {
    final path = req.url.path;
    calls.add('${req.method} $path');
    if (networkError) throw http.ClientException('network down', req.url);
    if (hang) return Completer<http.Response>().future;
    if (failStatus != null) {
      return http.Response(
        jsonEncode({
          'success': false,
          'data': null,
          'error': {'code': 'SERVER_ERROR', 'message': 'boom'},
        }),
        failStatus!,
      );
    }
    if (req.headers['Authorization'] == null) {
      return http.Response('{"detail":"no auth"}', 401);
    }

    if (path.endsWith('/start/')) {
      startCalls++;
      session = 'uuid-${++_sessionSeq}';
      q = 1;
      stage = 'basic';
      correctStreak = 0;
      wrongInQ = 0;
      score = 0;
      return _ok({'session_id': session});
    }
    if (path.endsWith('/round/answer/')) {
      if (answerDelay > Duration.zero) await Future.delayed(answerDelay);
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      answers.add(body);
      final isTimeout = body['is_timeout'] == true;
      final correct = !isTimeout && body['answer_position'] == currentTarget;
      final last = q >= totalQuestions;
      int earned = 0;
      String action;
      if (correct) {
        earned = 10;
        score += 10;
        correctStreak++;
        if (last) {
          action = 'finished';
        } else if (correctStreak >= 5 && stage != 'advanced') {
          stage = stage == 'basic' ? 'intermediate' : 'advanced';
          correctStreak = 0;
          action = 'promoted';
        } else {
          action = 'next_question';
        }
      } else {
        correctStreak = 0;
        wrongInQ++;
        if (last) {
          action = 'finished';
        } else if (wrongInQ >= 3 || isTimeout) {
          action = 'next_question';
        } else {
          action = 'retry';
        }
      }
      if (action != 'retry') {
        q++;
        wrongInQ = 0;
      }
      return _ok({
        'is_correct': correct,
        'action': action,
        'current_stage': stage,
        'correct_streak': correctStreak,
        'wrong_attempts': wrongInQ,
        'score_earned': earned,
        'fast_correct_streak': 0,
      });
    }
    if (path.endsWith('/round/')) {
      if (roundDataOverride != null) return _ok(roundDataOverride);
      return _ok({
        'question_number': q,
        'stage': stage,
        'target_item': stage == 'basic'
            ? '魚'
            : (stage == 'intermediate' ? '鮭魚' : '鱸魚'),
        'target_position': currentTarget,
        'distractor_items': stage == 'advanced'
            ? [
                {'item': '魚骨頭', 'position': quadrants[(q + 2) % 4]},
              ]
            : [],
        'exposure_time_ms': stage == 'basic'
            ? 2000
            : (stage == 'intermediate' ? 1500 : 1000),
      });
    }
    if (path.endsWith('/finish/')) {
      finishCalls++;
      return _ok({
        'total_questions': totalQuestions,
        'answered_count': totalQuestions,
        'correct_count': score ~/ 10,
        'timeout_count': 0,
        'accuracy': 0.5,
        'avg_response_time_ms': 800,
        'final_stage': stage,
        'total_score': score,
      });
    }
    if (path.endsWith('/config/')) {
      return _ok({'total_questions': totalQuestions});
    }
    return http.Response('not found', 404);
  }
}

// ───────────────────────── 測試環境 ─────────────────────────

/// audioplayers 的 platform channel 全部回成功（null），其他 channel 照原本的 mock 走。
void installAudioChannelStub() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();
  messenger.allMessagesHandler = (channel, handler, message) {
    if (channel.startsWith('xyz.luan/audioplayers')) {
      return Future.value(codec.encodeSuccessEnvelope(null));
    }
    if (handler != null) return handler(message);
    return null;
  };
}

/// 收集 FlutterError（overflow、build 例外等），不讓第一個錯誤就中斷遊玩流程
class ErrorCollector {
  final List<FlutterErrorDetails> errors = [];
  FlutterExceptionHandler? _orig;
  void start() {
    _orig = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d);
  }

  void stop() {
    FlutterError.onError = _orig;
  }

  String get details => errors.map((e) => e.toString()).join('\n=====\n');

  List<String> get summaries => errors
      .map((e) => e.exceptionAsString().split('\n').take(2).join(' | '))
      .toList(growable: false);
}

DebugPrintCallback? _savedDebugPrint;

void silenceDebugPrint() {
  _savedDebugPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {};
}

void restoreDebugPrint() {
  if (_savedDebugPrint != null) debugPrint = _savedDebugPrint!;
}

String dumpTexts() => find
    .byType(Text)
    .evaluate()
    .map((e) => (e.widget as Text).data)
    .whereType<String>()
    .join(' | ');

void setSurface(WidgetTester tester, Size logical, {double dpr = 3}) {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = logical * dpr;
}

const landscapePhone = Size(780, 360); // 1080x2340 @3x 橫向
const smallLandscape = Size(640, 360); // 360x640 小手機 橫向
const tinyLandscape = Size(568, 320); // iPhone SE (1st) 橫向
const portraitPhone = Size(360, 780);
const smallPortrait = Size(360, 640);

/// 在 http zone 裡跑整個測試本體
Future<void> runGame(
  WidgetTester tester,
  FakeMarketBackend backend,
  Future<void> Function(ErrorCollector errors) body, {
  bool allowErrors = false,
}) async {
  final errors = ErrorCollector()..start();
  silenceDebugPrint();
  try {
    await http.runWithClient(
      () async {
        await body(errors);
        // 把所有遊戲頁拆掉，跑完殘留的 Future.delayed／Timer
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 30));
      },
      () => MockClient((req) => backend.handle(req)),
    );
  } finally {
    errors.stop();
    restoreDebugPrint();
  }
  if (errors.summaries.isNotEmpty) {
    // ignore: avoid_print
    print('── FlutterErrors (${errors.summaries.length}) ──\n'
        '${errors.summaries.toSet().join('\n')}');
    if (const bool.fromEnvironment('QA_VERBOSE')) {
      // ignore: avoid_print
      print(errors.details);
    }
  }
  if (!allowErrors) {
    expect(errors.summaries, isEmpty, reason: 'FlutterError 被觸發');
  }
}

Widget simpleHost({Widget Function()? page}) {
  return MaterialApp(
    home: Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(ctx).push(
              MaterialPageRoute(
                builder: (_) =>
                    (page ?? () => const GoToMarketTutorialPage())(),
              ),
            ),
            child: const Text('OPEN_MARKET'),
          ),
        ),
      ),
    ),
  );
}

// ───────────────────────── 操作 helper ─────────────────────────

Future<bool> pumpUntil(
  WidgetTester tester,
  bool Function() cond, {
  Duration step = const Duration(milliseconds: 100),
  int maxSteps = 400,
}) async {
  for (var i = 0; i < maxSteps; i++) {
    if (cond()) return true;
    await tester.pump(step);
  }
  return cond();
}

bool has(Finder f) => f.evaluate().isNotEmpty;

Finder get boardFinder => find.byWidgetPredicate(
  (w) => w is SizedBox && w.width == 480.0 && w.height == 150.0,
);

Finder get fishFinder =>
    find.descendant(of: boardFinder, matching: _fishImage);

Finder get _fishImage => find.byWidgetPredicate((w) {
  if (w is! Image || w.image is! AssetImage) return false;
  final name = (w.image as AssetImage).assetName;
  return name.contains('fish') && !name.contains('bone');
});

String quadrantOfFish(WidgetTester tester) {
  final b = tester.getRect(boardFinder);
  final f = tester.getCenter(fishFinder.first);
  final dx = f.dx - b.center.dx;
  final dy = f.dy - b.center.dy;
  if (dx.abs() < 20 && dy.abs() < 20) return 'center';
  if (dy < 0) return dx > 0 ? 'q1' : 'q2';
  return dx > 0 ? 'q4' : 'q3';
}

Offset offsetOf(WidgetTester tester, String pos) {
  final b = tester.getRect(boardFinder);
  switch (pos) {
    case 'center':
      return b.center;
    case 'q1':
      return Offset(b.left + b.width * 0.88, b.top + b.height * 0.2);
    case 'q2':
      return Offset(b.left + b.width * 0.12, b.top + b.height * 0.2);
    case 'q3':
      return Offset(b.left + b.width * 0.12, b.top + b.height * 0.8);
    default:
      return Offset(b.left + b.width * 0.88, b.top + b.height * 0.8);
  }
}

String wrongOf(String target) => target == 'q1' ? 'q3' : 'q1';

String currentStageLabel() {
  if (has(find.text('高階難度'))) return 'advanced';
  if (has(find.text('中階難度'))) return 'intermediate';
  return 'basic';
}

/// 等閃現開始、讀出魚的位置，再等到可以作答
Future<String> waitRoundAndReadTarget(WidgetTester tester) async {
  expect(
    await pumpUntil(
      tester,
      () => has(find.text(kExposeText)) && has(fishFinder),
    ),
    isTrue,
    reason: '閃現沒有開始（卡住？）',
  );
  final target = quadrantOfFish(tester);
  expect(
    await pumpUntil(tester, () => has(find.text(kAnswerText))),
    isTrue,
    reason: '閃現結束後沒有進入作答',
  );
  return target;
}

Future<void> tapPos(WidgetTester tester, String pos) async {
  await tester.tapAt(offsetOf(tester, pos));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

class AnswerRecord {
  final String stage;
  final int attempt;
  final bool correct;
  AnswerRecord(this.stage, this.attempt, this.correct);
}

/// 玩一題。attempts 例：['c']、['w','c']、['w','w','w']、['t']
/// 回傳這題結束後的狀態：'next' / 'transition' / 'result'
Future<String> playQuestion(
  WidgetTester tester,
  List<String> attempts,
  List<AnswerRecord> log,
) async {
  for (var i = 0; i < attempts.length; i++) {
    final target = await waitRoundAndReadTarget(tester);
    final stage = currentStageLabel();
    final a = attempts[i];
    if (a == 't') {
      await tester.pump(const Duration(seconds: 21));
      log.add(AnswerRecord(stage, i + 1, false));
    } else {
      await tapPos(tester, a == 'c' ? target : wrongOf(target));
      log.add(AnswerRecord(stage, i + 1, a == 'c'));
    }
    await tester.pump(const Duration(milliseconds: 50));
    final isLastAttempt = i == attempts.length - 1;
    if (!isLastAttempt) {
      expect(a, 'w', reason: '只有答錯可以接著重看');
      expect(
        await pumpUntil(tester, () => has(find.text(kRetryBtn)), maxSteps: 20),
        isTrue,
        reason: '答錯後沒有出現「重看題目」',
      );
      // 等 1.5 秒，確認不會自己跳題（retry 應停留在本題）
      await tester.pump(const Duration(milliseconds: 1500));
      expect(find.text(kRetryBtn), findsOneWidget, reason: 'retry 時不該自動跳題');
      await tester.tap(find.text(kRetryBtn));
      await tester.pump();
    }
  }
  final ok = await pumpUntil(
    tester,
    () =>
        has(find.text(kNextQBtn)) ||
        has(find.text(kScoreLabel)) ||
        has(find.text(kExposeText)),
    maxSteps: 100,
  );
  expect(ok, isTrue, reason: '作答後卡住，沒有下一題／升降階／結算。畫面：${dumpTexts()}');
  if (has(find.text(kNextQBtn))) return 'transition';
  if (has(find.text(kScoreLabel))) return 'result';
  return 'next';
}

String questionCounter(WidgetTester tester, {int total = 20}) {
  final t = find.textContaining(' / $total');
  if (!has(t)) return '';
  return (tester.widget<Text>(t.first).data ?? '');
}

/// 逐步走完整個教學（含上一步、再看一次教學），最後按「開始挑戰 20 題」
Future<void> walkTutorial(
  WidgetTester tester, {
  bool replayOnce = true,
  String startLabel = '開始挑戰 20 題',
}) async {
  expect(find.text('來去菜市場'), findsOneWidget);
  var guard = 0;
  var didPrev = false;
  var replayed = !replayOnce;
  while (guard++ < 80) {
    if (has(find.text('全難度教學完成！'))) {
      if (!replayed) {
        replayed = true;
        await tester.tap(find.text('再看一次教學'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('簡單難度教學'), findsWidgets);
        continue;
      }
      await tester.tap(find.text(startLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      return;
    }
    if (!didPrev && has(find.text('中等難度教學')) && has(find.text('第三步'))) {
      didPrev = true;
      await tester.tap(find.text('上一步'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('第二步'), findsOneWidget);
    }
    await tester.tap(find.text('下一步'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 200));
  }
  fail('教學頁走不完');
}

Future<void> openTutorialFromHost(WidgetTester tester) async {
  await tester.tap(find.text('OPEN_MARKET'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> skipTutorialIntoGame(WidgetTester tester) async {
  await openTutorialFromHost(tester);
  // 階段橫幅（黑色遮罩）蓋住整頁 1.6 秒，期間點「略過教學」只會關掉橫幅
  await tester.pump(const Duration(milliseconds: 1700));
  await tester.tap(find.text('略過教學'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.byType(GoToMarketGamePage), findsOneWidget);
}

Future<void> openPauseMenu(WidgetTester tester) async {
  await tester.tap(find.text('選單'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.text('遊戲暫停'), findsOneWidget);
}

int resultScore(WidgetTester tester) => tester
    .widget<MarketResultDialog>(find.byType(MarketResultDialog).last)
    .currentScore;

/// 本地模式計分（對照規格）：測試中反應時間 ~0ms，全部算快速作答 → +2
int localScore(List<AnswerRecord> log) {
  var s = 0;
  for (final r in log) {
    if (!r.correct) continue;
    final base = r.attempt == 1 ? 10 : (r.attempt == 2 ? 6 : 3);
    final mult = r.stage == 'advanced'
        ? 1.6
        : (r.stage == 'intermediate' ? 1.3 : 1.0);
    s += (base * mult).round() + 2;
  }
  return s;
}

Future<String> playAllCorrect(WidgetTester tester, int count) async {
  final log = <AnswerRecord>[];
  String state = '';
  for (var i = 0; i < count; i++) {
    state = await playQuestion(tester, ['c'], log);
    if (state == 'transition') {
      await tester.tap(find.text(kNextQBtn));
      await tester.pump();
    }
  }
  return state;
}

// ───────────────────────── 測試 ─────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'access_token': 'test'});
    installAudioChannelStub();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding
            .instance
            .defaultBinaryMessenger
            .allMessagesHandler =
        null;
  });

  // Demo 模式（12 月複賽）：admin_demo 帳號後端 config/ 回 3 題，前端照後端題數
  testWidgets('Demo 模式：config/ 給 3 題 → 教學按鈕顯示 3 題、答完第 3 題就結算', (tester) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend()..totalQuestions = 3;
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      await openTutorialFromHost(tester);
      await walkTutorial(tester, replayOnce: false, startLabel: '開始挑戰 3 題');
      expect(find.byType(GoToMarketGamePage), findsOneWidget);

      final log = <AnswerRecord>[];
      String state = '';
      for (var i = 0; i < 3; i++) {
        await pumpUntil(tester, () => has(find.text(kExposeText)));
        expect(questionCounter(tester, total: 3), '${i + 1} / 3');
        state = await playQuestion(tester, ['c'], log);
        if (i < 2) expect(state, isNot('result'), reason: '第 ${i + 1} 題就提早結算');
      }
      expect(state, 'result');
      expect(backend.answers.length, 3);
      expect(backend.finishCalls, 1);
    });
  });

  testWidgets('config/ 失敗時維持 20 題（一般使用者不受影響）', (tester) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend();
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      backend.failStatus = 500; // 教學頁、遊戲頁的 config/ 都失敗
      await openTutorialFromHost(tester);
      await walkTutorial(tester, replayOnce: false);
      await pumpUntil(tester, () => has(find.text(kExposeText)));
      expect(questionCounter(tester), '1 / 20');
    }, allowErrors: true);
  });

  // 1. 正式路徑：遊戲首頁 → 教學 → 20 題（後端正常）→ 結算 → 再玩一次 → 暫停 → 退出
  testWidgets('完整遊玩（後端正常）：首頁→教學→20 題→結算→再玩一次→暫停退出', (tester) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend();
    await runGame(tester, backend, (errors) async {
      setSurface(tester, portraitPhone);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(ctx).push(
                    MaterialPageRoute(builder: (_) => const TestHomeScreen()),
                  ),
                  child: const Text('MAIN'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('MAIN'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('注意力'));
      await tester.pump();
      setSurface(tester, landscapePhone); // 教學頁鎖橫向
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(GoToMarketTutorialPage), findsOneWidget);

      await walkTutorial(tester);
      expect(find.byType(GoToMarketGamePage), findsOneWidget);

      final plan = <List<String>>[
        ['c'], ['c'], ['c'], ['c'], ['c'], // Q1-5 → 後端 promoted
        ['w', 'c'], // Q6 retry
        ['w', 'w', 'w'], // Q7 三次錯
        ['t'], // Q8 超時
        ['c'], ['c'], ['c'], ['c'], ['c'], // Q9-13 → promoted 到高階
        ['c'], ['w', 'w', 'c'], ['c'], ['c'], ['c'], ['c'],
        ['w'], // Q20 最後一題答錯 → finished
      ];
      final log = <AnswerRecord>[];
      var transitions = 0;
      String state = '';
      for (var i = 0; i < plan.length; i++) {
        expect(questionCounter(tester), '${i + 1} / 20', reason: '題號不同步');
        state = await playQuestion(tester, plan[i], log);
        if (state == 'transition') {
          transitions++;
          await tester.tap(find.text(kNextQBtn));
          await tester.pump();
        }
        if (state == 'result') {
          expect(i, plan.length - 1, reason: '提早結算（第 ${i + 1} 題）');
        }
      }
      expect(state, 'result');
      expect(transitions, 2, reason: '後端回 promoted 兩次，應該出現兩次升階對話框');

      final a = backend.answers;
      expect(a.length, log.length);
      expect(a.where((e) => e['is_timeout'] == true).length, 1);
      expect(a.sublist(5, 7).map((e) => e['attempt_number']).toList(), [1, 2]);
      expect(backend.finishCalls, 1);

      expect(resultScore(tester), backend.score);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('market_score_list'), ['${backend.score}']);
      expect(prefs.getInt('market_highest_score'), backend.score);

      // 再玩一次 → 新場次、題號回到 1
      await tester.tap(find.text('再玩一次'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(backend.startCalls, 2);
      await waitRoundAndReadTarget(tester);
      expect(questionCounter(tester), '1 / 20');
      expect(find.text('初階難度'), findsOneWidget);

      // 暫停 → 繼續 → 暫停 → 退出遊戲
      await openPauseMenu(tester);
      await tester.tap(find.text('繼續遊戲'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('遊戲暫停'), findsNothing);
      await openPauseMenu(tester);
      await tester.tap(find.text('退出遊戲'));
      await tester.pump();
      setSurface(tester, portraitPhone);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(GoToMarketGamePage), findsNothing);
      expect(find.text('MAIN'), findsOneWidget); // 退出直接回到最底層的主畫面
    });
  });

  // 2. 本地模式（後端全部 500）+ 本地 DDA 升降階與計分
  testWidgets('後端全部 500：本地模式可玩完 20 題，升階／降階／計分正確', (tester) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend()..failStatus = 500;
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      await skipTutorialIntoGame(tester);

      final plan = <List<String>>[
        ['c'], ['c'], ['c'], // 快速連對 3 → 中階
        ['c'], ['c'], ['c'], // → 高階
        ['w', 'w', 'w'], // Q7 連錯 3
        ['w', 'w'], // Q8 連錯第 5 次 → 降階（中階）
        ['w', 'c'], // Q9
        ['t'], // Q10 超時
        ['w', 'w', 'c'], // Q11
        ['c'], ['c'], // Q12-13 → 快速連對 3 → 高階
        ['c'], ['c'], ['c'], ['c'], ['c'], ['c'], ['c'],
      ];
      final log = <AnswerRecord>[];
      final transitions = <String>[];
      String state = '';
      for (var i = 0; i < plan.length; i++) {
        expect(questionCounter(tester), '${i + 1} / 20');
        state = await playQuestion(tester, plan[i], log);
        if (state == 'transition') {
          transitions.add(has(find.text('表現優異！難度升級！')) ? 'up' : 'down');
          await tester.tap(find.text(kNextQBtn));
          await tester.pump();
        }
      }
      expect(state, 'result');
      expect(transitions, ['up', 'up', 'down', 'up']);
      expect(backend.answers, isEmpty); // 沒 session 不會送作答
      expect(resultScore(tester), localScore(log));
    });
  });

  testWidgets('網路斷線（ClientException）：不當機，本地模式可開始並作答', (tester) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend()..networkError = true;
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      await skipTutorialIntoGame(tester);
      final log = <AnswerRecord>[];
      expect(await playQuestion(tester, ['c'], log), 'next');
      expect(await playQuestion(tester, ['w', 'c'], log), 'next');
      expect(questionCounter(tester), '3 / 20');
    });
  });

  testWidgets('後端不回應（hang）：4 秒逾時後改本地模式，不會一直轉圈', (tester) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend()..hang = true;
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      await skipTutorialIntoGame(tester);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text(kExposeText), findsNothing);
      await tester.pump(const Duration(milliseconds: 1200));
      expect(find.text(kExposeText), findsOneWidget);
      final log = <AnswerRecord>[];
      expect(await playQuestion(tester, ['c'], log), 'next');
    });
  });

  testWidgets('遊戲中途後端掛掉（answer/round/finish 500）：可以玩到結算', (tester) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend();
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      await skipTutorialIntoGame(tester);
      await playAllCorrect(tester, 3);
      backend.failStatus = 500;
      final state = await playAllCorrect(tester, 17);
      expect(state, 'result');
      expect(resultScore(tester), greaterThan(0));
    });
  });

  testWidgets('沒有 token：跳「登入已過期」，選繼續練習可照常玩', (tester) async {
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final backend = FakeMarketBackend();
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      await skipTutorialIntoGame(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('登入已過期'), findsOneWidget);
      await tester.tap(find.text('繼續練習'));
      await tester.pump(const Duration(milliseconds: 300));
      final log = <AnswerRecord>[];
      expect(await playQuestion(tester, ['c'], log), 'next');
      expect(backend.calls, isEmpty); // 沒 token 不送請求
    });
  });

  testWidgets('後端回 401：跳「登入已過期」，繼續練習可玩', (tester) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend()..failStatus = 401;
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      await skipTutorialIntoGame(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('登入已過期'), findsOneWidget);
      await tester.tap(find.text('繼續練習'));
      await tester.pump(const Duration(milliseconds: 300));
      await waitRoundAndReadTarget(tester);
    });
  });

  testWidgets('GoToMarketEntryPage：第一次進教學、之後直接進遊戲', (tester) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend();
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(
        simpleHost(page: () => const GoToMarketEntryPage()),
      );
      await openTutorialFromHost(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(GoToMarketTutorialPage), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('has_played_market_game'), isTrue);
      await tester.pump(const Duration(milliseconds: 1700)); // 等橫幅消失
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('OPEN_MARKET'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(GoToMarketGamePage), findsOneWidget);
    });
  });

  testWidgets('App 切背景再回來：自動跳暫停選單，繼續後可作答', (tester) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend();
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      await skipTutorialIntoGame(tester);
      await waitRoundAndReadTarget(tester);
      await tester.pump(const Duration(seconds: 2));
      final b = tester.binding;
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        b.handleAppLifecycleStateChanged(s);
      }
      await tester.pump(const Duration(seconds: 30));
      expect(backend.answers, isEmpty, reason: '背景期間不該超時');
      for (final s in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        b.handleAppLifecycleStateChanged(s);
      }
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('遊戲暫停'), findsOneWidget);
      await tester.tap(find.text('繼續遊戲'));
      await tester.pump(const Duration(milliseconds: 300));
      await tapPos(tester, 'center');
      await tester.pump(const Duration(milliseconds: 50));
      expect(backend.answers.single['is_timeout'], isFalse);
    });
  });

  testWidgets('暫停選單「重新開始」：回到第 1 題、開新場次', (tester) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend();
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      await skipTutorialIntoGame(tester);
      await playAllCorrect(tester, 2);
      await openPauseMenu(tester);
      await tester.tap(find.text('重新開始'));
      await tester.pump(const Duration(milliseconds: 300));
      await waitRoundAndReadTarget(tester);
      expect(questionCounter(tester), '1 / 20');
      expect(backend.startCalls, 2);
    });
  });

  // ───────── 畫面尺寸：教學 + 遊戲 + 結算，不能有 overflow ─────────
  // 值 = 預期教學頁會 overflow 的訊息（null 代表不該有任何 FlutterError）
  final sizes = <String, (Size, String?)>{
    '一般手機橫向 780x360': (landscapePhone, null),
    '小手機橫向 640x360': (smallLandscape, null),
    // [BUG] 教學頁中間教學內容（徽章 + 140 高棋盤）在 320 高的橫向畫面放不下
    '[BUG] iPhone SE 橫向 568x320': (tinyLandscape, 'overflowed by 7.0 pixels on the bottom'),
    // [BUG] 轉向鎖失效（iPad 分割畫面、Web）時，高階教學的兩張辨識卡（400 寬）放不下
    '[BUG] 直向 360x780（轉向鎖失效時）': (portraitPhone, 'overflowed by 72 pixels on the right'),
    '[BUG] 小手機直向 360x640（轉向鎖失效時）': (smallPortrait, 'overflowed by 72 pixels on the right'),
  };
  for (final entry in sizes.entries) {
    final (size, expectedOverflow) = entry.value;
    testWidgets('版面 ${entry.key}：教學 + 一場遊戲 + 結算', (tester) async {
      addTearDown(tester.view.reset);
      final backend = FakeMarketBackend();
      late ErrorCollector collected;
      await runGame(tester, backend, (errors) async {
        collected = errors;
        setSurface(tester, size);
        await tester.pumpWidget(simpleHost());
        await openTutorialFromHost(tester);
        await walkTutorial(tester, replayOnce: false);
        final log = <AnswerRecord>[];
        String state = '';
        for (var i = 0; i < 20; i++) {
          state = await playQuestion(
            tester,
            i == 3 ? ['w', 'c'] : ['c'],
            log,
          );
          if (state == 'transition') {
            await tester.tap(find.text(kNextQBtn));
            await tester.pump();
          }
        }
        expect(state, 'result');
        expect(find.text('再玩一次'), findsOneWidget);
        expect(find.text('退出'), findsOneWidget);
      }, allowErrors: expectedOverflow != null);
      if (expectedOverflow != null) {
        expect(collected.summaries, isNotEmpty);
        expect(
          collected.summaries.every((m) => m.contains(expectedOverflow)),
          isTrue,
          reason: '${collected.summaries}',
        );
      }
    });
  }

  testWidgets('大字體（textScale 1.3）橫向 780x360：教學 + 遊戲 + 結算', (tester) async {
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    final backend = FakeMarketBackend();
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      await openTutorialFromHost(tester);
      await walkTutorial(tester, replayOnce: false);
      expect(await playAllCorrect(tester, 20), 'result');
    });
  });

  // ───────────────────────── [BUG] 重現 ─────────────────────────

  testWidgets('[BUG] 暫停選單→玩法教學→返回：閃現中暫停的話遊戲永久卡住', (tester) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend();
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      await skipTutorialIntoGame(tester);
      expect(
        await pumpUntil(tester, () => has(find.text(kExposeText))),
        isTrue,
      );
      await openPauseMenu(tester); // 閃現中暫停
      await tester.tap(find.text('玩法教學'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(GoToMarketTutorialPage), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1700)); // 等橫幅消失
      await tester.tap(find.byIcon(Icons.arrow_back)); // 用返回離開教學
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 60));
      expect(find.text(kExposeText), findsOneWidget);
      expect(find.text(kAnswerText), findsNothing);
      expect(backend.answers, isEmpty);
    });
  });

  testWidgets('[BUG] 遊戲中按「?」說明：計時沒暫停，在教學頁後面超時並跳題', (tester) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend();
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      await skipTutorialIntoGame(tester);
      await waitRoundAndReadTarget(tester);
      await tester.tap(find.byTooltip('遊戲說明'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(GoToMarketTutorialPage), findsOneWidget);
      await tester.pump(const Duration(seconds: 25)); // 玩家在看教學
      expect(backend.answers, hasLength(1));
      expect(backend.answers.single['is_timeout'], isTrue);
    });
  });

  testWidgets('[BUG] 答對後 1 秒回饋期間打開暫停選單：下一題在選單後面開始並超時', (tester) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend();
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      await skipTutorialIntoGame(tester);
      final target = await waitRoundAndReadTarget(tester);
      await tapPos(tester, target);
      await tester.pump(const Duration(milliseconds: 100));
      await openPauseMenu(tester);
      await tester.pump(const Duration(seconds: 30));
      expect(find.text('遊戲暫停'), findsOneWidget); // 選單仍開著
      expect(backend.answers, hasLength(2));
      expect(backend.answers[1]['is_timeout'], isTrue); // 第 2 題在暫停中超時
    });
  });

  testWidgets('[BUG] 暫停選單停留的時間被算進 response_time_ms', (tester) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend();
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      await skipTutorialIntoGame(tester);
      final target = await waitRoundAndReadTarget(tester);
      await openPauseMenu(tester);
      // 真實時間停留 1.2 秒（反應時間是用 DateTime.now() 算的）
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1200)),
      );
      await tester.tap(find.text('繼續遊戲'));
      await tester.pump(const Duration(milliseconds: 300));
      await tapPos(tester, target);
      await tester.pump(const Duration(milliseconds: 50));
      final a = backend.answers.single;
      expect(a['paused_duration_ms'], 0);
      expect(a['response_time_ms'] as int, greaterThanOrEqualTo(1200));
    });
  });

  testWidgets('[BUG] 超時後「重看題目」按鈕與「答錯囉！請看魚的正確位置」仍出現', (tester) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend();
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      await skipTutorialIntoGame(tester);
      await waitRoundAndReadTarget(tester);
      await tester.pump(const Duration(seconds: 21)); // 超時
      await tester.pump(const Duration(milliseconds: 50));
      expect(backend.answers.single['is_timeout'], isTrue);
      expect(find.text(kRetryBtn), findsOneWidget);
      expect(find.text('答錯囉！請看魚的正確位置'), findsOneWidget);
    });
  });

  testWidgets('[BUG] 第 20 題超時時按「重看題目」：結算視窗後面又開始作答，之後疊出第二個結算視窗', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend();
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      await skipTutorialIntoGame(tester);
      await playAllCorrect(tester, 19);
      expect(questionCounter(tester), '20 / 20');
      await waitRoundAndReadTarget(tester);
      await tester.pump(const Duration(seconds: 21)); // 第 20 題超時
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text(kRetryBtn));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(MarketResultDialog), findsOneWidget);
      await tester.pump(const Duration(seconds: 25));
      expect(find.byType(MarketResultDialog), findsNWidgets(2));
      expect(backend.finishCalls, 2);
    }, allowErrors: true);
  });

  testWidgets('結算「退出」直接回到最底層的主畫面（popUntil isFirst）', (tester) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend();
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost()); // simpleHost 代表 MainScreen
      await skipTutorialIntoGame(tester);
      expect(await playAllCorrect(tester, 20), 'result');
      await tester.tap(find.text('退出'));
      await tester.pump();
      setSurface(tester, portraitPhone);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(GoToMarketGamePage), findsNothing);
      expect(find.text('OPEN_MARKET'), findsOneWidget); // 回到主畫面
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      expect(nav.canPop(), isFalse);
    });
  });

  testWidgets('[BUG] 作答送出中（網路慢）按「重新開始」：舊回應套到新的一局', (tester) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend()
      ..answerDelay = const Duration(seconds: 2);
    await runGame(tester, backend, (errors) async {
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      await skipTutorialIntoGame(tester);
      final target = await waitRoundAndReadTarget(tester);
      await tapPos(tester, target); // answer 送出中（2 秒）
      await openPauseMenu(tester);
      await tester.tap(find.text('重新開始'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 3)); // 舊回應回來 + 1 秒回饋
      await tester.pump(const Duration(milliseconds: 500));
      expect(questionCounter(tester), '2 / 20');
    });
  });

  testWidgets('[邊界] round 的 distractor_items 不是 {item, position} 物件時 build 丟例外', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final backend = FakeMarketBackend()
      ..roundDataOverride = {
        'question_number': 1,
        'stage': 'advanced',
        'target_item': '鱸魚',
        'target_position': 'q1',
        'distractor_items': ['魚骨頭'],
        'exposure_time_ms': 1000,
      };
    late ErrorCollector collected;
    await runGame(tester, backend, (errors) async {
      collected = errors;
      setSurface(tester, landscapePhone);
      await tester.pumpWidget(simpleHost());
      await skipTutorialIntoGame(tester);
      await tester.pump(const Duration(milliseconds: 500));
    }, allowErrors: true);
    expect(collected.summaries, isNotEmpty);
  });
}
