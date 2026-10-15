// © 雾月星辰 & MLXC · github@XingChenRS
// XRCNet.h — 私服接入：把游戏 API 请求改指向自有服务端 + 全量请求日志。
//
// ⚠ 构建模式规则（本注释为单一出处，iOS / Android 通用，沿线沿用）：
//   · 发布构建（默认编译）**不包含私服功能**（面板「网络」页为阻断声明），且**主动阻断联网**：
//     所有 http(s) 请求的主域名重写到 RFC 2606 保留域 `xrcdemo-blocked.invalid`——
//     DNS 必然 NXDOMAIN、立即失败、不出网包；编译期锁死，无开关、配置改不回来。
//   · 为已有授权内容下载制作的侧载包可显式以 XRC_ALLOW_OFFICIAL_NET=1 构建；
//     此时请求保持游戏原地址，私服功能仍不可用。
//     配套：发布构建另有运行时可见水印（Tweak.x，防滥用威慑 + 泄漏溯源）。
//   · 只有编译时处于开发模式、且用户显式开启「私服」条目，才启用私服重定向；
//   · 私服内容的版权 / 数据处理 / 安全性由使用者自负；
//     本插件默认的练习能力不强制绑定私服。
//
// 设计依据（真机内存转储分析）：
//   · 游戏 API base = https://arcapi-v4.lowiro.com/coordinatedballetclock/42/<endpoint>
//     host 与端点之间还有一层 codename + 版本号，且该 codename 不存在于静态二进制。
//   · 游戏网络栈走 NSURLConnection（HttpAsynConnection 封装），不是 NSURLSession。
//   · pin 表按域名查询；换到自有域名后不在表内 → DomainNotPinned → 放行。
//
// 因此最小可行方案：**在 NSURLConnection 建连前改写 URL 的 scheme/host/port，
// 保留 path 与 query**。服务端因此能看到完整原始路径（含 codename），
// 对调试最有利；同时不碰任何 TLS/pin 逻辑。
#pragma once

#include <stdint.h>
#include <stdbool.h>

// 安装 hook（URL 改写 + 请求日志）。幂等。
void xrc_net_install(void);

// 运行期配置入口（面板/配置读取后调用）
void xrc_net_set_enabled(bool on);
void xrc_net_set_base(const char *base);     // 如 "http://192.168.1.10:8080"；空 = 不改写
void xrc_net_set_match(const char *hosts);   // 逗号分隔的需要改写的 host；空 = 用默认

bool   xrc_net_enabled(void);
// 统计
unsigned long long xrc_net_requests(void);
unsigned long long xrc_net_rewritten(void);
uint32_t xrc_net_dl_created(void);  // cocos 下载栈：建任务次数
uint32_t xrc_net_dl_done(void);     // cocos 下载栈：完结次数
