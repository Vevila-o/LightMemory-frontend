// 健康儀表板（儀表板／週報表／六大能力說明）與聲影日記的無障礙檢查（QA 用）
//
// 對每個畫面跑 Flutter 內建的四項 guideline（見 a11y_check.dart），
// 預設只收集違規、印出報告，不會讓測試失敗；
// 要讓違規直接失敗：flutter test --dart-define=A11Y_STRICT=true ...
//
// 除了四項 guideline，還補了幾個「自訂檢查」（guideline 欄會標「自訂」）：
// - 雷達圖等 CustomPaint 的內容有沒有出現在語意樹（讀屏軟體讀不讀得到）
// - 字級放大時有沒有 RenderFlex overflow（捕捉到就記成違規，不讓測試中斷）
//
// 後端、plugin 全部用假的：http 用 MockClient，record／audioplayers／
// flutter_tts／share_plus／path_provider 用 platform channel stub，
// image_picker 換成假的 platform 實作。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:intl/date_symbol_data_local.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:light_memory/app_settings.dart';
import 'package:light_memory/features/dashboard/pages/ability_detail_page.dart';
import 'package:light_memory/features/dashboard/pages/ability_menu_page.dart';
import 'package:light_memory/features/dashboard/pages/dashboard_page.dart';
import 'package:light_memory/features/dashboard/pages/diary_from_report_page.dart';
import 'package:light_memory/features/dashboard/pages/weekly_report_page.dart';
import 'package:light_memory/features/dashboard/widgets/ability_radar_chart.dart';
import 'package:light_memory/features/diary/models/diary_model.dart';
import 'package:light_memory/features/diary/pages/diary_chat_page.dart';
import 'package:light_memory/features/diary/pages/diary_finish_page.dart';
import 'package:light_memory/features/diary/pages/diary_home_page.dart';
import 'package:light_memory/features/diary/pages/diary_loading_page.dart';
import 'package:light_memory/features/diary/pages/diary_upload_page.dart';
import 'package:light_memory/main.dart';

import 'a11y_check.dart';

// ───────────────────────── 報告（整個檔案共用一份）─────────────────────────

final A11yReport a11y = A11yReport('dashboard_diary');

/// 目前跑到哪個情境（overflow 這類在 layout 時才丟出的錯誤用它當畫面名稱）
String _scenario = '';

/// 自訂檢查發現的問題，同畫面同內容只記一次
void _addCustom(String screen, String guideline, String reason) {
  final exists = a11y.violations.any(
    (v) => v.screen == screen && v.guideline == guideline && v.reason == reason,
  );
  if (!exists) a11y.violations.add(A11yViolation(screen, guideline, reason));
}

// ───────────────────────── 假後端 ─────────────────────────

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: _jsonHeaders);

class _Backend {
  Future<http.Response> Function() overview = () async => _json(_overview());
  Future<http.Response> Function() weekly = () async => _json(_weekly());
  Future<http.Response> Function() diaryList = () async => _json(_diaryList());
  Future<http.Response> Function() review = () async => _json(_diaryReview());
  Future<http.Response> Function() finalize = () async => _json(_diaryData());
  Future<http.Response> Function() reply = () async => _json({
    'data': {
      'round_index': 1,
      'transcript': '我和朋友在公園散步，天氣很好。',
      'audio_url': 'https://example.com/a.mp3',
      'ai_reply': '聽起來很棒！你們平常常去那裡嗎？',
      'reply_count': 2,
      'is_finalizable': true,
      'is_done': false,
    },
  });

  MockClient client() => MockClient((req) async {
    final path = req.url.path;
    if (path.endsWith('/api/dashboard/weekly-report/')) return weekly();
    if (path.endsWith('/api/dashboard/')) return overview();
    if (path.endsWith('/finalize/')) return finalize();
    if (path.endsWith('/replies/')) return reply();
    if (path.endsWith('/api/diary/review/')) return review();
    if (path.endsWith('/api/diary/')) return diaryList();
    return _json({
      'success': false,
      'error': {'code': 'NOT_FOUND', 'message': 'not found'},
    }, 404);
  });
}

const Map<String, double?> _fullZ = {
  'working_memory': 0.6,
  'attention': -0.4,
  'math': 1.2,
  'visual_spatial': 0.0,
  'executive_function': -1.1,
  'language': 0.8,
};

/// 有幾項近 7 天沒玩（null）
const Map<String, double?> _sparseZ = {
  'working_memory': 0.2,
  'attention': null,
  'math': -1.5,
  'visual_spatial': null,
  'executive_function': 0.9,
  'language': null,
};

/// 儀表板首頁（六項都解鎖）：z 分數換成 1～100 的 score；null 代表
/// 已解鎖但近 7 天沒玩
Map<String, dynamic> _overview({
  String? trend = 'up',
  Map<String, double?> z = _fullZ,
}) => {
  'success': true,
  'data': {
    'period_days': 7,
    'required_sessions': 3,
    'dimensions': [
      for (final e in z.entries)
        {
          'dimension': e.key,
          'unlocked': true,
          'valid_count': 5,
          'sessions_to_unlock': 0,
          'z_score': e.value,
          'score': e.value == null ? null : (e.value! + 2) * 25,
        },
    ],
    'encouragement': trend == null ? null : {'trend': trend},
  },
  'error': null,
};

/// 儀表板首頁（部分未解鎖）：每項能力各自判斷，encouragement 是 null
Map<String, dynamic> _locked(List<(String, int)> rows) => {
  'success': true,
  'data': {
    'period_days': 7,
    'required_sessions': 3,
    'dimensions': [
      for (final (dim, count) in rows)
        {
          'dimension': dim,
          'unlocked': count >= 3,
          'valid_count': count,
          'sessions_to_unlock': count >= 3 ? 0 : 3 - count,
          'z_score': count >= 3 ? 0.4 : null,
          'score': count >= 3 ? 60 : null,
        },
    ],
    'encouragement': null,
  },
  'error': null,
};

