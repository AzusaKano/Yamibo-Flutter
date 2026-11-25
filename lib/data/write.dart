import 'dart:convert';

import 'api.dart';
import 'http.dart';
import 'parser.dart';

/// 站内写操作。**只做收藏与书签**（小说 + 漫画各一套），其余动作不做原生实现
/// （评分 / 章评 / 打赏 / 关注作者都走网页版入口，见规划文档 §0、§4.5）。
///
/// 站点事实（2026-10-25 授权实测）：
///
/// | 动作 | 接口 | 参数 | type |
/// |---|---|---|---|
/// | 收藏 | `POST /fav/work` | `{type, id=作品id}` | 小说 1 / 漫画 3 |
/// | 书签 | `POST /fav/mark` | `{type, workId, chptId[, page]}` | 小说 2 / 漫画 4 |
///
/// 三条必须记住的坑：
///
/// 1. **`type` 不是「作品类型」，是「记录种类」的四值编号**（收藏/书签 × 小说/漫画），
///    所以收藏与书签的 type 不能混用。
/// 2. **两个接口都是翻转，不是「设置」**：收藏再调一次就是取消；书签传**当前那一章**是取消，
///    传**别的章节**是覆盖（一本书只有一条书签，唯一性在「用户 × 作品」）。
///    ⇒ 想「确保是收藏状态」必须先知道当前状态，否则会把用户的操作反向抵消。
/// 3. **`succ` 类型不稳定**（实测 `true` 与 `1` 都出现过），两种都得认；
///    `status` 才是「操作之后的状态」，UI 直接用它，别自己推断这次是加还是减。
///
/// 请求头：CSRF 要**双份**（`X-CSRF-Token` 头 + body `_csrf-frontend`），
/// 另外必须带 `X-Requested-With: XMLHttpRequest` —— 内联 `$.post` 靠 yii.js 自动加，
/// 少了它站点返回整页 HTML 而不是 JSON。
class YmWriteResult {
  const YmWriteResult({required this.ok, required this.status, this.msg = ''});

  /// 这次请求是否成功（站点的 `succ`）。
  final bool ok;

  /// **操作之后**的状态：1 = 已加 / 已收藏，0 = 已取消。
  final int status;

  /// 站点给的提示语（`/fav/mark`、`/fav/work` 有，`/fav/user` 没有）。
  final String msg;

  /// 操作后是不是「已加」状态。
  bool get on => status == 1;

  @override
  String toString() => 'YmWriteResult(ok: $ok, status: $status, msg: $msg)';
}

class YmWrite {
  YmWrite._();

  /// 收藏的记录种类：小说 1 / 漫画 3。
  static int favType({required bool manga}) => manga ? 3 : 1;

  /// 书签的记录种类：小说 2 / 漫画 4。
  static int markType({required bool manga}) => manga ? 4 : 2;

  /* ------------------------------- 收藏 ------------------------------- */

  /// 收藏 **翻转**：已收藏就取消，未收藏就加上。返回的 `status` 是操作后的状态。
  ///
  /// ⚠ 这是翻转不是设置。要「确保已收藏」请用 [setFav]。
  static Future<YmWriteResult> toggleFav({
    required String workId,
    required bool manga,
    String csrfToken = '',
  }) async {
    final token = await _resolveToken(
      token: csrfToken,
      pagePath: manga ? '/manga/$workId' : '/novel/$workId',
    );
    final result = await _post('/fav/work', <String, String>{
      'type': '${favType(manga: manga)}',
      'id': workId,
    }, token);
    if (result.ok) _evictDetail(workId: workId, manga: manga);
    return result;
  }

  /// 把收藏**设成** [on] 指定的状态。
  ///
  /// [currently] 是调用方认为的当前状态（详情页从 `#btnFav` 文案读，收藏列表本身即已收藏）。
  /// 与 [on] 一致时**直接返回、不发请求** —— 否则一次误触会把状态翻反。
  static Future<YmWriteResult> setFav({
    required String workId,
    required bool manga,
    required bool on,
    required bool currently,
    String csrfToken = '',
  }) async {
    if (on == currently) {
      return YmWriteResult(ok: true, status: on ? 1 : 0);
    }
    return toggleFav(workId: workId, manga: manga, csrfToken: csrfToken);
  }

  /* ------------------------------- 书签 ------------------------------- */

  /// 加书签。传**当前已钉着的那一章**就是取消，传别的章节是覆盖。
  ///
  /// [page] 只有漫画用（小说侧站点不认这个字段，带上也无害，这里干脆不带）。
  static Future<YmWriteResult> toggleBookmark({
    required String workId,
    required String chaptId,
    required bool manga,
    int page = 1,
    String csrfToken = '',
  }) async {
    final safePage = page < 1 ? 1 : page;
    final token = await _resolveToken(
      token: csrfToken,
      pagePath: manga
          ? '/manga/view-chapter?id=$chaptId&page=$safePage'
          : '/novel/view-chapter?id=$chaptId',
    );
    final fields = <String, String>{
      'type': '${markType(manga: manga)}',
      'workId': workId,
      'chptId': chaptId,
    };
    if (manga) fields['page'] = '$safePage';
    final result = await _post('/fav/mark', fields, token);
    if (result.ok) _evictChapter(chaptId: chaptId, manga: manga, page: safePage);
    return result;
  }

