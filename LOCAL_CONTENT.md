# 本地曲目导入（7.0.255）

## v14：难度差分音频

`songlist.difficulties[].audioOverride: true` 表示该难度使用独立的 `<难度>.ogg`。例如 Axium Divergence 和 Vicious [ANTi] Heroism 都使用原曲目目录中的 `3.aff` + `3.ogg`，PST/PRS/FTR 继续使用 `base.ogg`。原生音频路径为 `Documents/dl/<id>_audio_3`；`Documents/dl/<id>_3` 仍是 BYD 谱面，两者不可混用。

v13 的导入工具遗漏了这些音频。v14 的目录和 ZIP 输入都根据 `audioOverride` 收录、验证并映射真实的难度音频。缺少某难度的谱面或差分音频时，运行时只将该难度排除；其他完整难度仍可就绪。公共音频和附加视频校验保持有效。已经验证过文件的难度还可以补足原生难度登记状态，日志用 `declarationFallbackHits` 记录该回退是否命中；这个回退的实机效果尚待确认。

旧暂存目录需要从原始 songs 目录重新 prepare 才能补入这些文件。差分音频必须是与谱面匹配的真实资源，不能复制 `base.ogg` 或用占位音频代替。2026-10-24 本机资源中发现 8 首此类曲目；目前无设备连接，尚未完成 v14 实机验证。

已补入的曲目 ID：`pragmatism`、`ignotus`、`axiumcrisis`、`redandblue`、`singularity`、`dropdead`、`viciousheroism`、`last`。本机已通过两首实际歌曲的目录/ZIP 输出一致性核对、缺少 `3.ogg` 的拒绝检查，以及 arm64 编译。面板与启动日志构建标识为 `v14-audio-20261024`。

原生路径证据（7.0.255）：`sub_10084DD38` 在 `0x10084DDD4` 读取难度对象的音频覆盖标志；`0x10084DFAC–0x10084DFC0` 拼出 `_audio_`，随后追加标准化难度编号并调用 `sub_1008429D0` 取得 `Documents/dl/` 路径。

2026-10-16 真机结果：用户确认 Acid God 在 v9 中评级正常，且可以从 Start 进入游玩。此结果验证了单曲的完整音频、0/1/2/4 谱面导入和选曲评级修正；整套曲库及使用特殊音频/额外资源的曲目尚未验证。

## 资源如何被识别

把完整歌曲保存在 `Documents/cb/active/songs/dl_<id>/`。`Documents/xrc-local-content.json` 记录曲目 ID 与每个文件的字节数和 SHA-256。文件应来自用户有权使用的资源；本功能不下载资源、不生成缺失谱面，也不修改服务器授权数据。

启动时，插件对照当前 `songs/songlist` 的难度声明，核对各难度 `.aff` 和 `base.ogg`。全部通过后，在 `Documents/dl/` 中建立指向外置 cb 文件的相对软链：

| 原始文件 | 游戏原生路径（以 Acid God 为例） |
|---|---|
| `0.aff` | `Documents/dl/acidgod_0` |
| `1.aff` | `Documents/dl/acidgod_1` |
| `2.aff` | `Documents/dl/acidgod_2` |
| `4.aff` | `Documents/dl/acidgod_4` |
| `base.ogg` | `Documents/dl/acidgod` |

“全部解锁”开启时，仅对完成核对的曲目和难度，让原生资源状态查询返回就绪。未导入或文件不完整的曲目继续走原下载判定。现有原生文件若与导入内容不同，插件会拒绝覆盖，并记录路径冲突。

当前方案保留原 `meta.cb`、`songlist` 和预览资源。新增歌曲文件的认可由导入清单与定向资源状态覆盖完成，不依赖整套 cb 校验恒通过。

## 清单结构

```json
{
  "schema": 1,
  "contentVersion": "7.0.255",
  "songs": [
    {
      "id": "acidgod",
      "files": {
        "base.ogg": { "bytes": 3573515, "sha256": "<64 位十六进制 SHA-256>" },
        "0.aff": { "bytes": 10806, "sha256": "<SHA-256>" },
        "1.aff": { "bytes": 16680, "sha256": "<SHA-256>" },
        "2.aff": { "bytes": 60839, "sha256": "<SHA-256>" },
        "4.aff": { "bytes": 58329, "sha256": "<SHA-256>" }
      }
    }
  ]
}
```

实际清单必须使用文件真实的大小和哈希。修改资源后需同步更新清单，再彻底关闭并重开应用，使启动检查重新执行。日志 `[local] <id> verified+linked` 表示核对与路径映射成功；`[local.state] readyHits=...` 表示资源状态覆盖已命中。

## 导入步骤

1. 确认应用使用 7.0.255 基线，已有 `Documents/cb/active/songs/` 和当前版本的 `songs/songlist`。这项功能不会替一个全新空安装下载初始 cb 数据。
2. 从应用切换器彻底关闭应用。通过本地文件访问或设备文件工具，将歌曲目录复制为 `Documents/cb/active/songs/dl_<id>/`；不要把压缩包本身放进歌曲目录。
3. 为每个实际复制的文件生成准确字节数及 SHA-256，并更新 `Documents/xrc-local-content.json`。清单中的每个文件名必须和磁盘文件一致。
4. 重新启动应用。检查日志中对应曲目的 `verified+linked` 记录；确认后开启“全部解锁”，进入歌曲详情检查评级，再按 Start 验证。
5. 更新任何源文件后，重算哈希并重启应用。遇到 `[local]` 校验失败或路径冲突时，先核对文件名、大小、哈希与原生 `Documents/dl/` 下是否已有冲突文件。