const _lockedMixed = [
  ('working_memory', 1),
  ('attention', 3),
  ('math', 0),
  ('visual_spatial', 2),
  ('executive_function', 3),
  ('language', 1),
];

const _lockedDiaryDone = [
  ('working_memory', 3),
  ('attention', 0),
  ('math', 1),
  ('visual_spatial', 2),
  ('executive_function', 0),
  ('language', 3),
];

Map<String, dynamic> _stat(
  String dim, {
  bool played = true,
  double? thisWeek,
  double? lastWeek,
  double? best,
  String? trend,
  bool unlocked = true,
}) => {
  'dimension': dim,
  'played': played,
  'unlocked': unlocked,
  'this_week': thisWeek,
  'last_week': lastWeek,
  'best': best,
  'trend': trend,
};

Map<String, dynamic> _weekly({
  bool firstWeek = false,
  bool withDiaries = false,
}) => {
  'success': true,
  'data': {
    'week_start': '2026-10-19',
    'week_end': '2026-10-25',
    'summary': firstWeek ? '這是你的第一週，來了就是好的開始！' : '這週你很認真，有 4 天來玩，繼續保持喔！',
    'highlights': {
      'active_day_count': firstWeek ? 2 : 4,
      'session_count': firstWeek ? 3 : 9,
      'streak_days': firstWeek ? 1 : 3,
    },
    'play_time': {
      'total_seconds': firstWeek ? 600 : 5400,
      'games': [
        {'source': 'market_route', 'label': '菜市場找路', 'seconds': 1800},
        {'source': 'cooking_prep', 'label': '料理準備', 'seconds': 1200},
        {'source': 'market_sort', 'label': '整理菜籃', 'seconds': 300},
      ],
    },
    'daily_activity': [
      for (var i = 0; i < 7; i++)
        {
          'date': '2026-10-${19 + i}',
          'is_active': firstWeek
              ? i == 1 || i == 4
              : i != 2 && i != 5 && i != 6,
        },
    ],
    'abilities': {
      'overall': {
        'this_week': 72,
        'last_week': firstWeek ? null : 65,
        'best': 80,
        'trend': firstWeek ? null : 'up',
      },
      'dimensions': firstWeek
          ? [
              _stat('working_memory', thisWeek: 70, best: 70),
              _stat('attention', thisWeek: 66, best: 66),
              _stat('math', played: false),
              _stat('visual_spatial', played: false),
              _stat('executive_function', played: false),
              _stat('language'),
            ]
          : [
              _stat(
                'working_memory',
                thisWeek: 78,
                lastWeek: 60,
                best: 85,
                trend: 'up',
              ),
              _stat(
                'attention',
                thisWeek: 66,
                lastWeek: 67,
                best: 80,
                trend: 'steady',
              ),
              _stat(
                'math',
                thisWeek: 50,
                lastWeek: 70,
                best: 90,
                trend: 'practice',
              ),
              _stat('visual_spatial', played: false),
              _stat(
                'executive_function',
                thisWeek: 82,
                lastWeek: null,
                best: 82,
                trend: 'up',
              ),
              _stat('language'), // 有寫日記但還沒有分數
            ],
    },
    'diary': {
      'entries': withDiaries
          ? [
              {
                'diary_id': 1,
                'date': '2026-10-20',
                'title': '去公園散步',
                'photo_url': 'https://example.com/p1.jpg',
                'post_text': '今天天氣很好，和老朋友一起在公園散步，聊了很多往事。',
              },
              {
                'diary_id': 2,
                'date': '2026-10-22',
                'title': '孫子來看我',
                'photo_url': 'https://example.com/p2.jpg',
                'post_text': '孫子帶了蛋糕來，我們一起吃，好開心。',
              },
            ]
          : [],
      'talk_seconds': withDiaries ? 420 : 0,
    },
    'next_week_goal': '下週試試每天玩一場，慢慢來就好。',
    'disclaimer': '這不是醫療診斷，僅供自我了解',
  },
  'error': null,
};

/// D-2 動態回顧：昨天一篇、去年的今天沒有（順便檢查空狀態）
Map<String, dynamic> _diaryReview() {
  final y = DateTime.now().subtract(const Duration(days: 1));
  final date =
      '${y.year}-${y.month.toString().padLeft(2, '0')}-${y.day.toString().padLeft(2, '0')}';
  return {
    'success': true,
    'data': {
      'yesterday': [
        {
          'diary_id': 30,
          'date': date,
          'title': '花燈圈圈樂 ✨',
          'photo_url': 'https://example.com/photo.jpg',
          'post_text': '這個週末跟朋友去逛花燈，玩得很開心。',
          'audio_url': 'https://example.com/a.mp3',
          'is_shared': true,
          'post_id': 8,
          'created_at': '${date}T08:10:00+08:00',
        },
      ],
      'last_year': [],
    },
  };
}

