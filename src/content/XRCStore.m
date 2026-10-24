// © 雾月星辰 & MLXC · github@XingChenRS
// XRCStore.m — 外置实现。设计取舍见 XRCStore.h 顶部。
//
// 全程 POSIX（lstat/readlink/rename/symlink/rmdir），只有建目录与列目录用 NSFileManager：
// 软链判定必须用 lstat（stat 会跟链，把"已外置"误判成"是目录"）。

#import "XRCStore.h"
#include "XRCLog.h"
#include "XRCHook.h"
#include <CommonCrypto/CommonDigest.h>

#include <errno.h>
#include <limits.h>
#include <string.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static NSString *s_cb_in_support(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"]
            stringByAppendingPathComponent:@"cb"];
}

static NSString *s_cb_in_docs(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
            stringByAppendingPathComponent:@"cb"];
}

// 0 = 存在（*mode 有效）；-1 = 不存在或出错
static int s_lstat(const char *p, mode_t *mode) {
    struct stat st;
    if (!p || lstat(p, &st) != 0) return -1;
    if (mode) *mode = st.st_mode;
    return 0;
}

static NSString *s_symlink_target(const char *p) {
    char buf[PATH_MAX];
    ssize_t n = readlink(p, buf, sizeof(buf) - 1);
    if (n <= 0) return nil;
    buf[n] = '\0';
    return [NSString stringWithUTF8String:buf];
}

// 首次安装时先把包内基础 cb 放到 Documents，完成后才原子发布 cb 根。
// 已完成的单文件在临时目录中保留；首次启动中断时可以继续。
int xrc_store_seed_bundled_cb(void) {
    NSString *bundleCb = [[[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"XRCContent"]
                          stringByAppendingPathComponent:@"cb"];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:[bundleCb stringByAppendingPathComponent:@"meta.cb"]] ||
        ![fm fileExistsAtPath:[bundleCb stringByAppendingPathComponent:@"active/songs/songlist"]]) return 1;
    NSString *dest = s_cb_in_docs();
    mode_t mode = 0;
    if (s_lstat(dest.fileSystemRepresentation, &mode) == 0 ||
        s_lstat(s_cb_in_support().fileSystemRepresentation, &mode) == 0) return 1;

    NSString *staging = [dest stringByAppendingString:@".xrc-seed"];
    BOOL isDirectory = NO;
    if ([fm fileExistsAtPath:staging isDirectory:&isDirectory] && !isDirectory) return -1;
    NSError *err = nil;
    if (![fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:&err]) {
        xrc_loge(XRCLC_CB, @"[seed] 创建临时目录失败: %@", err);
        return -1;
    }
    NSUInteger copied = 0, reused = 0;
    for (NSString *relative in [fm enumeratorAtPath:bundleCb]) {
        NSString *src = [bundleCb stringByAppendingPathComponent:relative];
        NSString *dst = [staging stringByAppendingPathComponent:relative];
        BOOL srcDir = NO;
        if (![fm fileExistsAtPath:src isDirectory:&srcDir]) return -1;
        if (srcDir) {
            if (![fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:&err]) {
                xrc_loge(XRCLC_CB, @"[seed] 建目录失败 %@: %@", relative, err);
                return -1;
            }
            continue;
        }
        NSDictionary *sourceInfo = [fm attributesOfItemAtPath:src error:&err];
        NSDictionary *destInfo = [fm attributesOfItemAtPath:dst error:nil];
        if (!sourceInfo || ![sourceInfo[NSFileType] isEqual:NSFileTypeRegular]) return -1;
        if (destInfo && [destInfo[NSFileType] isEqual:NSFileTypeRegular] &&
            [destInfo[NSFileSize] unsignedLongLongValue] == [sourceInfo[NSFileSize] unsignedLongLongValue]) {
            chmod(dst.fileSystemRepresentation, 0644);
            reused++;
            continue;
        }
        NSString *partial = [dst stringByAppendingString:@".part"];
        [fm removeItemAtPath:partial error:nil];
        if (clonefile(src.fileSystemRepresentation, partial.fileSystemRepresentation, 0) != 0) {
            [fm removeItemAtPath:partial error:nil];
            if (![fm copyItemAtPath:src toPath:partial error:&err]) {
                xrc_loge(XRCLC_CB, @"[seed] 复制 %@ 失败: %@", relative, err);
                return -1;
            }
        }
        [fm removeItemAtPath:dst error:nil];
        if (rename(partial.fileSystemRepresentation, dst.fileSystemRepresentation) != 0) {
            xrc_loge(XRCLC_CB, @"[seed] 发布 %@ 失败: %s", relative, strerror(errno));
            return -1;
        }
        chmod(dst.fileSystemRepresentation, 0644);
        copied++;
    }
    if (![fm fileExistsAtPath:[staging stringByAppendingPathComponent:@"meta.cb"]] ||
        ![fm fileExistsAtPath:[staging stringByAppendingPathComponent:@"active/songs/songlist"]] ||
        rename(staging.fileSystemRepresentation, dest.fileSystemRepresentation) != 0) {
        xrc_loge(XRCLC_CB, @"[seed] cb 快照发布失败: %s", strerror(errno));
        return -1;
    }
    xrc_logi(XRCLC_CB, @"[seed] 包内基础 cb 已恢复到 Documents/cb（新复制 %lu，复用 %lu）",
             (unsigned long)copied, (unsigned long)reused);
    return 0;
}

