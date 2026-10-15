// © 雾月星辰 & MLXC · github@XingChenRS
// XRCNet.m — 私服重定向与请求日志实现。
//
// 为什么在 NSURLConnection 层做：游戏的 HttpAsynConnection 最终都走
// -[NSURLConnection initWithRequest:delegate:startImmediately:]；在这里改写 URL
// 能一次覆盖所有 API（成绩、auth、cb 下载、applog…），且完全不碰 TLS 栈——
// 换域后 TrustKit 因域名不在 pin 表而返回 DomainNotPinned，证书由系统正常校验。
//
// 注意：不改 scheme/host 之外的任何东西。path 与 query 原样保留，服务端因此
// 能看到真实端点（含 /coordinatedballetclock/42/ 前缀），便于对照与日志。
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include <stdatomic.h>
#include <string.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/select.h>

#include "XRCNet.h"
#include "XRCProfile.h"
#import "XRCLog.h"

static _Atomic(bool) s_enabled = false;

// ---- 发布构建：联网阻断（编译期锁死，规则单一出处 = XRCNet.h 文件头）----
// 全部 http(s) 请求的主域名重写到 RFC 2606 保留域 `.invalid`：DNS 必然 NXDOMAIN、
// 立即失败、不出网包（比黑洞 IP 挂到超时干净）。无开关、配置改不回来。
#define XRC_NET_BLOCK_HOST  "xrcdemo-blocked.invalid"
static bool s_should_rewrite(void) {
#if XRC_ALLOW_OFFICIAL_NET
    return false;                      /* 此侧载构建：保留游戏原始请求地址 */
#elif !XRC_DEBUG_BUILD
    return true;                       /* 发布构建恒阻断 */
#else
    return atomic_load(&s_enabled);    /* 开发构建：显式开启才改写（私服） */
#endif
}
static _Atomic(unsigned long long) s_requests = 0;
static _Atomic(unsigned long long) s_rewritten = 0;

// ---------------- 诊断：进程内裸 socket 直连 ----------------
// NSURLConnection 报 -1009（瞬间失败）时，用它区分两种根因：
//   socket 也连不上 → App 沙盒/权限/路由层面就出不去（local network / VPN / 无路由）
//   socket 能连上   → 问题在 URL 加载层（ATS 决策 / 连接配置）
static void s_diag_socket(NSString *host, NSInteger port) {
    if (!host.length || port <= 0) return;
    bool ok = false;
    char why[96] = "unknown";
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%ld", (long)port);
    int gai = getaddrinfo(host.UTF8String, portstr, &hints, &res);
    if (gai != 0 || !res) {
        xrc_logd(XRCLC_NET, @"[net-diag] getaddrinfo(%@:%ld) failed: %s", host, (long)port, gai_strerror(gai));
        xrc_logw(XRCLC_NET, @"[net-diag] %@:%ld 不可达（域名解析失败）", host, (long)port);
        return;
    }
    int fd = socket(res->ai_family, res->ai_socktype, 0);
    if (fd < 0) {
        xrc_logd(XRCLC_NET, @"[net-diag] socket() failed errno=%d(%s)", errno, strerror(errno));
        freeaddrinfo(res); return;
    }
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    int r = connect(fd, res->ai_addr, res->ai_addrlen);
    int e = errno;
    if (r == 0) {
        ok = true;
        xrc_logd(XRCLC_NET, @"[net-diag] socket connect to %@:%ld OK (immediate)", host, (long)port);
    } else if (e == EINPROGRESS) {
        fd_set w; FD_ZERO(&w); FD_SET(fd, &w);
        struct timeval tv = {5, 0};
        int sel = select(fd + 1, NULL, &w, NULL, &tv);
        if (sel > 0) {
            int soerr = 0; socklen_t sl = sizeof(soerr);
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl);
            if (soerr == 0) { ok = true; xrc_logd(XRCLC_NET, @"[net-diag] socket connect to %@:%ld OK", host, (long)port); }
            else {
                xrc_logd(XRCLC_NET, @"[net-diag] socket connect to %@:%ld FAILED so_error=%d(%s)",
                         host, (long)port, soerr, strerror(soerr));
                snprintf(why, sizeof(why), "连接失败 so_error=%d", soerr);
            }
        } else if (sel == 0) {
            xrc_logd(XRCLC_NET, @"[net-diag] socket connect to %@:%ld TIMEOUT", host, (long)port);
            snprintf(why, sizeof(why), "连接超时");
        } else {
            xrc_logd(XRCLC_NET, @"[net-diag] select failed errno=%d(%s)", errno, strerror(errno));
            snprintf(why, sizeof(why), "select errno=%d", errno);
        }
    } else {
        xrc_logd(XRCLC_NET, @"[net-diag] socket connect to %@:%ld failed errno=%d(%s)",
                host, (long)port, e, strerror(e));
        snprintf(why, sizeof(why), "连接失败 errno=%d", e);
    }
    close(fd);
    freeaddrinfo(res);
    if (ok) xrc_logd(XRCLC_NET, @"[net-diag] %@:%ld 可达", host, (long)port);
    else    xrc_logw(XRCLC_NET, @"[net-diag] %@:%ld 不可达（%s）", host, (long)port, why);
}

