// 聲影日記 AI 對話頁：往上滑照片縮小、錄音時進入聚焦模式（黑色 50% 疊層＋照片與問題置中）

// record_platform_interface 是 record 的相依套件，測試裡用它換掉真的麥克風
// ignore: depend_on_referenced_packages
import 'package:record_platform_interface/record_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:light_memory/features/diary/models/diary_model.dart';
import 'package:light_memory/features/diary/pages/diary_chat_page.dart';

const _question = '這張照片是在哪裡拍的？當時發生了什麼特別的事情嗎？';
const _subtitle = 'AI 會陪你聊 4 段小對話，聊完會自動生成今天的日記';

/// 假的錄音 platform：一律有權限、start 後就算錄音中、stop 回傳假路徑
class _FakeRecordPlatform extends RecordPlatform
    with MockPlatformInterfaceMixin {
  bool _recording = false;

  @override
  Future<void> create(String recorderId) async {}

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      true;

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async {
    _recording = true;
  }

  @override
  Future<bool> isRecording(String recorderId) async => _recording;

  @override
  Future<bool> isPaused(String recorderId) async => false;

  @override
  Future<void> pause(String recorderId) async {}

  @override
  Future<void> resume(String recorderId) async {}

  @override
  Future<String?> stop(String recorderId) async {
    _recording = false;
    return 'round_audio.webm';
  }

  @override
  Future<void> cancel(String recorderId) async {
    _recording = false;
  }

  @override
  Future<void> dispose(String recorderId) async {}

  @override
  Future<Amplitude> getAmplitude(String recorderId) async =>
      Amplitude(current: -30, max: 0);

  @override
  Stream<RecordState> onStateChanged(String recorderId) =>
      const Stream<RecordState>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DiaryModel _diary({String photoUrl = 'https://example.com/photo.jpg'}) =>
    DiaryModel.fromJson({
      'diary_id': 1,
      'date': '2026-11-14',
      'created_at': '2026-11-14T10:00:00+08:00',
      'status': 'in_progress',
      'photo_url': photoUrl,
      'first_question': _question,
    });

/// AI 問題出現在疊層上（對話列表裡本來就有一份）
Finder get _overlayQuestion => find.text(_question);

/// 聚焦疊層的透明度（0 = 沒有聚焦）
double _overlayOpacity(WidgetTester tester) {
  return tester
      .widget<AnimatedOpacity>(
        find.byKey(const ValueKey('diary-focus-overlay')),
      )
      .opacity;
}

/// 標題列上的聚焦疊層透明度
double _topOverlayOpacity(WidgetTester tester) {
  return tester
      .widget<AnimatedOpacity>(
        find.byKey(const ValueKey('diary-focus-overlay-top')),
      )
      .opacity;
}

/// 錄音中計時器、波形每 150ms 更新一次，用固定時間的 pump 讓動畫跑完
Future<void> _pumpWhileRecording(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late RecordPlatform original;

  setUp(() {
    original = RecordPlatform.instance;
    RecordPlatform.instance = _FakeRecordPlatform();
  });
  tearDown(() => RecordPlatform.instance = original);

  Future<void> pumpPage(WidgetTester tester, {DiaryModel? diary}) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: DiaryChatPage(initialDiary: diary ?? _diary())),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('一開始：標題、說明、照片都在，沒有聚焦疊層', (tester) async {
    await pumpPage(tester);

    expect(find.text(_subtitle), findsOneWidget);
    expect(_overlayOpacity(tester), 0);
    expect(find.bySemanticsLabel('放大照片'), findsNothing);
  });

  testWidgets('往上滑對話氣泡：照片縮成縮圖，點縮圖放回原本大小', (tester) async {
    await pumpPage(tester);

    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();

    expect(find.text(_subtitle), findsNothing);
    expect(find.bySemanticsLabel('放大照片'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('放大照片'));
    await tester.pumpAndSettle();

    expect(find.text(_subtitle), findsOneWidget);
  });

  testWidgets('在最上面往下拉：照片展開', (tester) async {
    await pumpPage(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(find.text(_subtitle), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, 120));
    await tester.pumpAndSettle();

    expect(find.text(_subtitle), findsOneWidget);
  });

  testWidgets('沒有照片時往上滑不會縮', (tester) async {
    await pumpPage(tester, diary: _diary(photoUrl: ''));

    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();

    expect(find.text(_subtitle), findsOneWidget);
  });

  testWidgets('錄音中與暫停：聚焦疊層出現，問題顯示在疊層上；重錄回待機就恢復', (tester) async {
    await pumpPage(tester);
    expect(_overlayQuestion, findsOneWidget);

    // 開始錄音（錄音中計時器一直在跑，不能用 pumpAndSettle，會一路跑到 3 分鐘自動送出）
    await tester.tap(find.byIcon(Icons.mic));
    await _pumpWhileRecording(tester);

    expect(_overlayOpacity(tester), 1);
    // 對話列表一份＋疊層一份
    expect(_overlayQuestion, findsNWidgets(2));
    expect(find.text('點擊暫停，或按完成送出'), findsOneWidget);

    // 暫停仍維持聚焦
    await tester.tap(find.byIcon(Icons.pause));
    await _pumpWhileRecording(tester);
    expect(_overlayOpacity(tester), 1);

    // 重新錄製 → 回到待機，疊層消失
    await tester.tap(find.text('重新錄製'));
    await tester.pumpAndSettle();
    expect(_overlayOpacity(tester), 0);
    expect(_overlayQuestion, findsOneWidget);
  });

  testWidgets('按完成送出：離開聚焦模式（第一輪太短會請長輩再錄一次）', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byIcon(Icons.mic));
    await _pumpWhileRecording(tester);
    expect(_overlayOpacity(tester), 1);

    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(_overlayOpacity(tester), 0);
  });

  testWidgets('小螢幕手機（360x640）聚焦模式不溢版', (tester) async {
    await pumpPage(tester);
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.mic));
    await _pumpWhileRecording(tester);

    expect(tester.takeException(), isNull);
    expect(_overlayOpacity(tester), 1);
    // 收尾：暫停錄音，計時器才不會留到測試結束
    await tester.tap(find.byIcon(Icons.pause));
    await _pumpWhileRecording(tester);
  });

  testWidgets('聚焦模式蓋滿整個畫面：標題列、對話區都模糊變暗，錄音區黑底撐滿寬度', (tester) async {
    // 寬螢幕（網頁版）也要整個寬度都變暗
    tester.view.physicalSize = const Size(1000 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    // 從別頁推進來，返回鍵才有地方可以回去
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigatorKey, home: const SizedBox()),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => DiaryChatPage(initialDiary: _diary()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(BackdropFilter), findsNothing);
    expect(_topOverlayOpacity(tester), 0);

    await tester.tap(find.byIcon(Icons.mic));
    await _pumpWhileRecording(tester);

    // 標題列＋對話區各一層模糊
    expect(find.byType(BackdropFilter), findsNWidgets(2));
    expect(_topOverlayOpacity(tester), 1);

    // 錄音區的黑色底撐滿整個寬度（不是只有按鈕那一塊）
    final recordArea = find
        .ancestor(
          of: find.text('點擊暫停，或按完成送出'),
          matching: find.byType(AnimatedContainer),
        )
        .first;
    expect(tester.getSize(recordArea).width, 1000);
    // 而且一路到螢幕最下面
    expect(tester.getBottomLeft(recordArea).dy, 844);

    // 聚焦時標題列的返回鍵被疊層擋住，不會不小心離開
    await tester.tap(find.byIcon(Icons.arrow_back), warnIfMissed: false);
    await _pumpWhileRecording(tester);
    expect(find.byType(DiaryChatPage), findsOneWidget);

    await tester.tap(find.byIcon(Icons.pause));
    await _pumpWhileRecording(tester);
  });
}
