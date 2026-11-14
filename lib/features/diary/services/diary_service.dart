import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import '../models/diary_model.dart';
import '../models/diary_reply_model.dart';
import '../../../core/network/api_response.dart';
import '../../../core/network/auth_headers.dart';
import '../../../core/network/error_message.dart';
import '../../../core/constants/api_constants.dart';
import '../../rewards/models/rewards_models.dart';

/// 決定上傳日記照片的 Content-Type。
///
/// 後端（日記上傳限制）靠「副檔名或 Content-Type 是 image/*」判斷是不是圖片。
/// 手機 App 的檔名一定有副檔名沒問題；Flutter Web 選到的檔案檔名常常沒有副檔名，
/// 如果又沒帶 Content-Type 會被判成 INVALID_IMAGE，所以這裡一律明確帶上：
/// 1. 選圖器給的 mimeType（要是 image/*）
/// 2. 否則依副檔名對應
/// 3. 都沒有就當 JPEG（相機與相簿拍出來的照片最常見）
MediaType photoMediaType(XFile photo) {
  final mime = photo.mimeType?.trim().toLowerCase();
  if (mime != null && mime.startsWith('image/') && mime.length > 'image/'.length) {
    return MediaType.parse(mime);
  }
  final name = photo.name.toLowerCase();
  final dot = name.lastIndexOf('.');
  final ext = dot == -1 ? '' : name.substring(dot + 1);
  switch (ext) {
    case 'png':
      return MediaType('image', 'png');
    case 'webp':
      return MediaType('image', 'webp');
    case 'heic':
      return MediaType('image', 'heic');
    case 'heif':
      return MediaType('image', 'heif');
    default:
      return MediaType('image', 'jpeg');
  }
}

/// 上傳照片失敗時要顯示的文字。
///
/// 後端對上傳有大小與類型限制（IMAGE_TOO_LARGE、INVALID_IMAGE…），
/// `message` 已經是給使用者看的中文（例如「這張照片太大了…換一張試試看吧」），
/// 有錯誤碼的就直接顯示；其他（連不上、500…）維持原本的「照片儲存失敗」。
String photoUploadErrorMessage(Object error) {
  if (error is ApiException && error.code != null && error.statusCode < 500) {
    return error.message;
  }
  if (error is ApiException) return '照片儲存失敗，請再試一次';
  return friendlyErrorMessage(error, fallback: '照片儲存失敗，請再試一次');
}

/// D-1 回應的外層包裝
class DiaryMonthResult {
  final String month;
  final bool hasTodayDiary;
  final List<DiarySummaryModel> diaries;

  DiaryMonthResult({
    required this.month,
    required this.hasTodayDiary,
    required this.diaries,
  });
}

/// D-2 回應的外層包裝：昨天、去年的今天各是一個陣列，沒有日記時是空陣列
/// （原本規格是單篇，但同一天可能寫不只一篇，需求表改成陣列）
class DiaryReviewResult {
  final List<DiaryReviewItem> yesterday;
  final List<DiaryReviewItem> lastYear;

  DiaryReviewResult({required this.yesterday, required this.lastYear});
}

/// S-1 回應中完成頁會用到的欄位：分享連結與邀請文字
class ShareToWallResult {
  final int postId;
  final String? shareUrl; // 親友分享頁網址：/share/<share_token>/
  final String inviteText;

  /// 點數與成就：分享日記解鎖的成就（data.rewards，只有第一次會有）
  final RewardsResult rewards;

  ShareToWallResult({
    required this.postId,
    required this.shareUrl,
    required this.inviteText,
    this.rewards = RewardsResult.empty,
  });
}

/// 聲影日記資料服務。
/// D-1～D-7 都已改接真實後端（D-6 跳過本輪是 11/14 後端新增的 API）。
class DiaryService {
  static const String _baseUrl = '${ApiConstants.serverUrl}/api/diary/';

  /// S-1（分享到動態牆）後端還沒完成前先回傳假資料，
  /// 詩雅的 S-1 上線後把這裡改成 false 就會改打真實 API。
  static const bool _useMockShareToWall = false;

