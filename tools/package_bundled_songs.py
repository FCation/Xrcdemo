#!/usr/bin/env python3
"""Put a verified local-content stage inside an unsigned IPA.

The IPA's plugin must support XRCContent in its app bundle. Song assets stay
local to the resulting IPA; this script never publishes them to a repository.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import zipfile

from local_content_import import validate_stage


APP = "Payload/Arc-mobile.app/"
CONTENT = APP + "XRCContent/"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def package(base, stage, songlist, output):
    if output.exists():
        raise FileExistsError(f"输出已存在：{output}")
    manifest = validate_stage(stage)
    report = json.loads((stage / "import-report.json").read_text(encoding="utf-8"))
    if sha256(songlist) != report["songlist_sha256"]:
        raise ValueError("songlist 与生成暂存包时使用的版本不同")
    if base.resolve() == output.resolve():
        raise ValueError("输出路径不能覆盖输入 IPA")
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(base) as source:
        info = plistlib.loads(source.read(APP + "Info.plist"))
        if info.get("CFBundleIdentifier") != "guy.guy.guy" or info.get("CFBundleDisplayName") != "ArcaeaXRC":
            raise ValueError("IPA 的 Bundle ID 或应用名称不符合预期")
        if any(name.startswith(CONTENT) for name in source.namelist()):
            raise ValueError("输入 IPA 已包含 XRCContent")
        if APP + "Frameworks/libxrcdemo.dylib" not in source.namelist():
            raise ValueError("输入 IPA 缺少插件")
        temp_handle = tempfile.NamedTemporaryFile(prefix=".xrc-bundled-", suffix=".ipa",
                                                   dir=output.parent, delete=False)
        temp = Path(temp_handle.name)
        temp_handle.close()
        try:
            with zipfile.ZipFile(temp, "w", allowZip64=True) as target:
                for entry in source.infolist():
                    if entry.is_dir():
                        target.writestr(entry, b"")
                        continue
                    with source.open(entry) as incoming, target.open(entry, "w", force_zip64=True) as outgoing:
                        shutil.copyfileobj(incoming, outgoing, 1024 * 1024)
                target.write(stage / "Documents" / "xrc-local-content.json",
                             CONTENT + "xrc-local-content.json", compress_type=zipfile.ZIP_DEFLATED)
                target.write(songlist, CONTENT + "songlist", compress_type=zipfile.ZIP_DEFLATED)
                for row in manifest["songs"]:
                    for name in row["files"]:
                        asset = stage / "Documents" / "cb" / "active" / "songs" / f"dl_{row['id']}" / name
                        archive_name = CONTENT + f"songs/dl_{row['id']}/{name}"
                        compression = zipfile.ZIP_STORED if name.endswith(".ogg") else zipfile.ZIP_DEFLATED
                        target.write(asset, archive_name, compress_type=compression)
            os.replace(temp, output)
        except Exception:
            temp.unlink(missing_ok=True)
            raise
    return {"output": str(output), "bytes": output.stat().st_size,
            "sha256": sha256(output), "songs": len(manifest["songs"]),
            "assets": sum(len(row["files"]) for row in manifest["songs"]),
            "bundle_id": info["CFBundleIdentifier"], "display_name": info["CFBundleDisplayName"]}


def main():
    parser = argparse.ArgumentParser(description="把已校验的歌曲暂存包嵌入未签名 IPA")
    parser.add_argument("--base-ipa", type=Path, required=True, help="已编入包内歌曲支持的基础 IPA")
    parser.add_argument("--stage", type=Path, required=True, help="local_content_import.py prepare 的输出目录")
    parser.add_argument("--songlist", type=Path, required=True, help="与暂存包相同版本的 songlist")
    parser.add_argument("--output", type=Path, required=True, help="新的未签名 IPA 路径")
    args = parser.parse_args()
    print(json.dumps(package(args.base_ipa, args.stage, args.songlist, args.output),
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
