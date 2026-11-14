import 'dart:math';
import 'game_rule.dart';

class StagePlan {
  final String stageName;
  final int questionCount;
  final List<GameRule> rules;

  const StagePlan({
    required this.stageName,
    required this.questionCount,
    required this.rules,
  });
}

/// 固定版本，保留給既有測試（market_sort_game_controller_test.dart）核對用，
/// 不要因為新增隨機版本而動到既有測試的比對基準
final List<StagePlan> marketSort28QuestionPlan = [
  StagePlan(
    stageName: '生熟',
    questionCount: 5,
    rules: List.filled(5, GameRule.freshness),
  ),
  StagePlan(
    stageName: '種類',
    questionCount: 5,
    rules: List.filled(5, GameRule.species),
  ),
  StagePlan(
    stageName: '顏色',
    questionCount: 5,
    rules: List.filled(5, GameRule.color),
  ),
  StagePlan(
    stageName: '隨機混合',
    questionCount: 13,
    rules: [
      GameRule.color, GameRule.species, GameRule.freshness,
      GameRule.species, GameRule.color, GameRule.freshness,
      GameRule.species, GameRule.freshness, GameRule.color,
      GameRule.species, GameRule.color, GameRule.freshness,
      GameRule.species,
    ],
  ),
];

/// 真正遊戲進行時使用的版本：前三階段固定不變，
/// 第四階段每次呼叫都用傳入的 random 重新產生，
/// 規則以連續2~3題為一組隨機排列，組與組之間規則不同
List<StagePlan> buildMarketSort28QuestionPlan(Random random) {
  return [
    StagePlan(
      stageName: '生熟',
      questionCount: 5,
      rules: List.filled(5, GameRule.freshness),
    ),
    StagePlan(
      stageName: '種類',
      questionCount: 5,
      rules: List.filled(5, GameRule.species),
    ),
    StagePlan(
      stageName: '顏色',
      questionCount: 5,
      rules: List.filled(5, GameRule.color),
    ),
    StagePlan(
      stageName: '隨機混合',
      questionCount: 13,
      rules: _buildStage4Rules(random, 13),
    ),
  ];
}

List<GameRule> _buildStage4Rules(Random random, int totalCount) {
  final result = <GameRule>[];
  GameRule? lastRule;
  while (result.length < totalCount) {
    final remaining = totalCount - result.length;
    var runLength = 2 + random.nextInt(2); // 每組2或3題
    if (runLength > remaining) runLength = remaining;

    GameRule rule;
    do {
      rule = GameRule.values[random.nextInt(GameRule.values.length)];
    } while (rule == lastRule);

    result.addAll(List.filled(runLength, rule));
    lastRule = rule;
  }
  return result;
}
/// 只保留前 [limit] 題（複賽 demo 用的 admin_demo 帳號，後端 config/ 會給 3 題）。
///
/// 依原本的階段順序切，不重新排題；最後一個保留的階段只留到剛好湊滿的題數。
/// [limit] 大於等於整份題目數時原樣回傳。
List<StagePlan> limitMarketSortPlan(List<StagePlan> plan, int limit) {
  final result = <StagePlan>[];
  var remaining = limit;
  for (final stage in plan) {
    if (remaining <= 0) break;
    final count = min(stage.questionCount, remaining);
    result.add(
      count == stage.questionCount
          ? stage
          : StagePlan(
              stageName: stage.stageName,
              questionCount: count,
              rules: stage.rules.sublist(0, count),
            ),
    );
    remaining -= count;
  }
  return result;
}
