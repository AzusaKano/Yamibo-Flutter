/// 论坛唯一网络出口（只连 bbs.yamibo.com），与阅读侧 `http.dart` 完全两套：
///
/// - 域名 `bbs` + **移动 UA**：站点按 UA 返两套模板，解析器只认 `mobile=2` 那套
///   （阅读侧强制 PC UA，别把这套头复制过去）；
/// - Cookie 罐独立（`ForumSession`，前缀 `EeqY_2132_`；www 的 PHPSESSID 论坛不认）；
/// - 间隔 400ms、并发 1（论坛页面重，先按最保守节奏走）；
/// - 图片另见各取数方：论坛附件必须带论坛侧 `Referer`（见 [forumImageHeaders]），
///   漫画图正好相反（带才 403）——两套规则分开放，**不做全局默认头**。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../http.dart' show YmDebugRequest, YmHttpError;
import 'forum_auth.dart';

const String kForumBase = 'https://bbs.yamibo.com';

/// 论坛图请求头（Referer + 移动 UA + 论坛罐 Cookie）。
///
/// 放在数据层而不是控件层：2026-11-24 起论坛离线下载也要拉图（下载队列在
/// `data/`），控件层不能反向成为数据层的依赖。
/// 图片请求须与页面请求带同一套头（Referer / UA / Cookie 三者一致），只带
/// Referer 会被站点重定向循环拒掉——2026-11-15 真机诊断即为此。Cookie 只发往
/// bbs 域，来源 = 论坛罐（含登录凭据与挑战层凭据）。
/// 渲染侧与下载侧共用这一份，同 url + 同头 = 同一条缓存流。
Map<String, String> forumImageHeaders() => <String, String>{
  HttpHeaders.refererHeader: '$kForumBase/',
  HttpHeaders.userAgentHeader: kForumMobileUa,
  if (ForumSession.cookieHeader() != null)
    HttpHeaders.cookieHeader: ForumSession.cookieHeader()!,
};

/// 移动 UA。与阅读侧 `kYmPcUa` 相反：论坛解析器只认手机模板。
const String kForumMobileUa =
    'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36';

/// 论坛响应快照。[location] 是 3xx 的 `Location`（搜索 POST 靠它拿结果页地址）。
class ForumRawResponse {
  const ForumRawResponse({required this.status, required this.body, this.location});
  final int status;
  final String body;
  final String? location;
}

/// isolate 里的请求描述与结果（不携带闭包 / 单例状态，可跨 isolate 传递）。
class _IsoRequest {
  const _IsoRequest({
    required this.method,
    required this.url,
    required this.timeout,
    required this.headers,
    this.body,
  });
  final String method;
  final String url;
  final Duration timeout;
  final Map<String, String> headers;
  final List<int>? body;
}

class _IsoResponse {
  const _IsoResponse({
    required this.status,
    required this.body,
    required this.setCookie,
    this.location,
  });
  final int status;
  final String body;
  final List<String> setCookie;
  final String? location;
}

Future<_IsoResponse> _isoSend(_IsoRequest r) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..autoUncompress = true;
  try {
    final req = await client.openUrl(r.method, Uri.parse(r.url)).timeout(r.timeout);
    req.followRedirects = false;
    r.headers.forEach(req.headers.set);
    final body = r.body;
    if (body != null) {
      req.contentLength = body.length;
      req.add(body);
    }
    final res = await req.close().timeout(r.timeout);
    final bytes = await res
        .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk))
        .timeout(r.timeout);
    return _IsoResponse(
      status: res.statusCode,
      body: utf8.decode(bytes, allowMalformed: true),
      setCookie: res.headers[HttpHeaders.setCookieHeader] ?? const <String>[],
      location: res.headers.value(HttpHeaders.locationHeader),
    );
  } finally {
    client.close(force: true);
  }
}

