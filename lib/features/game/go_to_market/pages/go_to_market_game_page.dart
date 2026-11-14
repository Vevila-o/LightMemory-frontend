import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:light_memory/features/game/go_to_market/models/go_to_market_model.dart';
import '../services/audio_service.dart';
import '../services/go_to_market_service.dart';
import '../../../../core/services/token_storage.dart';
import '../../../auth/pages/auth_gate.dart';
import '../widgets/market_result_dialog.dart';
import '../../widgets/game_pause.dart';
import '../../widgets/game_menu_button.dart';
import 'go_to_market_tutorial_page.dart';
import '../../../rewards/models/rewards_models.dart';
import '../../../rewards/widgets/rewards_dialog.dart';

class GoToMarketGamePage extends StatefulWidget {
  const GoToMarketGamePage({super.key});

  @override
  State createState() => _GoToMarketGamePageState();
}

class _GoToMarketGamePageState extends State with WidgetsBindingObserver {
  /// 一場幾題：開局時照後端 config/ 的 total_questions（一般帳號 20 題，
  /// 複賽 demo 用的 admin_demo 帳號是 3 題）；打不到 config/ 就用預設 20 題。
  int totalQuestions = kMarketRouteDefaultTotalQuestions;
  int currentQuestionNumber = 1;
  int attemptNumber = 1; // 當前題目的嘗試次數 (1~3)

  String? sessionId; // 後端回傳 UUID 字串；null 代表本地模式
  String currentStage = 'basic';
  int correctStreak = 0;
  int fastCorrectStreak = 0; // 快速連對數 (答對且反應時間 <= 曝光時間 50%)
  int wrongStreak = 0;
  int correctCount = 0;
  int totalScoreAccumulated = 0;

  int exposureTimeMs = 2000;
  bool isExposing = true;
  bool canAnswer = false;
  int _remainingSeconds = 20;
  Timer? _exposureTimer;
  Timer? _countdownTimer;

  DateTime? _questionStartTime;
  final List _reactionTimes = [];

  DateTime? _pausedStartTime;
  int _totalPausedMsThisRound = 0;
  bool _isPauseDialogOpen = false;
  bool _canAutoPause = false;
  bool _hasPromptedRelogin = false; // 401 提示每場只跳一次

  String? feedbackState; // 'correct' | 'wrong' | null
  String? lastUserClickedPosition;

  MarketRoundData? currentRound;

