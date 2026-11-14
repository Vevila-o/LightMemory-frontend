// 冰箱清點（fridge_inventory）完整遊玩流程測試
//
// 沒有實機 / 模擬器，用 widget test 模擬玩家：
//   入口 → 教學 → 10 題（簡單 4 / 中等 3 / 困難 3，答對答錯都有）
//   → 成績結算 → 再玩一次 / 退出 / 暫停選單 / API 失敗處理 / 小螢幕溢出
//
// 後端用 package:http/testing 的 MockClient 模擬（FakeFridgeBackend），
// 回傳格式依照 lib/features/game/fridge_inventory/services、models 的解析程式碼推測。
//
// 標示「BUG:」的測試：目前是「斷言現有的錯誤行為存在」，
// 用來重現問題；問題修好後這些測試會失敗，屆時請改成斷言正確行為。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:light_memory/core/constants/api_constants.dart';
import 'package:light_memory/features/game/fridge_inventory/pages/fridge_game_page.dart';
import 'package:light_memory/features/game/fridge_inventory/pages/fridge_result_page.dart';
import 'package:light_memory/features/game/fridge_inventory/pages/fridge_tutorial_page.dart';
import '../support/test_home_screen.dart';

// ====================================================================
// 假後端
// ====================================================================

const String kBase = '${ApiConstants.serverUrl}/api/games/fridge-check';

class FakeFridgeBackend {
  FakeFridgeBackend({this.startQ = 1, this.total = 10});

  /// 開新 session 時從第幾題開始（用來快速跳到中等 / 困難 / 最後一題）
  int startQ;

  /// 一場幾題（admin_demo 帳號後端給 3）
  final int total;

  int q = 1;
  int score = 0;
  int attempts = 3;
  bool completed = false;
  int sessionCount = 0;

  Duration latency = const Duration(milliseconds: 200);

  // 失敗注入
  int startStatus = 200;
  String? startBodyOverride;
  bool startThrows = false;
  Duration? startHang; // 模擬伺服器很慢
  int answerStatus = 200;
  bool omitNextQuestion = false;
  int historyStatus = 200;

  final List<http.Request> requests = [];

  List<http.Request> get answerRequests =>
      requests.where((r) => r.url.path.endsWith('/answers/')).toList();
  List<http.Request> get sessionRequests => requests
      .where((r) => r.method == 'POST' && r.url.path.endsWith('/sessions/'))
      .toList();

  String get sessionId =>
      '7d6635ab-eef8-458b-9c1a-${sessionCount.toString().padLeft(12, '0')}';

  static String diffOf(int i) => i <= 4 ? 'easy' : (i <= 7 ? 'medium' : 'hard');

  static Map<String, dynamic> cell(String pos, String? code, String? name) => {
    'position': pos,
    'food_code': code,
    'food_name': name,
  };

  Map<String, dynamic> question(int i) {
    final d = diffOf(i);
    if (d == 'easy') {
      return {
        'question_id': 100 + i,
        'question_type': 'identify_food',
        'prompt': '請找出牛奶右邊的是什麼？',
        'board': [
          cell('r1c1', 'egg', '雞蛋'),
          cell('r1c2', 'milk', '牛奶'),
          cell('r1c3', 'tofu', '豆腐'),
          cell('r2c1', 'tomato', '番茄'),
          cell('r2c2', 'cabbage', '高麗菜'),
          cell('r2c3', 'pepper', '青椒'),
          cell('r3c1', 'carrot', '胡蘿蔔'),
          cell('r3c2', 'apple', '蘋果'),
          cell('r3c3', 'banana', '香蕉'),
        ],
      };
    }
    if (d == 'medium') {
      return {
        'question_id': 100 + i,
        'question_type': 'find_position',
        'prompt': '請找出第二排中間的雞蛋',
        'board': [
          for (final r in [1, 2, 3])
            for (final c in [1, 2, 3]) cell('r${r}c$c', 'egg', '雞蛋'),
        ],
      };
    }
    return {
      'question_id': 100 + i,
      'question_type': 'place_item',
      'prompt': '把番茄移到第二排中間',
      'board': [
        cell('r1c1', 'tofu', '豆腐'),
        cell('r1c2', null, null),
        cell('r1c3', 'apple', '蘋果'),
        cell('r2c1', 'egg', '雞蛋'),
        cell('r2c2', null, null),
        cell('r2c3', 'milk', '牛奶'),
        cell('r3c1', 'carrot', '胡蘿蔔'),
        cell('r3c2', null, null),
        cell('r3c3', 'banana', '香蕉'),
      ],
      'source_food': {'food_code': 'tomato', 'food_name': '番茄'},
    };
  }

  bool _judge(Map answer) {
    switch (diffOf(q)) {
      case 'easy':
        return answer['food_code'] == 'tofu' && !answer.containsKey('position');
      case 'medium':
        return answer['position'] == 'r2c2' && !answer.containsKey('food_code');
      default:
        return answer['food_code'] == 'tomato' && answer['position'] == 'r2c2';
    }
  }

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  Map<String, dynamic> _advance(Map<String, dynamic> base) {
    if (q >= total) {
      completed = true;
      return {
        ...base,
        'is_completed': true,
        'current_score': score,
        'final_score': score,
      };
    }
    q++;
    attempts = 3;
    return {
      ...base,
      'is_completed': false,
      'current_score': score,
      'current_question': q,
      'difficulty': diffOf(q),
      if (!omitNextQuestion) 'next_question': question(q),
    };
  }