/// 站点的挑战层响应，两种形态都只做识别 + 人话报错：
///
/// - 405 形态：响应体带挑战页特征；
/// - 200 形态：**状态码 200 也可能是挑战页**。此前被当普通 200 喂给解析器，
///   解析出来全是垃圾 → 整个论坛「打不开」。识别出来统一走人话报错。
bool isForumWafChallenge(int status, String body) {
  if (body.contains('acw_sc__v2') && body.contains('arg1=')) return true;
  return status == 405 &&
      (body.contains('__noxexpire') ||
          body.contains('/nox_') ||
          body.contains('gangplank_'));
}

/// 论坛通道。单车道：间隔 400ms、并发 1，先到先走（论坛暂时没有预取场景）。
class ForumHttp {
  ForumHttp._();

  static final ForumHttp instance = ForumHttp._();

  /// 测试用：拦截所有请求、不联网。设为 null 走真实网络。
  static Future<ForumRawResponse> Function(String url)? debugHandler;

  /// 测试用：每次请求真正发出前回调（比 [debugHandler] 早）。断言 UA / Referer / Cookie 用。
  static void Function(YmDebugRequest req)? debugOnSend;

  /// 最近一次请求的面包屑（诊断导出用：网络层失败没有响应原文可抓，
  /// 至少要知道卡在哪个请求上）。只记 method + path，不带任何凭据。
  static String lastRequest = '';

  /// 网络日志（环形，最近 60 条）：时间 / 方法+路径 / 结果 / 耗时。
  /// WAF 对指纹的拦截是间歇性的，散装面包屑看不出规律，完整时序才能——
  /// 诊断导出用。只记元数据，不记页面内容与 Cookie。
  static final List<String> _netLog = <String>[];

  static void _netLogAdd(String entry) {
    _netLog.add(entry);
    if (_netLog.length > 60) _netLog.removeRange(0, _netLog.length - 60);
  }

  static String netLogDump() => _netLog.isEmpty ? '(本次启动还没有请求)' : _netLog.join('\n');

  /// 图片加载失败诊断（2026-11-15 加）：头像/帖子图走 Flutter 自带的
  /// Image.network，**不经过本通道**——失败时既没 URL 也没状态码，排查全靠猜
  ///（用户实机反复复现「网页能加载、App 不能」的图片问题）。调用方把
  /// URL + 失败详情传进来，进同一个环形日志，关于页一复制就有。
  /// 只记元数据；同一失败（URL+详情）**10 秒窗口内只记一条**——errorBuilder
  /// 会随界面重建反复触发，真机实证（0.1.22）：验证窗口期一条头像兜圈能刷出
  /// 十几条同款，把别的日志全淹了。0.1.22 前只挡「连续重复」，URL 一交替
  /// 就挡不住（0.1.22 修）。
  static final Map<String, int> _imgFailAt = <String, int>{};

  static void logImageFailure(String url, String detail) {
    final where = url.length > 120 ? url.substring(0, 120) : url;
    final entry = '${DateTime.now().toString().substring(11, 19)} IMG ✗ $detail $where';
    final key = '$detail $where';
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _imgFailAt[key];
    if (last != null && now - last < 10000) return;
    _imgFailAt[key] = now;
    // 粗修剪：键太多时挤掉最旧的（窗口判定按值比，删键不影响正确性）
    if (_imgFailAt.length > 8) {
      var oldest = '';
      var oldestAt = now;
      _imgFailAt.forEach((k, v) {
        if (v <= oldestAt) {
          oldestAt = v;
          oldest = k;
        }
      });
      _imgFailAt.remove(oldest);
    }
    _netLogAdd(entry);
  }

  int _running = 0;
  int _lastAt = 0;

  static const _gap = Duration(milliseconds: 400);

