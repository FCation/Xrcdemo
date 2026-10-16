# 本地曲目导入（7.0.255 / v9）

2026-10-16 真机结果：用户确认 Acid God 在 v9 中评级正常，且可以从 Start 进入游玩。此结果验证了单曲的完整音频、0/1/2/4 谱面导入和选曲评级修正；整套曲库及使用特殊音频/额外资源的曲目尚未验证。

## 资源如何被识别

把完整歌曲保存在 `Documents/cb/active/songs/dl_<id>/`。`Documents/xrc-local-content.json` 记录曲目 ID 与每个文件的字节数和 SHA-256。

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

## 评级 ? 的修正

`sub_100919E5C(song, selectedDifficulty)` 返回当前所选难度的锁态和显示标志。五个返回字节不是 PST/PRS/FTR/BYD/ETR 五个难度槽。

旧代码因为歌曲没有 BYD 而设置 bit24；选曲信息页用 bit24 决定是否隐藏评级，因此其他难度也显示成 `?`。v9 保留“当前所选难度已声明”的守卫，通过后清空全部锁态标志；当前难度不存在时继续执行原判定。

完整音频的开局路径来自 `sub_10084DD38`，键为 `<id>`。此前使用 `<id>_` 的音频映射会导致 START 已显示但开局提示下载；v9 已更正。

## 构建与结果

构建启用 `local_content` BRK 组：资源查询 site `0x100844774`，replay `0x101468168`。文件核对和软链建立在正常启动上下文运行；SIGTRAP 处理器只读发布后的曲目表，不在处理器内读取文件或运行 Objective-C。

验证包：`Arcaea_7.0.255-xrc-local-content-v9-unsigned.ipa`，Bundle ID `guy.guy.guy`，显示名 `ArcaeaXRC`。IPA SHA-256：`2b7aa94c59a38361fd41a25f8eb9aac5295b4f052d38d005ab5261255a7f1084`。

歌曲资源和设备日志仅保存于本机，不作为插件源码的一部分。