Map<String, dynamic> _diaryList({bool hasToday = false}) {
  final now = DateTime.now();
  String d(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  final first = DateTime(now.year, now.month, 1);
  return {
    'data': {
      'month': '${now.year}-${now.month.toString().padLeft(2, '0')}',
      'has_today_diary': hasToday,
      'diaries': [
        {
          'diary_id': 1,
          'date': d(first),
          'title': '月初的早晨',
          'photo_url': 'https://example.com/p.jpg',
          'post_text': '今天的天氣很好。',
          'created_at': '${d(first)}T08:00:00Z',
        },
      ],
    },
  };
}

Map<String, dynamic> _diaryData() => {
  'data': {
    'diary_id': 7,
    'date': '2026-10-25',
    'created_at': '2026-10-25T08:00:00Z',
    'status': 'done',
    'photo_url': 'https://example.com/p.jpg',
    'title': '和孫子的午後',
    'post_text': '今天孫子來家裡玩，我們一起做了蛋糕，笑得很開心。',
    'hashtags': ['#家人', '#蛋糕', '#開心'],
    'share_url': 'https://example.com/share/7',
    'invite_text': '來看我的日記',
  },
};

DiaryModel _diaryModel() => DiaryModel.fromJson({
  ..._diaryData()['data'] as Map<String, dynamic>,
  'first_question': '這張照片是在哪裡拍的呢？',
  'replies': <dynamic>[],
  'pending_question': '這張照片是在哪裡拍的呢？',
  'reply_count': 0,
  'is_finalizable': false,
  'is_done': false,
  'ai_response': '',
  'category': '',
  'is_shared': false,
  'invite_text': '來看我的日記',
});

// ───────────────────────── plugin／環境 stub ─────────────────────────

/// record plugin 的 stop() 要回傳的「錄好的音檔」路徑
String _recordedPath = 'round_audio.webm';

/// 擋掉 record、audioplayers、flutter_tts、share_plus、path_provider、
/// image_picker 的 platform channel（測試環境沒有原生端），其他 channel 照常
void _stubPlatformChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();
  messenger.allMessagesHandler = (channel, handler, message) {
    if (channel == 'com.llfbandit.record/messages' && message != null) {
      final call = codec.decodeMethodCall(message);
      final Object? result = switch (call.method) {
        'hasPermission' => true,
        'isRecording' => true,
        'isPaused' => false,
        'stop' => _recordedPath,
        'getAmplitude' => {'current': -30.0, 'max': -10.0},
        _ => null,
      };
      return Future.value(codec.encodeSuccessEnvelope(result));
    }
    const stubbed = [
      'com.llfbandit.record',
      'xyz.luan/audioplayers',
      'flutter_tts',
      'dev.fluttercommunity.plus/share',
      'plugins.flutter.io/path_provider',
      'plugins.flutter.io/image_picker',
      'dev.flutter.pigeon.path_provider',
      'dev.flutter.pigeon.image_picker',
    ];
    if (stubbed.any(channel.startsWith)) {
      return Future.value(codec.encodeSuccessEnvelope(null));
    }
    if (handler != null) return handler(message);
    return null;
  };
}

/// 1x1 的 PNG，當作「使用者選的照片」
const _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

class _FakeImagePicker extends ImagePickerPlatform
    with MockPlatformInterfaceMixin {
  final String path;
  _FakeImagePicker(this.path);

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => XFile(path);
}

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;
}

class _Env {
  final _Backend backend = _Backend();
  final List<String> unexpectedErrors = [];
}

/// 畫面設定：360x780 邏輯像素的直向手機
void _setSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = const Size(360, 780) * 3;
  addTearDown(tester.view.reset);
}

/// 一個情境：設好手機尺寸、假後端、plugin stub、錯誤收集，跑完還原設定。
/// 會被當成「違規」記下來的錯誤（overflow）不會讓測試失敗，
/// 其他沒預期到的 Flutter 錯誤（image 載入失敗除外）會在最後讓測試失敗。
void _scenarioTest(
  String description,
  Future<void> Function(WidgetTester tester, _Env env) body,
) {
  testWidgets(description, (tester) async {
    _scenario = description;
    final env = _Env();
    _setSurface(tester);
    SharedPreferences.setMockInitialValues({'access_token': 'test'});
    _stubPlatformChannels();
    // 手機 App 錄音要先拿到暫存資料夾
    PathProviderPlatform.instance = _FakePathProvider();
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    AppSettings.fontSizeLevel.value = 2;
    AppSettings.isDarkMode.value = false;
    AppSettings.isHighContrast.value = false;

    // 測試環境裡 Image.network 一律失敗（沒有 errorBuilder 的頁面會長出紅字的
    // ErrorWidget，影響對比檢查），先把用到的網址塞進 image cache，
    // 讓它們都解成一張小圖
    final photo = await tester.runAsync(
      () => decodeImageFromList(base64Decode(_pngBase64)),
    );
    for (final url in [
      'https://example.com/p.jpg',
      'https://example.com/p1.jpg',
      'https://example.com/p2.jpg',
    ]) {
      PaintingBinding.instance.imageCache.putIfAbsent(
        NetworkImage(url),
        () => OneFrameImageStreamCompleter(
          Future.value(ImageInfo(image: photo!.clone())),
        ),
      );
    }

    final oldOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.toString();
      final first = details.exceptionAsString().split('\n').first;
      if (first.contains('overflowed')) {
        final loc = RegExp(r'lib/[^\s:]+\.dart:\d+').firstMatch(text)?.group(0);
        _addCustom(
          _scenario,
          'layoutOverflow（自訂）',
          '$first${loc == null ? '' : '  @$loc'}',
        );
      } else if (text.contains('NetworkImageLoadException') ||
          text.contains('HTTP request failed')) {
        // 測試環境裡 Image.network 一律回 400；沒有 errorBuilder 的頁面會丟錯，
        // 這不是這次要檢查的東西
      } else {
        env.unexpectedErrors.add(first);
      }
    };

    try {
      await http.runWithClient(
        () => body(tester, env),
        () => env.backend.client(),
      );
      // 收掉畫面，讓計時器、動畫都停下來
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    } finally {
      FlutterError.onError = oldOnError;
      PaintingBinding.instance.imageCache.clear();
      AppSettings.fontSizeLevel.value = 2;
      AppSettings.isDarkMode.value = false;
      AppSettings.isHighContrast.value = false;
      tester.platformDispatcher.clearAllTestValues();
    }
    expect(env.unexpectedErrors, isEmpty, reason: '畫面上有沒預期到的 Flutter 錯誤');
  });
}

