import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/game_rule.dart';
import '../models/market_sort_item.dart';
import '../models/market_sort_item_pool.dart';
import '../models/market_sort_stage_plan.dart';
import '../models/trial_result.dart';
import '../services/market_sort_answer_judge.dart';

enum QuestionPhase { locked, interactive, resolved }

class MarketSortGameController extends ChangeNotifier {
  MarketSortGameController({Random? random}) : _random = random ?? Random() {
    _setPlan(buildMarketSort28QuestionPlan(_random));
    _pickItemForCurrentQuestion();
  }

  final Random _random;

  /// 後端 config/ 給的題數上限（admin_demo 是 3）；null 代表照原本 28 題
  int? _questionLimit;

  void _setPlan(List<StagePlan> plan) {
    final limit = _questionLimit;
    _plan = limit == null ? plan : limitMarketSortPlan(plan, limit);
    _flattenedRules = _plan.expand((stage) => stage.rules).toList();
    _questionStageIndex = _plan
        .asMap()
        .entries
        .expand(
          (entry) => List.filled(entry.value.questionCount, entry.key),
        )
        .toList();
    _stageBoundaryIndices = _computeStageBoundaryIndices();
  }

  /// 開局前套用後端給的題數（`MarketSortApiService.fetchTotalQuestions`）。
  ///
  /// 比目前題數少才會縮短（只出前 N 題），null、0 以下或不比 28 少都維持原樣。
  /// 已經開始作答就不再改，避免玩到一半題數變了；之後 [reset] 重新開局也會沿用。
  void applyQuestionLimit(int? limit) {
    if (_currentIndex != 0 || _results.isNotEmpty) return;
    if (limit == null || limit <= 0 || limit >= totalQuestionCount) return;
    _questionLimit = limit;
    _setPlan(_plan);
    notifyListeners();
  }

  late List<StagePlan> _plan;
  late List<GameRule> _flattenedRules;
  late List<int> _questionStageIndex;
  late List<int> _stageBoundaryIndices;

  List<int> _computeStageBoundaryIndices() {
    final boundaries = <int>[];
    int cumulative = 0;
    for (final stage in _plan) {
      cumulative += stage.questionCount;
      if (cumulative < totalQuestionCount) {
        boundaries.add(cumulative);
      }
    }
    return boundaries;
  }

  int _currentIndex = 0;

  int get displayQuestionNumber => _currentIndex + 1;
  int get totalQuestionCount => _flattenedRules.length;
  GameRule get currentRule => _flattenedRules[_currentIndex];
  GameRule? get previousRule =>
      _currentIndex == 0 ? null : _flattenedRules[_currentIndex - 1];
  bool get isRepeatTrial =>
      previousRule != null && currentRule == previousRule;

  /// 送給後端記錄用的題型：第 1 題沒有上一題，記成 repeat（計分文件問題 7）
  /// isRepeatTrial 維持原本邏輯，只用來決定鎖定時間（第 1 題仍是 1 秒）
  TrialType get recordedTrialType =>
      (_currentIndex == 0 || isRepeatTrial)
          ? TrialType.repeat
          : TrialType.switchType;

  int get currentStageIndex => _questionStageIndex[_currentIndex];
  String get currentStageName => _plan[currentStageIndex].stageName;
  bool get isStageBoundary => _stageBoundaryIndices.contains(_currentIndex);
  bool get isLastQuestion => _currentIndex == totalQuestionCount - 1;

  late MarketSortItem _currentItem;
  MarketSortItem get currentItem => _currentItem;

  void _pickItemForCurrentQuestion() {
    final availableItems = marketSortItemPool
        .where((item) => !item.isExcludedFor(currentRule))
        .toList();
    _currentItem = availableItems[_random.nextInt(availableItems.length)];
  }

  QuestionPhase _phase = QuestionPhase.locked;
  QuestionPhase get phase => _phase;

  final Stopwatch _stopwatch = Stopwatch();
  int? _lastReactionTimeMs;
  int? get lastReactionTimeMs => _lastReactionTimeMs;

  Timer? _lockedTimer;

  Duration get _lockedDuration {
    if (isRepeatTrial) {
      return const Duration(milliseconds: 300);
    }
    return isStageBoundary
        ? const Duration(seconds: 2)
        : const Duration(seconds: 1);
  }

  void startQuestion({
    VoidCallback? onEnterLocked,
    VoidCallback? onEnterInteractive,
  }) {
    _phase = QuestionPhase.locked;
    _lastReactionTimeMs = null;
    _stopwatch.reset();
    notifyListeners();
    onEnterLocked?.call();

    _lockedTimer?.cancel();
    _lockedTimer = Timer(_lockedDuration, () {
      _phase = QuestionPhase.interactive;
      _stopwatch.start();
      notifyListeners();
      onEnterInteractive?.call();
    });
  }

  final List<TrialResult> _results = [];
  List<TrialResult> get results => List.unmodifiable(_results);

  void resolveQuestion(Object selectedBucketValue) {
    if (_phase != QuestionPhase.interactive) return;
    _stopwatch.stop();
    _lastReactionTimeMs = _stopwatch.elapsedMilliseconds;
    _phase = QuestionPhase.resolved;

    final judgement = judgeAnswer(
      item: _currentItem,
      currentRule: currentRule,
      selectedBucketValue: selectedBucketValue,
      trialType: recordedTrialType,
      previousRule: previousRule,
    );

    _results.add(
      TrialResult(
        questionIndex: displayQuestionNumber,
        isCorrect: judgement.isCorrect,
        reactionTimeMs: _lastReactionTimeMs!,
        trialType: recordedTrialType,
        errorType: judgement.errorType,
      ),
    );

    notifyListeners();
  }

  void moveToNextQuestion() {
    if (isLastQuestion) return;
    _currentIndex++;
    _pickItemForCurrentQuestion();
  }

  void reset() {
    _currentIndex = 0;
    _results.clear();
    _lockedTimer?.cancel();
    _setPlan(buildMarketSort28QuestionPlan(_random));
    _pickItemForCurrentQuestion();
  }

  @override
  void dispose() {
    _lockedTimer?.cancel();
    super.dispose();
  }
}