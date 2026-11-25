import 'package:flutter/material.dart';

import '../../../data/cache/ym_cache_store.dart' show YmCache;
import '../../../data/forum/forum_http.dart';
import '../../theme.dart';
import '../../tokens.dart';

export '../../../data/forum/forum_http.dart' show forumImageHeaders;

/// Discuz 的 uc_server 头像地址规则：uid 补零到 9 位后按 3/2/2/2 切段
/// （如 438166 → `000/43/81/66`，站点楼层里印的就是这个形状）。
/// uid 非法返回空串（[YmForumImage] 会退首字占位）。
String forumAvatarUrl(String uid) {
  final id = int.tryParse(uid);
  if (id == null || id <= 0) return '';
  final s = id.toString().padLeft(9, '0');
  return '$kForumBase/uc_server/data/avatar/'
      '${s.substring(0, 3)}/${s.substring(3, 5)}/${s.substring(5, 7)}'
      '/${s.substring(7)}_avatar_small.jpg';
}

/// 论坛图（正文图 / 头像）。论坛附件对 `Referer` 有硬要求，须按论坛侧配置
/// （见 [forumImageHeaders]，缺了会被拒）——别把这套头带去阅读侧：漫画图对
/// Referer 的要求正好相反，两套头必须分开，混用会 403。
///
/// 加载失败退回首字占位（fill 底 + 品牌色首字），不给裂图。
///
/// 本机有这张图（帖子离线保存过）就走 `Image.file`，不发请求（第三期）。
class YmForumImage extends StatefulWidget {
  const YmForumImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.fallbackText = '',
    this.borderRadius,
    this.onLoaded,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// 失败 / 无地址时的首字占位（头像用作者名首字）。
  final String fallbackText;
  final BorderRadius? borderRadius;

  /// 图像**首帧**到手时回调（帧后再发，不在 build 里做副作业）。
  /// 分页引擎靠它感知「占位 → 解码完」的高度漂移，决定要不要重排；
  /// 失败不回调（退占位高度稳定，布局没变）。无地址也不回调。
  final VoidCallback? onLoaded;

  @override
  State<YmForumImage> createState() => _YmForumImageState();
}

class _YmForumImageState extends State<YmForumImage> {
  bool _notified = false;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final placeholder = Container(
      width: widget.width,
      height: widget.height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: widget.borderRadius,
      ),
      child: widget.fallbackText.isEmpty
          ? null
          : Text(
              widget.fallbackText,
              style: TextStyle(
                fontSize: YmFont.sub13,
                fontWeight: FontWeight.w700,
                color: c.brand,
              ),
            ),
    );

    if (widget.url.isEmpty) return placeholder;

    // 本机图优先（第三期）：离线保存过的帖子，正文图已经落在 `forum_img/` 下，
    // 命中就不再发请求——断网也能看图，联网时也省一次流量。
    // 用**同步** peek（渲染侧每帧都要判），目录没就绪时它自己的返回 null。
    final local = YmCache.instance.peekForumImageFile(widget.url);

    final image = local != null
        ? Image.file(
            local,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            // 本地文件读不出来（被清理 / 写坏）不写网络日志，也不偷偷回源：
            // 这一帧先给占位，下一帧 peek 不到自然会走网络分支
            errorBuilder: (context, error, stackTrace) => placeholder,
            frameBuilder: _frameBuilder(placeholder),
          )
        : Image.network(
            widget.url,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            headers: forumImageHeaders(),
            // 失败进网络日志（关于页可复制）：URL + HTTP 状态码/错误类型
            errorBuilder: (context, error, stackTrace) {
              final detail = error is NetworkImageLoadException
                  ? 'HTTP ${error.statusCode}'
                  : '异常 ${error.runtimeType}';
              ForumHttp.logImageFailure(widget.url, detail);
              return placeholder;
            },
            frameBuilder: _frameBuilder(placeholder),
          );
    if (widget.borderRadius == null) return image;
    return ClipRRect(borderRadius: widget.borderRadius!, child: image);
  }

  /// 首帧到手才通知外面（分页引擎靠它感知高度漂移），失败保持占位。
  ImageFrameBuilder _frameBuilder(Widget placeholder) {
    return (context, child, frame, wasSync) {
      if (frame != null && !_notified) {
        _notified = true;
        final cb = widget.onLoaded;
        if (cb != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => cb());
        }
      }
      return frame == null ? placeholder : child;
    };
  }
}