/// 以 App 真正的 theme／onGenerateRoute 建立 MaterialApp，首頁放 [home]
Future<void> _pumpApp(WidgetTester tester, Widget home) async {
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
    MaterialApp(theme: theme, onGenerateRoute: appRoutes, home: home),
  );
  await _settle(tester, 300);
}

/// 讓畫面穩定：build → 後端回應 → 進場動畫跑完（不用 pumpAndSettle，
/// 因為有些畫面有永遠在轉的動畫）
Future<void> _settle(WidgetTester tester, [int ms = 1600]) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(Duration(milliseconds: ms));
}

void _dark(bool on) => AppSettings.isDarkMode.value = on;

// ───────────────────────── 檢查工具 ─────────────────────────

/// 加 `--dart-define=A11Y_DUMP=true` 會在每次檢查時多印一行「讀屏軟體依序會讀到什麼」
const bool _dump = bool.fromEnvironment('A11Y_DUMP');

Future<void> _check(WidgetTester tester, String screen) async {
  await a11y.check(tester, screen);
  if (_dump) {
    // ignore: avoid_print
    print(
      '--- [$screen] 讀屏順序：${_spokenTexts(tester).join(' | ').replaceAll('\n', ' / ')}',
    );
  }
}

/// 讀屏軟體依序會讀到的所有文字（label／value／hint）
List<String> _spokenTexts(WidgetTester tester) {
  final handle = tester.ensureSemantics();
  try {
    return [
      for (final node in tester.semantics.simulatedAccessibilityTraversal())
        if (node.label.isNotEmpty) node.label,
    ];
  } finally {
    handle.dispose();
  }
}

/// 雷達圖：能力名稱、分數是 CustomPaint + TextPainter 畫的，
/// 看語意樹裡有沒有出現。只要六項名稱一個都讀不到，就記一筆自訂違規。
void _checkRadarSemantics(WidgetTester tester, String screen) {
  final spoken = _spokenTexts(tester).join('\n');
  const names = ['工作記憶', '注意力', '數學', '視覺空間', '執行功能', '語言'];
  final exposed = names.where(spoken.contains).toList();
  if (exposed.isEmpty) {
    _addCustom(
      screen,
      '語意內容（自訂）',
      '雷達圖（AbilityRadarChart，lib/features/dashboard/widgets/ability_radar_chart.dart:132 的 CustomPaint）'
          '沒有 Semantics：六項能力名稱、近期分數、「近期未遊玩」都不在語意樹，讀屏軟體只讀得到標題「認知能力分布圖」。',
    );
  }
}

/// 能力列（InkWell 包住的整列）被捲動區域的邊緣切到一半時，語意節點的
/// rect 也跟著被切小，tap target guideline 會誤報「高度只有 11px」。
/// 這類誤報（整個違規只含被切到的能力列）丟掉，改用 [_checkAbilityRowHeights]
/// 量實際高度。
void _dropClippedAbilityRows(WidgetTester tester, int from, String screen) {
  final rowLabel = RegExp(r'label: "(工作記憶|注意力|數學|視覺空間|執行功能|語言)(\\n|\n)');
  for (var i = a11y.violations.length - 1; i >= from; i--) {
    final v = a11y.violations[i];
    if (!v.guideline.endsWith('TapTarget') ||
        v.guideline == 'labeledTapTarget') {
      continue;
    }
    final nodes = 'SemanticsNode#'.allMatches(v.reason).length;
    if (nodes > 0 && rowLabel.allMatches(v.reason).length == nodes) {
      a11y.violations.removeAt(i);
    }
  }
}

/// 六列能力（可點）的實際高度要 >= 48
void _checkAbilityRowHeights(WidgetTester tester, String screen) {
  for (final title in ['工作記憶', '注意力', '數學', '視覺空間', '執行功能', '語言']) {
    final row = find.ancestor(
      of: find.text(title),
      matching: find.byType(InkWell),
    );
    if (row.evaluate().isEmpty) continue;
    final h = tester.getSize(row.first).height;
    if (h < 48) {
      _addCustom(
        screen,
        'androidTapTarget（自訂，量實際高度）',
        '「$title」那一列可點區高度只有 ${h.toStringAsFixed(1)}dp（weekly_report_sections.dart:543 的 InkWell）',
      );
    }
  }
}

