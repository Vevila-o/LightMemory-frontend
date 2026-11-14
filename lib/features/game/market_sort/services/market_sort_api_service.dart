import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../../../core/network/auth_headers.dart';
import '../../../../core/network/api_response.dart';
import '../models/trial_result.dart';
import '../../../../core/constants/api_constants.dart';
import '../../../rewards/models/rewards_models.dart';

class MarketSortSubmitResult {
  /// 每個人第一場是「熟悉場」，不計分
  final bool isPretest;

  /// 熟悉場或資料不夠算的場次是 null，一律有值才顯示
  final int? currentScore;
  final int? highestScore;
  final List<int> recentScores; // 不含 null 的場次，前幾次可能是空的
  final String? encouragementTier; // "great" / "good" / "keep_trying"

  /// 點數與成就：交卷回應的 data.rewards（熟悉場也會給點數）
  final RewardsResult rewards;

  MarketSortSubmitResult({
    this.isPretest = false,
    required this.currentScore,
    required this.highestScore,
    required this.recentScores,
    required this.encouragementTier,
    this.rewards = RewardsResult.empty,
  });

  factory MarketSortSubmitResult.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>;
    return MarketSortSubmitResult(
      isPretest: data['is_pretest'] as bool? ?? false,
      currentScore: data['current_score'] as int?,
      highestScore: data['highest_score'] as int?,
      recentScores: List<int>.from(data['recent_scores'] as List? ?? []),
      encouragementTier: data['encouragement_tier'] as String?,
      rewards: RewardsResult.fromData(data),
    );
  }
}

class MarketSortApiService {
  static const String _submitUrl = '${ApiConstants.serverUrl}/api/games/market-sort/submit/';
  static const String _configUrl = '${ApiConstants.serverUrl}/api/games/market-sort/config/';

  /// 一場幾題：GET config/ 的 data.total_questions。
  ///
  /// 一般帳號後端回 28；複賽 demo 用的 admin_demo 帳號回 3。前端不判斷帳號，一律聽後端。
  /// 打不到、逾時、沒有這個欄位或格式不對都回 null，遊戲照原本 28 題，一般使用者不受影響。
  static Future<int?> fetchTotalQuestions() async {
    try {
      final response = await http
          .get(Uri.parse(_configUrl), headers: await authHeaders())
          .timeout(const Duration(seconds: 4));
      return parseData(response, (data) {
        final raw = data is Map ? data['total_questions'] : null;
        return raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
      });
    } catch (e) {
      debugPrint('market-sort config 失敗，照原本 28 題：$e');
      return null;
    }
  }

  static Future<MarketSortSubmitResult> submit({
    required String sessionId,
    required bool isComplete,
    required List<TrialResult> questions,
  }) async {
    final response = await http.post(
      Uri.parse(_submitUrl),
      headers: await authHeaders(),
      body: jsonEncode({
        'session_id': sessionId,
        'is_complete': isComplete,
        'questions': questions
            .map((q) => {
                  'question_index': q.questionIndex,
                  'is_correct': q.isCorrect,
                  'reaction_time_ms': q.reactionTimeMs,
                  'trial_type':
                      q.trialType == TrialType.repeat ? 'repeat' : 'switch',
                  'error_type': q.errorType == null
                      ? null
                      : (q.errorType == ErrorType.persistent
                          ? 'persistent'
                          : 'random'),
                })
            .toList(),
      }),
    );

    return parseEnvelope(response, MarketSortSubmitResult.fromJson);
  }
}