  Future<http.Response> handle(http.Request req) async {
    requests.add(req);

    final path = req.url.toString();

    if (req.method == 'POST' && path == '$kBase/sessions/') {
      if (startHang != null) await Future.delayed(startHang!);
      await Future.delayed(latency);
      if (startThrows) throw http.ClientException('Connection refused');
      if (startBodyOverride != null) {
        return http.Response(startBodyOverride!, startStatus);
      }
      if (startStatus != 200 && startStatus != 201) {
        return _json({'detail': 'Internal Server Error'}, startStatus);
      }
      sessionCount++;
      q = startQ;
      score = 0;
      attempts = 3;
      completed = false;
      return _json({
        'success': true,
        'data': {
          'session_id': sessionId,
          'total_questions': total,
          'current_question': q,
          'difficulty': diffOf(q),
          'question': question(q),
        },
      }, 201);
    }

    if (req.method == 'POST' && path.endsWith('/answers/')) {
      await Future.delayed(latency);
      if (answerStatus != 200) {
        return _json({'detail': 'boom'}, answerStatus);
      }
      if (completed) {
        return _json({'detail': 'SESSION_COMPLETED'}, 409);
      }
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final answer = body['answer'] as Map;
      if (_judge(answer)) {
        score += 10;
        return _json({
          'data': _advance({'is_correct': true, 'remaining_attempts': 3}),
        });
      }
      attempts--;
      if (attempts > 0) {
        return _json({
          'data': {
            'is_correct': false,
            'retry': true,
            'is_completed': false,
            'remaining_attempts': attempts,
            'current_score': score,
          },
        });
      }
      return _json({
        'data': _advance({
          'is_correct': false,
          'retry': false,
          'remaining_attempts': 0,
        }),
      });
    }

    if (req.method == 'GET' && path == '$kBase/history/') {
      await Future.delayed(latency);
      if (historyStatus != 200) return _json({'detail': 'boom'}, historyStatus);
      return _json({
        'data': {
          'history': [
            {'final_score': 40, 'created_at': '2026-10-20T10:00:00'},
            {'final_score': 95, 'created_at': '2026-10-21T10:00:00'},
            {'final_score': 60, 'created_at': '2026-10-22T10:00:00'},
            if (completed)
              {'final_score': score, 'created_at': '2026-10-26T10:00:00'},
          ],
        },
      });
    }

    return _json({'detail': 'not found: ${req.method} $path'}, 404);
  }

  MockClient client() => MockClient(handle);
}

// ====================================================================
// 測試工具
// ====================================================================

/// 收集 FlutterError（RenderFlex overflow、setState after dispose 等）
class ErrorCollector {
  final List<FlutterErrorDetails> errors = [];
  final List<String> _fullTexts = [];
  void Function(FlutterErrorDetails)? _orig;

  void start() {
    _orig = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details);
      // 要在當下轉成字串，之後 widget 被卸載就拿不到建立位置
      _fullTexts.add(details.toString());
    };
  }

  void stop() => FlutterError.onError = _orig;

  List<String> get messages => errors
      .map((e) => e.exceptionAsString().split('\n').first)
      .toList();

  /// 溢出訊息 + 造成溢出的 widget 位置（lib/...dart:行:列），去除重複
  List<String> get overflows {
    final out = <String>{};
    for (var i = 0; i < errors.length; i++) {
      final first = errors[i].exceptionAsString().split('\n').first;
      if (!first.contains('overflowed')) continue;
      final loc = RegExp(r'(lib/[^\s:]+\.dart:\d+:\d+)')
              .firstMatch(_fullTexts[i])
              ?.group(1) ??
          '?';
      out.add('$first  @ $loc');
    }
    return out.toList();
  }
}

/// 根頁（模擬 App 首頁）→ 遊戲首頁（stub）→ 冰箱清點
Widget buildApp() {
  return MaterialApp(
    home: Builder(
      builder: (rootCtx) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.push(
              rootCtx,
              MaterialPageRoute(builder: (_) => const _GameHomeStub()),
            ),
            child: const Text('ROOT_HOME'),
          ),
        ),
      ),
    ),
  );
}

