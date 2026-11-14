// 料理準備（cooking_prep / memory_recall）完整遊玩模擬測試。
//
// 沒有實機／模擬器，所以用 widget test 模擬玩家從遊戲首頁進入、看教學、
// 前測 4 輪、自動進正式賽、升階 basic→intermediate→advanced、時間到、
// 彩蛋、結算、再玩一次、暫停選單各按鈕、以及 API 失敗等情境。
//
// 後端用 FakeBackend 模擬（依照 services/memory_recall_service.dart 與
// models/memory_recall_model.dart 的解析方式產生 JSON），1-back 物品鏈：
// P(0)=seed_item，第 N 輪 option_items = {P(N-1), 干擾物}、new_item = P(N)，
// 選 P(N-1) 才算答對。
//
// 名稱以「BUG:」開頭的測試斷言的是「目前（錯誤）的行為」：通過代表問題仍然存在。
// 每個 BUG 測試上方的 FIXME 註解寫了正確行為應該是什麼；修好 lib/ 之後這些
// 斷言會失敗，屆時請把斷言改成正確行為（並把名稱的「BUG:」拿掉）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:light_memory/features/game/cooking_prep/pages/cooking_prep_game_page.dart';
import '../support/test_home_screen.dart';

// ───────────────────────── Fake backend ─────────────────────────

const Map<String, List<String>> kPools = {
  'basic': ['馬鈴薯', '胡蘿蔔', '洋蔥'],
  'intermediate': ['辣椒粉', '鮮奶油', '咖哩塊'],
  'advanced': ['馬鈴薯塊', '馬鈴薯泥', '紅蘿蔔塊', '紅蘿蔔片', '洋蔥圈', '洋蔥絲'],
};
const Map<String, String> kNextStage = {
  'basic': 'intermediate',
  'intermediate': 'advanced',
};
final List<String> kAllItems = kPools.values.expand((e) => e).toList();

class FakeBackend {
  FakeBackend({
    this.pretest = false,
    this.pretestRounds = 4,
    this.promoteStreak = 2,
    this.bonus = 15,
    this.gameLength = const Duration(seconds: 600),
  });

  bool pretest;
  final int pretestRounds;
  final int promoteStreak;
  final int bonus;
  Duration gameLength;

  /// endpoint -> 依序消耗的故障：int(HTTP status) / 'network' / 'hang'
  final Map<String, List<Object>> faults = {};
  final Map<String, Duration> delays = {};

  /// 送出這一輪答案時回 GAME_TIME_UP（模擬正式賽時間到）
  int? timeUpAtRound;

  /// Demo 模式（admin_demo）：正式賽答完這一輪就回 action: finished，finish/ 的 total_score 固定 80
  int? demoRounds;

  // 狀態
  int startCount = 0;
  int finishCount = 0;
  String? sessionId;
  bool sessionPretest = false;
  String stage = 'basic';
  int bridgeRound = -1;
  String bridgeStage = 'basic';
  List<String> chain = [];
  int servedRound = 0;
  List<String> currentOptions = [];
  int streak = 0;
  int correct = 0;
  int wrong = 0;
  int bonusTotal = 0;
  final List<int> rts = [];
  DateTime? expiresAt;
  bool finished = false;
  int _rot = 0;

  final List<String> log = [];
  final List<Map<String, dynamic>> answerBodies = [];
  final Map<String, int> roundCallsBySession = {};
  final Set<String> finishedSessions = {};

  String get rightAnswer => chain[servedRound - 1];