// 浅层合并：把 src 里 dst 缺的条目搬过去，dst 已有的（同名）保留不动。
// cb 目录只有 meta.cb / active / tmp / rm 几个条目，浅层足够。
static void s_merge_into(NSString *src, NSString *dst) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:src error:nil];
    int moved = 0, kept = 0;
    for (NSString *name in names) {
        NSString *from = [src stringByAppendingPathComponent:name];
        NSString *to   = [dst stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:to]) { kept++; continue; }
        if (rename(from.fileSystemRepresentation, to.fileSystemRepresentation) == 0) {
            moved++;
        } else {
            kept++;
            xrc_logw(XRCLC_CB, @"[store] 合并：%@ 搬入失败 (%s)", name, strerror(errno));
        }
    }
    xrc_logi(XRCLC_CB, @"[store] 合并：搬入 %d 项，保留 Documents 侧同名 %d 项", moved, kept);
}

int xrc_store_install(void) {
    @autoreleasepool {
        NSString *src = s_cb_in_support();
        NSString *dst = s_cb_in_docs();
        const char *csrc = src.fileSystemRepresentation;
        const char *cdst = dst.fileSystemRepresentation;
        mode_t m = 0;

        // ① 已是软链：确认指向
        if (s_lstat(csrc, &m) == 0 && S_ISLNK(m)) {
            NSString *t = s_symlink_target(csrc);
            if ([t isEqualToString:dst]) {
                xrc_logi(XRCLC_CB, @"[store] cb 已外置 → %@", dst);
                return 1;
            }
            // 侧载更新可能迁移数据容器并保留旧目录内容。绝对软链仍指向旧 UUID，
            // 必须原子重建；否则游戏下载完后写 meta.cb 时 fopen 会失败。
            BOOL ours = [t containsString:@"/Containers/Data/Application/"] &&
                        [t hasSuffix:@"/Documents/cb"];
            if (ours) {
                if (s_lstat(cdst, &m) != 0) {
                    NSError *err = nil;
                    if (![[NSFileManager defaultManager] createDirectoryAtPath:dst
                                               withIntermediateDirectories:YES
                                                                attributes:nil
                                                                     error:&err]) {
                        xrc_loge(XRCLC_CB, @"[store] 迁移后建 %@ 失败: %@", dst, err);
                        return -1;
                    }
                } else if (!S_ISDIR(m)) {
                    xrc_loge(XRCLC_CB, @"[store] 迁移后的 %@ 不是目录", dst);
                    return -1;
                }
                NSString *tmp = [src stringByAppendingFormat:@".xrc-relink-%@", [NSUUID UUID].UUIDString];
                const char *ctmp = tmp.fileSystemRepresentation;
                if (symlink(cdst, ctmp) != 0) {
                    xrc_loge(XRCLC_CB, @"[store] 新 cb 软链创建失败: %s", strerror(errno));
                    return -1;
                }
                if (rename(ctmp, csrc) != 0) {
                    int saved = errno;
                    unlink(ctmp);
                    xrc_loge(XRCLC_CB, @"[store] cb 软链更新失败: %s", strerror(saved));
                    return -1;
                }
                xrc_logi(XRCLC_CB, @"[store] 容器迁移后 cb 软链已修复：%@ → %@", t, dst);
                return 0;
            }
            xrc_logw(XRCLC_CB, @"[store] cb 是软链但指向 %@（期望 %@），不动它", t, dst);
            return 1;
        }

        BOOL srcIsDir = (s_lstat(csrc, &m) == 0 && S_ISDIR(m));
        BOOL srcOther = (s_lstat(csrc, &m) == 0 && !S_ISDIR(m));
        BOOL dstIsDir = (s_lstat(cdst, &m) == 0 && S_ISDIR(m));

        if (srcOther) {   // 意外形态（普通文件等）：不碰，交给人处理
            xrc_logw(XRCLC_CB, @"[store] %@ 存在非目录对象，跳过外置", src);
            return -1;
        }

        if (srcIsDir && !dstIsDir) {
            // 同卷 rename：瞬时、零拷贝、原子（cb 动辄数百 MB，绝不能走拷贝）
            if (rename(csrc, cdst) != 0) {
                xrc_loge(XRCLC_CB, @"[store] cb 搬迁失败: %s", strerror(errno));
                return -1;
            }
            xrc_logi(XRCLC_CB, @"[store] cb 已搬到 Documents（rename，无拷贝）");
        } else if (srcIsDir && dstIsDir) {
            xrc_logw(XRCLC_CB, @"[store] 两处都有 cb —— 浅层合并（Documents 侧同名优先）");
            s_merge_into(src, dst);
            if (rmdir(csrc) != 0) {
                // 残留（合并时两侧都有的那份）挪到旁边，保证软链能建起来、内容不丢
                NSString *aside = [NSString stringWithFormat:@"%@.stale-%lld", src, (long long)time(NULL)];
                if (rename(csrc, aside.fileSystemRepresentation) == 0)
                    xrc_logw(XRCLC_CB, @"[store] 残留内容移到 %@", aside);
                else
                    xrc_logw(XRCLC_CB, @"[store] 残留内容清理失败 (%s)，继续建链", strerror(errno));
            }
        } else {
            // 全新安装：建 Documents/cb 占位，之后游戏的 cb 下载直接落在这里
            NSError *err = nil;
            if (![[NSFileManager defaultManager] createDirectoryAtPath:dst
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:&err]) {
                xrc_loge(XRCLC_CB, @"[store] 建 %@ 失败: %@", dst, err);
                return -1;
            }
            xrc_logi(XRCLC_CB, @"[store] 无既有 cb，已建 Documents/cb 占位");
        }

        if (symlink(cdst, csrc) != 0) {
            // 全新安装时 Library/Application Support 可能还不存在（游戏自己还没建），
            // 补一次父目录再试；仍失败则完全放弃（cb 留在原处，功能不受影响）。
            if (errno == ENOENT &&
                [[NSFileManager defaultManager] createDirectoryAtPath:
                      [src stringByDeletingLastPathComponent]
                                                withIntermediateDirectories:YES
                                                                 attributes:nil
                                                                      error:nil] &&
                symlink(cdst, csrc) == 0) {
                xrc_logi(XRCLC_CB, @"[store] cb 外置完成（补建父目录）：%@ → %@", src, dst);
                return 0;
            }
            xrc_loge(XRCLC_CB, @"[store] 软链失败: %s（cb 仍在原处，功能不受影响）", strerror(errno));
            return -1;
        }
        xrc_logi(XRCLC_CB, @"[store] cb 外置完成：%@ → %@", src, dst);
        return 0;
    }
}