class _GameHomeStub extends StatelessWidget {
  const _GameHomeStub();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('GAME_HOME'),
            ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FridgeTutorialPage()),
              ),
              child: const Text('OPEN_FRIDGE'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FridgeGamePage()),
              ),
              child: const Text('OPEN_FRIDGE_GAME'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 換頁動畫時間（Flutter 3.44 預設 Android 轉場比 300ms 長，保守抓 1200ms）
const int kNav = 1200;

/// 以 50ms 為一格推進時間（模擬真實的連續 frame）
Future<void> wait(WidgetTester t, int ms) async {
  var left = ms;
  while (left > 0) {
    final step = left > 50 ? 50 : left;
    await t.pump(Duration(milliseconds: step));
    left -= step;
  }
  await t.pump();
}

/// 等一次 API 往返（latency 200ms）+ setState
Future<void> waitApi(WidgetTester t) => wait(t, 260);

Future<void> setPhone(WidgetTester t, {double w = 1080, double h = 2340, double dpr = 3}) async {
  t.view.physicalSize = Size(w, h);
  t.view.devicePixelRatio = dpr;
  addTearDown(t.view.reset);
}

/// 從 stub 遊戲首頁直接進遊戲（跳過教學）
Future<void> openGame(WidgetTester t) async {
  await t.pumpWidget(buildApp());
  await t.tap(find.text('ROOT_HOME'));
  await wait(t, kNav);
  await t.tap(find.text('OPEN_FRIDGE_GAME'));
  await wait(t, kNav);
  await waitApi(t);
  await wait(t, 300);
}

int gamePageCount() =>
    find.byType(FridgeGamePage, skipOffstage: false).evaluate().length;

/// 在困難題把番茄放到 r2c2（雞蛋 r2c1 與 牛奶 r2c3 中間）
Future<void> placeTomatoAt(WidgetTester t, {bool correct = true}) async {
  await t.tap(find.text('番茄'));
  await t.pump();
  if (correct) {
    final a = t.getCenter(find.text('雞蛋'));
    final b = t.getCenter(find.text('牛奶'));
    await t.tapAt(Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2));
  } else {
    await t.tap(find.text('豆腐'));
  }
}

Future<void> answerCorrect(WidgetTester t, String diff) async {
  if (diff == 'easy') {
    await t.tap(find.text('豆腐'));
  } else if (diff == 'medium') {
    await t.tap(find.text('雞蛋').at(4)); // r2c2
  } else {
    await placeTomatoAt(t);
  }
  await waitApi(t);
  expect(find.byIcon(Icons.check), findsOneWidget, reason: '答對要顯示打勾');
  await wait(t, 900); // 800ms 答對效果後換題
}

Future<void> answerWrong(WidgetTester t, String diff) async {
  if (diff == 'easy') {
    await t.tap(find.text('雞蛋'));
  } else if (diff == 'medium') {
    await t.tap(find.text('雞蛋').at(0));
  } else {
    await placeTomatoAt(t, correct: false);
  }
  await waitApi(t);
}

Map<String, dynamic> bodyOf(http.Request r) =>
    jsonDecode(r.body) as Map<String, dynamic>;

// ====================================================================
// 測試
// ====================================================================

