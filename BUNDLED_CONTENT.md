# 把本地歌曲装入 IPA

适用场景：把 7.0.255 的基础 `cb` 内容和完整歌曲资源放进同一个 IPA，供全新安装或覆盖侧载使用，不再用 AFC 从电脑逐首复制。

插件优先读取应用包 `XRCContent/xrc-local-content.json`，逐首核对 `XRCContent/songs/dl_<id>/` 中的完整音频与谱面，再把游戏使用的 `Documents/dl/<id>` 和 `Documents/dl/<id>_<难度>` 映射到包内文件。覆盖安装导致应用包路径变化时，插件会在下次启动重建自己创建的映射。包内没有资源时，仍支持原有的 `Documents` 导入方式。

`tools/package_bundled_songs.py` 接收已经运行 `local_content_import.py prepare` 得到的暂存目录、与之匹配的 `songlist`，以及已编入包内资源支持的基础 IPA。用 `--cb-root` 加入完整的 7.0.255 基础 `cb` 目录时，工具还会根据 `meta.cb` 核对每个基础文件，再生成适合全新安装的未签名 IPA。歌曲和基础内容只进入本地输出 IPA，不提交到源码仓库。

```powershell
py -3 tools/package_bundled_songs.py `
  --base-ipa 'C:\path\to\v12-standalone-base-unsigned.ipa' `
  --stage 'C:\path\to\local-content-stage' `
  --songlist 'C:\path\to\cb\active\songs\songlist' `
  --cb-root 'C:\path\to\cb' `
  --output 'C:\path\to\ArcaeaXRC-with-songs-unsigned.ipa'
```

首次安装时，插件会先把包内基础 `cb` 恢复到应用数据目录，然后在后台校验并映射包内歌曲。首次启动需要等待文件准备完成；如果途中退出，下次启动会继续复制未完成的文件。若已进入选曲界面但歌曲仍显示下载图标，等待片刻后彻底关闭并重开应用。进入游戏后开启“全部解锁”。IPA 内的 Bundle ID 是 `guy.guy.guy`，显示名 `ArcaeaXRC`；签名工具可能把实际安装 ID 改为带 Team ID 的形式。覆盖侧载时，签名后的实际 ID 应与已安装版本一致。

省略 `--cb-root` 时，只生成适合已有基础 `cb` 内容的包。全新安装应提供 `--cb-root`。
