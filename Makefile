# © 雾月星辰 & MLXC · github@XingChenRS
TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

# 构建轴：本地默认开发构建（调试工具 + DEBUG 日志）；CI 发布显式 XRC_DEBUG=0。
XRC_DEBUG ?= 1
XRC_ALLOW_OFFICIAL_NET ?= 0

# xrcdemo：侧载 dylib；主程序定点手术全部由 inject.py 完成（dylib 注入 / 判定桩 / BRK 站点）。
LIBRARY_NAME = xrcdemo

xrcdemo_FILES = src/boot/Tweak.x
xrcdemo_FILES += src/core/XRCRuntime.m
xrcdemo_FILES += src/core/XRCConfig.m
xrcdemo_FILES += src/core/XRCHook.m
xrcdemo_FILES += src/gameplay/XRCGameplay.m
xrcdemo_FILES += src/gameplay/XRCClock.m
xrcdemo_FILES += src/gameplay/XRCPlayer.m
xrcdemo_FILES += src/gameplay/XRCAudio.m
xrcdemo_FILES += src/gameplay/XRCJudge.m
xrcdemo_FILES += src/gameplay/XRCReplay.m
xrcdemo_FILES += src/content/XRCNet.m
xrcdemo_FILES += src/content/XRCStore.m
xrcdemo_FILES += src/diag/XRCLog.m
xrcdemo_FILES += src/diag/XRCProbe.m
xrcdemo_FILES += src/diag/XRCDump.m
xrcdemo_FILES += src/diag/XRCOMLog.m
xrcdemo_FILES += src/ui/XRCFloatButton.m
xrcdemo_FILES += src/ui/XRCTheme.m
xrcdemo_FILES += src/ui/XRCTimelineView.m
xrcdemo_FILES += src/ui/XRCSwitchRow.m
xrcdemo_FILES += src/ui/XRCPracticePanel.m
xrcdemo_FILES += vendor/fishhook/fishhook.c
xrcdemo_FILES += $(wildcard vendor/WHToast/*.m)

xrcdemo_CFLAGS  += -fobjc-arc
xrcdemo_CFLAGS += -Isrc/core -Isrc/gameplay -Isrc/content -Isrc/diag -Isrc/ui
xrcdemo_CFLAGS += -Ivendor -Ivendor/fishhook
xrcdemo_CFLAGS += -DXRC_DEBUG_BUILD=$(XRC_DEBUG)
xrcdemo_CFLAGS += -DXRC_ALLOW_OFFICIAL_NET=$(XRC_ALLOW_OFFICIAL_NET)

xrcdemo_LIBRARIES = substrate
xrcdemo_LOGOSFLAGS = -c generator=MobileSubstrate
xrcdemo_LDFLAGS = -Xlinker -not_for_dyld_shared_cache

ADDITIONAL_CFLAGS += -Wno-error=unused-variable -Wno-error=unused-function
ADDITIONAL_CFLAGS += -Wno-error=unused-but-set-variable
ADDITIONAL_CFLAGS += -Wno-error=deprecated-declarations

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/library.mk

.PHONY: sideload package-sideload

sideload:
	$(MAKE)

package-sideload:
	$(MAKE) package