  http.Response _ok(Map<String, dynamic> data) => http.Response.bytes(
    utf8.encode(jsonEncode({'success': true, 'data': data, 'error': null})),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  http.Response _err(int status, String code, String message) =>
      http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'success': false,
            'data': null,
            'error': {'code': code, 'message': message},
          }),
        ),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  Future<http.Response> handle(http.Request req) async {
    // 先在「收到請求當下」算好回應，再模擬回程延遲（跟真實後端一致）
    final ep = _ep(req.url.path);
    final d = delays[ep];
    http.Response? resp;
    Object? err;
    try {
      resp = await _handle(req);
    } catch (e) {
      err = e;
    }
    if (d != null) await Future<void>.delayed(d);
    if (err != null) throw err;
    return resp!;
  }

  String _ep(String path) {
    if (path.endsWith('/round/answer/')) return 'answer';
    if (path.endsWith('/round/')) return 'round';
    if (path.endsWith('/config/')) return 'config';
    if (path.endsWith('/start/')) return 'start';
    if (path.endsWith('/finish/')) return 'finish';
    return 'other:$path';
  }

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    final String ep;
    if (path.endsWith('/round/answer/')) {
      ep = 'answer';
    } else if (path.endsWith('/round/')) {
      ep = 'round';
    } else if (path.endsWith('/config/')) {
      ep = 'config';
    } else if (path.endsWith('/start/')) {
      ep = 'start';
    } else if (path.endsWith('/finish/')) {
      ep = 'finish';
    } else {
      ep = 'other:$path';
    }
    log.add(ep);
    if (req.headers['Authorization'] != 'Bearer test') {
      return _err(401, 'UNAUTHORIZED', 'no token');
    }
    final f = faults[ep];
    if (f != null && f.isNotEmpty) {
      final x = f.removeAt(0);
      if (x == 'network') {
        throw http.ClientException('Connection closed', req.url);
      }
      if (x == 'hang') return Completer<http.Response>().future;
      if (x is int) {
        return http.Response('<h1>Server Error ($x)</h1>', x);
      }
    }

    switch (ep) {
      case 'config':
        return _ok({
          'is_pretest': pretest,
          'current_stage': 'basic',
          'pretest_total_rounds': pretestRounds,
          'base_time_limit_seconds': gameLength.inSeconds,
          'promote_streak': promoteStreak,
          'promote_bonus_seconds': bonus,
        });
      case 'start':
        startCount++;
        sessionId = 's$startCount';
        sessionPretest = pretest;
        stage = 'basic';
        bridgeRound = -1;
        chain = [kPools['basic']![startCount % 3]];
        servedRound = 0;
        currentOptions = [];
        streak = 0;
        correct = 0;
        wrong = 0;
        bonusTotal = 0;
        rts.clear();
        finished = false;
        expiresAt = sessionPretest ? null : DateTime.now().add(gameLength);
        return _ok({
          'session_id': sessionId,
          'is_pretest': sessionPretest,
          'current_stage': stage,
          'expires_at': expiresAt?.toUtc().toIso8601String(),
          'seed_item': chain.first,
        });
      case 'round':
        final sid = req.url.queryParameters['session_id']!;
        roundCallsBySession[sid] = (roundCallsBySession[sid] ?? 0) + 1;
        if (sid != sessionId) {
          return _err(404, 'SESSION_NOT_FOUND', 'session not found');
        }
        if (finished) {
          return _err(400, 'SESSION_ALREADY_FINISHED', 'already finished');
        }
        servedRound++;
        final prev = chain.last;
        final pool = kPools[stage]!;
        String newItem;
        do {
          newItem = pool[_rot++ % pool.length];
        } while (newItem == prev);
        final distractor = pool.firstWhere(
          (x) => x != prev && x != newItem,
        );
        currentOptions = servedRound.isEven
            ? [prev, distractor]
            : [distractor, prev];
        chain.add(newItem);
        final reported = servedRound == bridgeRound ? bridgeStage : stage;
        return _ok({
          'round_number': servedRound,
          'stage': reported,
          'option_items': currentOptions,
          'new_item': newItem,
        });
      case 'answer':
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        answerBodies.add(body);
        if (body['session_id'] != sessionId) {
          return _err(404, 'SESSION_NOT_FOUND', 'session not found');
        }
        if (finished) {
          return _err(400, 'SESSION_ALREADY_FINISHED', 'already finished');
        }
        if (body['round_number'] != servedRound) {
          return _err(400, 'ROUND_MISMATCH', 'round mismatch');
        }
        if (timeUpAtRound == servedRound) {
          finished = true;
          return _err(400, 'GAME_TIME_UP', '遊戲時間已結束');
        }
        final ok = body['selected_item'] == chain[servedRound - 1];
        rts.add((body['response_time_ms'] as num).toInt());
        if (ok) {
          correct++;
          streak++;
        } else {
          wrong++;
          streak = 0;
        }
        String action = 'next_question';
        int granted = 0;
        if (sessionPretest) {
          if (servedRound >= pretestRounds) action = 'finished';
        } else if (demoRounds != null && servedRound >= demoRounds!) {
          action = 'finished';
        } else if (ok && streak >= promoteStreak && kNextStage[stage] != null) {
          action = 'promoted';
          bridgeStage = stage;
          bridgeRound = servedRound + 1;
          stage = kNextStage[stage]!;
          streak = 0;
          granted = bonus;
          bonusTotal += bonus;
          expiresAt = expiresAt?.add(Duration(seconds: bonus));
        }
        return _ok({
          'is_correct': ok,
          'action': action,
          'current_stage': stage,
          'correct_streak': streak,
          'bonus_seconds_granted': granted,
          'expires_at': expiresAt?.toUtc().toIso8601String(),
          'score_earned': ok ? 10 : 0,
        });
      case 'finish':
        finishCount++;
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        finishedSessions.add(body['session_id'].toString());
        finished = true;
        if (sessionPretest) pretest = false; // 結束過一場，下次就是正式賽
        final total = correct + wrong;
        return _ok({
          'total_rounds': total,
          'total_correct': correct,
          'total_wrong': wrong,
          'accuracy': total == 0 ? 0.0 : correct / total,
          'avg_response_time_ms': rts.isEmpty
              ? 0
              : rts.reduce((a, b) => a + b) ~/ rts.length,
          'final_stage': stage,
          'total_bonus_seconds': bonusTotal,
          'total_score': sessionPretest
              ? null
              : (demoRounds != null ? 80 : correct * 10),
        });
    }
    return http.Response('not found', 404);
  }
}

// ───────────────────────── Harness ─────────────────────────

