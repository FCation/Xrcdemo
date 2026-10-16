# 开发与验证说明

本文记录本 fork 针对 Arcaea iOS 7.0.255 的改动、可复现构建配置和已完成的设备验证。地址、原始指令和重放位置都针对 7.0.255；其他版本必须重新确认二进制指纹与调用语义。

## 变更导览

| 文件 | 内容 |
|---|---|
| `src/core/XRCHook.m` | 解锁与锁态处理、评级标志修正、完整导入曲目的资源就绪覆盖 |
| `src/content/XRCStore.m`、`XRCStore.h` | 外置 `cb` 目录迁移后重连、导入清单读取、哈希校验和原生资源路径映射 |
| `src/content/XRCNet.m`、`XRCNet.h` | 网络构建轴；默认发布配置继续阻断网络，可选编译配置保留官方原请求地址 |
| `src/core/XRCProfile.h` | 7.0.255 地址、原始指令证据、站点语义和重放策略 |
| `inject.py` | 主程序补丁站点、重放跳板与按功能选择的注入配置 |
| `Makefile` | Theos 构建选项与默认值 |

`inject.py` 中 v9 已验证的功能组合为：

```text
unlock_own,unlock_lock,chain_guard,unlock_all,dl_ready,local_content,autoplay
```

其中 `local_content` 默认属于开发功能，必须显式加入；`download_diag` 包含对下载弹窗第二道门的定向放行，属于实验诊断功能，不在 v9 已验证组合内。CI 的 push 构建使用 dev profile，可能包含额外调试站点；发布工作流的手动 release 选项才设置 `XRC_DEBUG=0`。复现设备验证时应使用上面的显式列表，而非全量 profile。

## 构建与注入

需要 Theos、iOS SDK、Python 3，以及与目标主程序配套的 `libellekit.dylib`。在源码根目录构建 arm64：

```sh
make clean
make DEBUG=1 XRC_DEBUG=0 XRC_ALLOW_OFFICIAL_NET=1 ARCHS=arm64
```

`XRC_ALLOW_OFFICIAL_NET=1` 只保留游戏原始请求地址并关闭私服重定向；它不保证服务端可达或资源下载成功。默认值为 `0`，发布配置的网络行为仍是阻断请求。需要发布默认网络行为时可省略该变量。

将生成的 dylib 与匹配的 `libellekit.dylib` 放到 `ios/Payload/Arc-mobile.app/Frameworks/`，然后在仓库根目录运行：

```sh
python inject.py --stub --brk --features unlock_own,unlock_lock,chain_guard,unlock_all,dl_ready,local_content,autoplay
python inject.py --check ios/Payload/Arc-mobile.app/Arc-mobile
```

检查 `xrc_patch_manifest.json` 中的目标版本、功能列表、BRK 站点与 dylib 哈希；之后由设备所有者使用自己的签名工具重签和侧载。IPA 签名不属于本仓库的自动构建步骤。跨版本适配前，先在原始二进制上核实 `src/core/XRCProfile.h` 的期望字节、函数语义和 replay 地址，再同步维护 `inject.py` 与 handler 表。

## 关键修正

### 难度评级与锁态

`sub_100919E5C(song, selectedDifficulty)` 返回当前所选难度的锁态及显示标志；返回结构中的字节不是五个难度各自的槽位。旧处理把不存在的 BYD 难度写成 bit 24，选曲详情页又用这个标志隐藏评级，因此其他已声明难度也显示为 `?`。现在 `unlock_all` 保留“所选难度已在 songlist 声明”的检查，只在该难度存在时清除锁态标志；未声明的难度仍沿原流程处理。

`unlock_all` 的锁态、可玩性、条件判断和锁绘钩子是不同的主程序站点。保持这些站点按各自语义工作，可避免把 Divine Oblivion 的特殊锁绘错误传播到其他歌曲。

### 下载状态与本地文件

显示下载按钮的状态和实际能否开局是两条路径。默认未导入曲目继续走原版下载判断；完整导入并通过清单校验的曲目才由 `local_content` 对本地资源状态查询返回就绪。歌曲音频的原生键是 `<id>`，难度谱面的键是 `<id>_<difficulty>`。详见[本地内容说明](LOCAL_CONTENT.md)。

### `cb` 外置目录重连

侧载覆盖可能更换应用容器 UUID。启动时 `XRCStore` 检查 `Documents/cb` 的外置目标并重建当前容器内的链接，避免容器迁移后找不到已有内容。此处理不导入新曲目，也不代表任意修改过的 `meta.cb`、`songlist` 或资源树都可用。

## 验证记录与边界

| 项目 | 结果 |
|---|---|
| Theos `arm64` 编译 | 成功；构建参数见上文 |
| IPA 检查与注入 | 使用 7.0.255 主程序与显式 v9 功能列表 |
| 设备侧载后启动 | 用户报告可进入歌曲界面 |
| Acid God 完整本地资源导入 | 真机上显示评级 PST 4、PRS 7+、FTR 9+、ETR 10+；Start 可进入游玩 |
| 其他歌曲及全量曲库 | 未验证；没有批量导入曲库 |
| 特殊音频、额外依赖资源或不同目录布局 | 未验证；当前导入器按 `base.ogg` 与已声明 `.aff` 文件设计 |
| 官方服务器下载 | 未验证为可用；此前设备下载尝试失败，网络构建轴只切换客户端编译行为 |
| arm64e 设备行为 | 未作为 v9 设备验证目标 |

单曲测试不代表所有包、曲目和设备状态均正常。资源文件与个人设备日志不纳入仓库。调试日志可能包含本地环境信息，分享前应自行检查并脱敏。

## 配置参考

- `XRC_DEBUG=1`：默认本地开发构建，包含诊断功能与 DEBUG 日志；`0` 为精简构建。
- `XRC_ALLOW_OFFICIAL_NET=0`：默认网络隔离行为；设为 `1` 保留原请求地址，不改写到私服。
- `inject.py --features ...`：显式指定主程序 BRK 功能集；显式列表会取代 profile 默认选择。
- `local_content`：默认关闭的本地内容映射功能，只有核验成功的清单条目才可返回本地就绪。
- `download_diag`：实验诊断功能，包含下载门定向改写；不要把它当作通用下载修复。
