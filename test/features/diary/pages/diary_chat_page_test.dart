// 聲影日記 AI 對話頁：往上滑照片縮小、錄音時進入聚焦模式（黑色 50% 疊層＋照片與問題置中）

// record_platform_interface 是 record 的相依套件，測試裡用它換掉真的麥克風
// ignore: depend_on_referenced_packages
import 'package:record_platform_interface/record_platform_interface.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
// path_provider_platform_interface 是 path_provider 的相依套件，測試裡換掉暫存資料夾
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:light_memory/features/diary/models/diary_model.dart';
import 'package:light_memory/features/diary/pages/diary_chat_page.dart';

const _question = '這張照片是在哪裡拍的？當時發生了什麼特別的事情嗎？';
const _subtitle = 'AI 會陪你聊 4 段小對話，聊完會自動生成今天的日記';

/// 假的錄音 platform：一律有權限、start 後就算錄音中、stop 回傳假路徑
class _FakeRecordPlatform extends RecordPlatform
    with MockPlatformInterfaceMixin {
  bool _recording = false;
  bool permission = true;
  String? lastPath;
  RecordConfig? lastConfig;

  @override
  Future<void> create(String recorderId) async {}

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      permission;

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async {
    lastPath = path;
    lastConfig = config;
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

DiaryModel _diary({
  String photoUrl = 'https://example.com/photo.jpg',
  String question = _question,
}) => DiaryModel.fromJson({
  'diary_id': 1,
  'date': '2026-11-14',
  'created_at': '2026-11-14T10:00:00+08:00',
  'status': 'in_progress',
  'photo_url': photoUrl,
  'first_question': question,
});

/// Android（捲到頭會停住）和 iPhone（捲到頭會回彈）的捲動方式不同，兩種都要測
const _androidAndIos = TargetPlatformVariant(<TargetPlatform>{
  TargetPlatform.android,
  TargetPlatform.iOS,
});

/// 很長的問題，讓對話列表可以捲動（模擬聊了好幾輪）
final _longQuestion = List.filled(40, '這張照片是在哪裡拍的？').join();

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

/// 假的手機暫存資料夾
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getTemporaryPath() async => '/fake/tmp';
}

void main() {
  late RecordPlatform original;
  late PathProviderPlatform originalPaths;
  late _FakeRecordPlatform recorder;

  setUp(() {
    original = RecordPlatform.instance;
    originalPaths = PathProviderPlatform.instance;
    recorder = _FakeRecordPlatform();
    RecordPlatform.instance = recorder;
    PathProviderPlatform.instance = _FakePathProvider();
  });
  tearDown(() {
    RecordPlatform.instance = original;
    PathProviderPlatform.instance = originalPaths;
  });

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

  testWidgets('對話還很短時：往下拉縮小，往上推展開，點縮圖也能展開', (tester) async {
    await pumpPage(tester);

    // 往下拉（想看前面的對話）→ 照片縮成縮圖
    await tester.drag(find.byType(ListView), const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(find.text(_subtitle), findsNothing);
    expect(find.bySemanticsLabel('放大照片'), findsOneWidget);

    // 往上推（回到最新）→ 展開
    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(find.text(_subtitle), findsOneWidget);

    // 再縮一次，點縮圖展開
    await tester.drag(find.byType(ListView), const Offset(0, 120));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('放大照片'));
    await tester.pumpAndSettle();
    expect(find.text(_subtitle), findsOneWidget);
  }, variant: _androidAndIos);

  testWidgets('對話很長時：往上捲看前面的對話縮小，捲回最底部展開', (tester) async {
    await pumpPage(tester, diary: _diary(question: _longQuestion));
    final list = find.byType(ListView);

    // 先捲到最底部（最新的問題），照片維持展開
    await tester.drag(list, const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(find.text(_subtitle), findsOneWidget);

    // 往上捲看前面 → 縮小
    await tester.drag(list, const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(find.text(_subtitle), findsNothing);

    // 捲到一半往下（還沒到底）→ 維持縮小
    await tester.drag(list, const Offset(0, -50));
    await tester.pumpAndSettle();
    expect(find.text(_subtitle), findsNothing);

    // 捲回最底部 → 展開
    await tester.drag(list, const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(find.text(_subtitle), findsOneWidget);
  }, variant: _androidAndIos);

  testWidgets('往下快速滑回最底部（慣性）也會展開', (tester) async {
    await pumpPage(tester, diary: _diary(question: _longQuestion));
    final list = find.byType(ListView);

    await tester.drag(list, const Offset(0, -3000));
    await tester.pumpAndSettle();
    await tester.drag(list, const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text(_subtitle), findsNothing);

    // 快速往上一甩，靠慣性衝回最底部
    await tester.fling(list, const Offset(0, -200), 3000);
    await tester.pumpAndSettle();
    expect(find.text(_subtitle), findsOneWidget);
  }, variant: _androidAndIos);

  testWidgets('網頁版用滑鼠滾輪捲動也會縮小、展開', (tester) async {
    await pumpPage(tester, diary: _diary(question: _longQuestion));
    final center = tester.getCenter(find.byType(ListView));

    Future<void> wheel(double dy) async {
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      pointer.hover(center);
      await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
      await tester.pumpAndSettle();
    }

    await wheel(3000); // 滾到最底部
    expect(find.text(_subtitle), findsOneWidget);

    await wheel(-200); // 往上滾看前面
    expect(find.text(_subtitle), findsNothing);

    await wheel(3000); // 滾回最底部
    expect(find.text(_subtitle), findsOneWidget);
  });

  testWidgets('沒有照片時捲動不會縮', (tester) async {
    await pumpPage(tester, diary: _diary(photoUrl: ''));

    await tester.drag(find.byType(ListView), const Offset(0, 120));
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

  testWidgets('手機 App 錄音：存到 App 的暫存資料夾，用 AAC（m4a）編碼', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byIcon(Icons.mic));
    await _pumpWhileRecording(tester);

    // 只給檔名會寫到 App 不能寫的根目錄，iOS 錄音直接失敗
    expect(recorder.lastPath, '/fake/tmp/round_audio.m4a');
    expect(recorder.lastConfig?.encoder, AudioEncoder.aacLc);
    expect(_overlayOpacity(tester), 1);
  });

  testWidgets('手機 App 沒有麥克風權限：請長輩到手機設定開啟，不會叫他去開瀏覽器權限', (tester) async {
    recorder.permission = false;
    await pumpPage(tester);

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();

    expect(find.textContaining('請到手機的「設定」允許憶智防線使用麥克風'), findsOneWidget);
    expect(find.textContaining('瀏覽器'), findsNothing);
    expect(recorder.lastPath, isNull);
  });
}