  String get levelTitle {
    switch (currentStage) {
      case 'intermediate':
        return '中階難度';
      case 'advanced':
        return '高階難度';
      case 'basic':
      default:
        return '初階難度';
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 強制橫向鎖定
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    });

    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) {
        setState(() {
          _canAutoPause = true;
        });
      }
    });

    _startNewGameSession();
  }

  @override
  void dispose() {
    // 退出遊戲時恢復為直向
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    WidgetsBinding.instance.removeObserver(this);
    _exposureTimer?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedStartTime = DateTime.now();
      _pauseTimers();
    } else if (state == AppLifecycleState.resumed) {
      if (_pausedStartTime != null) {
        final pausedMs = DateTime.now()
            .difference(_pausedStartTime!)
            .inMilliseconds;
        _totalPausedMsThisRound += pausedMs;
        _pausedStartTime = null;
      }
      if (_canAutoPause && !_isPauseDialogOpen && mounted) {
        _showPauseDialog();
      }
    }
  }

  void _pauseTimers() {
    _exposureTimer?.cancel();
    _countdownTimer?.cancel();
  }

  void _resumeTimers() {
    if (isExposing) {
      _startExposure();
    } else if (canAnswer) {
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return;
        if (_remainingSeconds > 1) {
          _remainingSeconds--;
        } else {
          timer.cancel();
          _handleAnswer(userPosition: null, isTimeout: true);
        }
      });
    }
  }

  void _showPauseDialog() {
    _isPauseDialogOpen = true;
    _pauseTimers();

    GamePause.show(
      context,
      onResume: () {
        AudioService.playClick();
        _isPauseDialogOpen = false;
        _resumeTimers();
      },
      onTutorial: () async {
        AudioService.playClick();
        _isPauseDialogOpen = false;
        final restart = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (context) =>
                const GoToMarketTutorialPage(openedFromGame: true),
          ),
        );
        // 在教學頁按了「開始挑戰」或「略過教學」：這一場重新開始
        if (restart == true && mounted) _resetGame();
      },
      onRestart: () {
        AudioService.playClick();
        _isPauseDialogOpen = false;
        _resetGame();
      },
      onExit: () {
        AudioService.playClick();
        _isPauseDialogOpen = false;
        Navigator.of(context).popUntil((route) => route.isFirst);
      },
    );
  }

  void _resetGame() {
    setState(() {
      currentQuestionNumber = 1;
      attemptNumber = 1;
      correctCount = 0;
      correctStreak = 0;
      fastCorrectStreak = 0;
      wrongStreak = 0;
      totalScoreAccumulated = 0;
      currentStage = 'basic';
      exposureTimeMs = 2000;
      _reactionTimes.clear();
      _startNewGameSession();
    });
  }

  Future _startNewGameSession() async {
    _hasPromptedRelogin = false;
    // config/（一場幾題）跟 start/ 同時打，後端沒回應時最多只等一次 4 秒逾時
    final configFuture = GoToMarketService.fetchConfig();
    sessionId = await GoToMarketService.startGame();
    final config = await configFuture;
    if (!mounted) return;
    setState(() => totalQuestions = marketRouteTotalQuestions(config));
    if (await _promptReloginIfUnauthorized()) return;
    await _loadRound();
  }

  /// API 回 401 時提示重新登入（每場只跳一次），否則會默默用本地模式、成績不進後端。
  /// 回傳 true 代表已導去登入流程，呼叫端要停止後續動作。
  Future<bool> _promptReloginIfUnauthorized() async {
    if (!GoToMarketService.unauthorized || _hasPromptedRelogin || !mounted) {
      return false;
    }
    _hasPromptedRelogin = true;

    final relogin = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFFF7F9F6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_clock_rounded,
                color: Color(0xFFD97736),
                size: 54,
              ),
              SizedBox(height: 8),
              Text(
                '登入已過期',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2D5A43),
                ),
              ),
              SizedBox(height: 6),
              Text(
                '請重新登入，這場遊戲的成績才會被記錄。\n選擇「繼續練習」可以照常玩，但成績不會寫入後端。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: Color(0xFF4C5E53)),
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF2D5A43), width: 1.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () {
                AudioService.playClick();
                Navigator.of(dialogContext).pop(false);
              },
              child: const Text(
                '繼續練習',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2D5A43),
                ),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2D5A43),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () {
                AudioService.playClick();
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text(
                '重新登入',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        );
      },
    );
    if (relogin != true || !mounted) return false;

    // 清掉過期 token，交給 AuthGate 走一般的登入／註冊流程
    await TokenStorage.clear();
    if (!mounted) return true;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const AuthGate()),
      (route) => false,
    );
    return true;
  }

  Future _loadRound() async {
    MarketRoundData? round;
    if (sessionId != null) {
      round = await GoToMarketService.fetchRound(sessionId: sessionId!);
    }
    round ??= _generateLocalRound(
      currentQuestionNumber,
      currentStage,
      exposureTimeMs,
    );

    if (!mounted) return;
    setState(() {
      currentRound = round;
      exposureTimeMs = round!.exposureTimeMs;
      attemptNumber = 1;
      feedbackState = null;
      lastUserClickedPosition = null;
      _totalPausedMsThisRound = 0;
    });

    _startExposure();
  }

  /// 本地題目生成 (與規格書難度對齊)
  MarketRoundData _generateLocalRound(
    int qNum,
    String stage,
    int currentExpMs,
  ) {
    final quadrants = ['q1', 'q2', 'q3', 'q4'];
    final random = Random();

    if (stage == 'basic') {
      // 初階：只出現在正中央 center，無干擾物，閃現時間 2000~1500ms
      return MarketRoundData(
        questionNumber: qNum,
        stage: 'basic',
        targetItem: '魚',
        targetPosition: 'center',
        distractorItems: const [],
        exposureTimeMs: currentExpMs.clamp(1500, 2000),
      );
    } else if (stage == 'intermediate') {
      // 中階：四象限之一 q1~q4，無干擾物，閃現時間 1500~1000ms
      final target = quadrants[random.nextInt(quadrants.length)];
      return MarketRoundData(
        questionNumber: qNum,
        stage: 'intermediate',
        targetItem: '鮭魚',
        targetPosition: target,
        distractorItems: const [],
        exposureTimeMs: currentExpMs.clamp(1000, 1500),
      );
    } else {
      // 高階：四象限之一 q1~q4，有 1 個干擾物 (不重疊)，閃現時間 1000~500ms
      final target = quadrants[random.nextInt(quadrants.length)];
      final remainingQuadrants = quadrants.where((q) => q != target).toList();
      final distractor =
          remainingQuadrants[random.nextInt(remainingQuadrants.length)];

      return MarketRoundData(
        questionNumber: qNum,
        stage: 'advanced',
        targetItem: '鱸魚',
        targetPosition: target,
        distractorItems: [
          {'item': '魚骨頭', 'position': distractor},
        ],
        exposureTimeMs: currentExpMs.clamp(500, 1000),
      );
    }
  }

  void _startExposure() {
    _exposureTimer?.cancel();
    _countdownTimer?.cancel();

    setState(() {
      isExposing = true;
      canAnswer = false;
      feedbackState = null;
      _remainingSeconds = 20;
    });

    _exposureTimer = Timer(Duration(milliseconds: exposureTimeMs), () {
      if (!mounted) return;
      setState(() {
        isExposing = false;
        canAnswer = true;
        _questionStartTime = DateTime.now();
      });

      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return;
        if (_remainingSeconds > 1) {
          _remainingSeconds--;
        } else {
          timer.cancel();
          _handleAnswer(userPosition: null, isTimeout: true);
        }
      });
    });
  }

  /// 點擊作答核心處理
  Future _handleAnswer({
    required String? userPosition,
    bool isTimeout = false,
  }) async {
    if (!canAnswer) return;
    _countdownTimer?.cancel();

    final now = DateTime.now();
    final rawReactionMs = _questionStartTime != null
        ? now.difference(_questionStartTime!).inMilliseconds
        : 20000;
    final finalReactionMs = (rawReactionMs - _totalPausedMsThisRound).clamp(
      0,
      20000,
    );
    _reactionTimes.add(finalReactionMs);

    // 核心判斷：是否等於目標位置
    final actualTarget = currentRound?.targetPosition;
    final bool isCorrect =
        !isTimeout && (userPosition != null && userPosition == actualTarget);

    setState(() {
      canAnswer = false;
      lastUserClickedPosition = userPosition;
    });

    MarketAnswerResponse? response;
    if (sessionId != null) {
      try {
        response = await GoToMarketService.submitAnswer(
          sessionId: sessionId!,
          questionNumber: currentQuestionNumber,
          attemptNumber: attemptNumber,
          answerPosition: userPosition,
          isTimeout: isTimeout,
          responseTimeMs: finalReactionMs,
          pausedDurationMs: _totalPausedMsThisRound,
        );
      } catch (e) {
        debugPrint('⚠️ submitAnswer API 異常，啟動本地 DDA 邏輯: $e');
      }
    }

    // 當 API 失敗、或是回傳結果異常時，以本地標準規格邏輯為準
    if (response == null || response.isCorrect != isCorrect) {
      response = _generateLocalAnswerResponse(
        isCorrect,
        isTimeout,
        finalReactionMs,
      );
    }

    _applyAnswerResponse(response, isCorrect, isTimeout, finalReactionMs);
  }

  /// 依照最新規格書實作本地 DDA 與計分邏輯（支援雙軌升階）
  MarketAnswerResponse _generateLocalAnswerResponse(
    bool isCorrect,
    bool isTimeout,
    int reactionMs,
  ) {
    final bool isLastQuestion = (currentQuestionNumber >= totalQuestions);

    if (isCorrect) {
      final newCorrectStreak = correctStreak + 1;

      // 1. 速度加成與快速連對判定：反應時間 <= 曝光時間 50%
      final bool isFast = (reactionMs <= (exposureTimeMs * 0.5));
      final int speedBonus = isFast ? 2 : 0;
      final int newFastStreak = isFast ? (fastCorrectStreak + 1) : 0;

      // 2. 基礎分
      int baseScore = (attemptNumber == 1) ? 10 : (attemptNumber == 2 ? 6 : 3);

      // 3. 難度係數
      double multiplier = (currentStage == 'advanced')
          ? 1.6
          : (currentStage == 'intermediate' ? 1.3 : 1.0);

      int scoreEarned = (baseScore * multiplier).round() + speedBonus;

      // 4. 雙軌升階判定：一般升階 (連對 5) OR 快速升階 (連 3 題快速答對)
      final bool triggerGeneralPromote = (newCorrectStreak >= 5);
      final bool triggerFastPromote = (newFastStreak >= 3);

      if ((triggerGeneralPromote || triggerFastPromote) &&
          currentStage != 'advanced') {
        final nextStage = (currentStage == 'basic')
            ? 'intermediate'
            : 'advanced';
        return MarketAnswerResponse(
          isCorrect: true,
          action: isLastQuestion ? 'finished' : 'promoted',
          currentStage: nextStage,
          correctStreak: 0,
          wrongAttempts: 0,
          scoreEarned: scoreEarned,
          fastCorrectStreak: 0,
        );
      }

      return MarketAnswerResponse(
        isCorrect: true,
        action: isLastQuestion ? 'finished' : 'next_question',
        currentStage: currentStage,
        correctStreak: newCorrectStreak,
        wrongAttempts: 0,
        scoreEarned: scoreEarned,
        fastCorrectStreak: newFastStreak,
      );
    } else {
      // 答錯時連錯數 +1
      final newWrongStreak = wrongStreak + 1;

      // 連錯 5 題降階
      if (newWrongStreak >= 5 && currentStage != 'basic') {
        final prevStage = (currentStage == 'advanced')
            ? 'intermediate'
            : 'basic';
        return MarketAnswerResponse(
          isCorrect: false,
          action: isLastQuestion ? 'finished' : 'demoted',
          currentStage: prevStage,
          correctStreak: 0,
          wrongAttempts: attemptNumber,
          scoreEarned: 0,
          fastCorrectStreak: 0,
        );
      }

      // 規格書：連錯第 3 次、或超時未作答、或最後一題 -> 直接跳題
      if (attemptNumber >= 3 || isTimeout || isLastQuestion) {
        return MarketAnswerResponse(
          isCorrect: false,
          action: isLastQuestion ? 'finished' : 'next_question',
          currentStage: currentStage,
          correctStreak: 0,
          wrongAttempts: attemptNumber,
          scoreEarned: 0,
          fastCorrectStreak: 0,
        );
      }

      // 連錯未滿 3 次：顯示重看題目 (action = retry)
      return MarketAnswerResponse(
        isCorrect: false,
        action: 'retry',
        currentStage: currentStage,
        correctStreak: 0,
        wrongAttempts: attemptNumber,
        scoreEarned: 0,
        fastCorrectStreak: 0,
      );
    }
  }

  void _applyAnswerResponse(
    MarketAnswerResponse response,
    bool isCorrect,
    bool isTimeout,
    int reactionMs,
  ) {
    setState(() {
      currentStage = response.currentStage;
      correctStreak = response.correctStreak;
      totalScoreAccumulated += response.scoreEarned;

      // 更新快速連對數
      if (isCorrect) {
        final bool isFast = (reactionMs <= (exposureTimeMs * 0.5));
        if (response.action == 'promoted') {
          fastCorrectStreak = 0;
        } else {
          fastCorrectStreak = isFast ? (fastCorrectStreak + 1) : 0;
        }
      } else {
        fastCorrectStreak = 0;
      }

      // 閃現時間動態調整 (做法 B)
      if (response.action == 'promoted' || response.action == 'demoted') {
        wrongStreak = 0;
        fastCorrectStreak = 0;
        // 升/降階重設回該階段寬鬆端
        if (currentStage == 'basic') exposureTimeMs = 2000;
        if (currentStage == 'intermediate') exposureTimeMs = 1500;
        if (currentStage == 'advanced') exposureTimeMs = 1000;
      } else if (isCorrect) {
        wrongStreak = 0;
        int lowerBound = (currentStage == 'basic')
            ? 1500
            : (currentStage == 'intermediate' ? 1000 : 500);
        exposureTimeMs = max(lowerBound, exposureTimeMs - 100);
      } else {
        wrongStreak++;
        int upperBound = (currentStage == 'basic')
            ? 2000
            : (currentStage == 'intermediate' ? 1500 : 1000);
        exposureTimeMs = min(upperBound, exposureTimeMs + 150);
      }
    });

    if (isCorrect) {
      AudioService.playCorrect();
      correctCount++;
      setState(() {
        feedbackState = 'correct';
      });

      Future.delayed(const Duration(milliseconds: 1000), () {
        if (!mounted) return;
        if (currentQuestionNumber >= totalQuestions ||
            response.action == 'finished') {
          _showGameSummary();
        } else if (response.action == 'promoted') {
          _showLevelTransitionDialog(isPromoted: true);
        } else {
          _proceedToNextQuestion();
        }
      });
    } else {
      AudioService.playWrong();
      setState(() {
        feedbackState = 'wrong';
      });

      // 規格書：連錯未滿 3 次且 action == 'retry'，保留畫面讓使用者按「重看題目」
      if (attemptNumber < 3 && !isTimeout && response.action == 'retry') {
        // 停留在本題，等待點擊按鈕
      } else {
        // 連錯第 3 次或超時，閃一下答錯後直接進入下一題或結算
        Future.delayed(const Duration(milliseconds: 1200), () {
          if (!mounted) return;
          if (currentQuestionNumber >= totalQuestions ||
              response.action == 'finished') {
            _showGameSummary();
          } else if (response.action == 'demoted') {
            _showLevelTransitionDialog(isPromoted: false);
          } else {
            _proceedToNextQuestion();
          }
        });
      }
    }
  }

  void _proceedToNextQuestion() {
    if (currentQuestionNumber < totalQuestions) {
      setState(() {
        currentQuestionNumber++;
        attemptNumber = 1;
      });
      _loadRound();
    } else {
      _showGameSummary();
    }
  }

  void _showLevelTransitionDialog({required bool isPromoted}) {
    if (isPromoted) {
      AudioService.playLevelUp();
    } else {
      AudioService.playClick();
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFFF7F9F6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isPromoted ? Icons.stars_rounded : Icons.info_outline_rounded,
                color: isPromoted
                    ? const Color(0xFFE5A93C)
                    : const Color(0xFF4C7B5D),
                size: 60,
              ),
              const SizedBox(height: 8),
              Text(
                isPromoted ? '表現優異！難度升級！' : '節奏調整！進入更合適的難度',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2D5A43),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '目前階段為【$levelTitle】\n閃現時間已調整為寬鬆模式，準備好迎接下一題！',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, color: Color(0xFF4C5E53)),
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2D5A43),
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: () {
                AudioService.playClick();
                Navigator.of(context).pop();
                _proceedToNextQuestion();
              },
              child: const Text(
                '進入下一題',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future _showGameSummary() async {
    int finalScore = totalScoreAccumulated;
    RewardsResult rewards = RewardsResult.empty; // 點數與成就：finish 回應的 rewards

    if (sessionId != null) {
      final finishRes = await GoToMarketService.finishGame(
        sessionId: sessionId!,
      );
      if (finishRes != null) {
        finalScore = finishRes.totalScore;
        rewards = finishRes.rewards;
      }
    }

    // 遊戲中途 token 過期時，結算前提醒這場成績沒進後端
    if (await _promptReloginIfUnauthorized()) return;

    final List history = [];
    int highestScore = finalScore;

    try {
      final prefs = await SharedPreferences.getInstance();
      final List? savedList = prefs.getStringList('market_score_list');

      if (savedList != null && savedList.isNotEmpty) {
        for (final item in savedList) {
          final val = int.tryParse(item);
          if (val != null) history.add(val);
        }
      }

      history.add(finalScore);
      while (history.length > 5) {
        history.removeAt(0);
      }

      await prefs.setStringList(
        'market_score_list',
        history.map((e) => e.toString()).toList(),
      );

      final storedHighest = prefs.getInt('market_highest_score') ?? 0;
      highestScore = storedHighest > finalScore ? storedHighest : finalScore;
      await prefs.setInt('market_highest_score', highestScore);
    } catch (e) {
      debugPrint('❌ 本地紀錄儲存失敗: $e');
      history.clear();
      history.add(finalScore);
    }

    if (!mounted) return;

    // 點數與成就：先跳點數視窗、成就視窗，再開原本的結算視窗
    if (!mounted) return;
    await showRewardsAndAchievements(context, rewards, forceLight: true);
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return MarketResultDialog(
          currentScore: finalScore,
          highestScore: highestScore,
          history: List.from(history),
          onPlayAgain: _resetGame,
          onExit: () => Navigator.of(context).popUntil((route) => route.isFirst),
        );
      },
    );
  }

  Widget _buildFishImage() {
    final itemName = currentRound?.targetItem ?? '魚';
    String assetName = 'assets/images/fish.png';

    if (itemName.contains('鮭魚') || itemName.contains('fish2')) {
      assetName = 'assets/images/fish2.png';
    } else if (itemName.contains('鱸魚') || itemName.contains('fish3')) {
      assetName = 'assets/images/fish3.png';
    } else {
      assetName = 'assets/images/fish.png';
    }

    return Image.asset(assetName, width: 140, height: 48, fit: BoxFit.contain);
  }

  Widget _buildFishBoneImage() {
    return Image.asset(
      'assets/images/fish_bone.png',
      width: 95,
      height: 48,
      fit: BoxFit.contain,
    );
  }

  Widget _buildCheckMark() {
    return Container(
      width: 54,
      height: 54,
      decoration: const BoxDecoration(
        color: Color(0xFF3F6851),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: const Icon(Icons.check, color: Colors.white, size: 34),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (currentRound == null) {
      return const Scaffold(
        backgroundColor: Color(0xFFF7F9F6),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF2D5A43)),
        ),
      );
    }

    final targetPos = currentRound!.targetPosition;
    final distractorList = currentRound!.distractorItems;
    final bool showObjects = isExposing || feedbackState != null;

    const double boardWidth = 480.0;
    const double boardHeight = 150.0;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9F6),
      body: Stack(
        children: [
          if (feedbackState == 'correct')
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.center,
                      radius: 0.95,
                      colors: [
                        Colors.transparent,
                        const Color(0xFF3B7252).withOpacity(0.08),
                        const Color(0xFF2F6646).withOpacity(0.32),
                      ],
                      stops: const [0.65, 0.85, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          if (feedbackState == 'wrong')
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.center,
                      radius: 0.95,
                      colors: [
                        Colors.transparent,
                        const Color(0xFFF58A61).withOpacity(0.10),
                        const Color(0xFFEB6B42).withOpacity(0.35),
                      ],
                      stops: const [0.65, 0.85, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 4.0,
              ),
              child: Column(
                children: [
                  // 1. 頂部導航列
                  Row(
                    children: [
                      // 橫向畫面頂部空間小，只換掉返回箭頭，用小尺寸的「選單」按鈕
                      GameMenuButton(
                        compact: true,
                        onTap: () {
                          AudioService.playClick();
                          _showPauseDialog();
                        },
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: const Icon(
                          Icons.help_outline_rounded,
                          color: Color(0xFF2D5A43),
                          size: 22,
                        ),
                        tooltip: '遊戲說明',
                        onPressed: () async {
                          AudioService.playClick();
                          final restart = await Navigator.of(context)
                              .push<bool>(
                                MaterialPageRoute(
                                  builder: (context) =>
                                      const GoToMarketTutorialPage(
                                        openedFromGame: true,
                                      ),
                                ),
                              );
                          // 在教學頁按了「開始挑戰」或「略過教學」：這一場重新開始
                          if (restart == true && mounted) _resetGame();
                        },
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8EFE9),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          levelTitle,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF2D5A43),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        currentQuestionNumber.toString() +
                            ' / ' +
                            totalQuestions.toString(),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2D5A43),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: currentQuestionNumber / totalQuestions,
                            backgroundColor: const Color(0xFFDDE5DF),
                            valueColor: const AlwaysStoppedAnimation(
                              Color(0xFF2D5A43),
                            ),
                            minHeight: 5,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const Spacer(),

                  // 2. 十字象限作答棋盤
                  SizedBox(
                    width: boardWidth,
                    height: boardHeight,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // 十字水平線
                        Container(
                          width: boardWidth - 10,
                          height: 3.0,
                          color: const Color(0xFF6B8775),
                        ),
                        // 十字垂直線
                        Container(
                          width: 3.0,
                          height: boardHeight - 8,
                          color: const Color(0xFF6B8775),
                        ),

                        // 物件顯示層
                        if (showObjects) ...[
                          if (targetPos == 'center') _buildFishImage(),
                          if (targetPos == 'q1')
                            Positioned(
                              top: 6,
                              right: 20,
                              child: _buildFishImage(),
                            ),
                          if (targetPos == 'q2')
                            Positioned(
                              top: 6,
                              left: 20,
                              child: _buildFishImage(),
                            ),
                          if (targetPos == 'q3')
                            Positioned(
                              bottom: 6,
                              left: 20,
                              child: _buildFishImage(),
                            ),
                          if (targetPos == 'q4')
                            Positioned(
                              bottom: 6,
                              right: 20,
                              child: _buildFishImage(),
                            ),

                          for (final d in distractorList) ...[
                            if (d['position'] == 'q1')
                              Positioned(
                                top: 6,
                                right: 30,
                                child: _buildFishBoneImage(),
                              ),
                            if (d['position'] == 'q2')
                              Positioned(
                                top: 6,
                                left: 30,
                                child: _buildFishBoneImage(),
                              ),
                            if (d['position'] == 'q3')
                              Positioned(
                                bottom: 6,
                                left: 30,
                                child: _buildFishBoneImage(),
                              ),
                            if (d['position'] == 'q4')
                              Positioned(
                                bottom: 6,
                                right: 30,
                                child: _buildFishBoneImage(),
                              ),
                          ],
                        ],

                        if (feedbackState == 'correct') _buildCheckMark(),

                        // 作答觸控層
                        if (canAnswer) ...[
                          // 第二象限 (左上 q2)
                          Positioned(
                            top: 0,
                            left: 0,
                            width: boardWidth / 2,
                            height: boardHeight / 2,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _handleAnswer(userPosition: 'q2'),
                            ),
                          ),
                          // 第一象限 (右上 q1)
                          Positioned(
                            top: 0,
                            right: 0,
                            width: boardWidth / 2,
                            height: boardHeight / 2,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _handleAnswer(userPosition: 'q1'),
                            ),
                          ),
                          // 第三象限 (左下 q3)
                          Positioned(
                            bottom: 0,
                            left: 0,
                            width: boardWidth / 2,
                            height: boardHeight / 2,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _handleAnswer(userPosition: 'q3'),
                            ),
                          ),
                          // 第四象限 (右下 q4)
                          Positioned(
                            bottom: 0,
                            right: 0,
                            width: boardWidth / 2,
                            height: boardHeight / 2,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _handleAnswer(userPosition: 'q4'),
                            ),
                          ),
                          // 正中央點擊區 (初階專用 center)
                          Center(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () =>
                                  _handleAnswer(userPosition: 'center'),
                              child: Container(
                                width: 90,
                                height: 70,
                                color: Colors.transparent,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  const Spacer(),

                  // 3. 底部提示與重看題目按鈕
                  Text(
                    isExposing
                        ? '注意看！記住魚出現的位置！'
                        : (feedbackState == 'wrong'
                              ? (attemptNumber >= 3
                                    ? '答錯三次囉！準備進入下一題'
                                    : '答錯囉！請看魚的正確位置')
                              : (feedbackState == 'correct'
                                    ? '太棒了！答對了！'
                                    : '請點擊剛剛魚出現的位置！')),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1E2D24),
                    ),
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 6),

                  // 規格書：連錯未滿 3 次可點擊重看題目
                  if (feedbackState == 'wrong' && attemptNumber < 3)
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFC0D8CC),
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 6,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () {
                        AudioService.playClick();
                        setState(() {
                          attemptNumber++;
                        });
                        _startExposure();
                      },
                      child: const Text(
                        '重看題目',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2D5A43),
                        ),
                      ),
                    )
                  else
                    const SizedBox(height: 32),

                  const SizedBox(height: 2),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