String _describe(FlutterErrorDetails d) {
  final first = d.exceptionAsString().split('\n').first;
  final lines = d.toString().split('\n');
  final i = lines.indexWhere((l) => l.contains('relevant error-causing widget'));
  final where = (i >= 0 && i + 2 < lines.length)
      ? '${lines[i + 1].trim()} ${lines[i + 2].trim()}'
      : '';
  return '$first  @ $where';
}

class H {
  H(this.t, this.b);
  final WidgetTester t;
  final FakeBackend b;
  final List<String> errors = [];
  final List<String> ignored = [];
  final List<String> failures = [];
  final List<String> previews = [];
  final Set<String> titles = {};
  Set<String> _vis = {};

  bool has(Finder f) => f.evaluate().isNotEmpty;

  void check(bool cond, String msg) {
    if (!cond) failures.add(msg);
  }

  Future<void> step([int ms = 100]) async {
    await t.pump(Duration(milliseconds: ms));
    final e = t.takeException();
    if (e != null) errors.add('UNCAUGHT: $e');
    final now = <String>{};
    for (final it in kAllItems) {
      if (has(find.byKey(ValueKey<String?>(it)))) now.add(it);
    }
    for (final it in now) {
      if (!_vis.contains(it)) previews.add(it);
    }
    _vis = now;
    for (final w in t.widgetList<Text>(find.textContaining('料理準備・'))) {
      titles.add(w.data ?? '');
    }
  }

  Future<void> wait(int ms) async {
    for (var e = 0; e < ms; e += 100) {
      await step(100);
    }
  }

  Future<bool> until(bool Function() c, {int maxMs = 20000, int stepMs = 100}) async {
    for (var e = 0; e <= maxMs; e += stepMs) {
      if (c()) return true;
      await step(stepMs);
    }
    return c();
  }

  bool optionsShown(int n) =>
      b.servedRound == n &&
      b.chain.length > n - 1 &&
      !has(find.text('請記住這個')) &&
      has(find.byKey(ValueKey<String>(b.chain[n - 1])));

  Future<bool> waitOptions(int n, {int maxMs = 20000}) =>
      until(() => optionsShown(n) && !has(find.byType(Dialog)), maxMs: maxMs);

  Future<void> answer(bool correct) async {
    final right = b.rightAnswer;
    final pick = correct
        ? right
        : b.currentOptions.firstWhere((o) => o != right);
    await t.tap(find.byKey(ValueKey<String>(pick)));
    await step(50);
  }

  Future<void> tapText(String s) async {
    await t.tap(find.text(s).last);
    await step(50);
  }

  /// 等教學頁出現並且轉場動畫結束
  Future<bool> waitTutorial() async {
    final ok = await until(() => has(find.text('基本玩法')));
    for (var i = 0; i < 8; i++) {
      await step(100);
    }
    return ok;
  }

  /// 教學頁：一路按「下一頁」到最後按「開始遊戲」
  Future<void> passTutorial() async {
    check(await waitTutorial(), '教學頁沒有出現');
    await tapText('下一頁 →');
    await until(() => has(find.text('三個關卡')), maxMs: 2000);
    await wait(400);
    await tapText('下一頁 →');
    await until(() => has(find.text('限時挑戰')), maxMs: 2000);
    await wait(400);
    await tapText('開始遊戲 →');
    await until(() => !has(find.text('限時挑戰')), maxMs: 2000);
  }

  int? prefsScore() => null;
}

void setSurface(WidgetTester t, Size logical) {
  t.view.devicePixelRatio = 3;
  t.view.physicalSize = logical * 3;
}

/// 包住 http mock、錯誤收集，最後拆掉 widget tree 清空計時器。
Future<H> runGame(
  WidgetTester t,
  FakeBackend b,
  Future<void> Function(H h) body, {
  Size size = const Size(780, 360),
  bool startFromHome = false,
  bool strictTutorialLayout = false,
}) async {
  final h = H(t, b);
  addTearDown(t.view.reset);
  final orig = FlutterError.onError;
  FlutterError.onError = (d) {
    final desc = 'FLUTTER_ERROR: ${_describe(d)}';
    // 教學頁溢出在專門的版面測試檢查，其他測試只記錄不判失敗
    if (!strictTutorialLayout && desc.contains('cooking_prep_tutorial_dialog.dart')) {
      h.ignored.add(desc);
    } else {
      h.errors.add(desc);
    }
  };
  try {
    await http.runWithClient(() async {
      if (startFromHome) {
        setSurface(t, const Size(360, 780));
        await t.pumpWidget(const MaterialApp(home: TestHomeScreen()));
        await h.step();
        await t.tap(find.text('工作記憶'));
        setSurface(t, size); // 頁面鎖橫向
        await h.step();
      } else {
        setSurface(t, size);
        await t.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (ctx) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(ctx).push(
                      MaterialPageRoute(
                        builder: (_) => const CookingPrepGamePage(),
                      ),
                    ),
                    child: const Text('ENTER'),
                  ),
                ),
              ),
            ),
          ),
        );
        await t.tap(find.text('ENTER'));
        await h.step();
      }
      await body(h);
      await t.pumpWidget(const SizedBox());
      for (var i = 0; i < 60; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      final e = t.takeException();
      if (e != null) h.errors.add('UNCAUGHT(teardown): $e');
    }, () => MockClient(b.handle));
  } finally {
    FlutterError.onError = orig;
    // ignore: avoid_print
    for (final e in h.errors) print('  [error] $e');
    // ignore: avoid_print
    for (final f in h.failures) print('  [check-failed] $f');
  }
  return h;
}

