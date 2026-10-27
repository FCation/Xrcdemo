# 自定义启动文字与替换图片

截图中的三段英文与日文是透明 PNG，不是本地化字符串。原始位置在 `Payload/Arc-mobile.app/startup/`：

| 文件 | 对应主文字 | 尺寸（像素） |
|---|---|---|
| `m1.png` / `m1_lephon.png` | DIVINE GRACE | 596 × 159 |
| `m2.png` / `m2_lephon.png` | FALLS UPON YOU IN A DEAD WORLD | 1541 × 157 |
| `m3.png` / `m3_lephon.png` | WITHOUT LIGHT OR CONFLICT | 1247 × 159 |

每张图同时包含主文字与下面的小字。`startup/StartScreen.csb` 在偏移 `0x45c`、`0x34c`、`0x23c` 分别引用 `startup/m1.png`、`m2.png`、`m3.png`；主程序还保存了主题切换用的 `_lephon` 路径。原始两套图片内容相同。此功能仅替换这些图片，不修改启动布局、主程序、插件或回放模块。

## 从文字自动生成

需要 Python 与 Pillow（只在 render 时需要）。在 UTF-8 的 `text.json` 中填写三段文字；`sub` 留空可取消小字，main/sub 都留空可隐藏整段。每项最多 256 字符，支持中文、日文、英文与换行。程序使用输入 IPA 自带的字体，按固定画布自动缩小字号、左对齐并保留透明背景。

```json
{
  "lines": [
    {"main": "AS I ALWAYS SAY", "sub": "正如我经常说的"},
    {"main": "IF YOU DONT LIKE IT, DONT PLAY", "sub": "爱玩不玩，不玩给老子滚"},
    {"main": "GO PLAY CYTUS II", "sub": "给我去玩《赛特斯 二代》"}
  ]
}
```

```powershell
python tools/custom_startup.py build `
  --ipa 'D:\path\to\ArcaeaXRC-unsigned.ipa' `
  --config 'D:\path\to\text.json' `
  --output 'D:\path\to\ArcaeaXRC-custom-startup-unsigned.ipa' `
  --apply
```

`build` 自动完成图片制作和 IPA 替换，图片保存在输出 IPA 同名的 `-images` 目录。省略 `--apply` 时生成图片并展示替换计划，不输出 IPA。仅需生成图片时使用：

```powershell
python tools/custom_startup.py render `
  --ipa 'D:\path\to\ArcaeaXRC-unsigned.ipa' `
  --config 'D:\path\to\text.json' `
  --output 'D:\path\to\new-images'
```

输出为 `m1.png`、`m2.png`、`m3.png` 及字号报告。输出目录必须尚不存在。如果文字缩到最小字号仍不能放下，会明确报错而不会截断。需要安装依赖时运行 `python -m pip install Pillow`。

## 打进 IPA，或手动替图

可以直接编辑工具生成的 PNG，也可以自己制作相同尺寸的 PNG。将要替换的图片放入一个目录，使用 `m1.png`、`m2.png`、`m3.png` 命名；只放一张也可以。默认把每张图片同时用于普通与 Lephon 两套资源；若目录里有 `m1_lephon.png` 等专用文件，则 Lephon 优先使用专用文件。`--theme base` 或 `--theme lephon` 可限定一套。

```powershell
python tools/custom_startup.py pack `
  --ipa 'D:\path\to\ArcaeaXRC-unsigned.ipa' `
  --images 'D:\path\to\new-images' `
  --output 'D:\path\to\ArcaeaXRC-custom-startup-unsigned.ipa' `
  --apply
```

省略 `--apply` 时只预览替换计划。工具检查 PNG 尺寸与 CRC，只接受 `guy.guy.guy` / `ArcaeaXRC` 的源 IPA，拒绝输出覆盖输入，生成后检查所有非目标文件的大小/CRC，确保改动只涉及选定图片。输出 IPA 需要按原来的方式重新签名并覆盖侧载。`moe.uip.lite` 的 UIP 包会被拒绝。

图片和完整 IPA 仅保存在本地；源码仓库只保存工具和使用说明。
