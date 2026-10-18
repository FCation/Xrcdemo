# 把本地歌曲装入 IPA

适用场景：当前设备已能进入 7.0.255 的歌曲界面，希望覆盖侧载一个包含完整音频及谱面的 IPA，而不再用 AFC 从电脑逐首复制。

插件优先读取应用包 `XRCContent/xrc-local-content.json`，逐首核对 `XRCContent/songs/dl_<id>/` 中的完整音频与谱面，再把游戏使用的 `Documents/dl/<id>` 和 `Documents/dl/<id>_<难度>` 映射到包内文件。覆盖安装导致应用包路径变化时，插件会在下次启动重建自己创建的映射。包内没有资源时，仍支持原有的 `Documents` 导入方式。

`tools/package_bundled_songs.py` 接收已经运行 `local_content_import.py prepare` 得到的暂存目录、与之匹配的 `songlist`，以及已编入包内资源支持的基础 IPA。它会验证所有文件的字节数和 SHA-256，再生成新的未签名 IPA。歌曲文件只进入本地输出 IPA，不提交到源码仓库。

```powershell
py -3 tools/package_bundled_songs.py `
  --base-ipa 'C:\path\to\v11-base-unsigned.ipa' `
  --stage 'C:\path\to\local-content-stage' `
  --songlist 'C:\path\to\cb\active\songs\songlist' `
  --output 'C:\path\to\ArcaeaXRC-with-songs-unsigned.ipa'
```

使用相同签名方式覆盖侧载，保留应用数据；首次启动后开启“全部解锁”。插件会在启动时校验歌曲，因此资源越多，启动所需时间越长。IPA 内的 Bundle ID 是 `guy.guy.guy`，显示名 `ArcaeaXRC`；签名工具可能把实际安装 ID 改为带 Team ID 的形式。要覆盖当前设备上的 ArcaeaXRC，签名后的实际 ID 应与已安装版本一致。

本包内置的是远端歌曲的完整音频和谱面。游戏自身的 `cb/active` 基础内容仍由已有安装保留；全新安装若尚无这些基础内容，仍需完成游戏的初始内容准备。