static NSString *s_base = nil;      // 目标 base，如 http://192.168.1.10:8080
static NSArray<NSString *> *s_match = nil;   // 需要改写的 host 列表

static IMP s_orig_init = NULL;

static NSArray<NSString *> *s_default_match(void) {
    // 默认改写名单集中在 XRCProfile.h（跨版本单一编辑点）
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *h in [@(XRC_NET_DEFAULT_MATCH) componentsSeparatedByString:@","]) {
        NSString *t = [h stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [a addObject:t];
    }
    return a.count ? a : @[ @"arcapi-v4.lowiro.com" ];
}

// 可达性自检派发：仅在「私服已启用 且 base 有效」时执行（后台线程，不阻塞启动）。
static void s_diag_dispatch(void) {
    if (!s_base || !atomic_load(&s_enabled)) return;
    NSURLComponents *c = [NSURLComponents componentsWithString:s_base];
    NSString *h = c.host;
    NSNumber *p = c.port ?: (NSNumber *)@([c.scheme isEqualToString:@"https"] ? 443 : 80);
    if (!h || p.integerValue <= 0) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        s_diag_socket(h, p.integerValue);
    });
}

void xrc_net_set_enabled(bool on) {
#if !XRC_DEBUG_BUILD
    /* 发布构建：联网阻断恒开、私服能力不存在——外部设置一律忽略（编译期锁死）。
       规则单一出处 = XRCNet.h 文件头。 */
    (void)on;
    return;
#endif
    bool was = atomic_exchange(&s_enabled, on);
    if (on && !was) s_diag_dispatch();   // 开启瞬间做一次自检
}
bool xrc_net_enabled(void) { return atomic_load(&s_enabled); }

void xrc_net_set_base(const char *base) {
    s_base = (base && *base) ? @(base) : nil;
    xrc_logd(XRCLC_NET, @"[net] base = %@", s_base ?: @"(none)");
    s_diag_dispatch();   // 正常启动顺序为 base → enabled；此处覆盖“先 base 后 enabled”的补检
}

void xrc_net_set_match(const char *hosts) {
    if (hosts && *hosts) {
        NSMutableArray *a = [NSMutableArray array];
        for (NSString *h in [@(hosts) componentsSeparatedByString:@","]) {
            NSString *t = [h stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]];
            if (t.length) [a addObject:t];
        }
        s_match = a.count ? a : s_default_match();
    } else {
        s_match = s_default_match();
    }
}

unsigned long long xrc_net_requests(void) { return atomic_load(&s_requests); }
unsigned long long xrc_net_rewritten(void) { return atomic_load(&s_rewritten); }

// 改写 scheme/host/port，保留 path/query/fragment
static NSURL *s_rewrite(NSURL *url) {
#if XRC_ALLOW_OFFICIAL_NET
    (void)url;
    return nil;
#elif !XRC_DEBUG_BUILD
    /* 发布构建：联网阻断——任何 http(s) 一律改写到保留域（本地资源不经本栈） */
    if (!url || !url.host) return nil;
    NSString *sch = url.scheme.lowercaseString;
    if (![sch isEqualToString:@"http"] && ![sch isEqualToString:@"https"]) return nil;
    NSURLComponents *b = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    b.scheme = @"http";
    b.host = @(XRC_NET_BLOCK_HOST);
    b.port = nil;
    return b.URL;
#else
    if (!s_base || !url) return nil;
    NSString *host = url.host;
    if (!host) return nil;
    BOOL matched = NO;
    for (NSString *h in s_match) {
        if ([host caseInsensitiveCompare:h] == NSOrderedSame) { matched = YES; break; }
    }
    if (!matched) return nil;

    NSURLComponents *base = [NSURLComponents componentsWithString:s_base];
    if (!base.scheme || !base.host) return nil;
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    c.scheme = base.scheme;
    c.host = base.host;
    c.port = base.port;
    return c.URL;
#endif
}

