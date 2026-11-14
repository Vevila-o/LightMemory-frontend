import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_memory/features/game/market_sort/controllers/market_sort_game_controller.dart';
import 'package:light_memory/features/game/market_sort/models/trial_result.dart';
import 'package:light_memory/features/game/market_sort/models/game_rule.dart';
import 'package:light_memory/features/game/market_sort/models/market_sort_stage_plan.dart';

void main() {
  test('28題的規則與階段邊界推進邏輯正確', () {
    final controller = MarketSortGameController();

    final boundaryQuestions = <int>[];

    for (var i = 0; i < 28; i++) {
      if (controller.isStageBoundary) {
        boundaryQuestions.add(controller.displayQuestionNumber);
      }
      controller.moveToNextQuestion();
    }

    // 三個大階段邊界應該剛好是第6、11、16題（生熟5題結束後、
    // 種類5題結束後、顏色5題結束後，各自的下一題）
    expect(boundaryQuestions, [6, 11, 16]);
  });

  test('全場第一題沒有previousRule', () {
    final controller = MarketSortGameController();
    expect(controller.previousRule, isNull);
  });

  test('走完28題後isLastQuestion為true', () {
    final controller = MarketSortGameController();
    for (var i = 0; i < 27; i++) {
      controller.moveToNextQuestion();
    }
    expect(controller.isLastQuestion, isTrue);
  });

  test('第一題(非repeat、非邊界)locked狀態1秒後自動轉interactive', () async {
    final controller = MarketSortGameController();
    controller.startQuestion();
    expect(controller.phase, QuestionPhase.locked);

    await Future.delayed(const Duration(milliseconds: 1100));
    expect(controller.phase, QuestionPhase.interactive);
  });

  test('resolveQuestion記錄reaction_time_ms並轉入resolved', () async {
    final controller = MarketSortGameController();
    controller.startQuestion();
    await Future.delayed(const Duration(milliseconds: 1100)); // 等過locked
    await Future.delayed(const Duration(milliseconds: 200)); // 模擬思考時間

    controller.resolveQuestion('dummy');

    expect(controller.phase, QuestionPhase.resolved);
    expect(controller.lastReactionTimeMs, isNotNull);
    expect(controller.lastReactionTimeMs! >= 150, isTrue);
  });

  test('locked狀態呼叫resolveQuestion應被防呆擋下，不會誤判定', () async {
    final controller = MarketSortGameController();
    controller.startQuestion();
    controller.resolveQuestion('dummy'); // 這時還在locked，應該什麼都不發生

    expect(controller.phase, QuestionPhase.locked);
  });

  test('resolveQuestion會產生正確的TrialResult並累積進results', () async {
    // 用固定種子的Random，確保抽題結果可預測
    final controller = MarketSortGameController(random: Random(42));
    controller.startQuestion(); // 之前漏掉這行，locked狀態沒過，resolveQuestion會被防呆擋下
    await Future.delayed(const Duration(milliseconds: 1100));

    final correctValue = controller.currentItem.valueFor(
      controller.currentRule,
    );
    controller.resolveQuestion(correctValue!);

    expect(controller.results.length, 1);
    expect(controller.results.first.isCorrect, isTrue);
    expect(controller.results.first.errorType, isNull);
    expect(controller.results.first.questionIndex, 1);
  });

  test('抽到的商品一定適用於當題規則（不會是null屬性）', () {
    final controller = MarketSortGameController(random: Random(1));
    expect(
      controller.currentItem.isExcludedFor(controller.currentRule),
      isFalse,
    );
  });

  test('第1題記錄成repeat，但鎖定時間仍維持1秒', () async {
    final controller = MarketSortGameController(random: Random(42));
    controller.startQuestion();
    await Future.delayed(const Duration(milliseconds: 1100));
    expect(controller.phase, QuestionPhase.interactive);

    controller.resolveQuestion('dummy');
    expect(controller.results.first.trialType, TrialType.repeat);
  });

  group('Demo 模式：後端 config/ 給的題數', () {
    test('給 3 題：只出前 3 題（生熟），第 3 題是最後一題', () {
      final c = MarketSortGameController(random: Random(1));
      c.applyQuestionLimit(3);
      expect(c.totalQuestionCount, 3);
      expect(c.currentRule, GameRule.freshness);
      expect(c.isStageBoundary, isFalse);
      c.moveToNextQuestion();
      c.moveToNextQuestion();
      expect(c.isLastQuestion, isTrue);
      c.dispose();
    });

    test('重新開始（reset）沿用 3 題', () {
      final c = MarketSortGameController(random: Random(1));
      c.applyQuestionLimit(3);
      c.reset();
      expect(c.totalQuestionCount, 3);
      c.dispose();
    });

    test('null、0、28 以上都維持 28 題', () {
      for (final limit in [null, 0, -1, 28, 40]) {
        final c = MarketSortGameController(random: Random(1));
        c.applyQuestionLimit(limit);
        expect(c.totalQuestionCount, 28, reason: 'limit=$limit');
        c.dispose();
      }
    });

    test('已經開始作答就不再改題數', () {
      final c = MarketSortGameController(random: Random(1));
      c.moveToNextQuestion();
      c.applyQuestionLimit(3);
      expect(c.totalQuestionCount, 28);
      c.dispose();
    });

    test('limitMarketSortPlan 跨階段時最後一個階段只留到湊滿的題數', () {
      final plan = limitMarketSortPlan(marketSort28QuestionPlan, 7);
      expect(plan.map((s) => s.stageName), ['生熟', '種類']);
      expect(plan.map((s) => s.questionCount), [5, 2]);
      expect(plan.last.rules, hasLength(2));
    });
  });
}
