import 'package:flutter/material.dart';

/// 整個 App 的 Navigator，給「不在畫面裡」的地方換頁用（例如點手機通知打開通知頁）
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