static void s_log_request(NSURLRequest *req) {
    NSString *method = req.HTTPMethod ?: @"GET";
    NSUInteger bodyLen = req.HTTPBody.length;
    NSDictionary *hdrs = req.allHTTPHeaderFields;
    xrc_logd(XRCLC_NET, @"[net] %@ %@ (body=%lu, hdrs=%lu)",
            method, req.URL.absoluteString, (unsigned long)bodyLen,
            (unsigned long)hdrs.count);
}

// -[NSURLConnection initWithRequest:delegate:startImmediately:]
static id s_init_with_request(id self, SEL _cmd, NSURLRequest *req, id delegate, BOOL start) {
    atomic_fetch_add(&s_requests, 1);
    if (req) {
        @try {
            if (s_should_rewrite()) {
                NSURL *nu = s_rewrite(req.URL);
                if (nu) {
                    NSMutableURLRequest *m = [req mutableCopy];
                    m.URL = nu;
                    req = m;
                    atomic_fetch_add(&s_rewritten, 1);
                }
            }
            s_log_request(req);
        } @catch (NSException *e) {
            xrc_logd(XRCLC_NET, @"[net] EX: %@", e);
        }
    }
    return ((id (*)(id, SEL, NSURLRequest *, id, BOOL))s_orig_init)(self, _cmd, req, delegate, start);
}

// 结果观测：委托类是游戏的 HttpAsynConnection。只记录、原样转发，不改行为。
// 目的：区分"请求没发出去"（ATS/连接层拦截）与"发出去了但服务端没响应"。
static IMP s_orig_fail = NULL;
static IMP s_orig_resp = NULL;
static IMP s_orig_data = NULL;    // -[HttpAsynConnection connection:didReceiveData:]
static IMP s_orig_dt = NULL;      // -[NSURLSession dataTaskWithRequest:]
static IMP s_orig_dtu = NULL;     // -[NSURLSession dataTaskWithURL:]
static IMP s_orig_async = NULL;   // +[NSURLConnection sendAsynchronousRequest:queue:completionHandler:]
static _Atomic(bool) s_diag_done_on_fail = false;

static void s_hook_fail(id self_, SEL _cmd, NSURLConnection *c, NSError *err) {
    @try {
        xrc_logw(XRCLC_NET, @"[net] ✗ FAILED %@ — %@ (%ld)",
                c.originalRequest.URL.path, err.localizedDescription, (long)err.code);
        // 首次失败时补一次进程内直连自检：那一刻的网络栈状态最能说明问题
        bool expect = false;
        if (s_base && atomic_load(&s_enabled) && atomic_compare_exchange_strong(&s_diag_done_on_fail, &expect, true)) {
            NSURLComponents *u = [NSURLComponents componentsWithString:s_base];
            NSString *h = u.host;
            NSInteger p = u.port ? u.port.integerValue
                                 : ([u.scheme isEqualToString:@"https"] ? 443 : 80);
            if (h) {
                // 同时报一下错误对象里的失败 URL 主机，便于对照
                xrc_logd(XRCLC_NET, @"[net-diag] on-fail probe: base=%@:%ld failedURL=%@",
                        h, (long)p, c.originalRequest.URL.absoluteString);
                s_diag_socket(h, p);
            }
        }
    } @catch (NSException *e) {}
    if (s_orig_fail) ((void (*)(id, SEL, NSURLConnection *, NSError *))s_orig_fail)(self_, _cmd, c, err);
}

static void s_hook_resp(id self_, SEL _cmd, NSURLConnection *c, NSURLResponse *r) {
    @try {
        NSInteger code = [(NSHTTPURLResponse *)r statusCode];
        xrc_logd(XRCLC_NET, @"[net] ← %ld %@", (long)code, c.originalRequest.URL.path);
    } @catch (NSException *e) {}
    if (s_orig_resp) ((void (*)(id, SEL, NSURLConnection *, NSURLResponse *))s_orig_resp)(self_, _cmd, c, r);
}

