import 'dart:async';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:image_picker/image_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import '../models/diary_model.dart';
import '../models/diary_reply_model.dart';
import '../services/diary_service.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/record_button.dart';
import '../../../theme/app_theme.dart';
import '../../../core/constants/route_constants.dart';
import '../../../core/network/error_message.dart';
import '../../../app_settings.dart';
import '../../home/widgets/top_bar.dart';

class _ChatMessage {
  final bool isUser;
  final String text;
  final String? audioUrl;

  const _ChatMessage.ai(this.text) : isUser = false, audioUrl = null;
  const _ChatMessage.user(this.text, {this.audioUrl}) : isUser = true;
}

class DiaryChatPage extends StatefulWidget {
  final DiaryModel initialDiary;

  const DiaryChatPage({super.key, required this.initialDiary});

  @override
  State<DiaryChatPage> createState() => _DiaryChatPageState();
}

class _DiaryChatPageState extends State<DiaryChatPage> {
  final DiaryService _diaryService = DiaryService();
  final AudioPlayer _replyPlayer = AudioPlayer();
  // 正在播放第幾則訊息的錄音，null 代表沒有在播放
  int? _playingIndex;
  StreamSubscription<void>? _playerCompleteSub;
  final GlobalKey<State<RecordButton>> _recordButtonKey =
      GlobalKey<State<RecordButton>>();
  final ScrollController _scrollController = ScrollController();

  static const int _minFirstReplySeconds = 15;
  static const int _maxShortAttempts = 3;
  static const int _targetReplies = 4;
  static const int _minRepliesToFinalize = 2;

  bool _isSubmitting = false;
  bool _isTyping = false;
  bool _isDone = false;
  RecordButtonState _recordState = RecordButtonState.idle;

  late String? _photoUrl;
  final List<_ChatMessage> _messages = [];
  int _roundIndex = 1;
  int _replyCount = 0;
  int _firstRoundShortAttempts = 0;
  bool _isFinalizable = false;

  /// 使用者往上滑對話氣泡時，照片縮成標題旁的小縮圖，讓對話區變大
  bool _photoCollapsed = false;

  /// 對話區上一次的高度：照片縮放、下方按鈕出現消失時對話區高度會變，
  /// 用來把捲動位置補回去
  double? _lastChatHeight;

  /// iPhone 放手後從邊界彈回來的那段捲動不算使用者捲的，等這次捲動結束再恢復
  bool _ignoringBounce = false;

  /// 聚焦模式的黑色 50% 疊層＋背景模糊
  static const Color _focusOverlayColor = Color(0x80000000);
  static const double _focusBlurSigma = 8;
  static const Duration _focusAnimation = Duration(milliseconds: 200);

  int get _diaryId => widget.initialDiary.diaryId;

  bool get _hasPhoto => _photoUrl != null && _photoUrl!.isNotEmpty;

  /// 錄音中（含暫停）進入聚焦模式：畫面蓋上半透明黑色疊層，
  /// 照片和目前的 AI 問題放在正中央；按完成送出或重錄回待機就恢復
  bool get _isFocusMode =>
      _recordState == RecordButtonState.recording ||
      _recordState == RecordButtonState.paused;

  /// 目前正在回答的 AI 問題（最後一則 AI 訊息）
  String get _currentQuestion {
    for (final message in _messages.reversed) {
      if (!message.isUser) return message.text;
    }
    return '';
  }

  void _setPhotoCollapsed(bool collapsed) {
    if (_photoCollapsed == collapsed || !_hasPhoto) return;
    setState(() => _photoCollapsed = collapsed);
  }

