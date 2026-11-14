import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import '../../../theme/app_theme.dart';
import '../../../app_settings.dart';

enum RecordButtonState { idle, recording, paused, uploading }

class RecordButton extends StatefulWidget {
  /// 使用者按下「完成」、錄音正式結束時呼叫，
  /// 回傳錄好的音檔與這段錄了幾秒；15 秒門檻這類規則由外部（頁面）自行判斷。
  final void Function(XFile audioFile, int elapsedSeconds) onRoundComplete;
  /// 每次內部狀態變化時通知外部（例如頁面要知道現在是不是正在錄音中，
  /// 用來決定「跳過」「提前完成」這些按鈕要不要顯示）
  final void Function(RecordButtonState state)? onStateChanged;
  /// 錄音發生任何失敗時，把可以顯示給使用者看的訊息往外拋
  final void Function(String message)? onError;
  /// 是否為第一輪；第一輪待機時要提醒長輩「至少講 15 秒」
  final bool isFirstRound;
  /// 放在聚焦模式的黑色半透明疊層上：計時、提示文字、波形、完成鍵改成白色
  final bool onDarkOverlay;

  const RecordButton({
    super.key,
    required this.onRoundComplete,
    this.onStateChanged,
    this.onError,
    this.isFirstRound = false,
    this.onDarkOverlay = false,
  });