应用覆盖侧载可能改变容器标识。插件会尝试重连已有外置 `cb` 目录，但文件复制工具应以当前应用的 `Documents` 目录为目标；复制后从设备读回文件并核对大小/哈希，可以排除传输不完整。

当前实现最多登记 1024 个曲目；ID 限定为 1–63 个小写 ASCII 字母、数字或下划线。工具按 `base.ogg`、`songlist` 声明的 `.aff`、差分 `.ogg` 及附加媒体文件映射。AFC 通信会按小批次重建会话，避免长时间逐文件查询导致协议头错误。不同版本的特殊命名或目录结构需要单独核对。

## 批量导入工具

`tools/local_content_import.py` 可以直接接收整棵 `songs` 目录，自动读取其中的 `songlist`，逐个扫描子目录并生成暂存包。它也接受单曲文件夹、多个文件夹或 ZIP；这些输入没有自带 `songlist` 时，用 `--songlist` 指定当前版本的文件。曲目目录名可以是 `<id>` 或 `dl_<id>`。只有远端曲目且具备 `base.ogg` 与 songlist 所列全部难度 `.aff` 时才会收录；缺文件、重复 ID、文件头异常等会写入 `import-report.json`。个人资源不会加入源码仓库。

```powershell
python tools/local_content_import.py prepare `
  --source 'C:\path\to\cb\active\songs' `
  --output 'C:\path\to\local-content-stage'
```

需要分散输入时重复 `--source`。如果传入的是单曲目录或 ZIP，可另外加 `--songlist 'C:\path\to\cb\active\songs\songlist'`。输出目录必须尚不存在；生成的 `Documents/cb/active/songs/dl_<id>/` 和 `Documents/xrc-local-content.json` 即为待同步内容。程序只复制本地谱面及完整音频，不修改 cb 的 `songlist`、`meta.cb` 或现有封面。`songlist` 应与目标应用的 cb 版本一致。

关闭 iPad 上的应用后，先执行只读预览；`--apply` 才会实际写入设备。`--bundle-id` 填设备上**签名后**的实际 ID，可能与打包时的 `guy.guy.guy` 不同。`--afc-dll` 指向本机的 libimobiledevice 动态库，也可设置 `XRC_AFC_LIBRARY`。

```powershell
python tools/local_content_import.py install `
  --stage 'C:\path\to\local-content-stage' `
  --bundle-id '<实际签名后的 Bundle ID>' `
  --afc-dll 'C:\path\to\imobiledevice.dll'

# 确认预览的歌曲数、文件数与冲突检查结果后，再加 --apply 运行同一命令。
```

传输时先检查设备 `songlist`、已有文件和已有清单；不同内容的目标文件会被拒绝覆盖。缺失文件写入临时路径、读回校验并改名。`--apply` 默认每 8 首完成后发布一次清单，可用 `--batch-size` 调整（1–100）。中断后重跑同一命令，已经传输且哈希一致的文件会跳过，已发布的批次也会保留；加 `--pending-only` 可跳过已发布的曲目，加速续传。遇到 AFC 通信中断会重连并重试当前文件；完整的临时文件会先核对再复用。用 `--only factorder` 可先处理单首；多首时重复 `--only`。每次发布前，旧清单会备份到暂存目录中的 `device-manifest-before-<哈希>.json`。侧载、文件复制或清单更新后必须重新启动应用，让插件重新验证并建立原生 `Documents/dl/` 映射。批量工具仅完成文件准备与传输，曲目实际可玩性仍需逐首确认。

## 评级 ? 的修正

`sub_100919E5C(song, selectedDifficulty)` 返回当前所选难度的锁态和显示标志。五个返回字节不是 PST/PRS/FTR/BYD/ETR 五个难度槽。

旧代码因为歌曲没有 BYD 而设置 bit24；选曲信息页用 bit24 决定是否隐藏评级，因此其他难度也显示成 `?`。v9 保留“当前所选难度已声明”的守卫，通过后清空全部锁态标志；当前难度不存在时继续执行原判定。

完整音频的开局路径来自 `sub_10084DD38`，键为 `<id>`。此前使用 `<id>_` 的音频映射会导致 START 已显示但开局提示下载；v9 已更正。

## 构建与结果

构建启用 `local_content` BRK 组：资源查询 site `0x100844774`，replay `0x101468168`。文件核对和软链建立在正常启动上下文运行；SIGTRAP 处理器只读发布后的曲目表，不在处理器内读取文件或运行 Objective-C。v9 对应完整构建参数见[开发说明](DEVELOPMENT.md)。

验证包：`Arcaea_7.0.255-xrc-local-content-v9-unsigned.ipa`，Bundle ID `guy.guy.guy`，显示名 `ArcaeaXRC`。IPA SHA-256：`2b7aa94c59a38361fd41a25f8eb9aac5295b4f052d38d005ab5261255a7f1084`。

歌曲资源和设备日志仅保存于本机，不作为插件源码的一部分。
