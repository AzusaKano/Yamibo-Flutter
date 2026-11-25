import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// 轻提示（自绘，不使用 Material SnackBar）：底部浮出一条，淡入 → 停留 → 淡出。
///
/// 资产包没有 toast 件；这里按令牌取值（底 `text` / 字 `bg` / 圆角 inner），
/// 只服务「操作结果一句话」这种场景，替代原来的 SnackBar。
void showYmToast(
  BuildContext context,
  String text, {
  Duration duration = const Duration(milliseconds: 1400),
  double bottomOffset = 24,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final colors = YmScope.of(context).colors;
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _YmToast(
      text: text,
      colors: colors,
      duration: duration,
      bottomOffset: bottomOffset,
      onDone: entry.remove,
    ),
  );
  overlay.insert(entry);
}

class _YmToast extends StatefulWidget {
  const _YmToast({
    required this.text,
    required this.colors,
    required this.duration,
    required this.bottomOffset,
    required this.onDone,
  });

  final String text;
  final YmColors colors;
  final Duration duration;
  final double bottomOffset;
  final VoidCallback onDone;

  @override
  State<_YmToast> createState() => _YmToastState();
}

class _YmToastState extends State<_YmToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _fade.forward();
    _timer = Timer(widget.duration, () async {
      if (!mounted) return;
      await _fade.reverse();
      widget.onDone();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return Positioned(
      left: YmLayout.pagePad,
      right: YmLayout.pagePad,
      bottom: MediaQuery.viewPaddingOf(context).bottom + widget.bottomOffset,
      child: IgnorePointer(
        child: Center(
          child: FadeTransition(
            opacity: _fade,
            // 必须有 Material 祖先：OverlayEntry 挂在根 Overlay 上，不在 Scaffold 的
            // Material 之下，缺它时 Text 会落到 WidgetsApp 的错误样式（黄字 + 双下划线）。
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 320),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: c.text,
                  borderRadius: BorderRadius.circular(YmRadius.inner),
                ),
                child: Text(
                  widget.text,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: YmFont.small12, color: c.bg),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