  @override
  State<RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<RecordButton> {
  final AudioRecorder _recorder = AudioRecorder();
  RecordButtonState _state = RecordButtonState.idle;
  int _elapsedSeconds = 0;
  Timer? _timer;
  StreamSubscription<Amplitude>? _amplitudeSub;

  static const int maxRecordSeconds = 180; // 單輪最長 3 分鐘，時間到自動送出
  static const int _barCount = 12;
  static const double _minBarHeight = 8;
  static const double _maxBarHeight = 48;
  final List<double> _barHeights = List.filled(_barCount, _minBarHeight);
  final Random _random = Random();

  // 網頁版：Chrome 等瀏覽器的 MediaRecorder 不支援預設的 AAC 編碼，
  // 改用 Opus（webm）在 web 跟大多數手機瀏覽器上都能正常錄音。
  // 手機 App：iOS／Android 原生錄音用 AAC（m4a）最穩，後端與 Whisper 都收。
  RecordConfig get _recordConfig => kIsWeb
      ? const RecordConfig(encoder: AudioEncoder.opus)
      : const RecordConfig(encoder: AudioEncoder.aacLc);

  static const String _webFileName = 'round_audio.webm';
  static const String _nativeFileName = 'round_audio.m4a';

  /// 錄音檔要存在哪裡。
  ///
  /// 網頁版的 path 只是名稱，實際錄在瀏覽器記憶體裡；
  /// 手機 App 一定要給可寫入的完整路徑，只給檔名會寫到 App 不能寫的根目錄，
  /// 錄音直接失敗（iOS 上會被誤報成「麥克風權限沒開」）。
  Future<String> _recordPath() async {
    if (kIsWeb) return _webFileName;
    final dir = await getTemporaryDirectory();
    return '${dir.path}/$_nativeFileName';
  }

  static String get _noPermissionMessage => kIsWeb
      ? '沒有取得麥克風權限，請允許瀏覽器使用麥克風'
      : '沒有取得麥克風權限，請到手機的「設定」允許憶智防線使用麥克風';

  static String get _startFailedMessage => kIsWeb
      ? '錄音無法啟動，請確認瀏覽器麥克風權限後再試一次'
      : '錄音無法啟動，請確認麥克風沒有被其他 App（例如通話）使用中，再試一次';

  void _updateState(RecordButtonState newState) {
    setState(() => _state = newState);
    widget.onStateChanged?.call(newState);
  }

  /// 外部（頁面）判斷這段錄音不合格（例如太短）時呼叫，讓按鈕回到待機狀態重錄
  void resetToIdle() {
    _timer?.cancel();
    _stopAmplitudeListening();
    setState(() {
      _state = RecordButtonState.idle;
      _elapsedSeconds = 0;
    });
    widget.onStateChanged?.call(RecordButtonState.idle);
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsedSeconds++);
      if (_elapsedSeconds >= maxRecordSeconds) {
        _completeRecording();
      }
    });
  }

  void _listenAmplitude() {
    _amplitudeSub?.cancel();
    _amplitudeSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 150))
        .listen((amp) {
      if (!mounted) return;
      final level = ((amp.current + 60) / 60).clamp(0.0, 1.0);
      setState(() {
        for (var i = 0; i < _barHeights.length; i++) {
          final jitter = 0.55 + _random.nextDouble() * 0.45;
          _barHeights[i] =
              _minBarHeight + (level * (_maxBarHeight - _minBarHeight) * jitter);
        }
      });
    });
  }

  void _stopAmplitudeListening() {
    _amplitudeSub?.cancel();
    _amplitudeSub = null;
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < _barHeights.length; i++) {
        _barHeights[i] = _minBarHeight;
      }
    });
  }

  Future<void> _startRecording() async {
    try {
      final hasPermission = await _recorder.hasPermission();
      debugPrint('[RecordButton] hasPermission: $hasPermission');
      if (!hasPermission) {
        widget.onError?.call(_noPermissionMessage);
        return;
      }
      await _recorder.start(_recordConfig, path: await _recordPath());
      final isRecording = await _recorder.isRecording();
      debugPrint('[RecordButton] start() 之後 isRecording: $isRecording');
      if (!isRecording) {
        widget.onError?.call(_startFailedMessage);
        return;
      }
      setState(() {
        _state = RecordButtonState.recording;
        _elapsedSeconds = 0;
      });
      widget.onStateChanged?.call(RecordButtonState.recording);
      _startTimer();
      _listenAmplitude();
    } catch (e) {
      debugPrint('[RecordButton] _startRecording 例外: $e');
      widget.onError?.call(_startFailedMessage);
    }
  }

  Future<void> _pauseRecording() async {
    await _recorder.pause();
    _timer?.cancel();
    _stopAmplitudeListening();
    _updateState(RecordButtonState.paused);
  }

  Future<void> _resumeRecording() async {
    await _recorder.resume();
    _updateState(RecordButtonState.recording);
    _startTimer();
    _listenAmplitude();
  }

  /// 暫停時整段作廢，不用先完成送出再後悔
  Future<void> _restartRecording() async {
    _timer?.cancel();
    _stopAmplitudeListening();
    try {
      await _recorder.stop(); // 丟棄錄好的內容，不使用回傳的路徑
    } catch (e) {
      debugPrint('[RecordButton] _restartRecording stop() 例外: $e');
    }
    if (!mounted) return;
    setState(() {
      _state = RecordButtonState.idle;
      _elapsedSeconds = 0;
    });
    widget.onStateChanged?.call(RecordButtonState.idle);
  }

  Future<void> _completeRecording() async {
    _timer?.cancel();
    _stopAmplitudeListening();
    _updateState(RecordButtonState.uploading);
    try {
      final path = await _recorder.stop();
      debugPrint('[RecordButton] _recorder.stop() 回傳: $path');
      if (path == null) {
        widget.onError?.call('錄音沒有成功產生檔案，請重新錄製');
        resetToIdle();
        return;
      }
      // Web 上 _recorder.stop() 回傳的是瀏覽器產生的 blob 網址，
      // 網址本身沒有副檔名，直接包成 XFile 會讓後端收到的檔名、
      // Content-Type 都判斷不出是音訊檔，這裡明確指定 name／mimeType。
      widget.onRoundComplete(
        kIsWeb
            ? XFile(path, name: _webFileName, mimeType: 'audio/webm')
            : XFile(path, name: _nativeFileName, mimeType: 'audio/mp4'),
        _elapsedSeconds,
      );
    } catch (e) {
      debugPrint('[RecordButton] _completeRecording 例外: $e');
      widget.onError?.call('錄音處理失敗，請重新錄製');
      resetToIdle();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _amplitudeSub?.cancel();
    _recorder.dispose();
    super.dispose();
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
        // 提示文字與「/ 03:00」用的次要文字顏色
        final onOverlay = widget.onDarkOverlay;
        final hintColor = onOverlay
            ? Colors.white
            : isDark
            ? const Color(0xFFCCCCCC)
            : (isHighContrast
                ? Colors.black
                : AppTheme.colorScheme.onSurfaceVariant);
        // 計時數字與完成鍵：疊層上用白色才看得清楚
        final accentColor = onOverlay ? Colors.white : AppTheme.primaryColor;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 計時器：已錄時間放大顯示，後面接較小的「/ 03:00」提示上限
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: _formatTime(_elapsedSeconds),
                    style: TextStyle(
                      fontSize: AppSettings.scaleFont(AppTheme.fontTimer),
                      fontWeight: FontWeight.bold,
                      color: accentColor,
                    ),
                  ),
                  TextSpan(
                    text: ' / ${_formatTime(maxRecordSeconds)}',
                    style: TextStyle(
                      fontSize: AppSettings.scaleFont(16),
                      fontWeight: FontWeight.w500,
                      color: hintColor,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            _buildWaveform(),
            const SizedBox(height: 14),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: _onMicTap,
                  child: Container(
                    width: AppTheme.sizeMicButton,
                    height: AppTheme.sizeMicButton,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _state == RecordButtonState.uploading
                          ? Colors.grey
                          : AppTheme.primaryColor,
                    ),
                    child: Icon(
                      _iconForState(),
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                ),
                if (_state == RecordButtonState.recording ||
                    _state == RecordButtonState.paused) ...[
                  const SizedBox(width: 20),
                  GestureDetector(
                    onTap: _state == RecordButtonState.uploading
                        ? null
                        : _completeRecording,
                    child: Container(
                      width: AppTheme.sizeMicButton,
                      height: AppTheme.sizeMicButton,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: accentColor,
                          width: 3,
                        ),
                      ),
                      child: Icon(
                        Icons.check,
                        color: accentColor,
                        size: 32,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            // 依目前狀態告訴長輩下一步可以做什麼
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                _hintForState(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppSettings.scaleFont(14),
                  height: 1.5,
                  fontWeight: FontWeight.w500,
                  color: hintColor,
                ),
              ),
            ),
            if (_state == RecordButtonState.paused) ...[
              const SizedBox(height: 4),
              TextButton(
                onPressed: _restartRecording,
                style: onOverlay
                    ? TextButton.styleFrom(foregroundColor: Colors.white)
                    : null,
                child: Text(
                  '重新錄製',
                  style: TextStyle(
                    fontSize: AppSettings.scaleFont(13),
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildWaveform() {
    final active = _state == RecordButtonState.recording;
    final onOverlay = widget.onDarkOverlay;
    final idleColor = onOverlay
        ? Colors.white54
        : AppTheme.colorScheme.outlineVariant;
    final activeColor = onOverlay ? Colors.white : AppTheme.primaryColor;
    return Container(
      width: 230,
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        border: Border.all(color: idleColor),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(_barCount, (i) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 4,
            height: active ? _barHeights[i] : _minBarHeight,
            decoration: BoxDecoration(
              color: active ? activeColor : idleColor,
              borderRadius: BorderRadius.circular(2),
            ),
          );
        }),
      ),
    );
  }

  void _onMicTap() {
    switch (_state) {
      case RecordButtonState.idle:
        _startRecording();
        break;
      case RecordButtonState.recording:
        _pauseRecording();
        break;
      case RecordButtonState.paused:
        _resumeRecording();
        break;
      case RecordButtonState.uploading:
        break; // 上傳中不接受任何點擊
    }
  }

  IconData _iconForState() {
    switch (_state) {
      case RecordButtonState.idle:
        return Icons.mic;
      case RecordButtonState.recording:
        return Icons.pause;
      case RecordButtonState.paused:
        return Icons.mic;
      case RecordButtonState.uploading:
        return Icons.hourglass_top;
    }
  }

  String _hintForState() {
    switch (_state) {
      case RecordButtonState.idle:
        return widget.isFirstRound
            ? '請盡量詳細描述照片裡的人、地點、發生的事（至少講 15 秒喔）。點擊開始錄音'
            : '點擊開始錄音';
      case RecordButtonState.recording:
        return '點擊暫停，或按完成送出';
      case RecordButtonState.paused:
        return '點擊繼續錄音，或按完成送出';
      case RecordButtonState.uploading:
        return '語音辨識與思考中…';
    }
  }

  String _formatTime(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}