  Future<ForumRawResponse> request(
    String path, {
    String method = 'GET',
    String? body,
    String? contentType,
    bool redirectOk = false,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
    String? referer,
  }) {
    // 测试 stub 直接走、不进车道：stub 不联网，节流没有意义，
    // 而车道的等待定时器在 widget 测试的假时钟下会让 pumpAndSettle 提前收工、请求挂死。
    if (debugHandler != null) {
      return _send(
        method: method,
        path: path,
        body: body,
        contentType: contentType,
        redirectOk: redirectOk,
        headers: headers ?? const <String, String>{},
        timeout: timeout,
        referer: referer,
      );
    }
    return _enqueue(
      method: method,
      path: path,
      body: body,
      contentType: contentType,
      redirectOk: redirectOk,
      headers: headers ?? const <String, String>{},
      timeout: timeout,
      referer: referer,
    );
  }

  /// 表单 POST（`application/x-www-form-urlencoded`）。搜索（POST+302）与
  /// 阶段 2 的收藏 / 签到走它：优先级最高、不重试、允许 302。
  Future<ForumRawResponse> requestForm(
    String path,
    Map<String, String> fields, {
    Duration timeout = const Duration(seconds: 20),
    Map<String, String>? headers,
    String? referer,
  }) {
    final encoded = fields.entries
        .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return request(
      path,
      method: 'POST',
      body: encoded,
      contentType: 'application/x-www-form-urlencoded',
      redirectOk: true,
      headers: headers,
      timeout: timeout,
      referer: referer,
    );
  }

