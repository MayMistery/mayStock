# MayStock App Icon — 生成 Prompt

> 按要求：icon 不由代码生成，用下面的 prompt 交给 Midjourney / DALL·E / Ideogram 等生成，
> 再按底部说明切图放入工程。

## 主 Prompt（English，直接可用）

```
macOS app icon, squircle rounded-square shape on transparent background.
A minimal, elegant candlestick chart motif: three ascending candlesticks in
luminous jade green with subtle inner glow, the last candle taller and
brighter, suggesting upward momentum. Behind them, a thin glowing amber
trend line sweeping up and to the right. Deep midnight-navy background with
a soft radial gradient (near-black #0B1020 at edges to deep indigo #1A2340
at center), faint grid lines barely visible like a trading terminal.
Frosted-glass depth, subtle top-light and soft inner shadow following the
squircle edge, in the style of modern macOS Tahoe icons — glassy, layered,
tactile. No text, no letters, no bitcoin logo. Centered composition,
generous margins inside the squircle, crisp vector-like edges, premium
fintech aesthetic. 1024x1024.
```

## 变体（可选口味）

- **更克制**：把 “three ascending candlesticks” 换成
  `a single elegant sparkline curve rising left-to-right, drawn in light`
- **深度图口味**：追加
  `mirrored translucent green and red area chart at the bottom edge, like a market depth chart`
- **暗金融终端风**：把 amber 换成 `electric cyan`，整体更冷。

## 负面提示（支持 negative prompt 的工具用）

```
--no text, letters, words, watermark, bitcoin symbol, dollar sign, 3d bevel
kitsch, photorealism, busy details, borders outside the squircle
```

## 生成后怎么放进工程

1. 得到 1024×1024 PNG（透明背景、squircle 已含在图内）。
2. 生成整套尺寸（macOS iconset 命名）：

```bash
cd Sources/MayStock/Resources/Assets.xcassets/AppIcon.appiconset
# 假设原图为 icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s icon_1024.png --out icon_${s}x${s}.png
  sips -z $((s*2)) $((s*2)) icon_1024.png --out icon_${s}x${s}@2x.png
done
```

3. `make run` 会自动把 iconset 打包成 `AppIcon.icns` 进 app bundle。

## 设计意图（给生成器之外的你）

菜单栏里的 MayStock 是数字与迷你趋势图，克制、单色系；
Dock/启动台里的 icon 则是它的「放大镜头」：同一套语言 ——
K 线、上升、玻璃质感的深夜终端 —— 一眼认出，但不喧哗。
