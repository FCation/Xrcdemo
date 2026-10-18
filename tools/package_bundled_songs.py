#!/usr/bin/env python3
"""Put a verified local-content stage inside an unsigned IPA.

The IPA's plugin must support XRCContent in its app bundle. Song assets stay
local to the resulting IPA; this script never publishes them to a repository.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
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


def validate_cb(cb_root, songlist):
    metadata = json.loads((cb_root / "meta.cb").read_text(encoding="utf-8"))
    if metadata.get("versionNumber") != "7.0.255" or not isinstance(metadata.get("added"), list):
        raise ValueError("基础 cb 的 meta.cb 不是 7.0.255")
    files = []
    seen = set()
    for row in metadata["added"]:
        relative = PurePosixPath(row["path"])
        if relative.is_absolute() or ".." in relative.parts or not relative.parts or str(relative) in seen:
            raise ValueError(f"meta.cb 路径不合法或重复：{relative}")
        seen.add(str(relative))
        source = cb_root / "active" / Path(*relative.parts)
        if source.is_symlink() or not source.is_file() or source.stat().st_size != row["length"]:
            raise ValueError(f"基础 cb 文件缺失或长度不符：{source}")
        expected = base64.b64decode(row["sha256HashBase64Encoded"], validate=True)
        if bytes.fromhex(sha256(source)) != expected:
            raise ValueError(f"基础 cb 文件哈希不符：{source}")
        files.append((source, str(relative)))
    actual = {p.relative_to(cb_root / "active").as_posix()
              for p in (cb_root / "active").rglob("*") if p.is_file()}
    if actual != seen:
        raise ValueError("基础 cb 的 active 文件表与 meta.cb 不一致")
    if (cb_root / "active" / "songs" / "songlist").read_bytes() != songlist.read_bytes():
        raise ValueError("基础 cb 的 songlist 与歌曲暂存包不同")
    return files


def package(base, stage, songlist, output, cb_root=None):
    if output.exists():
        raise FileExistsError(f"输出已存在：{output}")
    manifest = validate_stage(stage)
    report = json.loads((stage / "import-report.json").read_text(encoding="utf-8"))
    if sha256(songlist) != report["songlist_sha256"]:
        raise ValueError("songlist 与生成暂存包时使用的版本不同")
    cb_files = validate_cb(cb_root, songlist) if cb_root else []
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
                if cb_root:
                    target.write(cb_root / "meta.cb", CONTENT + "cb/meta.cb", compress_type=zipfile.ZIP_DEFLATED)
                    for asset, relative in cb_files:
                        compression = zipfile.ZIP_STORED if asset.suffix.lower() in (".ogg", ".jpg", ".png") else zipfile.ZIP_DEFLATED
                        target.write(asset, CONTENT + "cb/active/" + relative, compress_type=compression)
            os.replace(temp, output)
        except Exception:
            temp.unlink(missing_ok=True)
            raise
    return {"output": str(output), "bytes": output.stat().st_size,
            "sha256": sha256(output), "songs": len(manifest["songs"]),
            "assets": sum(len(row["files"]) for row in manifest["songs"]),
            "base_cb_files": len(cb_files),
            "bundle_id": info["CFBundleIdentifier"], "display_name": info["CFBundleDisplayName"]}


def main():
    parser = argparse.ArgumentParser(description="把已校验的歌曲暂存包嵌入未签名 IPA")
    parser.add_argument("--base-ipa", type=Path, required=True, help="已编入包内歌曲支持的基础 IPA")
    parser.add_argument("--stage", type=Path, required=True, help="local_content_import.py prepare 的输出目录")
    parser.add_argument("--songlist", type=Path, required=True, help="与暂存包相同版本的 songlist")
    parser.add_argument("--output", type=Path, required=True, help="新的未签名 IPA 路径")
    parser.add_argument("--cb-root", type=Path, help="可选：7.0.255 基础 cb 目录；提供后支持全新安装")
    args = parser.parse_args()
    print(json.dumps(package(args.base_ipa, args.stage, args.songlist, args.output, args.cb_root),
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
