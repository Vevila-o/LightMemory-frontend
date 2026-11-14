import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'theme/app_theme.dart';
import 'features/auth/pages/auth_gate.dart';
import 'features/diary/pages/diary_upload_page.dart';
import 'features/diary/pages/diary_chat_page.dart';
import 'features/diary/pages/diary_loading_page.dart';
import 'core/constants/route_constants.dart';
import 'core/navigation/app_route_observer.dart';
import 'core/navigation/app_navigator.dart';
import 'core/services/local_notifications.dart';
import 'core/services/new_notification_alerter.dart';
import 'core/services/reminder_service.dart';
import 'screens/notification_screen.dart';
import 'screens/market_sort_game_screen.dart';
import 'screens/main_screen.dart';
import 'features/diary/pages/diary_finish_page.dart';
import 'features/diary/pages/diary_review_page.dart';
import 'features/diary/models/diary_model.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Web 版預設不產生無障礙的 DOM，Lighthouse／axe 會掃不到東西，
  // 開發時（debug）先強制啟用；release 版維持預設，不影響使用者。
  if (kDebugMode) SemanticsBinding.instance.ensureSemantics();
  // cooking_prep 頁面會鎖橫向，啟動時強制回直向，
  // 避免 hot restart 後殘留橫向設定，讓其他直向頁面跑版。
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await initializeDateFormatting('zh_TW');
  // 每日提醒：依上次的設定重新排程（網頁版不做；失敗不影響啟動，所以不等它）
  unawaited(ReminderService.init());
  // 新通知提醒：定時查後端有沒有新通知（留言、語音加油），有就跳手機通知
  if (NewNotificationAlerter.isSupported) {
    LocalNotifications.onTap = _openFromNotification;
    NewNotificationAlerter.instance.start();
  }
  runApp(const MyApp());
}

/// App 開著或在背景時點了「新通知」的手機通知：打開通知頁。
/// 每日提醒的通知沒有 payload，只打開 App；App 原本完全關掉時也只打開 App
/// （啟動流程會換掉最上層的頁面），首頁鈴鐺會顯示未讀。
void _openFromNotification(String? payload) {
  if (payload != NewNotificationAlerter.payload) return;
  appNavigatorKey.currentState?.push(
    MaterialPageRoute(builder: (_) => const NotificationScreen()),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '憶智防線',
      navigatorKey: appNavigatorKey,
      theme: AppTheme.lightTheme,
      home: const AuthGate(),
      navigatorObservers: [appRouteObserver],
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case AppRoutes.gameMarketSort:
            return MaterialPageRoute(
              builder: (_) => const MarketSortGameScreen(),
            );
          case AppRoutes.voiceDiaryUpload:
            return MaterialPageRoute(builder: (_) => const DiaryUploadPage());
          case AppRoutes.voiceDiaryChat:
            final diary = settings.arguments as DiaryModel;
            return MaterialPageRoute(
              builder: (_) => DiaryChatPage(initialDiary: diary),
            );
          case AppRoutes.voiceDiaryLoading:
            final diaryId = settings.arguments as int;
            return MaterialPageRoute(
              builder: (_) => DiaryLoadingPage(diaryId: diaryId),
            );
          case AppRoutes.voiceDiaryFinish:
            final diary = settings.arguments as DiaryModel;
            return MaterialPageRoute(
              builder: (_) => DiaryFinishPage(diary: diary),
            );
          case AppRoutes.voiceDiaryReview:
            return MaterialPageRoute(builder: (_) => const DiaryReviewPage());
          default:
            return null;
        }
      },
      debugShowCheckedModeBanner: false,
    );
  }
}
