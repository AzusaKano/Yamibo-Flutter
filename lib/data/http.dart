import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'session.dart';

/// 唯一网络出口（只连 www.yamibo.com）。
///
/// 与 uni 版 `services/http.js` 对齐：两条通道 + 通道内优先级。
/// - `normal`：列表 / 详情 / 首页，间隔 650ms、并发 1；
/// - `chapter`：只给漫画章节页，间隔 180ms、并发 2（一话几十页的纯阅读流）。
///
/// 通道内按 priority 出队（user > normal > prefetch）：阅读器预取不能把用户
/// 真正要翻的那一页堵在队尾。
///
/// ⚠ 站点按 UA 返回两套模板（见记忆 `env-yamibo-per-client-html`）：
/// 必须强制 PC UA，解析器才只面对一种结构。
const String kYmBase = 'https://www.yamibo.com';

const String kYmPcUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

enum YmLane { normal, chapter }

enum YmPriority { user, normal, prefetch }

class YmHttpError implements Exception {
  YmHttpError(this.message, {this.code, this.status});

  /// 面向用户的短句（页面直接显示这句话）。
  final String message;

  /// `LOGIN_REQUIRED` / `CANCELLED` / `NETWORK` / `HTTP`。
  final String? code;
  final int? status;

  bool get isLoginRequired => code == 'LOGIN_REQUIRED';
  bool get isCancelled => code == 'CANCELLED';

  @override
  String toString() => message;
}

class YmRawResponse {
  const YmRawResponse({required this.status, required this.body});
  final int status;
  final String body;
}

/// 后台 isolate 的请求描述与结果（不携带任何闭包 / 单例状态，可跨 isolate 传递）。
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
  });
  final int status;
  final String body;
  final List<String> setCookie;
}

/// 在独立 isolate 里完成一次 HTTP 收发。
///
/// socket 分块读取 / TLS 握手的每个数据块都是 UI isolate 上的一次事件循环
/// 任务；实测（perfetto，2026-10-24）一次 32KB 章节页会把主 isolate 塞满
/// ~100ms 的亚毫秒级微任务，120Hz 的 vsync 只能接住约 9%，实际 ~10fps。
/// 所以收发必须整体搬离 UI isolate——这也正是 uni 版网络跑在独立 JS 线程
/// 天然获得的效果。
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
    );
  } finally {
    client.close(force: true);
  }
}

class _Lane {
  _Lane({required this.gapMs, required this.concurrency});
  final int gapMs;
  final int concurrency;
  int running = 0;
  int lastAt = 0;
  int seq = 0;
  final List<_Task> queue = <_Task>[];
}

class _Task {
  _Task({
    required this.priority,
    required this.seq,
    required this.path,
    required this.opts,
    required this.completer,
    required this.attempts,
  });

  final YmPriority priority;
  final int seq;
  final String path;
  final _Opts opts;
  final Completer<YmRawResponse> completer;
  final int attempts;
  bool cancelled = false;

  /// 失败重试一次（预取不重试）。重试在原调度槽内进行，不重新排队。
  Future<YmRawResponse> run() async {
    Object? lastErr;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        return await YmHttp.instance._send(path, opts);
      } catch (e) {
        lastErr = e;
        // 登录要求不是网络问题，不重试
        if (e is YmHttpError && e.isLoginRequired) rethrow;
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 1400));
        }
      }
    }
    throw lastErr ?? YmHttpError('网络请求失败', code: 'NETWORK');
  }
}

class _Opts {
  const _Opts({
    this.timeout = const Duration(seconds: 20),
    this.method = 'GET',
    this.body,
    this.contentType,
    this.redirectOk = false,
    this.headers = const <String, String>{},
  });
  final Duration timeout;
  final String method;
  final String? body;
  final String? contentType;
  final bool redirectOk;

  /// 额外请求头，在默认头与 Cookie **之后**合并（可覆盖任意一项）。
  /// 写操作用它带 `X-CSRF-Token` / `X-Requested-With`（见 `data/write.dart`）。
  final Map<String, String> headers;
}

/// 一次请求的真实参数快照，只给测试看（见 [YmHttp.debugOnSend]）。
///
/// 存在的理由：`debugHandler` 一接手就直接返回假 body，测试看不到
/// 「method 是不是 POST」「CSRF 头有没有带上」「表单体里的 type/id 对不对」。
class YmDebugRequest {
  const YmDebugRequest({
    required this.path,
    required this.method,
    required this.headers,
    this.body,
  });

  final String path;
  final String method;
  final Map<String, String> headers;
  final String? body;

