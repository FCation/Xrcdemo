// © 雾月星辰 & MLXC · github@XingChenRS
// XRCConfig.h — 配置 plist 读写 + judge 参数。
#pragma once

#import <Foundation/Foundation.h>

typedef struct {
    float     speeds[16];   // speed_keys 的值拷贝（不复用 plist 内对象，避免悬垂）
    NSInteger speed_count;
    NSInteger rate_index;
    BOOL      button_enabled;
    BOOL      toast;
    int       judge_max_ms;
    int       judge_pure_ms;
    int       judge_far_ms;
    int       judge_lost_ms;
    // ---- 私服接入（XRCNet）----
    BOOL      net_enabled;  // 是否改写 API 请求指向自有服务端
    NSString *net_base;     // 目标 base，如 http://192.168.1.10:8080
    NSString *net_match;    // 需改写的 host（逗号分隔）；空 = 内置默认
    // ---- 开关组（功能账 §1）----
    BOOL      unlock_own;   // 拥有链三层（unlock_l1/l2/l3）。归属由 cb 的
                            //   songlist/packlist/unlocks 三清单 + 服务器 /user/me 授予决定；
                            //   本项覆盖"未授予但本地有内容"的情形。默认关。
    BOOL      unlock_fv;    // FV 五曲 fast path → 五难度全解
    BOOL      unlock_do;    // DO(konzetsu) 分支 → 五难度全解
    BOOL      gate_open;    // 终章链门：1 = 放行（决定整表是否解锁）
    BOOL      unlock_all;   // 全条件放行：锁态总源/可玩性总源/难度条件恒真（本地有谱面即可见可玩；
                            //   另与 unlock_do 联动旁路 arghena 专属锁绘）。默认关。
    BOOL      dl_ready;     // 历史配置项；当前构建不启用下载谓词覆盖，保留字段兼容旧 plist。
    // ---- cb 验证链开关（功能账 §3）----
    BOOL      cb_bypass;    // 开（默认）：cb 自由化——校验结论恒通过（文件/三表比对恒等）+ 清树直返
                            //   + 就绪恒真 + 更新错码分发直返 + 内容更新强制门/远端更新指令直返
                            //   （后者覆盖"本机无 meta.cb、手动填充内容包"：版本/更新层不再拒绝加载）。
                            //   离线自用（改谱面/删文件不被清树）的前提。关：完全恢复原校验行为。
    // ---- 存储外置（XRCStore；免越狱通道）----
    BOOL      external_cb;  // 开（默认）：启动时把 cb 内容根从 Library/Application Support 搬到
                            //   Documents/cb（数据容器内软链，免 root）。之后 cb/active 覆盖层
                            //   与 cb 下载都物理落在 Documents，可由「文件」App/电脑直接管理。
                            //   关：不做任何迁移（已建好的软链不会自动撤销）。
    // ---- 音乐变速（XRCAudio）----
    BOOL      speed_audio;  // 开（默认）：BGM 跟着游戏速度走且**保持音高**（FMOD 内置移调 DSP 补偿）。
                            //   关：只 warp 谱面时钟（速度快时音画会逐渐错开）。
    // ---- 自动演奏（功能账 §5）----
    BOOL      autoplay;     // 开（默认关）：一切判定强制 Pure（含漏扫 ts=-1 直调）
    // ---- 回跳重播（XRCReplay）----
    BOOL      replay_arm;   // 开：回跳到已游玩并判定过的段落时支持重新游玩并清空分数记录（默认关）
    BOOL      stubs_lite;   // 开：观测桩轻量模式（开发构建专用；发布构建恒空操作）
    // ---- 日志（见 XRCLog.h）----
    int       log_level;    // 0=err 1=warn 2=info(默认) 3=debug（含采集落盘）
    int       log_cats;     // 类别位掩码（XRCLC_* 见 XRCLog.h）；0 = 全部
} xrc_config_t;

NSString *xrc_config_path(void);
void xrc_config_load(xrc_config_t *out);
void xrc_config_save(const xrc_config_t *c);

// 从 plist 原样读/写单键（菜单热更新用）。
NSMutableDictionary *xrc_config_dict(void);
void xrc_config_write_dict(NSDictionary *d);

void xrc_config_normalize_judge(xrc_config_t *c);

// 练习面板速度滑杆：写回当前 rateIndex 对应的预设键（与悬浮球长按切速同源）。
void xrc_config_set_current_speed(float v);
