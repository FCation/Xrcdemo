// © 雾月星辰 & MLXC · github@XingChenRS
// XRCHook.h — BRK 桩：SIGTRAP 分发 + 重放跳板（见 XRCProfile.h 注释）
//
// 与 trampoline v2 的区别：不改函数入口结构，只把**任意一条**指令原地换成
// `BRK #0`（4 字节，长度不变）。dylib 的 SIGTRAP 处理器接住陷阱，跑完自有逻辑
// 后把 ucontext 的 PC 指向"重放跳板"（原指令 + B 回 site+4）。
#pragma once

#include <stdint.h>
#include <stdbool.h>

// 安装 SIGTRAP 处理器。幂等；尽早调用（%ctor 内），别等 doBootstrap——
// 桩点在注入时已写死，走不到处理器就会被前一个 SIGTRAP 处理器（Crashlytics
// / Swift 运行时）接管。
void xrc_brk_install(void);

// 注册桩点。site/replay 为运行时地址。handler 可空；若给出，在 PC 重定向**之前**
// 调用，且必须 async-signal-safe（本模块内部只用原子计数）。
// 返回 false = 表满或参数非法。
bool xrc_brk_register(uint64_t site_va, uint64_t replay_va,
                      void (*handler)(void *uctx));

// 按本版本 profile 装配全部桩点（安装处理器 + 注册）。
void xrc_brk_setup(uint64_t image_base);

// 静态补丁自检：把"主程序里哪些静态补丁在生效 + 副作用"写进启动日志——
// 每条静态补丁都要能在设备上自证。
void xrc_brk_static_report(uint64_t image_base);

// 本构建是否包含某功能（= 该功能的 BRK 站点是否真的注入了；对应 inject.py 的 FEATURES）。
// 面板据此只显示本构建含有的项；未登记的名字 / 自检未跑时返回 true（不隐藏）。
bool xrc_feature_present(const char *feature);

// 早期装配：在 %ctor 里调用（安装处理器 + 立即注册，主程序基址经 dyld 自取）。
// 注册与处理器安装必须同刻——启动极早期就命中的桩（如 cb 校验）等不到 didFinishLaunching。
void xrc_brk_setup_early(void);

// ---- 开关组（功能账 §1）----
// 置真后对应桩的 handler 强制 `x0=` 直返（直返语义见 XRCHook.m 注释）；
// 置假恢复原行为（重放跳板）。async-signal-safe：处理器只做原子读。
//   own  → unlock_l1/l2/l3（拥有链；归属由 cb 三清单 + 服务器授予决定，
//          本组覆盖"未授予但本地有内容"的情形）
//   fv   → lock_fv（FV 五曲 fast path → 五难度全解）
//   do   → lock_do（DO/konzetsu 分支）
//   gate → fv_gate（终章链门；1 = 放行，决定整表是否解锁）
//   all  → lock_all/play_gate/cond_unlock_*（全条件放行：锁态总源/可玩性总源/难度条件恒真，
//          另与 do 联动旁路锁绘族——本地有谱面即可见可玩、曲绘不显锁）
//   dl   → dl_play（下载"需动作"谓词恒 0：开局不转下载弹窗；文件存在性仍由开局链亲验）
void xrc_brk_set_unlock_own(bool on);
void xrc_brk_set_unlock_fv(bool on);
void xrc_brk_set_unlock_do(bool on);
void xrc_brk_set_gate_open(bool on);
void xrc_brk_set_unlock_all(bool on);
void xrc_brk_set_dl_ready(bool on);
bool xrc_brk_unlock_own(void);
bool xrc_brk_unlock_fv(void);
bool xrc_brk_unlock_do(void);
bool xrc_brk_gate_open(void);
bool xrc_brk_unlock_all(void);
bool xrc_brk_dl_ready(void);
void xrc_brk_download_diag_report(void); // 主线程定时器记录点击下载分流的快照
bool xrc_brk_local_content_add(const char *song_id, uint32_t difficulty_mask);

// ---- cb 验证链开关（功能账 §3）----
// 置真后：就绪位恒真、逐文件与三清单校验恒通过、清树直返（cb 自由化）。
void xrc_brk_set_cb_bypass(bool on);
bool xrc_brk_cb_bypass(void);

// 统计（异步写入，主线程读；供定时器落日志）
uint32_t    xrc_brk_hits(int slot_index);
int         xrc_brk_slot_count(void);
const char *xrc_brk_slot_name(int slot_index);
uint64_t    xrc_brk_last_hit_us(int slot_index);   // mach_absolute_time 微秒

// 未注册桩位自愈：本桩表不含、但主程序里残留的桩被就地还原的次数 / 最后一次的 pc-base。
// >0 ⇒ 主程序与当前桩表不一致，建议用 inject.py 重新注入。
int         xrc_brk_selfheal_count(void);
uint64_t    xrc_brk_selfheal_last_off(void);

// 曲目锁态覆盖命中计数（FV fast path / DO 分支入口直返全解锁的次数）。
uint32_t    xrc_brk_lock_hits(void);

// ---- 回跳重播配套（XRCReplay / 面板使用）----
void xrc_arc_stubs_lite_set(int on);   // 观测桩轻量模式（发布构建为空操作）
void xrc_arc_nohide_set(int on);       // 弧分段「藏→显」窗口开关（回跳窗口内）
void xrc_ap_latch_reset(void);         // autoplay「每音符一次」闩复位（回跳/换场景必清）

// ---- applog 明文捕获 ----
// 处理器在 applog 桩点处按 OnlineManager+0x128/+0x130 抓取**加密前**的明文到内部
// 缓冲（async-signal-safe：只做 memcpy + 原子写）。主线程用 take() 取走再落盘。
void     xrc_brk_capture_enable(bool on);
uint32_t xrc_brk_capture_seq(void);                 // 捕获序号（每次命中 +1）
// 有新捕获时拷进 buf（最多 cap 字节）返回实际长度；无新数据返回 0。
size_t   xrc_brk_capture_take(void *buf, size_t cap);

// ---- log_blob 密文捕获（第二个桩点：载荷加密出口）----
// **整帧捕获**（从 SP 起 XRC_APPLOG_BLOB_FRAME_LEN 字节），离线再搜。
// 与上面那份**分开缓冲**：入口抓的是明文，出口抓的是密文，两次命中相隔极近，
// 共用一个缓冲会互相覆盖。主线程分别 take() 落盘。
uint32_t xrc_brk_blob_seq(void);
size_t   xrc_brk_blob_take(void *buf, size_t cap);
uint64_t xrc_brk_blob_sp(void);     // 该次捕获对应的 SP（离线换算帧内绝对地址用）
