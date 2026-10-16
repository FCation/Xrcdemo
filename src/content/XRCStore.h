// © 雾月星辰 & MLXC · github@XingChenRS
// XRCStore.h — 存储外置：把游戏的 cb 内容根搬进 Documents（数据容器内软链，免 root / 免越狱）。
//
// 事实基础（静态 + 设备实测）：
//   · 游戏所有资源读取都走 cocos2d FileUtils 的搜索表；搜索表里 **<cbRoot>/cb/active**
//     被游戏自己插在**最前面**（sub_100F43128 → addSearchPath(path, front=true)），
//     是"同名文件覆盖包内资源"的官方通道（cb/active/img/bg/*.png 即由此覆盖）。
//   · cbRoot 默认 = Library/Application Support（store+0xB8 字段为空时的回退）。
//   · 免越狱下只有 **Documents** 能被「文件」App / 电脑看到（UIFileSharingEnabled）。
//  ⇒ 把 cb 搬到 Documents == 把"内容覆盖层 + 下载落点"变成外部可管理，
//     这是免越狱自用（换谱面/改资源/丢曲包）的唯一现实通道。
//
// 选软链的理由：
//   ① 覆盖所有读 cb 的代码路径（含不走 store 的那些）；② 一次建好、每次启动都成立，
//   没有"必须在首次读取前写入"的时序依赖；③ 可逆（删链即恢复）。
// 免 root：软链建在 app **自己的数据容器**里，容器内建链/改名对 app 本身合法。
#pragma once

#import <Foundation/Foundation.h>

// 首次启动迁移（幂等）。三种情况都收敛到"AppSupport/cb 变成指向 Documents/cb 的软链"：
//   · 全新安装（无 cb）      → 建 Documents/cb 占位 + 软链（此后下载直接落在 Documents）
//   · 已有 cb（真目录）      → 同卷 rename（瞬时、零拷贝）→ 软链
//   · 两处都有              → 浅层合并（保留 Documents 侧同名）→ 软链
// 返回：0 = 本次完成迁移；1 = 已是外置态（跳过）；-1 = 失败（保持原状，日志有原因）。
int xrc_store_install(void);
void xrc_store_prepare_local_content(void);

// 状态查询（面板 / 诊断行）
BOOL      xrc_store_cb_external(void);   // cb 根当前是否已落在 Documents（软链且指向正确）
NSString *xrc_store_cb_status(void);     // 一句话状态（含实际落点或异常说明）
