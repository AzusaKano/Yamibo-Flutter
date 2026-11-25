import 'package:flutter/material.dart';

/// 章内阅读位置恢复（0.1.37 · 第十三期）。
///
/// 两个阅读器（小说 / 论坛）共用：进章、正文渲染完之后，把存下来的
/// `percent`（0~1）翻成滚动偏移落下去。
///
/// 为什么不放进 `YmReaderShell`：壳是纯展示件，只认「滚到哪显示什么」，
/// 不该管「什么时候恢复进度」这种页面级业务时机。

/// 恢复前的取值口径 —— 只有这一处判定，两个阅读器都走它。
///
/// 返回 `null` = 不需要恢复（直接回顶部）：刚开头（≤ 0.001）与非有限值。
///
/// 读到章末（接近 1）**照样恢复到底部**：换章时上一章的进度本来就会被覆盖，
/// 回到底部还能让人想起上次读到哪，没有坏处（2026-11-19 用户拍板，取消原来的「读完回顶」）。
double? readerRestoreTarget(double? percent) {
  if (percent == null) return null;
  if (!percent.isFinite) return null;
  if (percent <= 0.001) return null;
  return percent;
}

/// 把 [percent] 恢复成滚动位置。返回 `true` 表示真的定位过。
///
/// 三个坑按这个顺序处理：
/// 1. **`maxScrollExtent` 初值为 0**：正文刚 setState 完那一帧还没布局完，
///    此时 `jumpTo(percent * 0)` 等于跳到 0 ⇒ 先等布局落地（最多 [maxAttempts] 帧，
///    到上限就放弃、留在顶部，不无限重试）。
/// 2. **图片异步加载导致高度漂移**：图解码完总高度会变，原先换算的偏移就偏了
///    ⇒ 恢复后在 [watch] 窗口内盯着 `maxScrollExtent`，变了就按同一个 percent 重算一次。
/// 3. **用户自己动了就别抢**：窗口期内一旦发现位置不是我们落的（差值超 1px），
///    立即停止校正，把控制权交给用户。
Future<bool> restoreReaderScroll(
  ScrollController controller,
  double? percent, {
  int maxAttempts = 5,
  Duration watch = const Duration(milliseconds: 1500),
  Duration tick = const Duration(milliseconds: 100),
}) async {
  final target = readerRestoreTarget(percent);
  if (target == null) return false;

  var ready = false;
  for (var i = 0; i < maxAttempts; i++) {
    await _nextFrame();
    if (!controller.hasClients) continue;
    if (controller.position.maxScrollExtent > 0) {
      ready = true;
      break;
    }
  }
  if (!ready) return false;

  // 自己 jump 期间不算「用户动了」：标志只在往 controller 里写的那一刻立起来。
  var applying = false;
  var applied = _apply(controller, target, () => applying = true,
      () => applying = false);

  var userMoved = false;
  void onScroll() {
    if (applying || !controller.hasClients) return;
    if ((controller.position.pixels - applied).abs() > 1) userMoved = true;
  }

  controller.addListener(onScroll);
  try {
    // 用「拍数」而不是墙钟：虚拟时间跑测试时墙钟不走，按墙钟写会死循环。
    final ticks = tick.inMicroseconds <= 0
        ? 0
        : (watch.inMicroseconds ~/ tick.inMicroseconds);
    for (var i = 0; i < ticks; i++) {
      if (userMoved || !controller.hasClients) break;
      await Future<void>.delayed(tick);
      if (userMoved || !controller.hasClients) break;
      // 高度没变就不动（同一个 target 再 jump 是空转，还会打断惯性）
      final next = _apply(controller, target, () => applying = true,
          () => applying = false);
      if ((next - applied).abs() <= 1) continue;
      applied = next;
    }
  } finally {
    controller.removeListener(onScroll);
  }
  return true;
}

/// 按当前 `maxScrollExtent` 落一次位置，返回落到的像素。
double _apply(
  ScrollController controller,
  double percent,
  VoidCallback begin,
  VoidCallback end,
) {
  final pos = controller.position;
  final max = pos.maxScrollExtent;
  final target = (max * percent).clamp(pos.minScrollExtent, max);
  if ((pos.pixels - target).abs() > 0.5) {
    begin();
    try {
      controller.jumpTo(target);
    } finally {
      end();
    }
  }
  return target;
}

Future<void> _nextFrame() {
  // endOfFrame 在空闲时会自己排一帧，不必额外 ensureVisualUpdate。
  return WidgetsBinding.instance.endOfFrame;
}