/// 把整頁週報表由上往下捲，每個位置各檢查一次（沒捲到的區塊還沒進場，是透明的）
Future<void> _checkWeeklyScrolling(WidgetTester tester, String prefix) async {
  final scrollable = tester.state<ScrollableState>(
    find
        .descendant(
          of: find.byType(SingleChildScrollView),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  final maxExtent = scrollable.position.maxScrollExtent;
  final step = scrollable.position.viewportDimension * 0.8;
  var offset = 0.0;
  var index = 1;
  while (true) {
    scrollable.position.jumpTo(offset);
    await _settle(tester);
    final before = a11y.violations.length;
    await _check(tester, '$prefix（捲動位置 $index）');
    _dropClippedAbilityRows(tester, before, '$prefix（捲動位置 $index）');
    if (offset >= maxExtent) break;
    offset = math.min(offset + step, maxExtent);
    index++;
  }
  _checkAbilityRowHeights(tester, prefix);
}

/// 把畫面捲到某段文字並點下去
Future<void> _tapText(WidgetTester tester, String text) async {
  final finder = find.text(text).first;
  // 進場動畫、版面調整會讓位置還在動，捲到可見後再確認一次
  for (var i = 0; i < 3; i++) {
    await tester.ensureVisible(finder);
    await _settle(tester, 800);
    final y = tester.getCenter(finder).dy;
    if (y > 100 && y < 700) break;
  }
  await tester.tap(finder);
  await _settle(tester, 600);
}

// ───────────────────────── 測試 ─────────────────────────

void main() {
  setUpAll(() async {
    await initializeDateFormatting('zh_TW');
  });

  // ══════════════ 儀表板首頁 ══════════════
  group('儀表板首頁', () {
    Future<void> openDashboard(WidgetTester tester) async {
      await _pumpApp(tester, const DashboardPage());
      await _settle(tester);
    }

    for (final trend in ['up', 'steady', 'practice', null]) {
      _scenarioTest('已解鎖 趨勢=$trend（淺色）', (tester, env) async {
        env.backend.overview = () async => _json(
          _overview(
            trend: trend,
            // practice 這組帶幾個 null，驗證「近期未遊玩／未寫日記」的畫法
            z: trend == 'practice' ? _sparseZ : _fullZ,
          ),
        );
        await openDashboard(tester);
        final name = '儀表板／已解鎖／趨勢 ${trend ?? '無(歡迎開始)'}';
        await _check(tester, name);
        if (trend == 'up') _checkRadarSemantics(tester, name);
      });
    }

    _scenarioTest('已解鎖（深色）趨勢 up、practice', (tester, env) async {
      _dark(true);
      for (final trend in ['up', 'practice']) {
        env.backend.overview = () async => _json(_overview(trend: trend));
        await openDashboard(tester);
        await _check(tester, '儀表板／已解鎖／趨勢 $trend／深色');
      }
    });

    _scenarioTest('已解鎖（高對比）', (tester, env) async {
      AppSettings.isHighContrast.value = true;
      await openDashboard(tester);
      await _check(tester, '儀表板／已解鎖／高對比');
    });

    _scenarioTest('已解鎖（系統字級 1.3）', (tester, env) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      await openDashboard(tester);
      await _check(tester, '儀表板／已解鎖／字級1.3');
      // 往下捲一下，看到底部兩顆按鈕
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await _settle(tester, 300);
      await _check(tester, '儀表板／已解鎖／字級1.3／捲到底');
    });

    _scenarioTest('小提醒（近期某場表現特別低）淺色／深色／高對比', (tester, env) async {
      env.backend.overview = () async {
        final body = _overview();
        (body['data'] as Map<String, dynamic>)['alerts'] = [
          {
            'game_id': 'market_shopping',
            'game_title': '市場買菜',
            'dimension': 'math',
            'dimension_label': '數學',
            'played_at': '2026-11-12T15:30:00+08:00',
            'display_score': 18,
            'message': '11/12 玩「市場買菜」的表現比平常低一些，可能當天比較累，'
                '建議多注意一下，休息後再玩一次看看。',
          },
        ];
        return _json(body);
      };
      await openDashboard(tester);
      expect(find.text('小提醒'), findsOneWidget);
      await _check(tester, '儀表板／小提醒');

      _dark(true);
      await openDashboard(tester);
      await _check(tester, '儀表板／小提醒／深色');

      _dark(false);
      AppSettings.isHighContrast.value = true;
      await openDashboard(tester);
      await _check(tester, '儀表板／小提醒／高對比');
    });

    _scenarioTest('部分未解鎖（灰色軸、再玩 N 次）', (tester, env) async {
      env.backend.overview = () async => _json(_locked(_lockedMixed));
      await openDashboard(tester);
      await _check(tester, '儀表板／未解鎖進度（日記未完成）');
      // 未解鎖的軸寫還差幾次，語言用篇數
      expect(find.byType(DashboardPage), findsOneWidget);
      expect(find.text('歡迎開始！'), findsOneWidget);

      env.backend.overview = () async => _json(_locked(_lockedDiaryDone));
      await openDashboard(tester);
      await _check(tester, '儀表板／未解鎖進度（日記已完成，打勾）');

      _dark(true);
      env.backend.overview = () async => _json(_locked(_lockedMixed));
      await openDashboard(tester);
      await _check(tester, '儀表板／未解鎖進度／深色');
    });

    _scenarioTest('讀取中與讀不到資料', (tester, env) async {
      final never = Completer<http.Response>();
      env.backend.overview = () => never.future;
      await _pumpApp(tester, const DashboardPage());
      await tester.pump(const Duration(milliseconds: 300));
      await _check(tester, '儀表板／讀取中');
      never.complete(_json({}, 500)); // 收掉 20 秒逾時計時器

      env.backend.overview = () async => _json({
        'success': false,
        'error': {'code': 'SERVER', 'message': '伺服器忙碌'},
      }, 500);
      await openDashboard(tester);
      await _check(tester, '儀表板／讀不到資料(重試)');

      _dark(true);
      await openDashboard(tester);
      await _check(tester, '儀表板／讀不到資料(重試)／深色');
    });

    _scenarioTest('機器人頭像與雷達圖的語意', (tester, env) async {
      await openDashboard(tester);
      final spoken = _spokenTexts(tester);
      // 狀態用文字「進步了！」＋說明表達，機器人本身是裝飾；
      // 這裡只確認「心情」沒有只靠圖案傳達
      expect(spoken.any((t) => t.contains('進步了')), isTrue);
      expect(find.byType(AbilityRadarChart), findsOneWidget);
    });

    _scenarioTest('從儀表板進入週報表與六大能力說明', (tester, env) async {
      await openDashboard(tester);
      await _tapText(tester, '六大能力說明');
      expect(find.byType(AbilityMenuPage), findsOneWidget);
      await _check(tester, '六大能力說明選單（從儀表板進入）');
      await tester.tap(find.byTooltip('返回'));
      await _settle(tester, 600);
      await _tapText(tester, '查看週報表');
      expect(find.byType(WeeklyReportPage), findsOneWidget);
      await _check(tester, '週報表（從儀表板進入）');
    });
  });

  // ══════════════ 六大能力說明 ══════════════
  group('六大能力說明', () {
    _scenarioTest('選單', (tester, env) async {
      await _pumpApp(tester, const AbilityMenuPage());
      await _check(tester, '六大能力說明／選單');
      _dark(true);
      await _settle(tester, 300);
      await _check(tester, '六大能力說明／選單／深色');
      AppSettings.isHighContrast.value = true;
      _dark(false);
      await _settle(tester, 300);
      await _check(tester, '六大能力說明／選單／高對比');
    });

    _scenarioTest('單項說明頁', (tester, env) async {
      await _pumpApp(
        tester,
        const AbilityDetailPage(initialAbilityId: 'language'),
      );
      await _check(tester, '六大能力說明／單項(語言)');
      await tester.tap(find.byTooltip('下一項'));
      await _settle(tester, 700);
      await _check(tester, '六大能力說明／單項(下一項：工作記憶)');
      _dark(true);
      await _settle(tester, 300);
      await _check(tester, '六大能力說明／單項／深色');
    });

    _scenarioTest('單項說明頁（從週報表進入）', (tester, env) async {
      await _pumpApp(
        tester,
        const AbilityDetailPage(
          initialAbilityId: 'math',
          fromWeeklyReport: true,
        ),
      );
      await _check(tester, '六大能力說明／單項(數學，回到週報表)');
    });
  });

  // ══════════════ 週報表 ══════════════
  group('週報表', () {
    Future<void> openWeekly(WidgetTester tester) async {
      await _pumpApp(tester, const WeeklyReportPage());
      await _settle(tester);
    }

    _scenarioTest('第一週', (tester, env) async {
      env.backend.weekly = () async => _json(_weekly(firstWeek: true));
      await openWeekly(tester);
      await _checkWeeklyScrolling(tester, '週報表／第一週');
    });

    _scenarioTest('一般週', (tester, env) async {
      await openWeekly(tester);
      await _checkWeeklyScrolling(tester, '週報表／一般週');
      final spoken = _spokenTexts(tester).join('\n');
      // 打卡七格、長條、個人最佳標線：看語意樹是不是只剩零碎文字
      if (!spoken.contains('已打卡') && !spoken.contains('有打卡')) {
        _addCustom(
          '週報表／本週打卡',
          '語意內容（自訂）',
          '七個打卡圓點（WeeklyCheckInSection._dot，lib/features/dashboard/widgets/weekly_report_sections.dart:434）'
              '只靠「勾勾圓點 vs 空圓框」表達哪天有來，語意樹裡只有「一～日」文字和總結句，讀屏軟體聽不出是哪幾天。',
        );
      }
    });

    _scenarioTest('一般週（深色）', (tester, env) async {
      _dark(true);
      await openWeekly(tester);
      await _checkWeeklyScrolling(tester, '週報表／一般週／深色');
    });

    _scenarioTest('一般週（高對比）', (tester, env) async {
      AppSettings.isHighContrast.value = true;
      await openWeekly(tester);
      await _checkWeeklyScrolling(tester, '週報表／一般週／高對比');
    });

    _scenarioTest('一般週（系統字級 1.3）', (tester, env) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      await openWeekly(tester);
      await _checkWeeklyScrolling(tester, '週報表／一般週／字級1.3');
    });

    _scenarioTest('第一週（系統字級 1.3、深色）', (tester, env) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      _dark(true);
      env.backend.weekly = () async => _json(_weekly(firstWeek: true));
      await openWeekly(tester);
      await _checkWeeklyScrolling(tester, '週報表／第一週／字級1.3／深色');
    });

    _scenarioTest('有日記的一週與日記預覽彈窗', (tester, env) async {
      env.backend.weekly = () async => _json(_weekly(withDiaries: true));
      await openWeekly(tester);
      await _checkWeeklyScrolling(tester, '週報表／有日記');

      // 點日記相片 → 預覽彈窗
      await _tapText(tester, '10/20');
      expect(find.text('去公園散步'), findsOneWidget);
      await _check(tester, '週報表／日記預覽彈窗');
      await tester.tap(find.text('關閉'));
      await _settle(tester, 600);
      expect(find.text('去公園散步'), findsNothing);

      // 彈窗的配色是開啟當下傳進去的，要深色就得先切深色再開
      _dark(true);
      await _settle(tester, 600);
      await _tapText(tester, '10/22');
      expect(find.text('孫子來看我'), findsOneWidget);
      await _check(tester, '週報表／日記預覽彈窗／深色');
      await tester.tap(find.text('關閉'));
      await _settle(tester, 600);
    });

    _scenarioTest('點能力列的選擇彈窗', (tester, env) async {
      await openWeekly(tester);
      await _tapText(tester, '工作記憶');
      expect(find.text('想做什麼呢？'), findsOneWidget);
      await _check(tester, '週報表／能力選擇彈窗(工作記憶)');
      await tester.tap(find.byTooltip('關閉'));
      await _settle(tester, 600);

      await _tapText(tester, '語言');
      expect(find.text('去寫日記'), findsOneWidget);
      await _check(tester, '週報表／能力選擇彈窗(語言)');
      await tester.tap(find.byTooltip('關閉'));
      await _settle(tester, 600);

      // 彈窗的配色是開啟當下傳進去的，要深色就得先切深色再開
      _dark(true);
      await _settle(tester, 600);
      await _tapText(tester, '語言');
      await _check(tester, '週報表／能力選擇彈窗(語言)／深色');
      await tester.tap(find.byTooltip('關閉'));
      await _settle(tester, 600);

      AppSettings.isHighContrast.value = true;
      await _settle(tester, 600);
      await _tapText(tester, '語言');
      await _check(tester, '週報表／能力選擇彈窗(語言)／深色高對比');
      await tester.tap(find.byTooltip('關閉'));
      await _settle(tester, 600);
    });

    _scenarioTest('讀取中與讀不到資料', (tester, env) async {
      final never = Completer<http.Response>();
      env.backend.weekly = () => never.future;
      await _pumpApp(tester, const WeeklyReportPage());
      await tester.pump(const Duration(milliseconds: 300));
      await _check(tester, '週報表／讀取中');
      never.complete(_json({}, 500)); // 收掉 20 秒逾時計時器

      env.backend.weekly = () async => _json({
        'success': false,
        'error': {'code': 'SERVER', 'message': '伺服器忙碌'},
      }, 500);
      await openWeekly(tester);
      await _check(tester, '週報表／讀不到資料(重試)');
    });
  });

  // ══════════════ 聲影日記 ══════════════
  group('聲影日記', () {
    Future<void> openHome(WidgetTester tester) async {
      await _pumpApp(tester, const DiaryHomePage());
      await _settle(tester, 600);
    }

    _scenarioTest('首頁（月曆）', (tester, env) async {
      await openHome(tester);
      await _check(tester, '日記首頁／今天還沒寫（含月曆）');
      // 有日記的日子靠橘圈＋星星標示：語意樹裡那一格的文字有沒有提到「日記」
      final now = DateTime.now();
      final cell = _spokenTexts(
        tester,
      ).where((t) => t.contains('${now.year}年${now.month}月1日'));
      if (cell.isNotEmpty && !cell.any((t) => t.contains('日記'))) {
        _addCustom(
          '日記首頁／今天還沒寫（含月曆）',
          '語意內容（自訂）',
          '有日記的日期只靠橘色圓圈＋星星表示（diary_calendar.dart 的 defaultBuilder），'
              '那一格的語意文字只有「${cell.first}」，讀屏軟體聽不出哪天有日記。',
        );
      }

      env.backend.diaryList = () async => _json(_diaryList(hasToday: true));
      await openHome(tester);
      await _check(tester, '日記首頁／今天已完成');

      _dark(true);
      await openHome(tester);
      await _check(tester, '日記首頁／深色');
      _dark(false);

      AppSettings.isHighContrast.value = true;
      await openHome(tester);
      await _check(tester, '日記首頁／高對比');
    });

    _scenarioTest('首頁（系統字級 1.3）', (tester, env) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      await openHome(tester);
      await _check(tester, '日記首頁／字級1.3');
    });

    _scenarioTest('首頁 讀取中、讀取失敗', (tester, env) async {
      final never = Completer<http.Response>();
      env.backend.diaryList = () => never.future;
      await _pumpApp(tester, const DiaryHomePage());
      await tester.pump(const Duration(milliseconds: 300));
      await _check(tester, '日記首頁／讀取中');
      never.complete(_json({}, 500));

      env.backend.diaryList = () async => _json({
        'error': {'message': '登入逾時'},
      }, 401);
      await openHome(tester);
      await _check(tester, '日記首頁／讀取失敗(重新載入)');
    });

    // 動態回顧原本是底部面板，dev 上改成獨立頁面（DiaryReviewPage）
    _scenarioTest('首頁 動態回顧頁', (tester, env) async {
      await openHome(tester);
      await tester.tap(find.text('動態回顧'));
      await _settle(tester, 1000);
      expect(find.text('花燈圈圈樂 ✨'), findsOneWidget);
      await _check(tester, '日記首頁／動態回顧頁');
      await tester.tap(find.byTooltip('返回'));
      await _settle(tester, 600);
      _dark(true);
      await tester.tap(find.text('動態回顧'));
      await _settle(tester, 1000);
      await _check(tester, '日記首頁／動態回顧頁／深色');
    });

    _scenarioTest('從週報表進來的日記首頁', (tester, env) async {
      await _pumpApp(tester, const DiaryFromReportPage());
      await _settle(tester, 600);
      await _check(tester, '日記首頁（從週報表進入，含「回到週報表」）');
    });

    _scenarioTest('上傳照片頁', (tester, env) async {
      final dir = Directory.systemTemp.createTempSync('a11y_photo');
      // Windows 上圖片可能還被開著，刪不掉就留給系統清暫存，不算測試失敗
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } on FileSystemException catch (_) {}
      });
      final photo = File('${dir.path}/photo.png')
        ..writeAsBytesSync(base64Decode(_pngBase64));
      ImagePickerPlatform.instance = _FakeImagePicker(photo.path);

      await _pumpApp(tester, const DiaryUploadPage());
      await _check(tester, '日記上傳／尚未選照片');

      await tester.tap(find.text('點擊新增照片'));
      await _settle(tester, 600);
      expect(find.text('從相簿選擇'), findsOneWidget);
      await _check(tester, '日記上傳／選擇來源面板');
      await tester.tap(find.text('從相簿選擇'));
      await _settle(tester, 600);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await _settle(tester, 300);
      expect(find.text('點擊新增照片'), findsNothing);
      await _check(tester, '日記上傳／已選照片（有移除叉叉）');

      _dark(true);
      await _settle(tester, 300);
      await _check(tester, '日記上傳／已選照片／深色');
    });

    _scenarioTest('上傳照片頁（空、深色、字級 1.3）', (tester, env) async {
      _dark(true);
      await _pumpApp(tester, const DiaryUploadPage());
      await _check(tester, '日記上傳／尚未選照片／深色');
      _dark(false);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      await _settle(tester, 300);
      await _check(tester, '日記上傳／尚未選照片／字級1.3');
    });

    _scenarioTest('聊天室頁', (tester, env) async {
      await _pumpApp(tester, DiaryChatPage(initialDiary: _diaryModel()));
      await _check(tester, '日記聊天室／待機（第一輪提示）');

      // 開始錄音 → 錄音中（暫停鍵＋完成鍵）
      await tester.tap(find.byIcon(Icons.mic));
      await _settle(tester, 2500);
      expect(find.byIcon(Icons.pause), findsOneWidget);
      await _check(tester, '日記聊天室／錄音中');

      // 暫停 → 繼續錄／重新錄製
      await tester.tap(find.byIcon(Icons.pause));
      await _settle(tester, 300);
      expect(find.text('重新錄製'), findsOneWidget);
      await _check(tester, '日記聊天室／暫停（重新錄製）');

      // 按完成：錄不到 15 秒 → AI 請再多說一點，回到待機
      await tester.tap(find.byIcon(Icons.check));
      await _settle(tester, 800);
      expect(find.textContaining('再多說一點'), findsOneWidget);
      await _check(tester, '日記聊天室／錄太短的提示訊息');

      _dark(true);
      await _settle(tester, 300);
      await _check(tester, '日記聊天室／深色');
    });

    _scenarioTest('聊天室頁 送出一輪後（播放鈕、跳過、提前生成）', (tester, env) async {
      // stop() 回傳真的檔案，送出時才讀得到內容
      final dir = Directory.systemTemp.createTempSync('a11y_audio');
      addTearDown(() {
        _recordedPath = 'round_audio.webm';
        dir.deleteSync(recursive: true);
      });
      final audio = File('${dir.path}/round_audio.webm')
        ..writeAsBytesSync(List.filled(64, 1));
      _recordedPath = audio.path;

      await _pumpApp(tester, DiaryChatPage(initialDiary: _diaryModel()));
      await tester.tap(find.byIcon(Icons.mic));
      await _settle(tester, 300);
      await tester.pump(const Duration(seconds: 16)); // 第一輪至少錄 15 秒
      await tester.tap(find.byIcon(Icons.check));
      // 讀音檔是真的檔案 I/O，要讓真實的 event loop 與假時鐘輪流轉
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
      }
      await _settle(tester, 1500);
      expect(find.textContaining('我和朋友在公園散步'), findsOneWidget);
      expect(find.text('這題跳過'), findsOneWidget);
      await _check(tester, '日記聊天室／送出一輪後（錄音播放鈕、這題跳過、生成日記）');
      // 氣泡裡的播放鈕：GestureDetector 的語意會併進整個氣泡的文字節點，
      // guideline 看到的是「有標籤的大區塊」；實際能點的只有那顆小圓鈕，這裡直接量
      final play = find
          .ancestor(
            of: find.byIcon(Icons.play_arrow),
            matching: find.byType(GestureDetector),
          )
          .first;
      final playSize = tester.getSize(play);
      if (playSize.shortestSide < 48) {
        _addCustom(
          '日記聊天室／送出一輪後（錄音播放鈕、這題跳過、生成日記）',
          'androidTapTarget（自訂，量實際點擊區）',
          '使用者氣泡的錄音播放鈕只有 ${playSize.width.toStringAsFixed(0)}x${playSize.height.toStringAsFixed(0)}dp，'
              '而且沒有自己的語意標籤（語意併進氣泡文字，聽不出「播放錄音」）（chat_bubble.dart 的 GestureDetector）',
        );
      }

      _dark(true);
      await _settle(tester, 300);
      await _check(tester, '日記聊天室／送出一輪後／深色');
    });

    _scenarioTest('聊天室頁（字級 1.3）', (tester, env) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      await _pumpApp(tester, DiaryChatPage(initialDiary: _diaryModel()));
      await _check(tester, '日記聊天室／字級1.3');
    });

    _scenarioTest('生成中頁', (tester, env) async {
      final never = Completer<http.Response>();
      env.backend.finalize = () => never.future;
      await _pumpApp(tester, const DiaryLoadingPage(diaryId: 7));
      await tester.pump(const Duration(milliseconds: 500));
      await _check(tester, '日記生成中／整理中');
      never.complete(_json({}, 500));

      env.backend.finalize = () async => _json({
        'error': {'message': 'x'},
      }, 500);
      await _pumpApp(tester, const DiaryLoadingPage(diaryId: 7));
      await _settle(tester, 300);
      expect(find.text('重試'), findsOneWidget);
      await _check(tester, '日記生成中／生成失敗(重試)');
    });

    _scenarioTest('完成頁（分享）', (tester, env) async {
      final diary = DiaryModel.fromJson({
        ..._diaryData()['data'] as Map<String, dynamic>,
        'first_question': '',
        'replies': <dynamic>[],
        'reply_count': 4,
        'is_finalizable': true,
        'is_done': true,
        'ai_response': '',
        'category': '',
        'is_shared': false,
      });
      await _pumpApp(tester, DiaryFinishPage(diary: diary));
      await _check(tester, '日記完成頁／分享');
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -600),
      );
      await _settle(tester, 300);
      await _check(tester, '日記完成頁／分享（捲到底）');

      _dark(true);
      await _settle(tester, 300);
      await _check(tester, '日記完成頁／深色');

      _dark(false);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      await _settle(tester, 300);
      await _check(tester, '日記完成頁／字級1.3');
    });
  });

  // 一定要放最後：印出報告、寫到 build/a11y_report/dashboard_diary.txt
  test('彙整無障礙報告', () {
    a11y.finish();
  });
}