  /// 表单体（`x-www-form-urlencoded`）里的字段，已解码。取不到返回 null。
  String? field(String name) {
    final raw = body;
    if (raw == null || raw.isEmpty) return null;
    for (final pair in raw.split('&')) {
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      if (Uri.decodeQueryComponent(pair.substring(0, eq)) == name) {
        return Uri.decodeQueryComponent(pair.substring(eq + 1));
      }
    }
    return null;
  }

  /// 请求头（名字不区分大小写）。
  String? header(String name) {
    final lower = name.toLowerCase();
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == lower) return e.value;
    }
    return null;
  }
}

class YmHttp {
  YmHttp._();

  static final YmHttp instance = YmHttp._();

  /// 测试用：拦截所有请求、不联网。返回的 body 由测试提供。
  /// 设为 null 表示走真实网络。
  static Future<YmRawResponse> Function(String path)? debugHandler;

  /// 测试用：每次请求真正发出前回调（比 [debugHandler] 早，stub 接手后也照样回调）。
  /// 用来断言写操作带对了 method / CSRF 头 / 表单体。
  static void Function(YmDebugRequest req)? debugOnSend;

  final Map<YmLane, _Lane> _lanes = {
    // 相邻两个请求**开始时间**的最小差，不是并发数
    YmLane.normal: _Lane(gapMs: 650, concurrency: 1),
    YmLane.chapter: _Lane(gapMs: 180, concurrency: 2),
  };

  /// 测试用：把 lane 的排队 / 在飞 / 时间基准全部清零。
  ///
  /// widget 测试的 fake-async 里，用例结束时还在退避的请求会被连同定时器一起
  /// 丢掉，但 `running` 计数留在单例上（`_schedule` 的收尾跑不到）—— 于是**后面
  /// 的用例**全被这个「永远占着的槽」卡死，表现为页面一直 loading。
  /// 每个用例 `setUp` 里调一次即可。
  static void resetForTest() {
    for (final lane in instance._lanes.values) {
      lane.running = 0;
      lane.lastAt = 0;
      lane.queue.clear();
    }
  }

  static const _priorityRank = {
    YmPriority.user: 0,
    YmPriority.normal: 1,
    YmPriority.prefetch: 2,
  };

  /// 发一个请求。失败默认重试一次；预取不重试。
  Future<YmRawResponse> request(
    String path, {
    YmLane lane = YmLane.normal,
    YmPriority priority = YmPriority.normal,
    Duration timeout = const Duration(seconds: 20),
    bool? retry,
    String method = 'GET',
    String? body,
    String? contentType,
    bool redirectOk = false,
    Map<String, String>? headers,
  }) {
    final laneState = _lanes[lane]!;
    final effectiveRetry = retry ?? priority != YmPriority.prefetch;

    if (priority == YmPriority.user) _dropQueuedPrefetch(laneState);

    final completer = Completer<YmRawResponse>();
    final opts = _Opts(
      timeout: timeout,
      method: method,
      body: body,
      contentType: contentType,
      redirectOk: redirectOk,
      headers: headers ?? const <String, String>{},
    );
    final task = _Task(
      priority: priority,
      seq: laneState.seq++,
      path: path,
      opts: opts,
      completer: completer,
      attempts: effectiveRetry ? 2 : 1,
    );

    laneState.queue.add(task);
    _schedule(laneState);
    return completer.future;
  }

  Future<String> requestText(String path, {YmLane lane = YmLane.normal, YmPriority priority = YmPriority.normal, Duration timeout = const Duration(seconds: 20)}) async {
    final res = await request(path, lane: lane, priority: priority, timeout: timeout);
    return res.body;
  }

  /// 表单 POST（`application/x-www-form-urlencoded`）。注销与所有写操作都走它。
  ///
  /// 写操作专用：优先级最高、不重试、允许 302（站点用 302 表示「去看登录页」）。
  /// [headers] 用来带 CSRF 与 `X-Requested-With` —— 缺了后者站点会返回整页 HTML
  /// 而不是 JSON（内联 `$.post` 靠 yii.js 自动加头，客户端得自己带）。
  Future<YmRawResponse> requestForm(
    String path,
    Map<String, String> fields, {
    Duration timeout = const Duration(seconds: 20),
    Map<String, String>? headers,
  }) {
    final body = fields.entries
        .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return request(
      path,
      priority: YmPriority.user,
      method: 'POST',
      body: body,
      contentType: 'application/x-www-form-urlencoded',
      redirectOk: true,
      retry: false,
      timeout: timeout,
      headers: headers,
    );
  }