// ---- 响应体转储：只看清单/下载类路径，最多 3000 B，只记首个数据块 ----
// 目的：回答"对方服务器 ?url=true 的清单里到底有没有文件 URL"——客户端不发起下载时，
// 这是唯一能从设备侧看到的证据。
static void s_hook_data(id self_, SEL _cmd, NSURLConnection *c, NSData *data) {
    @try {
        static NSString *s_lastPath = nil;
        NSString *path = c.originalRequest.URL.path ?: @"";
        if (data.length && ![path isEqualToString:s_lastPath]) {
            if ([path containsString:@"serve/download"] || [path containsString:@"/download/"]) {
                s_lastPath = [path copy];
                NSUInteger n = MIN(data.length, (NSUInteger)3000);
                NSString *body = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, n)]
                                                       encoding:NSUTF8StringEncoding];
                if (!body) body = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, n)]
                                                        encoding:NSISOLatin1StringEncoding];
                xrc_logd(XRCLC_NET, @"[net-body] %@ (%lu B 中的前 %lu B): %@",
                        path, (unsigned long)data.length, (unsigned long)n, body ?: @"<binary>");
            }
        }
    } @catch (NSException *e) {}
    if (s_orig_data) ((void (*)(id, SEL, NSURLConnection *, NSData *))s_orig_data)(self_, _cmd, c, data);
}

// ---- 另两条 HTTP 栈的探针 ----
// 事实：清单请求走 NSURLConnection（有 [net] 日志），但**下载文件时一个请求都没有**——
// 要么客户端根本没发起下载，要么发起时走的是别条栈（NSURLSession / 异步连接）。
// 这里把这两条也记上：命中即证明"下载走的是它"，也顺手做同样的白名单改写。
static void s_log_any_url(NSURLRequest *req, const char *tag) {
    @try {
        if (!req.URL) return;
        NSString *h = req.URL.host ?: @"";
        // 过滤遥测/第三方栈（Firebase/Crashlytics/Google 走的就是 NSURLSession，避免刷屏）
        if ([h containsString:@"googleapis"] || [h containsString:@"firebase"] ||
            [h containsString:@"crashlytics"] || [h containsString:@"gstatic"] ||
            [h containsString:@"doubleclick"]) return;
        xrc_logd(XRCLC_NET, @"[net:%s] %@ %@", tag, req.HTTPMethod ?: @"GET", req.URL.absoluteString);
    } @catch (NSException *e) {}
}

static id s_nsurlsession_task(id self_, SEL _cmd, NSURLRequest *req) {
    if (req && s_should_rewrite()) {
        NSURL *nu = s_rewrite(req.URL);
        if (nu) {
            NSMutableURLRequest *m = [req mutableCopy];
            m.URL = nu;
            s_log_any_url(m, "session");
            @try {
                return ((id (*)(id, SEL, NSURLRequest *))s_orig_dt)(self_, _cmd, m);
            } @catch (NSException *e) {
                // 注意：这里记日志 + 原样抛出（不能吞掉异常后再用未改写的 req 重试——
                // 改写会静默失效且可能重复建任务）。
                xrc_logd(XRCLC_NET, @"[net] session dataTask EX: %@", e);
                @throw;
            }
        }
    }
    s_log_any_url(req, "session");
    return ((id (*)(id, SEL, NSURLRequest *))s_orig_dt)(self_, _cmd, req);
}

static id s_nsurlsession_task_url(id self_, SEL _cmd, NSURL *url) {
    s_log_any_url([NSURLRequest requestWithURL:url], "session");
    return ((id (*)(id, SEL, NSURL *))s_orig_dtu)(self_, _cmd, url);
}

static void s_nsurlconnection_async(id self_, SEL _cmd, NSURLRequest *req, NSOperationQueue *q, id h) {
    s_log_any_url(req, "async");
    if (s_orig_async) ((void (*)(id, SEL, NSURLRequest *, NSOperationQueue *, id))s_orig_async)(self_, _cmd, req, q, h);
}

// ---------------- cocos2d-x 下载栈 ----------------
// 事实（静态实证）：
//   · 游戏内"下载曲目"不走 NSURLConnection；走 cocos2d-x 的 Downloader：
//     -[DownloaderAppleImpl createFileTask:]/[createDataTask:] → NSURLSession 任务。
//   · NSURLSession 的 dataTask* 不覆盖下载栈（实测命中 0）——下载观测必须挂
//     downloadTask* 与 DownloaderAppleImpl 本身。
//   · DownloaderAppleImpl 的 18 个方法里没有 willPerformHTTPRedirection
//     ⇒ 下载的 302 由系统默认跟随。
// 观测范围：建任务（含 URL）/ 启动 / 完结（状态码 + 错误）；不改行为（白名单改写除外）。
static _Atomic(uint32_t) s_dl_created = 0;
static _Atomic(uint32_t) s_dl_done = 0;
uint32_t xrc_net_dl_created(void) { return atomic_load(&s_dl_created); }
uint32_t xrc_net_dl_done(void) { return atomic_load(&s_dl_done); }