/// 正式賽直接進到第 1 輪選項畫面
Future<void> enterFormalRound1(H h) async {
  await h.passTutorial();
  h.check(await h.waitOptions(1), '第1輪選項卡沒有出現');
}

/// 把 prefs 的歷史成績讀出來（需在 fake async 外用 runAsync 讀）
Future<List<String>?> readHistory(WidgetTester t) async {
  return t.runAsync<List<String>?>(() async {
    final p = await SharedPreferences.getInstance();
    return p.getStringList('cooking_prep_score_list');
  });
}

// ───────────────────────── Tests ─────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'access_token': 'test'});
    // audioplayers 的 method/event channel 在測試環境沒有實作，統一回成功。
    TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .allMessagesHandler = (channel, handler, message) {
      if (channel == 'plugins.flutter.io/path_provider') {
        // audioplayers 的 AssetSource 會把音檔複製到暫存資料夾
        return Future.value(
          const StandardMethodCodec().encodeSuccessEnvelope(
            Directory.systemTemp.path,
          ),
        );
      }
      if (channel.startsWith('xyz.luan/audioplayers')) {
        return Future.value(
          const StandardMethodCodec().encodeSuccessEnvelope(null),
        );
      }
      if (handler != null) return handler(message);
      return null;
    };
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding
            .instance
            .defaultBinaryMessenger
            .allMessagesHandler =
        null;
  });

  // Demo 模式（12 月複賽）：admin_demo 沒有熟悉場，第 3 回合答完後端回 action: finished
  testWidgets('Demo 模式：第 3 回合後端回 finished → 呼叫 finish/ 一次並出現結算（總分 80）', (t) async {
    final b = FakeBackend()..demoRounds = 3;
    final h = await runGame(t, b, (h) async {
      await h.passTutorial();
      for (var n = 1; n <= 3; n++) {
        final ok = await h.waitOptions(n);
        h.check(ok, '第$n輪選項沒出現（servedRound=${b.servedRound}）');
        if (!ok) return;
        await h.answer(true);
      }
      h.check(
        await h.until(() => h.has(find.text('本次分數')), maxMs: 5000),
        '第 3 回合後沒有出現結算視窗',
      );
      h.check(b.servedRound == 3, '不應再出第 4 回合（servedRound=${b.servedRound}）');
      h.check(b.finishCount == 1, 'finish/ 應呼叫一次（實際 ${b.finishCount}）');
      h.check(h.has(find.text('總分 80')), '總分應為後端給的 80');
    });
    expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    expect(h.errors, isEmpty, reason: h.errors.join('\n'));
  });

  testWidgets('完整流程：首頁進入→教學→前測4輪→正式賽升兩階→時間到→彩蛋→結算→再玩一次→退出', (
    t,
  ) async {
    final b = FakeBackend(pretest: true)..timeUpAtRound = null;
    final h = await runGame(t, b, startFromHome: true, (h) async {
      // ── 教學（第一次）：含上一頁按鈕
      h.check(await h.waitTutorial(), '教學沒出現');
      await h.tapText('下一頁 →');
      await h.until(() => h.has(find.text('三個關卡')), maxMs: 2000);
      await h.wait(400);
      await t.tap(find.byIcon(Icons.arrow_back));
      await h.wait(400);
      h.check(h.has(find.text('基本玩法')), '教學上一頁無效');
      await h.tapText('下一頁 →');
      await h.wait(400);
      await h.tapText('下一頁 →');
      await h.until(() => h.has(find.text('開始遊戲 →')), maxMs: 2000);
      await h.tapText('開始遊戲 →');

      // ── 前測 4 輪：對、錯、對、對
      final pretestPattern = [true, false, true, true];
      for (var n = 1; n <= 4; n++) {
        final ok = await h.waitOptions(n);
        h.check(ok, '前測第$n輪選項沒出現');
        if (!ok) return;
        h.check(h.has(find.text('練習題 $n / 4')), '前測徽章不是「練習題 $n / 4」');
        if (n == 1) {
          h.check(
            h.previews.length >= 2 &&
                h.previews[0] == b.chain[0] &&
                h.previews[1] == b.chain[1],
            '第1輪應依序展示 seed、P(1)，實際 ${h.previews}',
          );
        }
        h.previews.clear();
        await h.answer(pretestPattern[n - 1]);
      }
      // 前測結束 → 直接開正式賽、不再顯示教學
      final formalStarted = await h.until(() => b.startCount == 2, maxMs: 15000);
      h.check(formalStarted, '前測結束後沒有自動開始正式賽');
      h.check(b.finishCount == 1, '前測結束應呼叫 finish/ 一次');
      await h.wait(300);
      h.check(!h.has(find.text('基本玩法')), '前測→正式賽不該再顯示教學');
      h.check((await readHistory(t)) == null, '前測不應寫入歷史成績');

      // ── 正式賽：T F T T(升調味) T T(升烹飪) T F T，第10輪時間到
      b.timeUpAtRound = 10;
      final pattern = [true, false, true, true, true, true, true, false, true];
      for (var n = 1; n <= 10; n++) {
        final ok = await h.waitOptions(n);
        h.check(ok, '正式賽第$n輪選項沒出現（servedRound=${b.servedRound}）');
        if (!ok) return;
        if (n >= 2) {
          h.check(
            h.previews.length == 1 && h.previews.first == b.chain[n],
            '第$n輪應只展示 P($n)=${b.chain[n]}，實際 ${h.previews}',
          );
        }
        h.previews.clear();
        if (n == 10) {
          await h.answer(true); // → GAME_TIME_UP
        } else {
          await h.answer(pattern[n - 1]);
        }
      }
      h.check(
        await h.until(() => h.has(find.text('時間到！')), maxMs: 3000),
        'GAME_TIME_UP 後沒有顯示「時間到！」',
      );
      h.check(
        await h.until(() => h.has(find.text('恭喜完成烹飪關卡！')), maxMs: 5000),
        '玩到烹飪階段結束時沒有播彩蛋',
      );
      h.check(
        await h.until(() => h.has(find.text('本次分數')), maxMs: 5000),
        '沒有出現結算視窗',
      );
      // 7 對 2 錯 → 78
      h.check(h.has(find.text('78')), '結算分數應為 78（7/9）');
      h.check(h.has(find.text('總分 70')), '總分應為 70');
      h.check(h.titles.contains('料理準備・切菜'), '沒看到切菜標題');
      h.check(h.titles.contains('料理準備・調味'), '沒看到調味標題 ${h.titles}');
      h.check(h.titles.contains('料理準備・烹飪'), '沒看到烹飪標題 ${h.titles}');
      h.check((await readHistory(t))?.join(',') == '78', '歷史成績應為 [78]');
      for (final body in b.answerBodies) {
        h.check(
          (body['response_time_ms'] as int) >= 0,
          'response_time_ms 為負：$body',
        );
      }

      // ── 再玩一次 → 教學再出現（關閉鈕）→ 第1輪 → 選單 → 退出
      await h.tapText('再玩一次');
      h.check(await h.waitTutorial(), '再玩一次後沒有教學');
      h.check(b.startCount == 3, '再玩一次應重新 start/');
      await t.tap(find.byIcon(Icons.close));
      await h.wait(400);
      h.check(await h.waitOptions(1), '再玩一次後第1輪沒出現');
      await h.tapText('選單');
      h.check(h.has(find.text('遊戲暫停')), '暫停選單沒出現');
      await h.tapText('退出遊戲');
      setSurface(t, const Size(360, 780)); // 頁面 dispose 會鎖回直向
      await h.wait(500);
      await h.wait(500);
      h.check(h.has(find.text('工作記憶')), '退出後沒回到遊戲首頁');
    });
    expect(h.errors, isEmpty, reason: h.errors.join('\n'));
    expect(h.failures, isEmpty, reason: h.failures.join('\n'));
  });

  for (final size in const [Size(640, 360), Size(780, 360), Size(360, 640)]) {
    testWidgets('版面：${size.width.toInt()}x${size.height.toInt()} 教學＋各階段＋暫停＋結算不溢出', (
      t,
    ) async {
      final b = FakeBackend(promoteStreak: 1)..timeUpAtRound = 6;
      // 教學頁的溢出（BUG，見下方獨立測試）在這裡不計入錯誤，其餘畫面仍嚴格檢查
      final h = await runGame(t, b, size: size, (h) async {
        await h.passTutorial();
        final pattern = [true, true, true, true, false];
        for (var n = 1; n <= 6; n++) {
          // 展示階段中途打開暫停選單再繼續
          await h.until(() => h.has(find.text('請記住這個')), maxMs: 5000);
          if (h.has(find.text('請記住這個'))) {
            await h.tapText('選單');
            await h.wait(300);
            await h.tapText('繼續遊戲');
          }
          final ok = await h.waitOptions(n);
          h.check(ok, '第$n輪沒出現');
          if (!ok) return;
          await h.answer(n == 6 ? true : pattern[n - 1]);
        }
        h.check(
          await h.until(() => h.has(find.text('本次分數')), maxMs: 8000),
          '結算沒出現',
        );
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });
  }

  // FIXME(正確行為)：教學頁第 1 頁在橫向手機（高度 360）不應溢出，
  // cooking_prep_tutorial_dialog.dart:270 的 Column 需要可捲動或縮小。
  // 修好後把斷言改成「沒有溢出錯誤」（errors 應為空），並移除 BUG 前綴。
  for (final size in const [Size(640, 360), Size(780, 360)]) {
    testWidgets('BUG: 教學頁在 ${size.width.toInt()}x${size.height.toInt()} 橫向會 RenderFlex 溢出', (
      t,
    ) async {
      final b = FakeBackend();
      final h = await runGame(t, b, size: size, strictTutorialLayout: true, (h) async {
        h.check(await h.waitTutorial(), '教學頁沒有出現');
        h.check(
          h.errors.any(
            (e) =>
                e.contains('overflowed') &&
                e.contains('cooking_prep_tutorial_dialog.dart'),
          ),
          '目前行為：教學頁第 1 頁溢出，這次沒有重現',
        );
        h.errors.clear(); // 已知溢出，其餘錯誤才算失敗
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });
  }

  group('API 失敗', () {
    testWidgets('config/ 500 + start/ 500 → 錯誤畫面 → 重試成功', (t) async {
      final b = FakeBackend();
      b.faults['config'] = [500];
      b.faults['start'] = [500];
      final h = await runGame(t, b, (h) async {
        h.check(
          await h.until(() => h.has(find.text('重試'))),
          'start/ 失敗沒有顯示錯誤畫面',
        );
        h.check(h.has(find.text('發生錯誤（500）')), '錯誤訊息不對');
        await h.tapText('重試');
        await enterFormalRound1(h);
        await h.answer(true);
        h.check(await h.waitOptions(2), '重試後第2輪沒出現');
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });

    testWidgets('start/ 網路錯誤 → 錯誤畫面不卡住', (t) async {
      final b = FakeBackend();
      b.faults['start'] = ['network'];
      final h = await runGame(t, b, (h) async {
        h.check(await h.until(() => h.has(find.text('重試'))), '沒有錯誤畫面');
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });

    testWidgets('遊戲中 round/ 500 → 直接結算不當機', (t) async {
      final b = FakeBackend();
      final h = await runGame(t, b, (h) async {
        await enterFormalRound1(h);
        b.faults['round'] = [500];
        await h.answer(false);
        h.check(
          await h.until(() => h.has(find.text('本次分數')), maxMs: 8000),
          'round/ 失敗後沒有進結算',
        );
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });

    testWidgets('遊戲中 round/answer/ 網路錯誤 → 直接結算不當機', (t) async {
      final b = FakeBackend();
      final h = await runGame(t, b, (h) async {
        await enterFormalRound1(h);
        b.faults['answer'] = ['network'];
        await h.answer(true);
        h.check(
          await h.until(() => h.has(find.text('本次分數')), maxMs: 8000),
          'answer 失敗後沒有進結算',
        );
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });

    // FIXME(正確行為)：finish/ 失敗時不該把 0 分寫進歷史成績（歷史應維持 80,90）。
    testWidgets('BUG: finish/ 失敗時把 0 分寫進歷史成績與結算', (t) async {
      final b = FakeBackend()..timeUpAtRound = 3;
      SharedPreferences.setMockInitialValues({
        'access_token': 'test',
        'cooking_prep_score_list': ['80', '90'],
        'cooking_prep_highest_score': 90,
      });
      final h = await runGame(t, b, (h) async {
        await enterFormalRound1(h);
        await h.answer(true);
        await h.waitOptions(2);
        await h.answer(true);
        await h.waitOptions(3);
        b.faults['finish'] = [500];
        await h.answer(true); // GAME_TIME_UP → finish/ 500
        h.check(
          await h.until(() => h.has(find.text('本次分數')), maxMs: 8000),
          '結算沒出現',
        );
        final hist = await readHistory(t);
        h.check(
          hist?.join(',') == '80,90,0',
          '目前行為：finish/ 失敗（實際 2 題全對）卻把 0 分寫進歷史（預期 80,90,0），實際：$hist',
        );
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });

    // FIXME(正確行為)：停在「重試」錯誤畫面時應停止單題計時，不該自動 finish/ 跳出結算。
    testWidgets('BUG: 正式賽第1輪 round/ 失敗停在錯誤畫面，10 秒後結算視窗疊在錯誤畫面上', (
      t,
    ) async {
      final b = FakeBackend();
      b.faults['round'] = [500];
      final h = await runGame(t, b, (h) async {
        await h.passTutorial();
        h.check(await h.until(() => h.has(find.text('重試'))), '沒有錯誤畫面');
        // 單題計時用真實時間（DateTime.now），所以真的等 10.5 秒
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10500)),
        );
        await h.until(() => h.has(find.text('本次分數')), maxMs: 4000);
        h.check(
          h.has(find.text('本次分數')) &&
              h.has(find.text('重試')) &&
              b.finishCount == 1 &&
              (await readHistory(t))?.join(',') == '0',
          '目前行為：玩家停在「重試」錯誤畫面時，背景單題計時到期，自動 finish/ 並跳出 0 分結算 '
          '（finish 次數=${b.finishCount}，歷史=${await readHistory(t)}）',
        );
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });

    // FIXME(正確行為)：http 請求要有逾時，逾時後應顯示錯誤／重試而不是永遠卡住。
    testWidgets('BUG(輕): 前測中 answer 請求沒回應 → 沒有逾時，畫面永遠卡住', (t) async {
      final b = FakeBackend(pretest: true);
      final h = await runGame(t, b, (h) async {
        await h.passTutorial();
        h.check(await h.waitOptions(1), '第1輪沒出現');
        b.faults['answer'] = ['hang'];
        await h.answer(true);
        for (var i = 0; i < 60; i++) {
          await h.step(1000);
        }
        h.check(
          !h.has(find.text('重試')) &&
              !h.has(find.text('本次分數')) &&
              b.servedRound == 1,
          '目前行為：送出答案後 60 秒沒有任何回饋（http 無 timeout，前測又沒有計時器）',
        );
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });
  });

  group('計時', () {
    testWidgets('整場時間到（本地倒數）→ 時間到！→ 結算', (t) async {
      final b = FakeBackend(gameLength: const Duration(seconds: 2));
      final h = await runGame(t, b, (h) async {
        await enterFormalRound1(h);
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2600)),
        );
        h.check(
          await h.until(() => h.has(find.text('時間到！')), maxMs: 1000),
          '沒顯示時間到！',
        );
        h.check(
          await h.until(() => h.has(find.text('本次分數')), maxMs: 5000),
          '時間到後沒有結算',
        );
        h.check(b.finishCount == 1, 'finish/ 應呼叫 1 次，實際 ${b.finishCount}');
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });

    testWidgets('單題超時（10 秒）→ 本題超過作答時間 → 結算', (t) async {
      final b = FakeBackend();
      final h = await runGame(t, b, (h) async {
        await enterFormalRound1(h);
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10300)),
        );
        h.check(
          await h.until(() => h.has(find.text('本題超過作答時間')), maxMs: 1000),
          '沒顯示本題超過作答時間',
        );
        h.check(
          await h.until(() => h.has(find.text('本次分數')), maxMs: 5000),
          '超時後沒有結算',
        );
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });
  });

  group('暫停選單', () {
    testWidgets('展示物品時暫停會凍結，繼續後接續；玩法教學返回暫停選單', (t) async {
      final b = FakeBackend();
      final h = await runGame(t, b, (h) async {
        await h.passTutorial();
        await h.until(() => h.has(find.text('請記住這個')), maxMs: 3000);
        await h.tapText('選單');
        for (var i = 0; i < 50; i++) {
          await h.step(100);
        }
        h.check(h.has(find.text('請記住這個')), '暫停 5 秒後展示階段不該被跳過');
        // 玩法教學 → 關閉 → 回到暫停選單
        await h.tapText('玩法教學');
        h.check(await h.waitTutorial(), '教學沒出現');
        await t.tap(find.byIcon(Icons.close));
        await h.wait(500);
        h.check(h.has(find.text('遊戲暫停')), '關閉教學後應回到暫停選單');
        h.check(h.has(find.text('請記住這個')), '暫停期間展示被跳過');
        await h.tapText('繼續遊戲');
        h.check(await h.waitOptions(1), '繼續後第1輪沒出現');
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });

    // FIXME(正確行為)：暫停中不該揭曉下一輪選項卡（展示動畫應凍結到繼續遊戲後）。
    testWidgets('BUG: 答題後立刻暫停，下一個物品的展示在暫停選單後面播完', (t) async {
      final b = FakeBackend();
      final h = await runGame(t, b, (h) async {
        await enterFormalRound1(h);
        await h.answer(false); // 答錯會停 1.8 秒
        await h.tapText('選單');
        h.check(h.has(find.text('遊戲暫停')), '暫停選單沒出現');
        for (var i = 0; i < 60; i++) {
          await h.step(100);
        }
        h.check(
          h.optionsShown(2),
          '目前行為：暫停中第2輪的 new_item 展示已在暫停選單後面播完、選項卡已揭曉（玩家錯過要記的物品）',
        );
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });

    // FIXME(正確行為)：response_time_ms 不該是負數（>= 0）。
    testWidgets('BUG: 上述情況下送出的 response_time_ms 會是負數', (t) async {
      final b = FakeBackend();
      final h = await runGame(t, b, (h) async {
        await enterFormalRound1(h);
        await h.answer(false);
        await h.tapText('選單');
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1000)),
        );
        // 背景流程在暫停中揭曉第2輪（_questionShownAt = 現在）
        await h.until(() => h.optionsShown(2), maxMs: 6000);
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1000)),
        );
        await h.tapText('繼續遊戲'); // _questionShownAt += 整段暫停時間
        await h.answer(true);
        await h.step(200);
        final rt = b.answerBodies.last['response_time_ms'] as int;
        h.check(rt < 0, '目前行為：送給後端的 response_time_ms 應為負數，實際 $rt');
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });

    testWidgets('重新開始：重新 start/ 並再顯示教學', (t) async {
      final b = FakeBackend();
      final h = await runGame(t, b, (h) async {
        await enterFormalRound1(h);
        await h.tapText('選單');
        await h.tapText('重新開始');
        h.check(await h.waitTutorial(), '重新開始後沒教學');
        h.check(b.startCount == 2, 'startCount=${b.startCount}');
        await t.tap(find.byIcon(Icons.close));
        await h.wait(400);
        h.check(await h.waitOptions(1), '重新開始後第1輪沒出現');
        h.check(
          h.previews.length >= 2 && h.previews[h.previews.length - 2] == b.chain[0],
          '重新開始後第1輪應先展示 seed',
        );
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });

    // FIXME(正確行為)：重新開始後舊的作答流程要被取消：教學開著時新場次 s2 不該被
    // 呼叫 round/，關閉教學後看到的應是新場次第 1 輪（servedRound == 1）。
    testWidgets('BUG: 答錯後 1.8 秒內按重新開始，舊流程在教學背後偷抓新場次的題目', (
      t,
    ) async {
      final b = FakeBackend();
      final h = await runGame(t, b, (h) async {
        await enterFormalRound1(h);
        await h.answer(false);
        await h.tapText('選單');
        await h.tapText('重新開始');
        h.check(await h.waitTutorial(), '沒教學');
        for (var i = 0; i < 50; i++) {
          await h.step(100);
        }
        h.check(
          (b.roundCallsBySession['s2'] ?? 0) >= 1,
          '目前行為：教學還開著，新場次 s2 已被呼叫 round/（預期 >=1 次），實際 ${b.roundCallsBySession['s2']} 次'
          '（舊的 _onOptionTap 流程沒被取消）',
        );
        await t.tap(find.byIcon(Icons.close));
        await h.wait(400);
        // 新場次第1輪應展示 seed→P(1)，正解為 seed
        await h.wait(5000);
        h.check(
          b.servedRound > 1,
          '目前行為：關閉教學後看到的不是新場次第1輪（預期 servedRound>1），實際 ${b.servedRound}',
        );
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });

    // FIXME(正確行為)：不該有任何例外；重新開始要取消舊的作答流程，
    // 避免 _buildRewardWidget 的 `_currentRound!` 空值崩潰（page.dart 約 1202 行）。
    // FIXME(正確行為)：不該有任何例外；重新開始要取消舊的作答流程，
    // 避免 _buildRewardWidget 的 `_currentRound!` 空值崩潰（page.dart 約 1202 行）。
    testWidgets('BUG: 答對後網路慢、此時按重新開始 → _currentRound! 空值崩潰', (t) async {
      final b = FakeBackend();
      final h = await runGame(t, b, (h) async {
        await enterFormalRound1(h);
        b.delays['answer'] = const Duration(milliseconds: 1500);
        await h.answer(true); // basic 答對 → 400ms 後要顯示切菜動畫
        await h.tapText('選單');
        await h.tapText('重新開始');
        for (var i = 0; i < 40; i++) {
          await h.step(100);
        }
        await t.tap(find.byIcon(Icons.close));
        for (var i = 0; i < 40; i++) {
          await h.step(100);
        }
        h.check(
          h.errors.any((e) => e.contains('Null check operator')),
          '目前行為：應重現 Null check operator used on a null value，實際錯誤：${h.errors}',
        );
        h.errors.removeWhere((e) => e.contains('Null check operator'));
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });

    // FIXME(正確行為)：中途退出應呼叫 finish/ 一次（finishCount == 1）。
    testWidgets('BUG: 遊戲中途退出不呼叫 finish/（規格要求中途離開要呼叫）', (t) async {
      final b = FakeBackend();
      final h = await runGame(t, b, (h) async {
        await enterFormalRound1(h);
        await h.tapText('選單');
        await h.tapText('退出遊戲');
        await h.wait(500);
        await h.wait(500);
        h.check(b.finishCount == 0, '目前行為：中途退出不呼叫 finish/（預期 0 次），實際 ${b.finishCount}');
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });

    // FIXME(正確行為)：新的一場開始後不該還有舊的暫停選單蓋在上面（!has('遊戲暫停')）。
    testWidgets('BUG: 結束提示期間打開選單 → 結算疊在暫停選單上，再玩一次後暫停選單殘留', (
      t,
    ) async {
      final b = FakeBackend()..timeUpAtRound = 2;
      final h = await runGame(t, b, (h) async {
        await enterFormalRound1(h);
        await h.answer(false);
        await h.waitOptions(2);
        await h.answer(true); // GAME_TIME_UP → 顯示「時間到！」1.5 秒
        await h.until(() => h.has(find.text('時間到！')), maxMs: 2000);
        await h.tapText('選單');
        await h.until(() => h.has(find.text('本次分數')), maxMs: 5000);
        await h.tapText('再玩一次');
        await h.waitTutorial();
        await t.tap(find.byIcon(Icons.close));
        await h.wait(500);
        await h.wait(500);
        h.check(
          h.has(find.text('遊戲暫停')),
          '目前行為：新的一場已經開始計時，但舊的暫停選單還蓋在畫面上',
        );
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });

    // FIXME(正確行為)：暫停選單開著時，後面不該在展示物品（兩者不該同時成立）。
    testWidgets('BUG: 讀取中（網路慢）按選單 → 教學蓋在暫停選單上，教學關閉後遊戲在暫停選單後面跑', (
      t,
    ) async {
      final b = FakeBackend();
      b.delays['start'] = const Duration(seconds: 2);
      final h = await runGame(t, b, (h) async {
        await h.wait(300);
        await h.tapText('選單');
        await h.passTutorial();
        await h.wait(500);
        await h.wait(500);
        h.check(
          h.has(find.text('遊戲暫停')) && h.has(find.text('請記住這個')),
          '目前行為：暫停選單還開著，但後面已經在展示要記的物品',
        );
      });
      expect(h.errors, isEmpty, reason: h.errors.join('\n'));
      expect(h.failures, isEmpty, reason: h.failures.join('\n'));
    });
  });
}
