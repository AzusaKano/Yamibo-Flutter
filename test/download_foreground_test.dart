import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/data/cache/download_foreground.dart';

/// 下载前台服务那层壳。
///
/// 原生服务本身只能在真机上验（通知栏、熄屏后还在跑），这里只钉三件在 Dart 侧
/// 就能证明的事：非 Android / 测试环境一律静默跳过、状态不乱、重复 stop 不报错。
/// 之所以要钉：这条链路出问题会直接表现成「切出去下载就停」，但绝不该反过来
/// 把下载本身带崩 —— 通道失败必须当「没开成通知」处理。
void main() {
  setUp(() {
    YmDownloadForeground.resetForTest();
    YmDownloadForeground.disabledForTest = true;
  });

  tearDown(() {
    YmDownloadForeground.disabledForTest = false;
    YmDownloadForeground.resetForTest();
  });

  test('测试环境（无原生通道）下起停都是空转，不抛、不留下「在跑」的假状态', () async {
    await YmDownloadForeground.start('正在离线保存：测试 · 第1话');
    expect(YmDownloadForeground.running, isFalse);

    await YmDownloadForeground.update('正在离线保存：测试 · 第1话 · 2/38 页');
    expect(YmDownloadForeground.running, isFalse);

    // 没起来就 stop：同样是空转，不能抛
    await YmDownloadForeground.stop();
    expect(YmDownloadForeground.running, isFalse);
  });

  test('空文案不当作「开跑」', () async {
    await YmDownloadForeground.start('');
    expect(YmDownloadForeground.running, isFalse);
  });
}