static IMP s_orig_dlreq = NULL, s_orig_dlreqc = NULL, s_orig_dlurl = NULL, s_orig_dlurlc = NULL,
           s_orig_dlresume = NULL, s_orig_dtcreq = NULL, s_orig_dtcurl = NULL,
           s_orig_resume = NULL, s_orig_dlcomplete = NULL, s_orig_dlfinish = NULL,
           s_orig_cfile = NULL, s_orig_cdata = NULL, s_orig_dl_redirect = NULL;

// 下载请求也过一遍白名单改写（与 API 请求同源规则；未命中原样返回）
static NSURLRequest *s_rw_req(NSURLRequest *req) {
    if (!req || !s_should_rewrite()) return req;
    NSURL *nu = s_rewrite(req.URL);
    if (!nu) return req;
    NSMutableURLRequest *m = [req mutableCopy];
    m.URL = nu;
    xrc_logd(XRCLC_DL, @"[net:dl] rewritten → %@", nu.absoluteString);
    return m;
}

static id s_dl_req(id self_, SEL _cmd, NSURLRequest *req) {
    atomic_fetch_add(&s_dl_created, 1);
    NSURLRequest *r = s_rw_req(req);
    s_log_any_url(r, "dl");
    return ((id (*)(id, SEL, NSURLRequest *))s_orig_dlreq)(self_, _cmd, r);
}
static id s_dl_req_c(id self_, SEL _cmd, NSURLRequest *req, id h) {
    atomic_fetch_add(&s_dl_created, 1);
    NSURLRequest *r = s_rw_req(req);
    s_log_any_url(r, "dl");
    return ((id (*)(id, SEL, NSURLRequest *, id))s_orig_dlreqc)(self_, _cmd, r, h);
}
static id s_dl_url(id self_, SEL _cmd, NSURL *url) {
    atomic_fetch_add(&s_dl_created, 1);
    s_log_any_url([NSURLRequest requestWithURL:url], "dl");
    return ((id (*)(id, SEL, NSURL *))s_orig_dlurl)(self_, _cmd, url);
}
static id s_dl_url_c(id self_, SEL _cmd, NSURL *url, id h) {
    atomic_fetch_add(&s_dl_created, 1);
    s_log_any_url([NSURLRequest requestWithURL:url], "dl");
    return ((id (*)(id, SEL, NSURL *, id))s_orig_dlurlc)(self_, _cmd, url, h);
}
static id s_dl_resume(id self_, SEL _cmd, NSData *d) {
    atomic_fetch_add(&s_dl_created, 1);
    xrc_logd(XRCLC_DL, @"[net:dl] downloadTaskWithResumeData (%lu B)", (unsigned long)d.length);
    return ((id (*)(id, SEL, NSData *))s_orig_dlresume)(self_, _cmd, d);
}
static id s_dt_req_c(id self_, SEL _cmd, NSURLRequest *req, id h) {
    NSURLRequest *r = s_rw_req(req);
    s_log_any_url(r, "dl");
    return ((id (*)(id, SEL, NSURLRequest *, id))s_orig_dtcreq)(self_, _cmd, r, h);
}
static id s_dt_url_c(id self_, SEL _cmd, NSURL *url, id h) {
    s_log_any_url([NSURLRequest requestWithURL:url], "dl");
    return ((id (*)(id, SEL, NSURL *, id))s_orig_dtcurl)(self_, _cmd, url, h);
}
static void s_task_resume(id self_, SEL _cmd) {
    @try {
        if ([self_ isKindOfClass:[NSURLSessionTask class]])
            s_log_any_url([(NSURLSessionTask *)self_ originalRequest], "task");
    } @catch (NSException *e) { xrc_logd(XRCLC_DL, @"[net:dl] resume EX: %@", e); }
    if (s_orig_resume) ((void (*)(id, SEL))s_orig_resume)(self_, _cmd);
}
static void s_dl_complete(id self_, SEL _cmd, NSURLSession *sess, NSURLSessionTask *task, NSError *err) {
    atomic_fetch_add(&s_dl_done, 1);
    @try {
        NSHTTPURLResponse *r = (NSHTTPURLResponse *)task.response;
        NSString *fin = r.URL.absoluteString ?: task.currentRequest.URL.absoluteString;
        xrc_logd(XRCLC_DL, @"[net:dl] done %@ → final=%@ status=%ld bytes=%lld err=%@",
                task.originalRequest.URL.absoluteString, fin ?: @"(nil)", (long)r.statusCode,
                (long long)task.countOfBytesReceived,
                err ? [NSString stringWithFormat:@"%ld/%@", (long)err.code, err.localizedDescription]
                    : @"none");
    } @catch (NSException *e) { xrc_logd(XRCLC_DL, @"[net:dl] complete EX: %@", e); }
    if (s_orig_dlcomplete)
        ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))s_orig_dlcomplete)(self_, _cmd, sess, task, err);
}
static void s_dl_finish(id self_, SEL _cmd, NSURLSession *sess, NSURLSessionDownloadTask *task, NSURL *loc) {
    @try {
        NSHTTPURLResponse *r = (NSHTTPURLResponse *)task.response;
        xrc_logd(XRCLC_DL, @"[net:dl] file %@ → final=%@ status=%ld saved=%@",
                task.originalRequest.URL.absoluteString, r.URL.absoluteString ?: @"(nil)",
                (long)r.statusCode, loc.path);
    } @catch (NSException *e) { xrc_logd(XRCLC_DL, @"[net:dl] finish EX: %@", e); }
    if (s_orig_dlfinish)
        ((void (*)(id, SEL, NSURLSession *, NSURLSessionDownloadTask *, NSURL *))s_orig_dlfinish)(self_, _cmd, sess, task, loc);
}
static id s_cfile(id self_, SEL _cmd, void *taskref) {
    atomic_fetch_add(&s_dl_created, 1);
    xrc_logd(XRCLC_DL, @"[net:dl] cocos createFileTask（下载入口命中）");
    return ((id (*)(id, SEL, void *))s_orig_cfile)(self_, _cmd, taskref);
}
static id s_cdata(id self_, SEL _cmd, void *taskref) {
    xrc_logd(XRCLC_DL, @"[net:dl] cocos createDataTask（下载入口命中）");
    return ((id (*)(id, SEL, void *))s_orig_cdata)(self_, _cmd, taskref);
}

