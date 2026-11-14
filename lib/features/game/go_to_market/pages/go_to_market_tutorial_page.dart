import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/go_to_market_model.dart';
import '../services/audio_service.dart';
import '../services/go_to_market_service.dart';
import 'go_to_market_game_page.dart';

class GoToMarketTutorialPage extends StatefulWidget {
  /// 是否從遊戲頁（暫停選單、說明按鈕）打開。
  /// 是的話離開教學要回到遊戲，維持橫向；
  /// 不是（從遊戲首頁打開）的話，離開教學要設回直向。
  final bool openedFromGame;

  const GoToMarketTutorialPage({super.key, this.openedFromGame = false});

  @override
  State<GoToMarketTutorialPage> createState() => _GoToMarketTutorialPageState();
}

class _GoToMarketTutorialPageState extends State<GoToMarketTutorialPage> {
  int stage = 0;
  final int totalStages = 3;
  int step = 0;

  bool showStageBanner = true;
  Timer? _bannerTimer;

  // 按「開始挑戰」或「略過教學」換成遊戲頁時設為 true，
  // dispose 就不會把方向改回直向（遊戲頁需要橫向）
  bool _leavingToGame = false;

  /// 「開始挑戰 N 題」的 N：照後端 config/（admin_demo 是 3 題），打不到就是 20
  int _totalQuestions = kMarketRouteDefaultTotalQuestions;

  Future<void> _loadTotalQuestions() async {
    final config = await GoToMarketService.fetchConfig();
    if (!mounted) return;
    setState(() => _totalQuestions = marketRouteTotalQuestions(config));
  }