void main() {
  late TestDefaultBinaryMessenger messenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({'access_token': 'test'});
    messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // audioplayers / path_provider 在測試環境沒有原生端，一律回成功
    messenger.allMessagesHandler = (channel, handler, message) {
      if (channel.startsWith('xyz.luan/audioplayers') ||
          channel.contains('path_provider')) {
        return Future.value(
          const StandardMethodCodec().encodeSuccessEnvelope(null),
        );
      }
      if (handler != null) return handler(message);
      return messenger.delegate.send(channel, message);
    };
  });

  tearDown(() {
    messenger.allMessagesHandler = null;
  });

  testWidgets('入口：遊戲首頁點「視覺空間」會進入冰箱清點教學', (t) async {
    await setPhone(t);
    final backend = FakeFridgeBackend();
    await http.runWithClient(() async {
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: ElevatedButton(
                onPressed: () => Navigator.push(
                  ctx,
                  MaterialPageRoute(builder: (_) => const TestHomeScreen()),
                ),
                child: const Text('ROOT_HOME'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('ROOT_HOME'));
      await wait(t, kNav);
      await t.tap(find.text('視覺空間'));
      await wait(t, kNav);
      expect(find.byType(FridgeTutorialPage), findsOneWidget);
      expect(find.text('簡單難度玩法教學'), findsOneWidget);
      await wait(t, 1500);
      expect(find.text('簡單難度玩法教學'), findsNothing);
    }, backend.client);
  });

  // Demo 模式（12 月複賽）：admin_demo 建立 session 回 total_questions = 3，第 3 題答完 is_completed: true
  testWidgets('Demo 模式：後端給 3 題 → 進度顯示 x/3，第 3 題答完到結算頁', (t) async {
    await setPhone(t);
    final backend = FakeFridgeBackend(total: 3);
    await http.runWithClient(() async {
      await openGame(t);
      expect(find.text('1/3'), findsOneWidget);
      await answerCorrect(t, 'easy');
      expect(find.text('2/3'), findsOneWidget);
      await answerCorrect(t, 'easy');
      expect(find.text('3/3'), findsOneWidget);
      await answerCorrect(t, 'easy');
      await wait(t, kNav);
      await waitApi(t);
      expect(find.byType(FridgeResultPage), findsOneWidget);
      expect(backend.answerRequests, hasLength(3));
    }, backend.client);
  });

  testWidgets('完整遊玩：教學(第一次) → 10 題(對錯混合) → 結算 → 再玩一次 → 暫停退出', (t) async {
    await setPhone(t);
    final backend = FakeFridgeBackend();
    final errs = ErrorCollector()..start();
    try {
      await http.runWithClient(() async {
        await t.pumpWidget(buildApp());
        await t.tap(find.text('ROOT_HOME'));
        await wait(t, kNav);
        await t.tap(find.text('OPEN_FRIDGE'));
        await wait(t, kNav);

        // ---------------- 教學 ----------------
        expect(find.text('簡單難度玩法教學'), findsOneWidget);
        await wait(t, 1500);
        expect(find.text('1 / 6'), findsOneWidget);

        Future<void> goToEnd() async {
          for (var i = 0; i < 5; i++) {
            await t.tap(find.text('下一步'));
            await wait(t, 400);
            await wait(t, 1500); // 第 3、5 頁會跳難度提示 1.4 秒
          }
          expect(find.text('6 / 6'), findsOneWidget);
          await t.tap(find.text('下一步'));
          await t.pump();
          expect(find.text('所有難度教學已完成'), findsOneWidget);
        }

        await goToEnd();
        await t.tap(find.text('再看一次教學'));
        await wait(t, 400);
        expect(find.text('1 / 6'), findsOneWidget);
        await goToEnd();
        await t.tap(find.text('開始遊戲'));
        await wait(t, kNav);
        await waitApi(t);
        await wait(t, 300);

        // ---------------- 遊戲 ----------------
        expect(find.byType(FridgeTutorialPage), findsNothing);
        expect(find.text('1/10'), findsOneWidget);
        expect(find.text('簡單難度'), findsOneWidget);

        // Q1：錯一次再對
        await answerWrong(t, 'easy');
        await wait(t, 700);
        expect(find.text('1/10'), findsOneWidget);
        await answerCorrect(t, 'easy');
        expect(find.text('2/10'), findsOneWidget);

        // Q2：錯三次 → 自動下一題
        for (var i = 0; i < 3; i++) {
          await answerWrong(t, 'easy');
          await wait(t, 700);
        }
        await wait(t, 300);
        expect(find.text('3/10'), findsOneWidget);

        // Q3、Q4
        await answerCorrect(t, 'easy');
        await answerCorrect(t, 'easy');
        expect(find.text('5/10'), findsOneWidget);
        expect(find.text('中等難度'), findsOneWidget);

        // Q5：錯一次再對；Q6、Q7
        await answerWrong(t, 'medium');
        await wait(t, 700);
        await answerCorrect(t, 'medium');
        await answerCorrect(t, 'medium');
        await answerCorrect(t, 'medium');
        expect(find.text('8/10'), findsOneWidget);
        expect(find.text('困難難度'), findsOneWidget);

        // Q8：沒選食材先點格子 → 提示；放錯；再放對
        await t.tap(find.text('豆腐'));
        await t.pump();
        expect(find.text('請先點擊下方待放入的食材！'), findsOneWidget);
        await wait(t, 1500);
        await answerWrong(t, 'hard');
        await wait(t, 700);
        await answerCorrect(t, 'hard');
        await answerCorrect(t, 'hard');

        // Q10 最後一題
        expect(find.text('10/10'), findsOneWidget);
        await answerCorrect(t, 'hard');
        await wait(t, kNav);
        await waitApi(t);

        // ---------------- 結算 ----------------
        expect(find.byType(FridgeResultPage), findsOneWidget);
        expect(find.byType(FridgeGamePage, skipOffstage: false), findsNothing);
        expect(find.text('成績結算'), findsOneWidget);
        // 10 題中 Q2 三次全錯，其餘 9 題最後都答對 → 90 分
        expect(backend.score, 90);
        expect(find.text('90'), findsOneWidget); // 本次分數
        expect(find.text('95'), findsOneWidget); // 最高分數（歷史）
        expect(find.text('非常棒！'), findsOneWidget);

        // ---------------- 請求內容檢查 ----------------
        final answers = backend.answerRequests;
        expect(answers.length, 2 + 3 + 1 + 1 + 2 + 1 + 1 + 2 + 1 + 1);
        for (final r in answers) {
          expect(r.headers['Authorization'], 'Bearer test');
          expect(r.url.path, contains(backend.sessionId));
          final b = bodyOf(r);
          expect(b['reaction_time_ms'], isA<int>());
          expect((b['reaction_time_ms'] as int) >= 0, isTrue);
        }
        expect(bodyOf(answers[0])['answer'], {'food_code': 'egg'});
        expect(bodyOf(answers[1])['answer'], {'food_code': 'tofu'});
        expect(bodyOf(answers[7])['answer'], {'position': 'r1c1'});
        expect(bodyOf(answers[8])['answer'], {'position': 'r2c2'});
        final hardLast = bodyOf(answers.last)['answer'] as Map;
        expect(hardLast, {'food_code': 'tomato', 'position': 'r2c2'});

        // ---------------- 再玩一次 ----------------
        await t.tap(find.text('再玩一次'));
        await wait(t, kNav);
        await waitApi(t);
        await wait(t, 300);
        expect(backend.sessionCount, 2);
        expect(find.text('1/10'), findsOneWidget);

        // ---------------- 暫停 → 退出遊戲 ----------------
        await t.tap(find.text('選單'));
        await wait(t, 300);
        expect(find.text('遊戲暫停'), findsOneWidget);
        await t.tap(find.text('退出遊戲'));
        await wait(t, 600);
        expect(gamePageCount(), 0);
        // 與其他遊戲統一：退回堆疊最底層的首頁
        expect(find.text('ROOT_HOME'), findsOneWidget);
      }, backend.client);
    } finally {
      errs.stop();
    }
    expect(errs.messages, isEmpty, reason: errs.messages.join('\n'));
  });

  testWidgets('教學：略過教學 / 上一步在第一頁開暫停 / 暫停中的選項', (t) async {
    await setPhone(t);
    final backend = FakeFridgeBackend();
    final errs = ErrorCollector()..start();
    try {
      await http.runWithClient(() async {
        await t.pumpWidget(buildApp());
        await t.tap(find.text('ROOT_HOME'));
        await wait(t, kNav);
        await t.tap(find.text('OPEN_FRIDGE'));
        await wait(t, 1900);

        // 第一頁按「上一步」= 開暫停
        await t.tap(find.text('上一步'));
        await wait(t, 300);
        expect(find.text('遊戲暫停'), findsOneWidget);
        await t.tap(find.text('繼續遊戲'));
        await wait(t, 300);
        expect(find.text('遊戲暫停'), findsNothing);

        // 走到第 2 頁再用暫停的「重新開始」回到第 1 頁
        await t.tap(find.text('下一步'));
        await wait(t, 400);
        expect(find.text('2 / 6'), findsOneWidget);
        await t.tap(find.byIcon(Icons.arrow_back));
        await wait(t, 300);
        await t.tap(find.text('重新開始'));
        await wait(t, 300);
        expect(find.text('1 / 6'), findsOneWidget);

        // 略過教學 → 遊戲
        await t.tap(find.text('略過教學'));
        await wait(t, kNav);
        await waitApi(t);
        expect(find.byType(FridgeTutorialPage), findsNothing);
        expect(find.text('1/10'), findsOneWidget);
        expect(backend.sessionCount, 1);
      }, backend.client);
    } finally {
      errs.stop();
    }
    expect(errs.messages, isEmpty, reason: errs.messages.join('\n'));
  });

  testWidgets('BUG(輕): 教學完成視窗開著時按左上返回→重新開始，完成視窗不會關', (t) async {
    await setPhone(t);
    final backend = FakeFridgeBackend();
    await http.runWithClient(() async {
      await t.pumpWidget(buildApp());
      await t.tap(find.text('ROOT_HOME'));
      await wait(t, kNav);
      await t.tap(find.text('OPEN_FRIDGE'));
      await wait(t, 1900);
      for (var i = 0; i < 5; i++) {
        await t.tap(find.text('下一步'));
        await wait(t, 1900);
      }
      await t.tap(find.text('下一步'));
      await t.pump();
      expect(find.text('所有難度教學已完成'), findsOneWidget);
      await t.tap(find.byIcon(Icons.arrow_back));
      await wait(t, 300);
      await t.tap(find.text('重新開始'));
      await wait(t, 300);
      expect(find.text('1 / 6'), findsOneWidget);
      // 期望：完成視窗關閉；實際：仍顯示
      expect(find.text('所有難度教學已完成'), findsOneWidget);
    }, backend.client);
  });

  testWidgets('暫停選單：繼續 / 重新開始 正常', (t) async {
    await setPhone(t);
    final backend = FakeFridgeBackend();
    final errs = ErrorCollector()..start();
    try {
      await http.runWithClient(() async {
        await openGame(t);
        await answerCorrect(t, 'easy');
        expect(find.text('2/10'), findsOneWidget);

        await t.tap(find.text('選單'));
        await wait(t, 300);
        await t.tap(find.text('繼續遊戲'));
        await wait(t, 300);
        expect(find.text('遊戲暫停'), findsNothing);
        expect(find.text('2/10'), findsOneWidget);

        await t.tap(find.text('選單'));
        await wait(t, 300);
        await t.tap(find.text('重新開始'));
        await wait(t, kNav);
        await waitApi(t);
        await wait(t, 300);
        expect(backend.sessionCount, 2);
        expect(find.text('1/10'), findsOneWidget);
        expect(gamePageCount(), 1);
      }, backend.client);
    } finally {
      errs.stop();
    }
    expect(errs.messages, isEmpty, reason: errs.messages.join('\n'));
  });

  testWidgets('BUG(中): 遊戲中 暫停→玩法教學→略過教學 後，堆疊裡會有兩個遊戲頁', (t) async {
    await setPhone(t);
    final backend = FakeFridgeBackend();
    await http.runWithClient(() async {
      await openGame(t);
      await answerCorrect(t, 'easy');
      expect(find.text('2/10'), findsOneWidget);

      await t.tap(find.text('選單'));
      await wait(t, 300);
      await t.tap(find.text('玩法教學'));
      await wait(t, kNav);
      expect(find.byType(FridgeTutorialPage), findsOneWidget);
      await wait(t, 1500);
      await t.tap(find.text('略過教學'));
      await wait(t, kNav);
      await waitApi(t);
      await wait(t, 300);

      // 期望：回到原本的遊戲（或只剩一個新遊戲）。實際：舊遊戲頁仍在底下 + 新開一局
      expect(backend.sessionCount, 2);
      expect(gamePageCount(), 2);
      // ignore: avoid_print
      print('[BUG] 暫停→玩法教學→略過教學：FridgeGamePage 數量 = ${gamePageCount()}，session 數 = ${backend.sessionCount}');

      // 兩個遊戲頁都註冊了 lifecycle observer → App 切到背景會跳出兩個暫停視窗
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await wait(t, 300);
      final pauseCount = find.text('遊戲暫停').evaluate().length;
      // ignore: avoid_print
      print('[BUG] 切到背景後暫停視窗數量 = $pauseCount');
      expect(pauseCount, 2);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await wait(t, 100);

      // 關掉兩個暫停視窗，再用新遊戲的 退出遊戲
      await t.tap(find.text('繼續遊戲').last);
      await wait(t, 300);
      await t.tap(find.text('繼續遊戲').last);
      await wait(t, 300);
    }, backend.client);
  });

  testWidgets('BUG(中): 最後一題答對後 800ms 內開暫停（或 App 切背景），結果頁會取代暫停視窗、遊戲頁殘留在底下', (t) async {
    await setPhone(t);
    final backend = FakeFridgeBackend(startQ: 10);
    await http.runWithClient(() async {
      await openGame(t);
      expect(find.text('10/10'), findsOneWidget);

      await placeTomatoAt(t);
      await waitApi(t);
      expect(find.byIcon(Icons.check), findsOneWidget);

      // 答對效果 800ms 內按「選單」
      await t.tap(find.text('選單'));
      await wait(t, 300);
      expect(find.text('遊戲暫停'), findsOneWidget);
      await wait(t, 700); // 計時器觸發 pushReplacement
      await waitApi(t);
      await wait(t, 300);

      expect(find.byType(FridgeResultPage), findsOneWidget);
      // 期望：遊戲頁被取代掉。實際：被取代的是暫停 dialog，遊戲頁還在
      expect(gamePageCount(), 1);
      // ignore: avoid_print
      print('[BUG] 結果頁出現後遊戲頁仍在堆疊：${gamePageCount()}');

      // 結果頁按「退出」：退回堆疊最底層的首頁，殘留的遊戲頁也一起清掉，
      // 不會再回到卡在打勾狀態的舊遊戲畫面
      await t.tap(find.text('退出'));
      await wait(t, kNav);
      expect(find.byType(FridgeResultPage), findsNothing);
      expect(gamePageCount(), 0);
      expect(find.text('ROOT_HOME'), findsOneWidget);
    }, backend.client);
  });

  testWidgets('BUG(中): 同一題快速連點兩下會送出兩次答案（第二次被後端算到下一題）', (t) async {
    await setPhone(t);
    final backend = FakeFridgeBackend();
    final errs = ErrorCollector()..start();
    try {
      await http.runWithClient(() async {
        await openGame(t);
        await t.tap(find.text('豆腐'));
        await t.pump(const Duration(milliseconds: 80));
        await t.tap(find.text('豆腐'));
        await waitApi(t);
        await wait(t, 1000);

        final n = backend.answerRequests.length;
        // ignore: avoid_print
        print('[BUG] 連點兩下送出答案次數 = $n，後端目前題號 = ${backend.q}，分數 = ${backend.score}，畫面 = ${find.textContaining('/10').evaluate().map((e) => (e.widget as Text).data).toList()}');
        expect(n, 2);
        // 第二次送出被後端當成第 2 題的作答（剛好答案一樣 → 第 2 題玩家沒看到就被答掉）
        expect(backend.q, 3);
        expect(backend.score, 20);
        expect(find.text('3/10'), findsOneWidget);
      }, backend.client);
    } finally {
      errs.stop();
    }
  });

  testWidgets('App 生命週期：切背景跳暫停、恢復後按繼續；選單已開時切背景會疊兩個暫停視窗', (t) async {
    await setPhone(t);
    final backend = FakeFridgeBackend();
    final errs = ErrorCollector()..start();
    try {
      await http.runWithClient(() async {
        await openGame(t);

        // paused 時測試環境不會出 frame，所以回到前景後再檢查
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await wait(t, 300);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await wait(t, 300);
        expect(find.text('遊戲暫停'), findsOneWidget);
        await t.tap(find.text('繼續遊戲'));
        await wait(t, 300);
        expect(find.text('遊戲暫停'), findsNothing);

        // 手動開選單後再切背景
        await t.tap(find.text('選單'));
        await wait(t, 300);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await wait(t, 300);
        final count = find.text('遊戲暫停').evaluate().length;
        // ignore: avoid_print
        print('[BUG] 選單開著時切背景，暫停視窗數量 = $count');
        expect(count, 2);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await wait(t, 100);
        await t.tap(find.text('繼續遊戲').last);
        await wait(t, 300);
        await t.tap(find.text('繼續遊戲').last);
        await wait(t, 300);
        expect(find.text('遊戲暫停'), findsNothing);
      }, backend.client);
    } finally {
      errs.stop();
    }
    expect(errs.messages, isEmpty, reason: errs.messages.join('\n'));
  });

  group('API 失敗處理', () {
    testWidgets('建立 session 500 → 錯誤畫面 → 重新連線成功', (t) async {
      await setPhone(t);
      final backend = FakeFridgeBackend()..startStatus = 500;
      final errs = ErrorCollector()..start();
      try {
        await http.runWithClient(() async {
          await openGame(t);
          expect(find.textContaining('無法連線至後端伺服器'), findsOneWidget);
          expect(find.text('重新連線'), findsOneWidget);
          backend.startStatus = 200;
          await t.tap(find.text('重新連線'));
          await t.pump();
          await waitApi(t);
          expect(find.text('1/10'), findsOneWidget);
        }, backend.client);
      } finally {
        errs.stop();
      }
      expect(errs.messages, isEmpty, reason: errs.messages.join('\n'));
    });

    testWidgets('網路錯誤 / 非 JSON 回應 / 沒登入 / 逾時 都進錯誤畫面，不會當機', (t) async {
      await setPhone(t);
      final backend = FakeFridgeBackend()..startThrows = true;
      final errs = ErrorCollector()..start();
      try {
        await http.runWithClient(() async {
          await openGame(t);
          expect(find.textContaining('Connection refused'), findsOneWidget);

          // Cloudflare tunnel 掛掉時常回 HTML
          backend.startThrows = false;
          backend.startStatus = 200;
          backend.startBodyOverride = '<html>Bad gateway</html>';
          await t.tap(find.text('重新連線'));
          await t.pump();
          await waitApi(t);
          expect(find.textContaining('FormatException'), findsOneWidget);

          // 逾時（伺服器 15 秒才回）
          backend.startBodyOverride = null;
          backend.startHang = const Duration(seconds: 15);
          await t.tap(find.text('重新連線'));
          await t.pump();
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          await wait(t, 10500);
          expect(find.textContaining('TimeoutException'), findsOneWidget);
          await wait(t, 6000); // 讓假伺服器的計時器跑完

          // 沒登入
          SharedPreferences.setMockInitialValues({});
          backend.startHang = null;
          final before = backend.requests.length;
          await t.tap(find.text('重新連線'));
          await t.pump();
          await waitApi(t);
          expect(find.textContaining('尚未登入'), findsOneWidget);
          expect(backend.requests.length, before, reason: '沒 token 不該打 API');
        }, backend.client);
      } finally {
        errs.stop();
      }
      expect(errs.messages, isEmpty, reason: errs.messages.join('\n'));
    });

    // 原本是 BUG：錯誤畫面對一般玩家顯示「測試成績頁」按鈕。dev 上已移除
    testWidgets('錯誤畫面不會顯示「測試成績頁」按鈕', (t) async {
      await setPhone(t);
      final backend = FakeFridgeBackend()..startStatus = 500;
      await http.runWithClient(() async {
        await openGame(t);
        expect(find.text('後端尚未開啟時，可以先測試成績頁'), findsNothing);
        expect(find.textContaining('測試成績頁'), findsNothing);
      }, backend.client);
    });

    testWidgets('送答案 500 → 紅色 SnackBar，玩家可以再答一次', (t) async {
      await setPhone(t);
      final backend = FakeFridgeBackend();
      final errs = ErrorCollector()..start();
      try {
        await http.runWithClient(() async {
          await openGame(t);
          backend.answerStatus = 500;
          await t.tap(find.text('豆腐'));
          await waitApi(t);
          expect(find.textContaining('後端判題發生錯誤'), findsOneWidget);
          await wait(t, 5000);
          backend.answerStatus = 200;
          await answerCorrect(t, 'easy');
          expect(find.text('2/10'), findsOneWidget);
        }, backend.client);
      } finally {
        errs.stop();
      }
      expect(errs.messages, isEmpty, reason: errs.messages.join('\n'));
    });

    testWidgets('BUG(中): 後端回答對但沒附 next_question（且不是最後一題）→ 畫面卡在打勾，無法再作答', (t) async {
      await setPhone(t);
      final backend = FakeFridgeBackend()..omitNextQuestion = true;
      await http.runWithClient(() async {
        await openGame(t);
        await t.tap(find.text('豆腐'));
        await waitApi(t);
        await wait(t, 3000);
        expect(find.text('1/10'), findsOneWidget);
        expect(find.byIcon(Icons.check), findsOneWidget);
        final before = backend.answerRequests.length;
        await t.tap(find.text('雞蛋'));
        await waitApi(t);
        expect(backend.answerRequests.length, before, reason: '卡住：點擊都被 _feedbackState 擋掉');
      }, backend.client);
    });

    testWidgets('BUG(輕): session 回 200 但資料格式不對（沒有 session_id / question）→ 空白冰箱，點了沒反應也沒錯誤訊息', (t) async {
      await setPhone(t);
      final backend = FakeFridgeBackend()
        ..startBodyOverride = jsonEncode({'detail': 'something else'});
      await http.runWithClient(() async {
        await openGame(t);
        expect(find.textContaining('無法'), findsNothing); // 沒有顯示錯誤畫面
        expect(find.text('1/10'), findsOneWidget);
        expect(find.text('冷藏室'), findsOneWidget); // 冰箱是空的
        expect(find.text('雞蛋'), findsNothing);
      }, backend.client);
    });

    testWidgets('成績頁：歷史成績 500 → 顯示錯誤 → 重新載入成功', (t) async {
      await setPhone(t);
      final backend = FakeFridgeBackend(startQ: 10)..historyStatus = 500;
      final errs = ErrorCollector()..start();
      try {
        await http.runWithClient(() async {
          await openGame(t);
          await answerCorrect(t, 'hard');
          await wait(t, kNav);
          await waitApi(t);
          expect(find.byType(FridgeResultPage), findsOneWidget);
          expect(find.text('目前無法取得歷史成績'), findsOneWidget);
          expect(find.text('10'), findsWidgets); // 本次 10 分
          backend.historyStatus = 200;
          await t.tap(find.text('重新載入'));
          await t.pump();
          await waitApi(t);
          expect(find.text('目前無法取得歷史成績'), findsNothing);
          expect(find.text('95'), findsOneWidget);
          expect(find.text('沒關係，再加油！'), findsOneWidget);

          // 退出 → 退回堆疊最底層的首頁
          await t.tap(find.text('退出'));
          await wait(t, kNav);
          expect(find.text('ROOT_HOME'), findsOneWidget);
        }, backend.client);
      } finally {
        errs.stop();
      }
      expect(errs.messages, isEmpty, reason: errs.messages.join('\n'));
    });
  });

  group('版面：小螢幕 / 大字體', () {
    Future<List<String>> collectLayout(
      WidgetTester t, {
      required double w,
      required double h,
      double textScale = 1.0,
    }) async {
      final found = <String>[];
      await setPhone(t, w: w * 3, h: h * 3, dpr: 3);
      t.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);

      for (final startQ in [1, 5, 8]) {
        final backend = FakeFridgeBackend(startQ: startQ);
        final errs = ErrorCollector()..start();
        try {
          await http.runWithClient(() async {
            await openGame(t);
            if (startQ == 8) {
              await t.tap(find.text('番茄'));
              await t.pump();
            }
            await t.tap(find.text('選單'));
            await wait(t, 300);
            await t.tap(find.text('繼續遊戲'));
            await wait(t, 300);
          }, backend.client);
        } finally {
          errs.stop();
        }
        found.addAll(errs.overflows.map((m) => '遊戲(${FakeFridgeBackend.diffOf(startQ)}): $m'));
        await t.pumpWidget(const SizedBox());
        await wait(t, 100);
      }

      // 教學每一頁
      {
        final backend = FakeFridgeBackend();
        final errs = ErrorCollector()..start();
        try {
          await http.runWithClient(() async {
            await t.pumpWidget(buildApp());
            await t.tap(find.text('ROOT_HOME'));
            await wait(t, kNav);
            await t.tap(find.text('OPEN_FRIDGE'));
            await wait(t, 1900);
            for (var i = 0; i < 5; i++) {
              await t.tap(find.text('下一步'));
              await wait(t, 1900);
            }
            await t.tap(find.text('下一步'));
            await t.pump();
          }, backend.client);
        } finally {
          errs.stop();
        }
        found.addAll(errs.overflows.map((m) => '教學: $m'));
        await t.pumpWidget(const SizedBox());
        await wait(t, 100);
      }

      // 成績頁
      {
        final backend = FakeFridgeBackend(startQ: 10);
        final errs = ErrorCollector()..start();
        try {
          await http.runWithClient(() async {
            await openGame(t);
            await t.tap(find.text('番茄'));
            await t.pump();
            final a = t.getCenter(find.text('雞蛋'));
            final b = t.getCenter(find.text('牛奶'));
            await t.tapAt(Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2));
            await waitApi(t);
            await wait(t, 1300);
            await waitApi(t);
          }, backend.client);
        } finally {
          errs.stop();
        }
        // 這段會先經過最後一題（困難）畫面，所以也可能收到遊戲頁的溢出
        found.addAll(errs.overflows.map((m) => '最後一題→成績頁: $m'));
        await t.pumpWidget(const SizedBox());
        await wait(t, 100);
      }
      return found;
    }

    testWidgets('一般手機 1080x2340@3、字體 1.0：沒有溢出', (t) async {
      final found = await collectLayout(t, w: 360, h: 780);
      // ignore: avoid_print
      print('[LAYOUT 360x780 x1.0] ${found.isEmpty ? '無溢出' : found.join('\n')}');
      expect(found, isEmpty);
    });

    testWidgets('小手機 360x640、字體 1.0', (t) async {
      final found = await collectLayout(t, w: 360, h: 640);
      // ignore: avoid_print
      print('[LAYOUT 360x640 x1.0]\n${found.isEmpty ? '無溢出' : found.join('\n')}');
    });

    testWidgets('一般手機 360x780、系統字體 1.3（長輩常放大字）', (t) async {
      final found = await collectLayout(t, w: 360, h: 780, textScale: 1.3);
      // ignore: avoid_print
      print('[LAYOUT 360x780 x1.3]\n${found.isEmpty ? '無溢出' : found.join('\n')}');
    });
  });
}
