// 作者色限幅映射单测（保留色相 / 对比度 ≥ 3.0 / 与背景过近改剧透遮罩；
// 不写死 #ffffff 判断）。
//
// 纯函数，亮 / 暗两套主题各跑一遍：只断言「对比度达不达标、该不该遮罩」，
// 不断言具体色值（观感留给真机人眼看）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/design/theme/forum_color.dart';
import 'package:yamibo_flutter/design/tokens.dart';

void main() {
  final light = YmColors.yamiboLight.card;
  final dark = YmColors.yamiboDark.card;

  test('亮底白字 → 剧透遮罩（含与背景几乎同色的浅色）', () {
    final white = forumReadableColor('#ffffff', light);
    expect(white.spoiler, isTrue, reason: '亮底白字就是剧透写法，不是可见文字');
    expect(white.color, isNull);

    expect(forumReadableColor('#fffaf3', light).spoiler, isTrue,
        reason: '不写死 #ffffff：任何与背景过近的颜色都判遮罩');
  });

  test('暗底白字是可读色（遮罩由解析器的 spoiler 位决定）', () {
    final r = forumReadableColor('#ffffff', dark);
    expect(r.spoiler, isFalse);
    expect(r.color, isNotNull);
    expect(forumContrastRatio(r.color!, dark),
        greaterThanOrEqualTo(kForumMinContrast));
  });

  test('正常红字：亮底原样，暗底抬到可读（色相不变）', () {
    final l = forumReadableColor('#8b0000', light);
    expect(l.spoiler, isFalse);
    expect(l.color, const Color(0xFF8B0000),
        reason: '亮底已经够对比度，不改作者色');

    final d = forumReadableColor('#8b0000', dark);
    expect(d.spoiler, isFalse);
    expect(d.color, isNotNull);
    expect(forumContrastRatio(d.color!, dark),
        greaterThanOrEqualTo(kForumMinContrast));
    final h0 = HSLColor.fromColor(const Color(0xFF8B0000)).hue;
    final h1 = HSLColor.fromColor(d.color!).hue;
    expect((h1 - h0).abs(), lessThan(1.0), reason: '只动亮度，不换色相');
  });

  test('暗底深字 → 剧透遮罩', () {
    expect(forumReadableColor('#201a16', dark).spoiler, isTrue);
    expect(forumReadableColor('#2a211c', dark).spoiler, isTrue);
  });

  test('黑字在白底可读，原样保留', () {
    expect(forumReadableColor('#000000', light).color, const Color(0xFF000000));
  });

  test('认不出的颜色 → 不改色、不遮罩（不编色值）', () {
    expect(forumReadableColor('', light).color, isNull);
    expect(forumReadableColor('not-a-color', light).spoiler, isFalse);
    expect(forumParseHexColor('#abc'), const Color(0xFFAABBCC));
    expect(forumParseHexColor('#zzz'), isNull);
    expect(forumParseHexColor('8b0000'), const Color(0xFF8B0000));
  });
}