// 下载链的 302：DownloaderAppleImpl 未实现 willPerformHTTPRedirection，
// 系统默认"自动跟随"。这里补一个实现只为**看清链路**：打印跳转前后 URL，然后
// 照默认语义 `handler(request)` 放行（未命中白名单时 s_rw_req 原样返回，零副作用）。
static void s_dl_redirect(id self_, SEL _cmd, NSURLSession *sess, NSURLSessionTask *task,
                          NSHTTPURLResponse *resp, NSURLRequest *newReq,
                          void (^handler)(NSURLRequest *)) {
    @try {
        xrc_logd(XRCLC_DL, @"[net:dl] redirect %ld %@ → %@", (long)resp.statusCode,
                task.originalRequest.URL.absoluteString, newReq.URL.absoluteString);
    } @catch (NSException *e) { xrc_logd(XRCLC_DL, @"[net:dl] redirect EX: %@", e); }
    if (s_orig_dl_redirect) {
        ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSHTTPURLResponse *, NSURLRequest *,
                   void (^)(NSURLRequest *)))s_orig_dl_redirect)(self_, _cmd, sess, task, resp, newReq, handler);
    } else {
        handler(s_rw_req(newReq));
    }
}

static void s_install_download_stack(void) {
    Class sc = objc_getClass("NSURLSession");
    if (sc) {
        struct { const char *sel; IMP imp; IMP *slot; } t[] = {
            {"downloadTaskWithRequest:",                    (IMP)s_dl_req,      &s_orig_dlreq},
            {"downloadTaskWithRequest:completionHandler:",  (IMP)s_dl_req_c,    &s_orig_dlreqc},
            {"downloadTaskWithURL:",                        (IMP)s_dl_url,      &s_orig_dlurl},
            {"downloadTaskWithURL:completionHandler:",      (IMP)s_dl_url_c,    &s_orig_dlurlc},
            {"downloadTaskWithResumeData:",                 (IMP)s_dl_resume,   &s_orig_dlresume},
            {"dataTaskWithRequest:completionHandler:",      (IMP)s_dt_req_c,    &s_orig_dtcreq},
            {"dataTaskWithURL:completionHandler:",          (IMP)s_dt_url_c,    &s_orig_dtcurl},
        };
        int n = 0;
        for (unsigned i = 0; i < sizeof(t) / sizeof(t[0]); i++) {
            Method m = class_getInstanceMethod(sc, sel_registerName(t[i].sel));
            if (!m) continue;
            *t[i].slot = method_getImplementation(m);
            method_setImplementation(m, t[i].imp);
            n++;
        }
        xrc_logi(XRCLC_NET, @"[net] download stack: NSURLSession factories hooked %d/7", n);
    }
    Class tk = objc_getClass("NSURLSessionTask");
    if (tk) {
        Method m = class_getInstanceMethod(tk, @selector(resume));
        if (m) {
            s_orig_resume = method_getImplementation(m);
            method_setImplementation(m, (IMP)s_task_resume);
        }
        xrc_logi(XRCLC_NET, @"[net] download stack: task-resume hook=%d", s_orig_resume != NULL);
    }
    Class dl = objc_getClass("DownloaderAppleImpl");
    if (dl) {
        struct { const char *sel; const char *enc; IMP imp; IMP *slot; } t2[] = {
            {"createFileTask:", "@24@0:8^v16", (IMP)s_cfile, &s_orig_cfile},
            {"createDataTask:", "@24@0:8^v16", (IMP)s_cdata, &s_orig_cdata},
            {"URLSession:task:didCompleteWithError:", "v40@0:8@16@24@32", (IMP)s_dl_complete, &s_orig_dlcomplete},
            {"URLSession:downloadTask:didFinishDownloadingToURL:", "v40@0:8@16@24@32", (IMP)s_dl_finish, &s_orig_dlfinish},
            {"URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:",
             "v@:@@@@@?", (IMP)s_dl_redirect, &s_orig_dl_redirect},
        };
        int n = 0;
        for (unsigned i = 0; i < sizeof(t2) / sizeof(t2[0]); i++) {
            SEL s = sel_registerName(t2[i].sel);
            Method m = class_getInstanceMethod(dl, s);
            if (m && method_getImplementation(m) != t2[i].imp) {
                *t2[i].slot = method_getImplementation(m);
                method_setImplementation(m, t2[i].imp);
                n++;
            } else if (!m && class_addMethod(dl, s, t2[i].imp, t2[i].enc)) {
                n++;
            }
        }
        xrc_logi(XRCLC_NET, @"[net] download stack: DownloaderAppleImpl hooked %d/5", n);
    } else {
        xrc_logw(XRCLC_NET, @"[net] download stack: DownloaderAppleImpl absent（下载不可见）");
    }
}