  void _dropQueuedPrefetch(_Lane lane) {
    for (final t in lane.queue) {
      if (t.priority == YmPriority.prefetch) t.cancelled = true;
    }
  }

  void _schedule(_Lane lane) {
    final gapMs = lane.gapMs;
    final concurrency = lane.concurrency;

    while (lane.running < concurrency && lane.queue.isNotEmpty) {
      final task = _takeNext(lane);
      if (task == null) return;
      if (task.cancelled) {
        task.completer.completeError(
          YmHttpError('请求已作废', code: 'CANCELLED'),
        );
        continue;
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final startAt = lane.lastAt + gapMs > now ? lane.lastAt + gapMs : now;
      lane.lastAt = startAt;
      lane.running += 1;

      final wait = startAt - now;
      Future<void>(() async {
        if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
        if (task.cancelled) {
          if (!task.completer.isCompleted) {
            task.completer.completeError(
              YmHttpError('请求已作废', code: 'CANCELLED'),
            );
          }
        } else {
          try {
            final res = await task.run();
            if (!task.completer.isCompleted) task.completer.complete(res);
          } catch (e, st) {
            if (!task.completer.isCompleted) task.completer.completeError(e, st);
          }
        }
        lane.running -= 1;
        _schedule(lane);
      });
    }
  }

  _Task? _takeNext(_Lane lane) {
    if (lane.queue.isEmpty) return null;
    var best = 0;
    for (var i = 1; i < lane.queue.length; i++) {
      final cur = lane.queue[i];
      final top = lane.queue[best];
      if (_priorityRank[cur.priority]! < _priorityRank[top.priority]! ||
          (_priorityRank[cur.priority] == _priorityRank[top.priority] && cur.seq < top.seq)) {
        best = i;
      }
    }
    return lane.queue.removeAt(best);
  }

  Future<YmRawResponse> _send(String path, _Opts opts) async {
    final headers = <String, String>{
      HttpHeaders.acceptHeader: 'text/html,*/*;q=0.9',
      // 站点只认 PC 模板；UA 不对会拿到另一套移动端结构
      HttpHeaders.userAgentHeader: kYmPcUa,
      // 显式要求不压缩：Dart 的 autoUncompress 只在它自己加的头下可靠
      HttpHeaders.acceptEncodingHeader: 'identity',
      HttpHeaders.acceptLanguageHeader: 'zh-CN,zh;q=0.9',
    };
    final cookie = YmSession.cookieHeader();
    if (cookie != null && cookie.isNotEmpty) {
      headers[HttpHeaders.cookieHeader] = cookie;
    }
    List<int>? bodyBytes;
    if (opts.body != null && opts.contentType != null) {
      headers[HttpHeaders.contentTypeHeader] = opts.contentType!;
      bodyBytes = utf8.encode(opts.body!);
    }
    // 额外头放最后：写操作要靠它把 `X-CSRF-Token` / `X-Requested-With` 带上去，
    // 且允许调用方覆盖上面任何一项。
    if (opts.headers.isNotEmpty) headers.addAll(opts.headers);

    // ⚠ 观察钩子必须在 debugHandler **之前**：测试里 stub 一接手就直接返回了，
    // 看不到真实构造出来的 method / headers / body（写操作的回归全靠它）。
    debugOnSend?.call(YmDebugRequest(
      path: path,
      method: opts.method,
      headers: Map<String, String>.unmodifiable(headers),
      body: opts.body,
    ));

    final stub = debugHandler;
    if (stub != null) return await stub(path);

    _IsoResponse res;
    try {
      res = await Isolate.run<_IsoResponse>(() => _isoSend(_IsoRequest(
            method: opts.method,
            url: kYmBase + path,
            timeout: opts.timeout,
            headers: headers,
            body: bodyBytes,
          )));
    } on TimeoutException {
      throw YmHttpError('网络请求超时', code: 'NETWORK');
    } on SocketException {
      throw YmHttpError('网络连接失败', code: 'NETWORK');
    } on HandshakeException {
      throw YmHttpError('安全连接失败', code: 'NETWORK');
    }

    YmSession.absorbSetCookie(res.setCookie);

    if (res.status >= 200 && res.status < 300) {
      return YmRawResponse(status: res.status, body: res.body);
    }
    if (res.status >= 300 && res.status < 400) {
      if (opts.redirectOk) return YmRawResponse(status: res.status, body: res.body);
      throw YmHttpError('需要登录后才能使用', code: 'LOGIN_REQUIRED', status: res.status);
    }
    throw YmHttpError('站点返回 ${res.status}', code: 'HTTP', status: res.status);
  }
}