  /// 把书签**设成** [on] 指定的状态。
  ///
  /// [pinnedChaptId] 是「现在钉着哪一章」（空串 = 没有书签）。
  /// ⚠ 一条书签记录绑一章，所以：
  /// - [on] 且当前没钉 → 直接加；
  /// - [on] 且钉的是别的章 → **会覆盖**，调用方应先提示用户（旧位置不可恢复）；
  /// - [on] 且钉的就是这一章 → 一致，不发请求；
  /// - 不要了（[on] false）且钉的是这一章 → 取消；
  /// - 不要了但钉的是别的章 → 一致（这本本来就没钉这一章），不发请求。
  static Future<YmWriteResult> setBookmark({
    required String workId,
    required String chaptId,
    required bool manga,
    required bool on,
    String pinnedChaptId = '',
    int page = 1,
    String csrfToken = '',
  }) async {
    final pinnedThis = pinnedChaptId.isNotEmpty && pinnedChaptId == chaptId;
    if (on == pinnedThis) {
      return YmWriteResult(ok: true, status: on ? 1 : 0);
    }
    if (!on && !pinnedThis) {
      // 要取消、但不是这条 —— 站点只有「钉这一章」这一个开关，
      // 对别的章再发一次只会把它覆盖掉，不能当取消用。
      return const YmWriteResult(ok: true, status: 0);
    }
    return toggleBookmark(
      workId: workId,
      chaptId: chaptId,
      manga: manga,
      page: page,
      csrfToken: csrfToken,
    );
  }

  /* ------------------------------ 内部实现 ----------------------------- */

  /// 拿 CSRF。优先用调用方传来的（详情 / 章节页面解析时已顺手带回，见 `csrfToken` 字段）；
  /// 空的话才回源取一次页面 —— 匿名页面没有 token，那必然是登录态失效。
  static Future<String> _resolveToken({
    required String token,
    required String pagePath,
  }) async {
    if (token.isNotEmpty) return token;
    final html = await YmHttp.instance.requestText(pagePath);
    final fresh = parseCsrfToken(html);
    if (fresh.isEmpty) {
      throw YmHttpError('需要登录后才能使用', code: 'LOGIN_REQUIRED');
    }
    return fresh;
  }

  static Future<YmWriteResult> _post(
    String path,
    Map<String, String> fields,
    String token,
  ) async {
    final body = <String, String>{...fields, '_csrf-frontend': token};
    final res = await YmHttp.instance.requestForm(
      path,
      body,
      headers: <String, String>{
        'X-CSRF-Token': token,
        'X-Requested-With': 'XMLHttpRequest',
      },
    );
    return _read(res);
  }

  static YmWriteResult _read(YmRawResponse res) {
    // 写请求固定 redirectOk=true ⇒ 3xx 不会被当作登录失效抛出，只能在这里判：
    // 站点对写请求的唯一重定向就是「去登录页」。
    if (res.status >= 300 && res.status < 400) {
      throw YmHttpError('需要登录后才能使用', code: 'LOGIN_REQUIRED', status: res.status);
    }

    final text = res.body.trim();
    final json = text.startsWith('{') ? _tryJson(text) : null;
    if (json != null) {
      final succ = json['succ'];
      final ok = succ == true || succ == 1 || succ == '1';
      final status = int.tryParse('${json['status'] ?? ''}');
      return YmWriteResult(
        ok: ok,
        // 站点没给 status 时：成功就按「已加」算，失败按「未加」算。
        status: status ?? (ok ? 1 : 0),
        msg: '${json['msg'] ?? ''}',
      );
    }

    // 返回了整页 HTML：多半是登录页（会话过期）。
    if (RegExp(r'name="LoginForm\[username\]"').hasMatch(text)) {
      throw YmHttpError('需要登录后才能使用', code: 'LOGIN_REQUIRED', status: res.status);
    }
    throw YmHttpError('操作没有成功，请稍后再试', code: 'WRITE', status: res.status);
  }

  static Map<String, Object?>? _tryJson(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  /// 收藏状态变了 ⇒ 那本书的详情缓存失效（收藏数、按钮文案都变），
  /// 顺带把**收藏列表**也作废（条目会新增 / 消失，`/my/fav` 分页也得重取）。
  static void _evictDetail({required String workId, required bool manga}) {
    evictCache(manga ? 'manga:$workId' : 'detail:$workId');
    evictCache('favs:');
  }

  /// 书签变了 ⇒ 那章的缓存失效（`#btnMark` 文案、书签态都在里面），
  /// 顺带把**书签列表**也作废（条目会新增 / 取消 / 被覆盖到别的章）。
  static void _evictChapter({
    required String chaptId,
    required bool manga,
    required int page,
  }) {
    evictCache(manga ? 'manga-ch:$chaptId:$page' : 'chapter:$chaptId');
    evictCache('bookmarks:');
  }
}
