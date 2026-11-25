import 'dart:io';

import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// 封面。图片直连站点图床；阅读侧图床对 Referer 敏感，带了会被拒，
/// Flutter 默认不发 Referer，这里不要额外加头。
///
/// [local] 是**离线存下来的本机封面文件**（第三期任务 B）：传了就用
/// `Image.file`（断网也能出图），没传的调用点行为与加这个参数之前**逐字节一致**。
class YmCover extends StatelessWidget {
  const YmCover({
    super.key,
    required this.title,
    this.url = '',
    this.local,
    this.width,
    this.height,
    this.radius = YmRadius.inner,
    this.fit = BoxFit.cover,
  });

  final String title;
  final String url;

  /// 本机封面（`YmCache.peekCoverFile` 同步取，null = 没存过 / 目录没就绪）。
  final File? local;

  final double? width;
  final double? height;
  final double radius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final placeholder = _Placeholder(title: title);

    Widget image;
    final file = local;
    if (file != null) {
      // 本机优先：不因为同时有 url 就走网络（那会在断网时又退回占位）
      image = Image.file(
        file,
        fit: fit,
        errorBuilder: (_, _, _) => placeholder,
      );
    } else if (url.isEmpty) {
      image = placeholder;
    } else {
      image = Image.network(
        url,
        fit: fit,
        errorBuilder: (_, _, _) => placeholder,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : placeholder,
      );
    }

    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: image,
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final glyph =
        title.isEmpty ? '书' : String.fromCharCode(title.runes.first);
    return LayoutBuilder(
      builder: (context, box) {
        final small = (box.maxWidth.isFinite ? box.maxWidth : 0) < 64;
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [c.fill, c.fillPlain],
            ),
          ),
          child: Center(
            // uni 母本的封面占位只有首字，没有书形图标。
            child: Text(
              glyph,
              // ⚠ 例外：这是封面的**装饰首字**（18/22px，非文本层级），
              // 不是说明小字，四档小字口径不涉及；w800 是为了在浅灰底上站得住。
              style: TextStyle(
                fontSize: small ? 18 : 22,
                fontWeight: FontWeight.w800,
                color: c.text3,
              ),
            ),
          ),
        );
      },
    );
  }
}
