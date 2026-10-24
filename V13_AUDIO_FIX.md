# v13 难度差分音频修复

源码基线：2026-10-20 的 `1fd6816`（v13）。本次变更限定为 `audioOverride` 差分音频的导入与原生路径映射。`XRCHook.m`、解锁判断、练习循环、UI、网络、视频占位逻辑均使用该提交的原始内容；没有包含 UIP 集成。

当 `songlist.difficulties[].audioOverride` 为 true 时，对应难度使用 `<难度>.ogg`。例如两首 BYD 需要 `3.aff` 和真实的 `3.ogg`，其余难度仍使用 `base.ogg`。原生路径分别是：

| 文件 | 原生路径 |
|---|---|
| `base.ogg` | `Documents/dl/<id>` |
| `3.aff` | `Documents/dl/<id>_3` |
| `3.ogg` | `Documents/dl/<id>_audio_3` |

修复后的导入工具从目录和 ZIP 中收录 songlist 声明的差分音频，并验证 Ogg 文件头、大小及 SHA-256。插件在 v13 原有校验链中核对这些文件并创建正确映射，其他校验和解锁策略保持 v13 行为。旧暂存目录需要用原始资源重新 prepare；完整音频不能用 base.ogg 或静音占位替代。

本机已补齐 8 首真实差分音频：`pragmatism`、`ignotus`、`axiumcrisis`、`redandblue`、`singularity`、`dropdead`、`viciousheroism`、`last`。IPA 直接基于 10 月 20 日的 v13 完整包，仅替换插件、更新歌曲清单并加入这 8 个文件；主程序及其余原有文件不变。

构建标识：`v13-audio-only-20261024`。本机检查包括 arm64 编译、目录与 ZIP 导入、差分音频缺失拒绝检查、与 v13 的逐文件包内容对比。实机 BYD 解锁与播放结果待用户确认。