static void s_swizzle_result_logging(void) {
    Class hc = objc_getClass("HttpAsynConnection");
    if (!hc) { xrc_logd(XRCLC_NET, @"[net] HttpAsynConnection absent (result logging off)"); return; }
    Method mf = class_getInstanceMethod(hc, @selector(connection:didFailWithError:));
    if (mf) {
        s_orig_fail = method_getImplementation(mf);
        method_setImplementation(mf, (IMP)s_hook_fail);
        xrc_logi(XRCLC_NET, @"[net] result logging: didFailWithError hooked");
    } else {
        xrc_logd(XRCLC_NET, @"[net] didFailWithError absent, skip");
    }
    Method mr = class_getInstanceMethod(hc, @selector(connection:didReceiveResponse:));
    if (mr) {
        s_orig_resp = method_getImplementation(mr);
        method_setImplementation(mr, (IMP)s_hook_resp);
    }
    Method md = class_getInstanceMethod(hc, @selector(connection:didReceiveData:));
    if (md) {
        s_orig_data = method_getImplementation(md);
        method_setImplementation(md, (IMP)s_hook_data);
        xrc_logi(XRCLC_NET, @"[net] body dump: didReceiveData hooked");
    }
}

// 另两条栈的探针（NSURLSession 的两种 task + 异步连接）
static void s_install_other_stacks(void) {
    Class scls = objc_getClass("NSURLSession");
    if (scls) {
        Method m1 = class_getInstanceMethod(scls, @selector(dataTaskWithRequest:));
        if (m1) { s_orig_dt = method_getImplementation(m1); method_setImplementation(m1, (IMP)s_nsurlsession_task); }
        Method m2 = class_getInstanceMethod(scls, @selector(dataTaskWithURL:));
        if (m2) { s_orig_dtu = method_getImplementation(m2); method_setImplementation(m2, (IMP)s_nsurlsession_task_url); }
        xrc_logi(XRCLC_NET, @"[net] NSURLSession probes: dt=%d dtu=%d", s_orig_dt != NULL, s_orig_dtu != NULL);
    }
    Class ncls = objc_getClass("NSURLConnection");
    if (ncls) {
        Method m3 = class_getClassMethod(ncls, @selector(sendAsynchronousRequest:queue:completionHandler:));
        if (m3) { s_orig_async = method_getImplementation(m3); method_setImplementation(m3, (IMP)s_nsurlconnection_async); }
        xrc_logi(XRCLC_NET, @"[net] async connection probe=%d", s_orig_async != NULL);
    }
}