  @override
  void initState() {
    super.initState();
    _loadTotalQuestions();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _triggerStageBanner();
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    // 回到遊戲首頁時才設回直向。放在 dispose 裡，
    // 用畫面返回鍵、Android 系統返回鍵或手勢離開都會執行到
    if (!widget.openedFromGame && !_leavingToGame) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    }
    super.dispose();
  }

  void _backToPreviousPage() {
    AudioService.playClick();
    Navigator.of(context).maybePop();
  }

  /// 開始遊戲：從遊戲頁打開的話直接返回，並通知遊戲頁重新開始，
  /// 避免在原本的遊戲頁上面再疊一個新的遊戲頁
  void _startGame() {
    if (widget.openedFromGame) {
      Navigator.of(context).pop(true);
      return;
    }
    _leavingToGame = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => const GoToMarketGamePage()),
    );
  }

  void _triggerStageBanner() {
    setState(() {
      showStageBanner = true;
    });
    _bannerTimer?.cancel();
    _bannerTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) {
        setState(() {
          showStageBanner = false;
        });
      }
    });
  }

  String get stageTitle {
    switch (stage) {
      case 0:
        return '簡單難度教學';
      case 1:
        return '中等難度教學';
      case 2:
        return '高階難度教學';
      default:
        return '';
    }
  }

  String get stepBadgeText {
    switch (step) {
      case 0:
        return '第一步';
      case 1:
        return '第二步';
      case 2:
        return '第三步';
      case 3:
        return '第四步';
      default:
        return '';
    }
  }

  String get instructionText {
    if (stage == 0) {
      switch (step) {
        case 0:
          return '注意看！圖案出現在正中間';
        case 1:
          return '剛剛的圖案出現在哪裡？';
        case 2:
          return '請點擊剛剛圖案出現的正中間！';
      }
    } else if (stage == 1) {
      switch (step) {
        case 0:
          return '注意看！圖案會隨機出現在四個角落';
        case 1:
          return '剛剛的圖案出現在哪裡？';
        case 2:
          return '請點擊剛剛圖案出現的角落！';
      }
    } else {
      switch (step) {
        case 0:
          return '記清楚！只需要點擊「目標物」，不要點到「干擾物」喔！';
        case 1:
          return '注意看！請專注記住「目標物」的位置';
        case 2:
          return '剛剛的「目標物」出現在哪裡？';
        case 3:
          return '請點擊剛剛「目標物」的位置，不要點「干擾物」喔！';
      }
    }
    return '';
  }

  bool get canGoPrev => !(stage == 0 && step == 0);

  void _nextStep() {
    AudioService.playClick();
    if (showStageBanner) {
      _bannerTimer?.cancel();
      setState(() {
        showStageBanner = false;
      });
      return;
    }

    int maxStep = (stage == 2) ? 3 : 2;

    setState(() {
      if (step < maxStep) {
        step++;
      } else {
        if (stage < totalStages - 1) {
          stage++;
          step = 0;
          _triggerStageBanner();
        } else {
          _showCompletionDialog();
        }
      }
    });
  }

  void _prevStep() {
    AudioService.playClick();
    if (showStageBanner) {
      _bannerTimer?.cancel();
      setState(() {
        showStageBanner = false;
      });
    }

    setState(() {
      if (step > 0) {
        step--;
      } else if (stage > 0) {
        stage--;
        step = (stage == 2) ? 3 : 2;
      }
    });
  }

  void _showCompletionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFFF7F9F6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          contentPadding: const EdgeInsets.fromLTRB(28, 20, 28, 14),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(
                Icons.check_circle_outline,
                size: 54,
                color: Color(0xFF2D5A43),
              ),
              SizedBox(height: 10),
              Text(
                '全難度教學完成！',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2D5A43),
                ),
              ),
              SizedBox(height: 8),
              Text(
                '您已經學會所有的規則囉！\n接下來共有 20 道題目，準備好挑戰了嗎？',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: Color(0xFF2C3E35),
                  height: 1.3,
                ),
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actionsPadding: const EdgeInsets.only(
            bottom: 18,
            left: 18,
            right: 18,
          ),
          actions: [
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF2D5A43), width: 1.5),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () {
                AudioService.playClick();
                Navigator.of(dialogContext).pop();
                setState(() {
                  stage = 0;
                  step = 0;
                  _triggerStageBanner();
                });
              },
              child: const Text(
                '再看一次教學',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2D5A43),
                ),
              ),
            ),
            const SizedBox(width: 14),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2D5A43),
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 2,
              ),
              onPressed: () {
                AudioService.playClick();
                Navigator.of(dialogContext).pop();
                _startGame();
              },
              child: Text(
                '開始挑戰 $_totalQuestions 題',
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
  }

  Widget _buildFishImage({double width = 140, double height = 48}) {
    return Image.asset(
      'assets/images/fish.png',
      width: width,
      height: height,
      fit: BoxFit.contain,
    );
  }

  Widget _buildFishBoneImage({double width = 95, double height = 48}) {
    return Image.asset(
      'assets/images/fish_bone.png',
      width: width,
      height: height,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) {
        return CustomPaint(
          size: Size(width, height),
          painter: _FishBonePainter(),
        );
      },
    );
  }

  Widget _buildUnifiedGuideTarget({
    required bool showFish,
    double boxWidth = 125,
    double boxHeight = 58,
  }) {
    return SizedBox(
      width: boxWidth,
      height: boxHeight,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (showFish) _buildFishImage(width: 105, height: 40),
          CustomPaint(
            size: Size(boxWidth, boxHeight),
            painter: _DottedBorderPainter(
              color: const Color(0xFF4C7B5D),
              strokeWidth: 2.0,
              gap: 4.0,
              borderRadius: 12.0,
            ),
          ),
          const Icon(
            Icons.touch_app,
            size: 32,
            color: Color(0xFF1B2C22),
            shadows: [
              Shadow(
                blurRadius: 6.0,
                color: Colors.white,
                offset: Offset(0, 0),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9F6),
      body: SafeArea(
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 4.0,
              ),
              child: Column(
                children: [
                  // 1. 頂部列
                  Row(
                    children: [
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: const Icon(
                          Icons.arrow_back,
                          color: Color(0xFF2D5A43),
                          size: 24,
                        ),
                        onPressed: _backToPreviousPage,
                      ),
                      const Expanded(
                        child: Center(
                          child: Text(
                            '來去菜市場',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF2D5A43),
                              letterSpacing: 1.0,
                            ),
                          ),
                        ),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          backgroundColor: const Color(0xFFE8EFE9),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: () {
                          AudioService.playClick();
                          _startGame();
                        },
                        child: const Text(
                          '略過教學',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF2D5A43),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),

                  // 2. 進度條列
                  Row(
                    children: [
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
                          stageTitle,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF2D5A43),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        '1/20',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2D5A43),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: const LinearProgressIndicator(
                            value: 1 / 20,
                            backgroundColor: Color(0xFFDDE5DF),
                            valueColor: AlwaysStoppedAnimation(
                              Color(0xFF2D5A43),
                            ),
                            minHeight: 5,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 4),

                  // 3. 中間教學內容
                  Expanded(child: Center(child: _buildStageContent())),

                  // 4. 指示文字
                  Text(
                    instructionText,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1E2D24),
                      letterSpacing: 0.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),

                  // 5. 上一步 / 下一步按鈕
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.chevron_left, size: 18),
                        label: const Text(
                          '上一步',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF2D5A43),
                          disabledForegroundColor: const Color(0xFFA5B8AC),
                          side: BorderSide(
                            color: canGoPrev
                                ? const Color(0xFF2D5A43)
                                : const Color(0xFFD1DDD5),
                            width: 1.5,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 5,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: canGoPrev ? _prevStep : null,
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton.icon(
                        icon: const Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: Colors.white,
                        ),
                        label: const Text(
                          '下一步',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2D5A43),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 5,
                          ),
                          elevation: 2,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: _nextStep,
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                ],
              ),
            ),
            if (showStageBanner)
              GestureDetector(
                onTap: _nextStep,
                child: Container(
                  color: Colors.black.withOpacity(0.35),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 36,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2D5A43),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.25),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          stageTitle,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          '請注意看題目說明與指引',
                          style: TextStyle(
                            fontSize: 14,
                            color: Color(0xFFE0EFE6),
                            letterSpacing: 0.6,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStageContent() {
    if (stage == 2 && step == 0) {
      return _buildIdentificationCards();
    }

    const double boardWidth = 460.0;
    const double boardHeight = 140.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFF2D5A43),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Text(
            stepBadgeText,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: 0.8,
            ),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: boardWidth,
          height: boardHeight,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: boardWidth - 10,
                height: 3.0,
                decoration: BoxDecoration(
                  color: const Color(0xFF6B8775),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Container(
                width: 3.0,
                height: boardHeight - 8,
                decoration: BoxDecoration(
                  color: const Color(0xFF6B8775),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              if (stage == 0 && step == 0)
                _buildFishImage(width: 140, height: 48),
              if (stage == 0 && step == 2)
                _buildUnifiedGuideTarget(showFish: true),
              if (stage == 1 && step == 0)
                Positioned(
                  top: 6,
                  right: 20,
                  child: _buildFishImage(width: 130, height: 44),
                ),
              if (stage == 1 && step == 2)
                Positioned(
                  top: 8,
                  right: 30,
                  child: _buildUnifiedGuideTarget(showFish: true),
                ),
              if (stage == 2 && step == 1) ...[
                Positioned(
                  top: 6,
                  right: 20,
                  child: _buildFishImage(width: 130, height: 44),
                ),
                Positioned(
                  bottom: 6,
                  left: 30,
                  child: _buildFishBoneImage(width: 90, height: 44),
                ),
              ],
              if (stage == 2 && step == 3)
                Positioned(
                  top: 8,
                  right: 30,
                  child: _buildUnifiedGuideTarget(showFish: true),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildIdentificationCards() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 190,
          height: 135,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F1EC),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '目標物',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF2D5A43),
                  ),
                ),
              ),
              _buildFishImage(width: 120, height: 42),
              const Text(
                '請記住它！',
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF6E7E75),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 20),
        Container(
          width: 190,
          height: 135,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFFDEBEB),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '干擾物',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFC75454),
                  ),
                ),
              ),
              _buildFishBoneImage(width: 90, height: 44),
              const Text(
                '請忽略它！',
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF6E7E75),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DottedBorderPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double gap;
  final double borderRadius;

  _DottedBorderPainter({
    required this.color,
    this.strokeWidth = 2.6,
    this.gap = 5.0,
    this.borderRadius = 16.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final RRect rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Radius.circular(borderRadius),
    );

    final Path path = Path()..addRRect(rrect);

    for (final metric in path.computeMetrics()) {
      double distance = 0.0;
      bool draw = true;
      while (distance < metric.length) {
        final double length = draw ? 7.0 : gap;
        if (draw) {
          canvas.drawPath(
            metric.extractPath(distance, distance + length),
            paint,
          );
        }
        distance += length;
        draw = !draw;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _FishBonePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint strokePaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final Paint fillPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;

    canvas.save();
    canvas.translate(size.width * 0.1, size.height * 0.2);
    canvas.rotate(-0.32);

    final Path headPath = Path()
      ..moveTo(0, 20)
      ..lineTo(28, 0)
      ..lineTo(28, 40)
      ..close();
    canvas.drawPath(headPath, strokePaint);
    canvas.drawCircle(const Offset(18, 15), 3.0, fillPaint);

    canvas.drawLine(const Offset(28, 20), const Offset(85, 20), strokePaint);

    for (int i = 0; i < 4; i++) {
      double x = 38.0 + (i * 11.0);
      double h = 14.0 - (i * 1.5);
      canvas.drawLine(Offset(x, 20 - h), Offset(x - 3, 20 + h), strokePaint);
    }

    final Path tailPath = Path()
      ..moveTo(85, 20)
      ..lineTo(102, 7)
      ..lineTo(96, 20)
      ..lineTo(102, 33)
      ..close();
    canvas.drawPath(tailPath, strokePaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
