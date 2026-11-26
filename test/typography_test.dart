import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/design/theme.dart';
import 'package:yamibo_flutter/design/tokens.dart';

/// 字重口径看守（rtgo_flutter v0.7.2 · 2026-11-09）。
///
/// 口径变更：**字重是「类属性」，不是「档属性」**。四档小字的 getter 默认值取该档多数派
/// w400，加粗由组件按母本那个类的声明显式覆盖（`copyWith(fontWeight: …)` /
/// `sub13Strong`）。原来按「一档一字重」写成 500/500/700/700，为了照顾一小撮控件标签，
/// 把辅助小字整体抬高了 1~3 档（母本 app.wxss 根级就是 400）。
void main() {
  test('辅助小字默认 w400：字重是类属性，不是档属性', () {
    final c = YmColors.yamiboLight;

    expect(c.sub13.fontWeight, FontWeight.w400);
    expect(c.small12.fontWeight, FontWeight.w400);
    expect(c.micro11.fontWeight, FontWeight.w400);
    expect(c.tag10.fontWeight, FontWeight.w400);

    // 加粗档留一个具名入口：13px 里母本声明加粗的那一小撮显式取它。
    expect(c.sub13Strong.fontWeight, FontWeight.w700);
  });
}