// ---------------- 302 / 重定向支持 ----------------
// 事实：`HttpAsynConnection` 未实现 `connection:willSendRequest:redirectResponse:`
//   （只有 didReceiveResponse / didFailWithError / willSendRequestForAuthenticationChallenge）
//   ⇒ NSURLConnection 遇到 302 时**自己在内部**按 Location 发起下一跳，新请求**不经过**
//   `initWithRequest:` 的改写 —— 这正是"服务器 302 到 CDN 后下载失败"的机制。
// 做法：用 `class_addMethod` 给该委托类**补上**这个回调，把系统提出的"下一跳请求"过一遍
//   `s_rewrite`；命中白名单就改写、否则**原样返回**（= 系统默认行为，零副作用）。
//   未命中白名单时额外打一行提示（点名该把哪个主机加进 netMatch），便于线上服务器排障。
static NSURLRequest *s_will_send(id self_, SEL _cmd, NSURLConnection *c,
                                 NSURLRequest *req, NSURLResponse *resp) {
    @try {
        if (req && s_should_rewrite()) {
            NSURL *nu = s_rewrite(req.URL);
            if (nu) {
                NSMutableURLRequest *m = [req mutableCopy];
                m.URL = nu;
                xrc_logd(XRCLC_NET, @"[net] 302 → %@ (host %@ → %@)",
                        req.URL.path, req.URL.host, nu.host);
                return m;
            }
            NSString *origHost = c.originalRequest.URL.host;
            if (req.URL.host && ![req.URL.host isEqualToString:origHost ?: @""]) {
                // 跨主机跳转才提示（同主机跳转是常态，不值得刷屏）
                xrc_logd(XRCLC_NET, @"[net] 302 → %@ host=%@ (orig=%@, 未改写)",
                        req.URL.path, req.URL.host, origHost ?: @"-");
            }
        }
    } @catch (NSException *e) {
        xrc_logd(XRCLC_NET, @"[net] redirect EX: %@", e);
    }
    return req;
}

static void s_install_redirect_hook(void) {
    Class hc = objc_getClass("HttpAsynConnection");
    if (!hc) { xrc_logd(XRCLC_NET, @"[net] HttpAsynConnection absent; redirect hook skipped"); return; }
    SEL rs = @selector(connection:willSendRequest:redirectResponse:);
    if (class_getInstanceMethod(hc, rs)) {
        xrc_logd(XRCLC_NET, @"[net] redirect hook: 已有实现，跳过（不改行为）");
        return;
    }
    BOOL ok = class_addMethod(hc, rs, (IMP)s_will_send, "@@:@@@");
    xrc_logi(XRCLC_NET, @"[net] redirect hook added=%d (302 跟跳将走同一套改写)", (int)ok);
}

void xrc_net_install(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s_match = s_default_match();
        Class cls = objc_getClass("NSURLConnection");
        if (!cls) { xrc_logd(XRCLC_NET, @"[net] NSURLConnection not found"); return; }
        SEL sel = @selector(initWithRequest:delegate:startImmediately:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { xrc_logd(XRCLC_NET, @"[net] method not found"); return; }
        s_orig_init = method_getImplementation(m);
        method_setImplementation(m, (IMP)s_init_with_request);
#if XRC_ALLOW_OFFICIAL_NET
        xrc_logi(XRCLC_NET, @"[net] installed（官方网络直连：请求地址保持原样）");
#elif !XRC_DEBUG_BUILD
        xrc_logi(XRCLC_NET, @"[net] installed（发布构建：联网阻断模式——全部 http(s) → *.%@）",
                 @(XRC_NET_BLOCK_HOST));
#else
        xrc_logi(XRCLC_NET, @"[net] installed (match=%@)", [s_match componentsJoinedByString:@","]);
#endif
        s_swizzle_result_logging();
        s_install_redirect_hook();
        s_install_other_stacks();
        s_install_download_stack();
    });
}