  /// 往回看前面的對話（往上捲）→ 照片縮小，對話區變大；
  /// 捲回最底部（最新的問題）→ 照片展開；點縮圖也能展開。
  ///
  /// 只看使用者自己的捲動：手指拖曳、放手後的慣性、網頁版的滑鼠滾輪／觸控板。
  /// 新訊息出現時程式自動捲到底不算，照片維持使用者原本的大小
  bool _onChatScroll(ScrollNotification notification) {
    if (notification is ScrollEndNotification) {
      _ignoringBounce = false;
      return false;
    }
    if (_isFocusMode) return false;
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails == null &&
        notification.metrics.outOfRange) {
      // 放手後的慣性往下衝過最底部 → 算是回到最新，照片展開
      final metrics = notification.metrics;
      if ((notification.scrollDelta ?? 0) > 0 &&
          metrics.pixels >= metrics.maxScrollExtent &&
          !_ignoringBounce) {
        _setPhotoCollapsed(false);
      }
      // 超出邊界之後是回彈，到停下來之前都不處理
      _ignoringBounce = true;
    }
    if (_ignoringBounce) return false;
    if (notification is ScrollUpdateNotification &&
        _isUserScroll(notification)) {
      final delta = notification.scrollDelta ?? 0;
      if (delta < 0) {
        _setPhotoCollapsed(true);
      } else if (delta > 0 && notification.metrics.extentAfter < 1) {
        _setPhotoCollapsed(false);
      }
    } else if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      // 對話還很短、列表不能捲時，Android 只會送 overscroll：
      // 往下拉（想看前面）縮小，往上推（回到最新）展開
      if (notification.overscroll < 0) {
        _setPhotoCollapsed(true);
      } else if (notification.overscroll > 0) {
        _setPhotoCollapsed(false);
      }
    }
    return false;
  }

  /// 對話區變高或變矮時（照片縮放、下方按鈕出現消失），維持「離最底部的距離」不變，
  /// 跟一般聊天 App 一樣以最新的訊息為準：
  /// - 往上看舊訊息 → 照片縮小、對話區變高，畫面上的氣泡不會跳，也不會因為
  ///   突然「到底了」又把照片展開（一縮一放）
  /// - 在最底部時照片展開 → 對話區變矮，最新的問題仍然留在畫面最下面
  /// 在版面配置當下用 correctBy 修正，不會打斷手指正在拖曳的捲動
  void _keepDistanceFromBottom(double height) {
    final last = _lastChatHeight;
    _lastChatHeight = height;
    if (last == null || last == height || !_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    // 回彈中（超出邊界）不補，讓它自己彈回去
    if (!position.hasPixels || position.outOfRange) return;
    final grow = height - last;
    final target = (position.pixels - grow).clamp(0.0, double.infinity);
    if (target != position.pixels) position.correctBy(target - position.pixels);
  }

  /// 這次捲動是不是使用者自己捲的：
  /// 拖曳時有 dragDetails；滑鼠滾輪和放手後的慣性沒有 dragDetails，
  /// 但捲動方向（userScrollDirection）不是 idle。程式的 animateTo 不會改方向
  bool _isUserScroll(ScrollUpdateNotification notification) {
    if (notification.dragDetails != null) return true;
    if (!_scrollController.hasClients) return false;
    return _scrollController.position.userScrollDirection !=
        ScrollDirection.idle;
  }

  @override
  void initState() {
    super.initState();
    // D-4（單篇日記詳情）後端還沒提供，這裡不再另外呼叫 API 讀歷史對話，
    // 直接用上一頁建立日記時（D-3）拿到的資料組出聊天室的起始畫面。
    _photoUrl = widget.initialDiary.photoUrl;
    _messages.add(_ChatMessage.ai(widget.initialDiary.firstQuestion));

    // 錄音自己播完時，圖示要從停止變回播放
    _playerCompleteSub = _replyPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingIndex = null);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _replyPlayer.dispose();
    _playerCompleteSub?.cancel();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  void _resetRecordButton() {
    (_recordButtonKey.currentState as dynamic)?.resetToIdle();
  }

  Future<void> _onRoundComplete(XFile audioFile, int elapsedSeconds) async {
    debugPrint(
      '[DiaryChatPage] onRoundComplete: roundIndex=$_roundIndex, elapsedSeconds=$elapsedSeconds',
    );
    // 只有第一輪才檢查最低時長，第二輪之後不管多短都直接送出
    if (_roundIndex == 1 && elapsedSeconds < _minFirstReplySeconds) {
      _firstRoundShortAttempts++;
      if (_firstRoundShortAttempts < _maxShortAttempts) {
        setState(() {
          _messages.add(
            _ChatMessage.ai(
              '再多說一點好嗎？可以講講照片裡有誰、在哪裡、發生了什麼事～（剛剛錄了 $elapsedSeconds 秒）',
            ),
          );
        });
        _scrollToBottom();
        _resetRecordButton();
        return;
      }
    }

    setState(() => _isSubmitting = true);
    try {
      final result = await _diaryService.submitReply(
        _diaryId,
        audio: audioFile,
        roundIndex: _roundIndex,
        isForced: _firstRoundShortAttempts >= _maxShortAttempts,
      );
      // 後端沒聽到聲音時回傳的是空字串而不是 null，
      // 兩種情況都要顯示提示，避免出現只有播放鍵的空白氣泡
      final transcript = result.transcript?.trim() ?? '';
      await _handleReplyResult(
        userText: transcript.isEmpty ? '（沒有聽清楚）' : transcript,
        audioUrl: result.audioUrl,
        result: result,
      );
    } catch (e) {
      debugPrint('[DiaryChatPage] 送出錄音例外: $e');
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(friendlyErrorMessage(e, fallback: '送出失敗，請再試一次')),
        ),
      );
      _resetRecordButton();
    }
  }

  Future<void> _onSkipTap() async {
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);
    try {
      final result = await _diaryService.skipReply(
        _diaryId,
        roundIndex: _roundIndex,
      );
      await _handleReplyResult(
        userText: '（已跳過本題）',
        audioUrl: null,
        result: result,
      );
    } catch (e) {
      debugPrint('[DiaryChatPage] 跳過本題例外: $e');
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(friendlyErrorMessage(e, fallback: '跳過失敗，請再試一次')),
        ),
      );
    }
  }

  Future<void> _handleReplyResult({
    required String userText,
    String? audioUrl,
    required ReplySubmitResult result,
  }) async {
    if (!mounted) return;
    setState(() {
      _messages.add(_ChatMessage.user(userText, audioUrl: audioUrl));
      _replyCount = result.replyCount;
      _isFinalizable = result.isFinalizable;
      _isSubmitting = false;
      _firstRoundShortAttempts = 0;
    });
    _scrollToBottom();

    if (result.isDone || result.aiReply == null) {
      setState(() => _isDone = true);
      _goToLoadingPage();
      return;
    }

    // 模擬 AI「思考中」的短暫停頓，跟比賽版一致
    setState(() => _isTyping = true);
    _scrollToBottom();
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    setState(() {
      _isTyping = false;
      _messages.add(_ChatMessage.ai(result.aiReply!));
      _roundIndex += 1;
    });
    _scrollToBottom();
    _resetRecordButton();
  }

  Future<void> _onFinalizeTap() async {
    if (_isSubmitting) return;
    _goToLoadingPage();
  }

  void _goToLoadingPage() {
    Navigator.pushReplacementNamed(
      context,
      AppRoutes.voiceDiaryLoading,
      arguments: _diaryId,
    );
  }

  /// 按播放鍵：正在播這一則就停止；播別則或沒在播就從頭播這一則
  Future<void> _togglePlayAudio(int index, String url) async {
    await _replyPlayer.stop();
    if (_playingIndex == index) {
      if (mounted) setState(() => _playingIndex = null);
      return;
    }
    if (mounted) setState(() => _playingIndex = index);
    await _replyPlayer.play(UrlSource(url));
  }

  /// 開始錄音前先停掉播放，避免播放的聲音被錄進去
  Future<void> _stopAudio() async {
    if (_playingIndex == null) return;
    await _replyPlayer.stop();
    if (mounted) setState(() => _playingIndex = null);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        AppSettings.fontSizeLevel,
        AppSettings.isDarkMode,
        AppSettings.isHighContrast,
      ]),
      builder: (context, _) {
        final isDark = AppSettings.isDarkMode.value;
        final isHighContrast = AppSettings.isHighContrast.value;

        final bgColor = isDark
            ? const Color(0xFF121212)
            : AppTheme.backgroundColor;
        final titleColor = isDark
            ? Colors.white
            : (isHighContrast ? Colors.black : const Color(0xFF1E1E1E));
        final subtitleColor = isDark
            ? const Color(0xFFCCCCCC)
            : AppTheme.colorScheme.onSurfaceVariant;

        final canSkip =
            _replyCount >= 2 &&
            _replyCount < _targetReplies &&
            !_isSubmitting &&
            !_isTyping &&
            _recordState == RecordButtonState.idle;
        final canFinalizeEarly =
            _replyCount >= _minRepliesToFinalize &&
            !_isSubmitting &&
            !_isTyping &&
            _recordState == RecordButtonState.idle;

        return Scaffold(
          backgroundColor: bgColor,
          // 聚焦模式時標題列也一起蓋上模糊黑色疊層，整個畫面只剩照片、問題和錄音鈕
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(kToolbarHeight),
            child: Stack(
              children: [
                const TopBar(title: '聲影日記', showBackButton: true),
                Positioned.fill(
                  child: _buildFocusLayer(
                    key: const ValueKey('diary-focus-overlay-top'),
                  ),
                ),
              ],
            ),
          ),
          // 底部不用 SafeArea：錄音區自己補上手機底部的安全距離，
          // 聚焦模式的黑色疊層才能一路蓋到螢幕最下面
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                            child: _buildHeader(titleColor, subtitleColor),
                          ),
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                _keepDistanceFromBottom(constraints.maxHeight);
                                return NotificationListener<ScrollNotification>(
                                  onNotification: _onChatScroll,
                                  child: ListView.builder(
                                    controller: _scrollController,
                                    // 對話還很短時也要能拖，才收得到「往上滑」
                                    physics:
                                        const AlwaysScrollableScrollPhysics(),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    itemCount:
                                        _messages.length + (_isTyping ? 1 : 0),
                                    itemBuilder: (context, index) {
                                      if (_isTyping &&
                                          index == _messages.length) {
                                        return const ChatBubble(
                                          isUser: false,
                                          text: '',
                                          isTyping: true,
                                        );
                                      }
                                      final message = _messages[index];
                                      return ChatBubble(
                                        isUser: message.isUser,
                                        text: message.text,
                                        isPlaying: _playingIndex == index,
                                        onPlayTap: message.audioUrl == null
                                            ? null
                                            : () => _togglePlayAudio(
                                                index,
                                                message.audioUrl!,
                                              ),
                                      );
                                    },
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                      // 聚焦模式疊層：模糊＋黑色蓋住對話區，照片和問題置中
                      Positioned.fill(
                        child: _buildFocusLayer(
                          key: const ValueKey('diary-focus-overlay'),
                          // 不在聚焦時不建內容，避免問題文字重複出現
                          child: _isFocusMode ? _buildFocusContent() : null,
                        ),
                      ),
                    ],
                  ),
                ),
                // 錄音區：聚焦模式時底色也變成同樣的黑色疊層（整個寬度、蓋到螢幕底），
                // 看起來整個畫面一起變暗，錄音按鈕維持同一個元件（錄音不中斷）
                AnimatedContainer(
                  duration: _focusAnimation,
                  width: double.infinity,
                  color: _isFocusMode ? _focusOverlayColor : Colors.transparent,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      20,
                      16,
                      20,
                      16 + MediaQuery.paddingOf(context).bottom,
                    ),
                    child: Column(
                      children: [
                        RecordButton(
                          key: _recordButtonKey,
                          isFirstRound: _roundIndex == 1,
                          onDarkOverlay: _isFocusMode,
                          onRoundComplete: _onRoundComplete,
                          onStateChanged: (s) {
                            if (s == RecordButtonState.recording) _stopAudio();
                            setState(() => _recordState = s);
                            // 錄音狀態一變，下方的提示文字、「這題跳過」、
                            // 「生成日記」按鈕可能出現或消失，對話區的高度會跟著變，
                            // 這時再捲一次到底，避免最新的 AI 問題被錄音區擋住
                            _scrollToBottom();
                          },
                          onError: (msg) {
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text(msg)));
                          },
                        ),
                        const SizedBox(height: 8),
                        if (canSkip)
                          OutlinedButton(
                            onPressed: _onSkipTap,
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(
                                color: isDark
                                    ? const Color(0xFF4A4A4A)
                                    : AppTheme.colorScheme.outlineVariant,
                                width: 1.5,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 6,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppTheme.radiusPill,
                                ),
                              ),
                            ),
                            child: Text(
                              '這題跳過',
                              style: TextStyle(
                                color: subtitleColor,
                                fontSize: AppSettings.scaleFont(13),
                              ),
                            ),
                          ),
                        if (canFinalizeEarly) ...[
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: ElevatedButton(
                              onPressed: _onFinalizeTap,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primaryColor,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    AppTheme.radiusPill,
                                  ),
                                ),
                              ),
                              child: Text(
                                '生成日記（已錄 $_replyCount 段，可繼續或直接生成）',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: AppSettings.scaleFont(14),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 標題區：一般時是標題＋說明＋照片；往上滑對話後縮成「小縮圖＋標題」一行，
  /// 點縮圖可以放回原本大小
  Widget _buildHeader(Color titleColor, Color subtitleColor) {
    final collapsed = _photoCollapsed && _hasPhoto;
    final title = Text(
      '跟我聊聊這張照片吧',
      textAlign: collapsed ? TextAlign.start : TextAlign.center,
      style: TextStyle(
        fontSize: AppSettings.scaleFont(AppTheme.fontTitle),
        fontWeight: FontWeight.bold,
        color: titleColor,
      ),
    );

    return AnimatedSize(
      duration: _focusAnimation,
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: collapsed
          ? Row(
              key: const ValueKey('header-collapsed'),
              children: [
                Semantics(
                  button: true,
                  label: '放大照片',
                  excludeSemantics: true,
                  child: GestureDetector(
                    // 照片還沒載入或載入失敗時，整塊 56x56 一樣可以點
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _setPhotoCollapsed(false),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(
                        _photoUrl!,
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Container(
                          width: 56,
                          height: 56,
                          color: subtitleColor.withValues(alpha: 0.15),
                          child: Icon(
                            Icons.image_outlined,
                            color: subtitleColor,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: title),
              ],
            )
          : Column(
              key: const ValueKey('header-expanded'),
              children: [
                title,
                const SizedBox(height: 4),
                Text(
                  'AI 會陪你聊 4 段小對話，聊完會自動生成今天的日記',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: AppSettings.scaleFont(AppTheme.fontBody),
                    color: subtitleColor,
                  ),
                ),
                const SizedBox(height: 14),
                if (_hasPhoto)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppTheme.radiusCard),
                    child: Image.network(
                      _photoUrl!,
                      height: 140,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      // 簽名網址過期或載入失敗時不要整塊破圖
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox(height: 140),
                    ),
                  ),
              ],
            ),
    );
  }

  /// 聚焦模式的疊層：背景模糊＋黑色 50%，淡入淡出。
  /// 聚焦時會擋住底下的點擊（標題列的返回鍵、對話氣泡），只剩錄音鈕能按
  Widget _buildFocusLayer({required Key key, Widget? child}) {
    return IgnorePointer(
      ignoring: !_isFocusMode,
      child: ExcludeSemantics(
        excluding: !_isFocusMode,
        child: AnimatedOpacity(
          key: key,
          opacity: _isFocusMode ? 1 : 0,
          duration: _focusAnimation,
          child: _isFocusMode
              ? ClipRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: _focusBlurSigma,
                      sigmaY: _focusBlurSigma,
                    ),
                    child: ColoredBox(
                      color: _focusOverlayColor,
                      child: child ?? const SizedBox.expand(),
                    ),
                  ),
                )
              : const SizedBox.expand(),
        ),
      ),
    );
  }

  /// 聚焦模式疊層上的內容：照片（完整顯示、不裁切）和目前的 AI 問題置中。
  /// 照片最高佔可用高度的一半多一點，橫向或小螢幕時自動縮小
  Widget _buildFocusContent() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final question = _currentQuestion;
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_hasPhoto) ...[
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth * 0.85,
                      maxHeight: constraints.maxHeight * 0.55,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.network(
                        _photoUrl!,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) =>
                            const SizedBox.shrink(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (question.isNotEmpty)
                  ChatBubble(isUser: false, text: question),
              ],
            ),
          ),
        );
      },
    );
  }
}
