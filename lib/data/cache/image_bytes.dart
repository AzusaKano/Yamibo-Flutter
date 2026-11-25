import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../http.dart';

/// 图片字节通道（缓存第二期 2A，2026-11-24 定稿）。
///
/// 存在理由：漫画页是一张 ~360KB 的图，不是一章 26KB 的 HTML。`Image.network`
/// 自己会下载，但**它下完的字节拿不到**，离线时也就没有东西可读；而走
/// `YmHttp.request` 拿回来的是 UTF-8 解过的字符串，图片会被解坏。所以单开一条
/// 只搬字节的通道，落盘交给缓存层。
///
/// 口径（照 `http.dart::_isoSend` 的结论，别改成主线程收字节）：
/// * **收发必须在独立 isolate**：一次 32KB 分块读就能把 UI isolate 塞满 ~100ms
///   的微任务（perfetto 实测，120Hz 只接住 9%）；一张漫画页 360KB 在主线程收
///   必然掉帧；
/// * **允许 301**：图片地址历史上是 `http://`，站点 301 到 `https://`；parser
///   已把 `imgPic` 的 src 改写成 https，这一条只是兜底；
/// * **不带 `Referer`**：2026-11-23 复测带不带都 200，与现有 `Image.network`
///   的渲染路径保持一致，保守做法就是不带头；
/// * **单张上限 12MB**：防止错误页 / 异常大文件被整块吃进内存；
/// * **不重试、不落盘、不解码、不碰 ImageCache、不做并发**（串行由下载队列保证）。
class YmImageBytes {
  YmImageBytes._();

  /// 单张图片的硬上限。超了直接判失败，**不截断**（截断的图解码必崩）。
  static const int maxImageBytes = 12 * 1024 * 1024;

  /// 测试用：拦截所有请求、不联网。与 `YmHttp.debugHandler` 同一套路，
  /// 测试里一律置 stub，**永不联网**（站点当前也常常连不上）。
  @visibleForTesting
  static Future<Uint8List> Function(String url)? debugHandler;

  /// 拉一张图的原始字节。
  ///
  /// 失败抛 [YmHttpError]：`NETWORK`（超时 / 连不上 / TLS）、`HTTP`（非 2xx、
  /// 超上限，后者 `status` 为 null）。**这里不重试**——重试只由下载队列做，
  /// 两处都重试会叠成 4 次请求（与 `fetchChapterHtml` 同一口径）。
  static Future<Uint8List> fetch(
    String url, {
    Duration timeout = const Duration(seconds: 40),
    Map<String, String>? headers,
  }) async {
    final stub = debugHandler;
    final bytes = stub != null
        ? await stub(url)
        : await _fetchReal(url, timeout: timeout, headers: headers);
    if (bytes.length > maxImageBytes) {
      throw YmHttpError('图片过大，已跳过', code: 'HTTP');
    }
    return bytes;
  }

  static Future<Uint8List> _fetchReal(
    String url, {
    required Duration timeout,
    Map<String, String>? headers,
  }) async {
    final merged = <String, String>{
      HttpHeaders.acceptHeader: 'image/*,*/*;q=0.8',
      // UA 沿用 http.dart 那一套，别自己编（站点按 UA 分模板）
      HttpHeaders.userAgentHeader: kYmPcUa,
    };
    if (headers != null) merged.addAll(headers);

    _IsoImageResponse res;
    try {
      res = await Isolate.run<_IsoImageResponse>(
        () => _isoGetBytes(
          _IsoImageRequest(url: url, timeout: timeout, headers: merged),
        ),
      );
    } on TimeoutException {
      throw YmHttpError('网络请求超时', code: 'NETWORK');
    } on SocketException {
      throw YmHttpError('网络连接失败', code: 'NETWORK');
    } on HandshakeException {
      throw YmHttpError('安全连接失败', code: 'NETWORK');
    } on HttpException {
      throw YmHttpError('网络连接失败', code: 'NETWORK');
    }

    if (res.tooLarge) {
      throw YmHttpError('图片过大，已跳过', code: 'HTTP');
    }
    if (res.status < 200 || res.status >= 300) {
      throw YmHttpError('站点返回 ${res.status}', code: 'HTTP', status: res.status);
    }
    if (res.bytes.isEmpty) {
      throw YmHttpError('图片下载失败，请稍后再试', code: 'NETWORK');
    }
    return res.bytes;
  }
}

/// 后台 isolate 的请求描述与结果（不携带闭包 / 单例状态，可跨 isolate 传递）。
class _IsoImageRequest {
  const _IsoImageRequest({
    required this.url,
    required this.timeout,
    required this.headers,
  });

  final String url;
  final Duration timeout;
  final Map<String, String> headers;
}

class _IsoImageResponse {
  const _IsoImageResponse({
    required this.status,
    required this.bytes,
    this.tooLarge = false,
  });

  final int status;
  final Uint8List bytes;

  /// 边读边数，超上限立刻放弃 —— 不把半张巨图攒进内存。
  final bool tooLarge;
}

Future<_IsoImageResponse> _isoGetBytes(_IsoImageRequest r) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..autoUncompress = true;
  try {
    final req = await client.openUrl('GET', Uri.parse(r.url)).timeout(r.timeout);
    // 与 `_isoSend` 相反：图片允许跟随跳转（http → https）
    req.followRedirects = true;
    r.headers.forEach(req.headers.set);
    final res = await req.close().timeout(r.timeout);

    if (res.statusCode < 200 || res.statusCode >= 300) {
      // 错误页不读：几十 KB 的登录页 / 404 页没有存下来的价值
      return _IsoImageResponse(status: res.statusCode, bytes: Uint8List(0));
    }

    final buf = BytesBuilder(copy: false);
    var total = 0;
    var tooLarge = false;
    await for (final chunk in res) {
      total += chunk.length;
      if (total > YmImageBytes.maxImageBytes) {
        tooLarge = true;
        break;
      }
      buf.add(chunk);
    }
    return _IsoImageResponse(
      status: res.statusCode,
      bytes: tooLarge ? Uint8List(0) : buf.takeBytes(),
      tooLarge: tooLarge,
    );
  } finally {
    // 不关会留着半截连接占 socket
    client.close(force: true);
  }
}