BOOL xrc_store_cb_external(void) {
    const char *csrc = s_cb_in_support().fileSystemRepresentation;
    mode_t m = 0;
    if (s_lstat(csrc, &m) != 0 || !S_ISLNK(m)) return NO;
    return [s_symlink_target(csrc) isEqualToString:s_cb_in_docs()];
}

NSString *xrc_store_cb_status(void) {
    NSString *src = s_cb_in_support();
    const char *csrc = src.fileSystemRepresentation;
    mode_t m = 0;
    if (s_lstat(csrc, &m) != 0)
        return @"cb 未创建（首次内容下载后生成）";
    if (S_ISLNK(m)) {
        NSString *t = s_symlink_target(csrc);
        if ([t isEqualToString:s_cb_in_docs()]) return @"cb 已外置 → Documents/cb";
        return [NSString stringWithFormat:@"cb 软链指向异常 → %@", t ?: @"(读不到)"];
    }
    return @"cb 在容器内：Library/Application Support/cb";
}

static NSString *s_local_sha256(NSData *data) {
    if (!data || data.length > UINT32_MAX) return nil;
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (size_t i = 0; i < sizeof(bytes); i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

// 原生远程谱面/音频不是 cb/active/songs/dl_* 的预览读取路径：
// 84D708 -> 8429D0 -> 84292C => FileUtils::getWritablePath()+"dl/"+id+"_"+diff。
// 开局完整音频 84DD38 的键为 id（不同于 84DAC4 构造的 id+"_"）。
// 使用相对软链可跨侧载容器 UUID 迁移。
void xrc_store_prepare_local_content(void) {
    NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *bundleContent = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"XRCContent"];
    NSData *raw = [NSData dataWithContentsOfFile:[bundleContent stringByAppendingPathComponent:@"xrc-local-content.json"]];
    BOOL bundled = raw != nil;
    if (!raw) raw = [NSData dataWithContentsOfFile:[docs stringByAppendingPathComponent:@"xrc-local-content.json"]];
    if (!raw) return;
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
    if (![manifest isKindOfClass:NSDictionary.class] || [manifest[@"schema"] intValue] != 1 ||
        ![manifest[@"contentVersion"] isEqual:@"7.0.255"] ||
        ![manifest[@"songs"] isKindOfClass:NSArray.class]) {
        xrc_logw(XRCLC_CB, @"[local] 导入清单格式/版本不匹配");
        return;
    }
    NSString *active = [docs stringByAppendingPathComponent:@"cb/active"];
    NSData *songData = [NSData dataWithContentsOfFile:[active stringByAppendingPathComponent:@"songs/songlist"]];
    if (!songData && bundled)
        songData = [NSData dataWithContentsOfFile:[bundleContent stringByAppendingPathComponent:@"songlist"]];
    NSDictionary *songList = songData ? [NSJSONSerialization JSONObjectWithData:songData options:0 error:nil] : nil;
    NSArray *songs = [songList isKindOfClass:NSDictionary.class] ? songList[@"songs"] : nil;
    if (![songs isKindOfClass:NSArray.class]) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *nativeRoot = [docs stringByAppendingPathComponent:@"dl"];
    if (![fm createDirectoryAtPath:nativeRoot withIntermediateDirectories:YES attributes:nil error:nil]) return;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789_"] invertedSet];
    for (NSDictionary *entry in manifest[@"songs"]) {
      @autoreleasepool {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *songID = entry[@"id"];
        NSDictionary *files = entry[@"files"];
        if (![songID isKindOfClass:NSString.class] || !songID.length || songID.length >= 64 ||
            [songID rangeOfCharacterFromSet:invalid].location != NSNotFound ||
            ![files isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *songInfo = nil;
        for (NSDictionary *candidate in songs) if ([candidate[@"id"] isEqual:songID]) { songInfo = candidate; break; }
        if (!songInfo || ![songInfo[@"remote_dl"] boolValue]) continue;
        uint32_t mask = 0;
        NSMutableArray<NSString *> *names = [NSMutableArray arrayWithObject:@"base.ogg"];
        for (NSDictionary *difficulty in songInfo[@"difficulties"]) {
            int index = [difficulty[@"ratingClass"] intValue];
            if (index >= 0 && index < 5) {
                mask |= 1u << index;
                [names addObject:[NSString stringWithFormat:@"%d.aff", index]];
                if ([difficulty[@"audioOverride"] boolValue])
                    [names addObject:[NSString stringWithFormat:@"%d.ogg", index]];
            }
        }
        if (!mask) continue;
        // 视频曲目进入谱面时会立即打开 additional_files。只验证 AFF/音频会把缺视频的
        // 曲目误报成已下载，AVPlayer 随后对空视频轨道取第 0 项并抛异常。
        NSSet<NSString *> *allowedExtra = [NSSet setWithArray:@[@"video.mp4", @"video_audio.ogg",
                                                               @"video_720.mp4", @"video_1080.mp4"]];
        BOOL extrasDeclared = YES;
        for (NSDictionary *extra in songInfo[@"additional_files"] ?: @[]) {
            NSString *name = [extra isKindOfClass:NSDictionary.class] ? extra[@"file_name"] : nil;
            if (![name isKindOfClass:NSString.class] || ![allowedExtra containsObject:name]) {
                extrasDeclared = NO;
                break;
            }
            if (![names containsObject:name]) [names addObject:name];
        }
        if (!extrasDeclared) continue;
        NSString *relative = [NSString stringWithFormat:@"../cb/active/songs/dl_%@", songID];
        NSString *sourceRoot = [(bundled ? bundleContent : active)
                                stringByAppendingPathComponent:[NSString stringWithFormat:@"songs/dl_%@", songID]];
        BOOL valid = YES;
        NSMutableArray<NSDictionary *> *links = [NSMutableArray array];
        for (NSString *name in names) {
            NSDictionary *expected = files[name];
            NSData *data = [NSData dataWithContentsOfFile:[sourceRoot stringByAppendingPathComponent:name]
                                                options:NSDataReadingMappedIfSafe error:nil];
            if (![expected isKindOfClass:NSDictionary.class] || !data.length ||
                data.length != [expected[@"bytes"] unsignedLongLongValue] ||
                ![s_local_sha256(data) isEqual:expected[@"sha256"]]) { valid = NO; break; }
            NSString *nativeKey = nil;
            if ([name isEqual:@"base.ogg"]) nativeKey = songID;
            else if ([name hasSuffix:@".aff"])
                nativeKey = [NSString stringWithFormat:@"%@_%@", songID, name.stringByDeletingPathExtension];
            // 难度差分音频与谱面使用不同的原生文件名（sub_10084DD38）。
            else if (name.length == 5 && [name hasSuffix:@".ogg"] &&
                     [@"01234" containsString:[name substringToIndex:1]])
                nativeKey = [NSString stringWithFormat:@"%@_audio_%@", songID, name.stringByDeletingPathExtension];
            else nativeKey = [NSString stringWithFormat:@"%@_%@", songID, name];
            NSString *native = [nativeRoot stringByAppendingPathComponent:nativeKey];
            NSString *target = bundled ? [sourceRoot stringByAppendingPathComponent:name] :
                                          [relative stringByAppendingPathComponent:name];
            mode_t mode = 0;
            if (s_lstat(native.fileSystemRepresentation, &mode) == 0) {
                if (S_ISLNK(mode)) {
                    NSString *oldTarget = s_symlink_target(native.fileSystemRepresentation);
                    if (![oldTarget isEqual:target]) {
                        NSString *oldRelative = [relative stringByAppendingPathComponent:name];
                        NSString *bundleSuffix = [NSString stringWithFormat:@"/XRCContent/songs/dl_%@/%@", songID, name];
                        BOOL ours = [oldTarget isEqual:oldRelative] ||
                            ([oldTarget hasSuffix:bundleSuffix] &&
                             [oldTarget rangeOfString:@".app/XRCContent/"].location != NSNotFound);
                        if (!ours) { valid = NO; break; }
                        [links addObject:@{@"native":native, @"target":target, @"replace":@YES}];
                    }
                } else if (!S_ISREG(mode) || ![s_local_sha256([NSData dataWithContentsOfFile:native]) isEqual:expected[@"sha256"]]) {
                    valid = NO; break;
                }
            } else {
                [links addObject:@{@"native":native, @"target":target}];
            }
        }
        if (!valid) { xrc_logw(XRCLC_CB, @"[local] %@ 文件不完整、哈希不符或原生路径冲突，保留原下载判定", songID); continue; }
        for (NSDictionary *link in links) {
            if ([link[@"replace"] boolValue] && unlink([link[@"native"] fileSystemRepresentation]) != 0) { valid = NO; break; }
            if (symlink([link[@"target"] fileSystemRepresentation], [link[@"native"] fileSystemRepresentation]) != 0) { valid = NO; break; }
        }
        if (valid && xrc_brk_local_content_add(songID.UTF8String, mask))
            xrc_logi(XRCLC_CB, @"[local] %@ verified+linked mask=0x%x source=%@ status=ready-on-unlock",
                     songID, mask, bundled ? @"IPA" : @"Documents");
        else
            xrc_logw(XRCLC_CB, @"[local] %@ 原生映射未完成，保留原下载判定", songID);
      }
    }
}