  /// D-2（動態回顧）後端還沒完成前先回傳假資料，
  /// 詩雅的 D-2 上線後把這裡改成 false 就會改打真實 API。
  static const bool _useMockReview = false;

  /// 統一解析後端 `{"data": {...}}` 成功格式／`{"error": {...}}`
  /// 或 `{"detail": "..."}`（例如 token 過期）失敗格式。
  ///
  /// 失敗時丟 [ApiException]，保留 HTTP 狀態碼與 `error.code`
  /// （例如 409 `ROUND_ALREADY_ANSWERED`），呼叫端才能依 code 分流；
  /// 畫面上顯示訊息一樣用 `friendlyErrorMessage`，行為跟以前相同。
  Map<String, dynamic> _unwrap(http.Response response) {
    final status = response.statusCode;
    Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(statusCode: status, message: '伺服器回應格式錯誤（$status）');
    }
    if (status >= 200 && status < 300 && json.containsKey('data')) {
      return json['data'] as Map<String, dynamic>;
    }
    final error = json['error'];
    if (error is Map && error['message'] != null) {
      throw ApiException(
        statusCode: status,
        code: error['code'] as String?,
        message: error['message'] as String,
      );
    }
    final detail = json['detail'];
    if (detail is String) {
      throw ApiException(statusCode: status, message: detail);
    }
    throw ApiException(statusCode: status, message: '發生錯誤（$status）');
  }

  /// D-3／D-7 回傳的內容不一定包含 `date`／聊天室進度相關欄位
  /// （不同 API 階段後端本來就不負責回傳這些），這裡補上預設值，
  /// 避免 DiaryModel.fromJson 因為欄位是 required 而噴錯。
  Map<String, dynamic> _fillMissingDiaryFields(Map<String, dynamic> data) {
    final merged = <String, dynamic>{
      'date': '',
      'reply_count': 0,
      'is_finalizable': false,
      'is_done': false,
      'first_question': '',
      'replies': [],
      'pending_question': null,
      'ai_response': '',
      'post_text': '',
      'hashtags': [],
      'category': '',
      'is_shared': false,
      'share_url': null,
      'invite_text': '',
      'title': '',
      ...data,
    };

    // 有些後端回應（例如建立日記時）只有 created_at，沒有 date，
    // 這裡用 created_at 推算出 YYYY-MM-DD 格式的 date 補上，
    // 避免 DiaryModel.fromJson 的 `json['date'] as String` 因為 null 而炸掉。
    final dateValue = merged['date'];
    final needsDateFallback =
        dateValue == null || (dateValue is String && dateValue.isEmpty);
    if (needsDateFallback && merged['created_at'] != null) {
      final createdAt = DateTime.tryParse(merged['created_at'] as String);
      if (createdAt != null) {
        merged['date'] =
            '${createdAt.year}-${createdAt.month.toString().padLeft(2, '0')}-${createdAt.day.toString().padLeft(2, '0')}';
      }
    }

    return merged;
  }

  /// D-1：月曆列表
  Future<DiaryMonthResult> getDiaryList({String? month}) async {
    final uri = Uri.parse(_baseUrl).replace(
      queryParameters: month != null ? {'month': month} : null,
    );
    final response = await http.get(uri, headers: await authHeaders(json: false));
    final data = _unwrap(response);
    return DiaryMonthResult(
      month: data['month'] as String,
      hasTodayDiary: data['has_today_diary'] as bool? ?? false,
      diaries: (data['diaries'] as List<dynamic>? ?? [])
          .map((e) => DiarySummaryModel.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// D-2：動態回顧（GET /api/diary/review/）
  Future<DiaryReviewResult> getDiaryReview() async {
    if (_useMockReview) {
      await Future.delayed(const Duration(milliseconds: 500));
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final yesterdayStr =
          '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';
      return DiaryReviewResult(
        yesterday: [
          DiaryReviewItem.fromJson({
            'diary_id': 30,
            'date': yesterdayStr,
            'title': '花燈圈圈樂 ✨',
            'photo_url': 'https://picsum.photos/seed/30/800/450',
            'post_text': '這個週末跟朋友去逛花燈，燈籠一排一排掛在河邊，'
                '我們邊走邊聊，還買了一支糖葫蘆，玩得很開心。'
                '回家的路上大家說明年還要再一起來。',
            'audio_url':
                'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3',
            'is_shared': true,
            'post_id': 8,
            'created_at': '${yesterdayStr}T08:10:00+08:00',
          }),
        ],
        // 去年的今天先放空陣列，用來確認空狀態畫面
        lastYear: [],
      );
    }
    final uri = Uri.parse('${_baseUrl}review/');
    final response = await http.get(uri, headers: await authHeaders(json: false));
    final data = _unwrap(response);
    List<DiaryReviewItem> parseList(dynamic raw) => (raw as List<dynamic>? ?? [])
        .map((e) => DiaryReviewItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return DiaryReviewResult(
      yesterday: parseList(data['yesterday']),
      lastYear: parseList(data['last_year']),
    );
  }

  /// D-3：上傳照片、建立日記
  Future<DiaryModel> createDiary(XFile photo) async {
    final request = http.MultipartRequest('POST', Uri.parse(_baseUrl));
    request.headers.addAll(await authHeaders(json: false));
    final bytes = await photo.readAsBytes();
    request.files.add(
      http.MultipartFile.fromBytes(
        'photo',
        bytes,
        filename: photo.name,
        contentType: photoMediaType(photo),
      ),
    );
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    final data = _unwrap(response);
    return DiaryModel.fromJson(_fillMissingDiaryFields(data));
  }

  /// D-4：單篇日記詳情（`GET diary/{id}/`）。
  /// 目前用在送出錄音遇到 409 `ROUND_ALREADY_ANSWERED`（網路重試造成，
  /// 其實上一次已經成功）時，重新取得這一輪的結果。
  Future<DiaryModel> getDiaryDetail(int diaryId) async {
    final uri = Uri.parse('$_baseUrl$diaryId/');
    final response = await http.get(uri, headers: await authHeaders(json: false));
    final data = _unwrap(response);
    return DiaryModel.fromJson(_fillMissingDiaryFields(data));
  }

  /// D-5：送出一輪錄音
  Future<ReplySubmitResult> submitReply(
    int diaryId, {
    required XFile audio,
    required int roundIndex,
    bool isForced = false,
  }) async {
    final uri = Uri.parse('$_baseUrl$diaryId/replies/');
    final request = http.MultipartRequest('POST', uri);
    request.headers.addAll(await authHeaders(json: false));
    request.fields['round_index'] = roundIndex.toString();
    if (isForced) request.fields['force'] = '1';
    final bytes = await audio.readAsBytes();
    request.files.add(
      http.MultipartFile.fromBytes(
        'audio',
        bytes,
        filename: audio.name,
        // 網頁版錄的是 webm，手機 App 錄的是 m4a（audio/mp4），跟著錄音檔走
        contentType: MediaType.parse(audio.mimeType ?? 'audio/webm'),
      ),
    );
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    return _parseReplyResponse(response, diaryId, roundIndex);
  }

  /// D-5／D-6 回應的共用解析。
  ///
  /// 409 `ROUND_ALREADY_ANSWERED`：這一輪後端已經收到並處理過（常見於網路重試，
  /// 錄音與跳過都一樣），不是失敗，改抓日記詳情把這一輪的結果組回來，
  /// 使用者不會看到錯誤。
  Future<ReplySubmitResult> _parseReplyResponse(
    http.Response response,
    int diaryId,
    int roundIndex,
  ) async {
    try {
      return ReplySubmitResult.fromJson(_unwrap(response));
    } on ApiException catch (e) {
      if (e.code == 'ROUND_ALREADY_ANSWERED') {
        return _resultOfAnsweredRound(diaryId, roundIndex, e);
      }
      rethrow;
    }
  }

  /// 一篇日記最多問答 4 輪，跟後端 `MAX_REPLY_ROUNDS` 一致。
  static const int maxReplyRounds = 4;

  /// 用 D-4 詳情還原「已經回答過的那一輪」的 D-5 回應。
  /// 詳情的 `is_done` 代表日記已經 finalize，跟 D-5 的「4 輪都答完」意思不同，
  /// 所以這裡改用回覆數判斷。找不到那一輪（不應該發生）就把原本的 409 丟出去。
  Future<ReplySubmitResult> _resultOfAnsweredRound(
    int diaryId,
    int roundIndex,
    ApiException original,
  ) async {
    final diary = await getDiaryDetail(diaryId);
    final matched = diary.replies.where((r) => r.roundIndex == roundIndex);
    if (matched.isEmpty) throw original;
    final reply = matched.first;
    final isDone = diary.isDone || diary.replyCount >= maxReplyRounds;
    return ReplySubmitResult(
      roundIndex: roundIndex,
      transcript: reply.transcript,
      audioUrl: reply.audioUrl.isEmpty ? null : reply.audioUrl,
      aiReply: isDone ? null : diary.pendingQuestion,
      replyCount: diary.replyCount,
      isFinalizable: diary.isFinalizable,
      isDone: isDone,
    );
  }

  /// D-6：跳過本輪（`POST diary/{id}/replies/skip/`，body：`{"round_index": n}`）。
  ///
  /// 回應形狀與 D-5 相同，只是沒有 `transcript`、`audio_url`；下一題是後端的
  /// 固定句型（不呼叫 AI），第 4 輪 `ai_reply` 為 null、`is_done` 為 true。
  /// 可能的錯誤（都是 [ApiException]，`message` 已是中文）：
  /// - 400 `SKIP_NOT_ALLOWED`：日記完全沒有錄過內容卻要跳過最後一輪
  /// - 400 `INVALID_ROUND_INDEX`、400 `DIARY_ALREADY_FINALIZED`、404 `DIARY_NOT_FOUND`
  /// - 409 `ROUND_ALREADY_ANSWERED`：這一輪已經處理過，會自動還原（見 [_parseReplyResponse]）
  Future<ReplySubmitResult> skipReply(
    int diaryId, {
    required int roundIndex,
  }) async {
    final uri = Uri.parse('$_baseUrl$diaryId/replies/skip/');
    final response = await http.post(
      uri,
      headers: await authHeaders(),
      body: jsonEncode({'round_index': roundIndex}),
    );
    return _parseReplyResponse(response, diaryId, roundIndex);
  }

  /// D-7：生成日記
  Future<DiaryModel> finalizeDiary(int diaryId) async {
    final uri = Uri.parse('$_baseUrl$diaryId/finalize/');
    final response = await http.post(uri, headers: await authHeaders(json: false));
    final data = _unwrap(response);
    return DiaryModel.fromJson(_fillMissingDiaryFields(data));
  }

  /// S-1：分享日記到動態牆。
  /// 後端新建立回 201、已經分享過回 200（同一則貼文，不會重複建立），
  /// 兩種都代表「已分享」，所以這裡不用區分。
  /// 後端回傳的是完整貼文物件，完成頁只需要 post_id、share_url、invite_text，
  /// 所以只取這三個欄位，不解析整個貼文（PostModel 由動態牆組維護）。
  Future<ShareToWallResult> shareToWall(int diaryId) async {
    if (_useMockShareToWall) {
      await Future.delayed(const Duration(milliseconds: 800));
      return ShareToWallResult(
        postId: 8,
        shareUrl: 'http://localhost:8000/share/mock-token/',
        inviteText: '我今天寫了一篇日記，點開看看，留句話給我吧！',
      );
    }
    final uri = Uri.parse('$_baseUrl$diaryId/share/');
    final response = await http.post(uri, headers: await authHeaders(json: false));
    final data = _unwrap(response);
    return ShareToWallResult(
      postId: data['post_id'] as int,
      shareUrl: data['share_url'] as String?,
      inviteText: data['invite_text'] as String? ?? '',
      rewards: RewardsResult.fromData(data),
    );
  }
}