  Future<ForumRawResponse> _enqueue({
    required String method,
    required String path,
    required String? body,
    required String? contentType,
    required bool redirectOk,
    required Map<String, String> headers,
    required Duration timeout,
    required String? referer,
  }) async {
    // 串行车道：等前一个走完，再保证与上一个**开始时间**至少隔 400ms。
    while (_running > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final startAt = _lastAt + _gap.inMilliseconds > now ? _lastAt + _gap.inMilliseconds : now;
    _lastAt = startAt;
    _running += 1;
    try {
      // 等待量钳到 400ms 上限：墙钟只会前进，正常最多等一个 gap；
      // 但测试的假时钟每个用例归零、设备休眠后恢复也会跳变，
      // 不钳的话会算出几秒的病态等待，请求永远挂起。
      final wait = (startAt - now).clamp(0, _gap.inMilliseconds);
      if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
      return await _sendWithRetry(
        method: method,
        path: path,
        body: body,
        contentType: contentType,
        redirectOk: redirectOk,
        headers: headers,
        timeout: timeout,
        referer: referer,
      );
    } finally {
      _running -= 1;
    }
  }

  /// 失败重试（写表单 POST 不重试：写操作重放有风险；GET 共 3 次尝试，
  /// 退避 1.4s / 3s——2026-11-14 真机实证：WAF 对 Dart 指纹有**间歇性**连接重置，
  /// 单次重试不够穿过，多试两次基本能过；登录要求 / WAF 挑战页不重试）。
  Future<ForumRawResponse> _sendWithRetry({
    required String method,
    required String path,
    required String? body,
    required String? contentType,
    required bool redirectOk,
    required Map<String, String> headers,
    required Duration timeout,
    required String? referer,
  }) async {
    Object? lastErr;
    final attempts = (method == 'POST') ? 1 : 3;
    const backoffs = [Duration(milliseconds: 1400), Duration(seconds: 3)];
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        return await _send(
          method: method,
          path: path,
          body: body,
          contentType: contentType,
          redirectOk: redirectOk,
          headers: headers,
          timeout: timeout,
          referer: referer,
        );
      } catch (e) {
        // 登录要求 / WAF 不是网络抖动，不重试
        if (e is YmHttpError && (e.isLoginRequired || e.code == 'WAF')) rethrow;
        lastErr = e;
        if (attempt < backoffs.length) {
          await Future<void>.delayed(backoffs[attempt]);
        }
      }
    }
    throw lastErr ?? YmHttpError('网络请求失败', code: 'NETWORK');
  }

  Future<ForumRawResponse> _send({
    required String method,
    required String path,
    required String? body,
    required String? contentType,
    required bool redirectOk,
    required Map<String, String> headers,
    required Duration timeout,
    required String? referer,
  }) async {
    final finalHeaders = <String, String>{
      HttpHeaders.acceptHeader: 'text/html,*/*;q=0.9',
      HttpHeaders.userAgentHeader: kForumMobileUa,
      HttpHeaders.acceptEncodingHeader: 'identity',
      HttpHeaders.acceptLanguageHeader: 'zh-CN,zh;q=0.9',
      // 论坛附件的硬口径：Referer 指到 bbs 本站，不带就 403
      HttpHeaders.refererHeader: referer ?? '$kForumBase/',
    };
    final cookie = ForumSession.cookieHeader();
    if (cookie != null && cookie.isNotEmpty) {
      finalHeaders[HttpHeaders.cookieHeader] = cookie;
    }
    List<int>? bodyBytes;
    if (body != null && contentType != null) {
      finalHeaders[HttpHeaders.contentTypeHeader] = contentType;
      bodyBytes = utf8.encode(body);
    }
    // 额外头放最后：写操作要靠它覆盖任意一项（含 Cookie / Referer）
    if (headers.isNotEmpty) finalHeaders.addAll(headers);

    debugOnSend?.call(YmDebugRequest(
      path: path,
      method: method,
      headers: Map<String, String>.unmodifiable(finalHeaders),
      body: body,
    ));

    lastRequest = '$method $path';

    final stub = debugHandler;
    if (stub != null) return await stub(kForumBase + path);

    Future<_IsoResponse> sendIso() async {
      final sw = Stopwatch()..start();
      final at = DateTime.now().toString().substring(11, 19);
      try {
        final r = await Isolate.run<_IsoResponse>(() => _isoSend(_IsoRequest(
              method: method,
              url: kForumBase + path,
              timeout: timeout,
              headers: finalHeaders,
              body: bodyBytes,
            )));
        _netLogAdd('$at $method $path → ${r.status} (${sw.elapsedMilliseconds}ms)');
        return r;
      } on TimeoutException {
        _netLogAdd('$at $method $path ✗ 超时 (${sw.elapsedMilliseconds}ms)');
        throw YmHttpError('网络请求超时', code: 'NETWORK');
      } on SocketException {
        _netLogAdd('$at $method $path ✗ 连接失败 (${sw.elapsedMilliseconds}ms)');
        throw YmHttpError('网络连接失败', code: 'NETWORK');
      } on HandshakeException {
        _netLogAdd('$at $method $path ✗ TLS握手被拒 (${sw.elapsedMilliseconds}ms)');
        throw YmHttpError('安全连接失败', code: 'NETWORK');
      }
    }

    var res = await sendIso();

    // 挑战响应：取一次 WebView 会话里的凭据重放（详见
    // ForumSession.absorbWafPassFromWebview）。只重放一次，仍被拦就是真的过不去
    // → 人话报错，别无限撞。
    if (isForumWafChallenge(res.status, res.body) && res.body.contains('acw_sc__v2')) {
      if (await ForumSession.absorbWafPassFromWebview()) {
        res = await sendIso();
      }
    }

    ForumSession.absorbSetCookie(res.setCookie);

    if (isForumWafChallenge(res.status, res.body)) {
      throw YmHttpError('论坛正在安全验证，请稍后再试', code: 'WAF', status: res.status);
    }
    if (res.status >= 200 && res.status < 300) {
      return ForumRawResponse(status: res.status, body: res.body);
    }
    if (res.status >= 300 && res.status < 400) {
      // Discuz 用 302 表示「去登录」（文学区等游客不可读）；
      // 搜索 POST 也用 302 表示「去看结果页」，由 redirectOk 区分。
      if (redirectOk) {
        return ForumRawResponse(status: res.status, body: res.body, location: res.location);
      }
      throw YmHttpError('需要登录后才能使用', code: 'LOGIN_REQUIRED', status: res.status);
    }
    throw YmHttpError('站点返回 ${res.status}', code: 'HTTP', status: res.status);
  }
}
