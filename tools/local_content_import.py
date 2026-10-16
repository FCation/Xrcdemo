#!/usr/bin/env python3
"""Stage verified local songs and optionally copy them to an iOS app container.

Only resources already owned and supplied by the user are read. The game plugin
performs its own verification again on launch; this utility never changes cb
metadata or the songlist.
"""

from __future__ import annotations

import argparse
import ctypes as C
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat as statmod
import sys
import tempfile
import zipfile


for stream in (sys.stdout, sys.stderr):
    try:
        stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass


VERSION = "7.0.255"
ID_RE = re.compile(r"[a-z0-9_]{1,63}\Z")
AFF_RE = re.compile(r"[0-4]\.aff\Z")
MAX_SONGS = 256  # XRCHook.m publishes a fixed-size startup table.
CHUNK = 1024 * 1024
AFC_CHUNK = 64 * 1024
DEVICE_ROOT = "Documents/cb/active/songs"
DEVICE_MANIFEST = "Documents/xrc-local-content.json"


def digest_stream(stream, sink=None):
    sha = hashlib.sha256()
    size = 0
    header = b""
    while block := stream.read(CHUNK):
        if not header:
            header = block[:32]
        sha.update(block)
        size += len(block)
        if sink is not None:
            sink.write(block)
    return {"bytes": size, "sha256": sha.hexdigest()}, header


def load_songlist(raw: bytes):
    data = json.loads(raw)
    rows = data.get("songs")
    if not isinstance(rows, list):
        raise ValueError("songlist 缺少 songs 数组")
    result = {}
    for row in rows:
        if isinstance(row, dict) and isinstance(row.get("id"), str):
            result[row["id"]] = row
    return result


def required_files(row):
    if not row or not row.get("remote_dl"):
        return None
    difficulties = row.get("difficulties")
    if not isinstance(difficulties, list):
        return None
    indexes = {d.get("ratingClass") for d in difficulties if isinstance(d, dict)}
    if not indexes or any(type(i) is not int or i < 0 or i > 4 for i in indexes):
        return None
    return ["base.ogg"] + [f"{i}.aff" for i in sorted(indexes)]


def song_id(name):
    result = name.removeprefix("dl_")
    return result if ID_RE.fullmatch(result) else None


class Candidate:
    def __init__(self, label, sid, names, opener):
        self.label, self.sid, self.names, self.open = label, sid, names, opener


def directory_candidates(root: Path):
    if not root.is_dir():
        return
    parents = {p.parent for p in root.rglob("base.ogg") if p.is_file()}
    parents.update(p.parent for p in root.rglob("*.aff") if p.is_file() and AFF_RE.fullmatch(p.name))
    for folder in sorted(parents):
        if folder.is_symlink():
            continue
        names = {p.name for p in folder.iterdir() if p.is_file() and not p.is_symlink()}
        sid = song_id(folder.name)

        def open_file(name, folder=folder):
            return (folder / name).open("rb")

        yield Candidate(str(folder), sid, names, open_file)


def zip_candidates(path: Path):
    with zipfile.ZipFile(path) as archive:
        parents = {}
        for info in archive.infolist():
            parts = PurePosixPath(info.filename).parts
            if info.is_dir() or len(parts) < 2 or "__MACOSX" in parts or ".." in parts:
                continue
            if statmod.S_ISLNK(info.external_attr >> 16):
                continue
            name = parts[-1]
            if name != "base.ogg" and not AFF_RE.fullmatch(name):
                continue
            parent = "/".join(parts[:-1])
            if name in parents.setdefault(parent, {}):
                raise ValueError(f"ZIP 中有重复文件：{path}!{parent}/{name}")
            parents[parent][name] = info
        for parent, members in sorted(parents.items()):
            sid = song_id(PurePosixPath(parent).name)

            def open_file(name, path=path, members=members):
                # ZipFile.open owns the archive; keep both handles alive until exit.
                archive = zipfile.ZipFile(path)
                member = archive.open(members[name])

                class ZipReader:
                    def __enter__(self):
                        return member

                    def __exit__(self, *exc):
                        try:
                            member.close()
                        finally:
                            archive.close()

                return ZipReader()

            yield Candidate(f"{path}!{parent}", sid, set(members), open_file)


def discover(sources):
    for source in sources:
        source = Path(source).resolve()
        if source.is_file() and source.suffix.lower() == ".zip":
            yield from zip_candidates(source)
        elif source.is_dir():
            yield from directory_candidates(source)
            for archive in sorted(source.rglob("*.zip")):
                yield from zip_candidates(archive)
        else:
            raise ValueError(f"输入必须是目录或 ZIP：{source}")


def stage(args):
    output = Path(args.output).resolve()
    if output.exists():
        raise FileExistsError(f"输出目录已存在，请换一个新目录：{output}")
    source_paths = [Path(p).resolve() for p in args.source]
    if any(output == p or output in p.parents or p in output.parents for p in source_paths):
        raise ValueError("输出目录与输入目录不能相互包含")
    songlist_raw = Path(args.songlist).read_bytes()
    songs = load_songlist(songlist_raw)
    output.parent.mkdir(parents=True, exist_ok=True)
    temp = Path(tempfile.mkdtemp(prefix=output.name + ".partial-", dir=output.parent))
    accepted, skipped, seen = [], [], set()
    try:
        for candidate in discover(source_paths):
            sid = candidate.sid
            reason = None
            if sid is None:
                reason = "目录名不是合法曲目 ID"
            elif sid in seen:
                reason = "重复曲目 ID"
            else:
                required = required_files(songs.get(sid))
                if required is None:
                    reason = "当前 songlist 中不存在，或不是可远端下载曲目"
                elif missing := sorted(set(required) - candidate.names):
                    reason = "缺少 " + ", ".join(missing)
            if reason:
                skipped.append({"source": candidate.label, "id": sid, "reason": reason})
                continue
            if len(accepted) >= MAX_SONGS:
                skipped.append({"source": candidate.label, "id": sid, "reason": f"超过 {MAX_SONGS} 曲目上限"})
                continue
            destination = temp / "Documents" / "cb" / "active" / "songs" / f"dl_{sid}"
            destination.mkdir(parents=True)
            assets = {}
            try:
                for name in required:
                    with candidate.open(name) as src, (destination / name).open("wb") as dst:
                        info, header = digest_stream(src, dst)
                    if not info["bytes"]:
                        raise ValueError(f"{name} 为空")
                    if info["bytes"] > 0xFFFFFFFF:
                        raise ValueError(f"{name} 超过插件单文件 4 GiB 上限")
                    if name.endswith(".aff") and not header.startswith(b"AudioOffset:"):
                        raise ValueError(f"{name} 缺少 AFF 头")
                    if name == "base.ogg" and not header.startswith(b"OggS"):
                        raise ValueError("base.ogg 缺少 Ogg 头")
                    assets[name] = info
            except (OSError, ValueError, zipfile.BadZipFile, EOFError) as exc:
                shutil.rmtree(destination)
                skipped.append({"source": candidate.label, "id": sid, "reason": str(exc)})
                continue
            seen.add(sid)
            accepted.append({"id": sid, "files": assets})
        if not accepted:
            detail = json.dumps(skipped, ensure_ascii=False, indent=2)
            raise ValueError("没有可导入的完整曲目；跳过原因：\n" + detail)
        manifest = {"schema": 1, "contentVersion": VERSION, "songs": accepted}
        manifest_path = temp / "Documents" / "xrc-local-content.json"
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        report = {"songlist_sha256": hashlib.sha256(songlist_raw).hexdigest(),
                  "included": [row["id"] for row in accepted], "skipped": skipped,
                  "total_bytes": sum(info["bytes"] for row in accepted for info in row["files"].values())}
        (temp / "import-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        temp.rename(output)
    except Exception:
        shutil.rmtree(temp, ignore_errors=True)
        raise
    print(json.dumps({"stage": str(output), **report}, ensure_ascii=False, indent=2))


class AFC:
    def __init__(self, library, bundle_id):
        self.lib = C.CDLL(str(library))
        self.P = C.c_void_p
        self.dev = self.P()
        self.lock = self.P()
        self.svc = self.P()
        self.house = self.P()
        self.client = self.P()
        self._call("idevice_new", [C.POINTER(self.P), C.c_char_p], C.byref(self.dev), None)
        self._call("lockdownd_client_new_with_handshake", [self.P, C.POINTER(self.P), C.c_char_p],
                   self.dev, C.byref(self.lock), b"XRC-local-import")
        self._call("lockdownd_start_service", [self.P, C.c_char_p, C.POINTER(self.P)],
                   self.lock, b"com.apple.mobile.house_arrest", C.byref(self.svc))
        self._call("house_arrest_client_new", [self.P, self.P, C.POINTER(self.P)],
                   self.dev, self.svc, C.byref(self.house))
        self._call("house_arrest_send_command", [self.P, C.c_char_p, C.c_char_p],
                   self.house, b"VendContainer", bundle_id.encode())
        self._call("afc_client_new_from_house_arrest_client", [self.P, C.POINTER(self.P)],
                   self.house, C.byref(self.client))

    def _call(self, name, types, *values):
        fn = getattr(self.lib, name)
        fn.argtypes, fn.restype = types, C.c_int
        code = fn(*values)
        if code:
            raise RuntimeError(f"{name}: AFC 错误 {code}")

    def stat(self, path):
        ptr = C.POINTER(C.c_char_p)()
        fn = self.lib.afc_get_file_info
        fn.argtypes, fn.restype = [self.P, C.c_char_p, C.POINTER(C.POINTER(C.c_char_p))], C.c_int
        code = fn(self.client, path.encode(), C.byref(ptr))
        if code == 8:  # AFC_E_OBJECT_NOT_FOUND
            return None
        if code:
            raise RuntimeError(f"stat {path}: AFC 错误 {code}")
        result = {}
        i = 0
        while ptr[i] and ptr[i + 1]:
            result[ptr[i].decode()] = ptr[i + 1].decode("utf-8", "replace")
            i += 2
        free = self.lib.afc_dictionary_free
        free.argtypes, free.restype = [C.POINTER(C.c_char_p)], None
        free(ptr)
        return result

    def mkdir(self, path):
        current = self.stat(path)
        if current:
            if current.get("st_ifmt") != "S_IFDIR":
                raise RuntimeError(f"设备路径不是目录：{path}")
            return
        self._call("afc_make_directory", [self.P, C.c_char_p], self.client, path.encode())

    def _open(self, path, mode):
        handle = C.c_uint64()
        self._call("afc_file_open", [self.P, C.c_char_p, C.c_uint64, C.POINTER(C.c_uint64)],
                   self.client, path.encode(), mode, C.byref(handle))
        return handle.value

    def _close(self, handle):
        self._call("afc_file_close", [self.P, C.c_uint64], self.client, handle)

    def hash(self, path):
        handle = self._open(path, 1)
        sha, size = hashlib.sha256(), 0
        try:
            while True:
                buf = C.create_string_buffer(AFC_CHUNK)
                actual = C.c_uint32()
                self._call("afc_file_read", [self.P, C.c_uint64, self.P, C.c_uint32, C.POINTER(C.c_uint32)],
                           self.client, handle, buf, AFC_CHUNK, C.byref(actual))
                if not actual.value:
                    break
                sha.update(buf.raw[:actual.value])
                size += actual.value
        finally:
            self._close(handle)
        return {"bytes": size, "sha256": sha.hexdigest()}

    def read(self, path, limit=4 * 1024 * 1024):
        metadata = self.stat(path)
        if metadata is None:
            return None
        if int(metadata["st_size"]) > limit:
            raise ValueError(f"设备文件过大，拒绝读取：{path}")
        handle = self._open(path, 1)
        data = bytearray()
        try:
            while len(data) < limit + 1:
                count = min(AFC_CHUNK, limit + 1 - len(data))
                buf = C.create_string_buffer(count)
                actual = C.c_uint32()
                self._call("afc_file_read", [self.P, C.c_uint64, self.P, C.c_uint32, C.POINTER(C.c_uint32)],
                           self.client, handle, buf, count, C.byref(actual))
                if not actual.value:
                    break
                data.extend(buf.raw[:actual.value])
        finally:
            self._close(handle)
        return bytes(data)

    def remove(self, path):
        self._call("afc_remove_path", [self.P, C.c_char_p], self.client, path.encode())

    def write_blocks(self, handle, stream):
        while block := stream.read(AFC_CHUNK):
            buffer = C.create_string_buffer(block)
            actual = C.c_uint32()
            self._call("afc_file_write", [self.P, C.c_uint64, self.P, C.c_uint32, C.POINTER(C.c_uint32)],
                       self.client, handle, buffer, len(block), C.byref(actual))
            if actual.value != len(block):
                raise IOError("设备分块写入不完整")

    def upload_atomic(self, path, source):
        temporary = path + ".xrc-import.tmp"
        if self.stat(temporary):
            self.remove(temporary)
        handle = self._open(temporary, 3)
        try:
            with open(source, "rb") as stream:
                self.write_blocks(handle, stream)
        finally:
            self._close(handle)
        with open(source, "rb") as stream:
            expected, _ = digest_stream(stream)
        if self.hash(temporary) != expected:
            self.remove(temporary)
            raise IOError(f"设备读回校验失败：{temporary}")
        if self.stat(path):
            self.remove(temporary)
            raise RuntimeError(f"设备目标在传输期间出现：{path}")
        self._call("afc_rename_path", [self.P, C.c_char_p, C.c_char_p],
                   self.client, temporary.encode(), path.encode())


def validate_stage(root):
    manifest = json.loads((root / "Documents" / "xrc-local-content.json").read_text(encoding="utf-8"))
    if manifest.get("schema") != 1 or manifest.get("contentVersion") != VERSION:
        raise ValueError("清单格式或内容版本不匹配")
    entries = manifest.get("songs")
    if not isinstance(entries, list) or not entries or len(entries) > MAX_SONGS:
        raise ValueError("曲目数量不合法")
    found = set()
    for row in entries:
        if not isinstance(row, dict):
            raise ValueError("清单包含非对象曲目条目")
        sid, files = row.get("id"), row.get("files")
        if not isinstance(sid, str) or not ID_RE.fullmatch(sid) or sid in found or not isinstance(files, dict) or not files:
            raise ValueError(f"清单曲目 ID 或文件表不合法：{sid!r}")
        found.add(sid)
        for name, expected in files.items():
            if name != "base.ogg" and not AFF_RE.fullmatch(name):
                raise ValueError(f"文件名不合法：{name}")
            source = root / "Documents" / "cb" / "active" / "songs" / f"dl_{sid}" / name
            if source.is_symlink() or not source.is_file():
                raise ValueError(f"暂存文件缺失：{source}")
            with source.open("rb") as stream:
                actual, _ = digest_stream(stream)
            if actual != expected:
                raise ValueError(f"暂存文件已改变：{source}")
    return manifest


def install(args):
    root = Path(args.stage).resolve()
    manifest = validate_stage(root)
    library = Path(args.afc_dll).resolve() if args.afc_dll else os.environ.get("XRC_AFC_LIBRARY")
    if not library:
        raise ValueError("请用 --afc-dll 指定 libimobiledevice 的动态库，或设置 XRC_AFC_LIBRARY")
    device = AFC(library, args.bundle_id)
    raw_songlist = device.read(f"{DEVICE_ROOT}/songlist", 4 * 1024 * 1024)
    if not raw_songlist:
        raise RuntimeError("设备缺少当前 cb/active/songs/songlist")
    songs = load_songlist(raw_songlist)
    existing_raw = device.read(DEVICE_MANIFEST)
    existing = json.loads(existing_raw) if existing_raw else {"schema": 1, "contentVersion": VERSION, "songs": []}
    if existing.get("schema") != 1 or existing.get("contentVersion") != VERSION or not isinstance(existing.get("songs"), list):
        raise ValueError("设备现有清单格式或版本不匹配")
    transfers = []
    for row in manifest["songs"]:
        sid, files = row["id"], row["files"]
        required = required_files(songs.get(sid))
        if required is None or set(required) != set(files):
            raise ValueError(f"设备 songlist 与暂存资源声明不符：{sid}")
        folder = f"{DEVICE_ROOT}/dl_{sid}"
        item = device.stat(folder)
        if item and item.get("st_ifmt") != "S_IFDIR":
            raise ValueError(f"设备目录路径冲突：{folder}")
        for name, expected in files.items():
            target = f"{folder}/{name}"
            current = device.stat(target)
            if current and (int(current["st_size"]) != expected["bytes"] or device.hash(target) != expected):
                raise ValueError(f"设备已有不同内容，拒绝覆盖：{target}")
            if not current:
                transfers.append((target, root / "Documents" / "cb" / "active" / "songs" / f"dl_{sid}" / name))
    merged = {row.get("id"): row for row in existing["songs"] if isinstance(row, dict) and isinstance(row.get("id"), str)}
    merged.update({row["id"]: row for row in manifest["songs"]})
    if len(merged) > MAX_SONGS:
        raise ValueError(f"合并后超过 {MAX_SONGS} 曲目上限")
    new_manifest = {"schema": 1, "contentVersion": VERSION, "songs": list(merged.values())}
    payload = (json.dumps(new_manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    plan = {"mode": "apply" if args.apply else "preview", "bundle_id": args.bundle_id,
            "songs": [row["id"] for row in manifest["songs"]],
            "files_to_copy": len(transfers), "bytes_to_copy": sum(p.stat().st_size for _, p in transfers),
            "existing_manifest_entries": len(existing["songs"]), "merged_entries": len(merged)}
    print(json.dumps(plan, ensure_ascii=False, indent=2), flush=True)
    if not args.apply:
        return
    backup = root / ("device-manifest-before-" + hashlib.sha256(existing_raw).hexdigest()[:12] + ".json") if existing_raw else None
    if backup and backup.exists() and backup.read_bytes() != existing_raw:
        raise FileExistsError(f"现有备份内容不同，拒绝覆盖：{backup}")
    if existing_raw:
        backup.write_bytes(existing_raw)
    previous_device = DEVICE_MANIFEST + ".xrc-import.previous"
    if device.stat(previous_device):
        raise FileExistsError(f"设备已有清单备份，请先检查：{previous_device}")
    for target, source in transfers:
        folder = target.rsplit("/", 1)[0]
        device.mkdir(folder)
        device.upload_atomic(target, source)
        print(f"已传输并读回核对：{target}", flush=True)
    temporary_local = root / "device-manifest-merged.json"
    temporary_local.write_bytes(payload)
    # Manifest is published last, after every resource has passed read-back.
    temporary_device = DEVICE_MANIFEST + ".xrc-import.tmp"
    if device.stat(temporary_device):
        device.remove(temporary_device)
    handle = device._open(temporary_device, 3)
    try:
        with temporary_local.open("rb") as stream:
            device.write_blocks(handle, stream)
    finally:
        device._close(handle)
    if device.hash(temporary_device) != {"bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}:
        raise IOError("设备清单读回校验失败")
    # AFC rename replacement behavior varies; back up the old manifest on device.
    if existing_raw:
        device._call("afc_rename_path", [device.P, C.c_char_p, C.c_char_p],
                     device.client, DEVICE_MANIFEST.encode(), previous_device.encode())
    try:
        device._call("afc_rename_path", [device.P, C.c_char_p, C.c_char_p],
                     device.client, temporary_device.encode(), DEVICE_MANIFEST.encode())
    except Exception:
        if existing_raw:
            device._call("afc_rename_path", [device.P, C.c_char_p, C.c_char_p],
                         device.client, previous_device.encode(), DEVICE_MANIFEST.encode())
        raise
    if device.hash(DEVICE_MANIFEST) != {"bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}:
        raise IOError("最终清单读回校验失败；设备上保留了旧清单备份")
    if existing_raw:
        device.remove(previous_device)
    print(f"清单已写入并核对：{DEVICE_MANIFEST}；请重开应用", flush=True)


def main():
    parser = argparse.ArgumentParser(description="7.0.255 本地曲目批量暂存与 iPad 导入")
    actions = parser.add_subparsers(dest="action", required=True)
    prep = actions.add_parser("prepare", help="扫描目录/ZIP，生成可导入暂存包")
    prep.add_argument("--songlist", required=True, help="当前 7.0.255 cb/active/songs/songlist 路径")
    prep.add_argument("--source", action="append", required=True, help="歌曲目录或 ZIP；可重复")
    prep.add_argument("--output", required=True, help="新暂存目录，不能已存在")
    prep.set_defaults(run=stage)
    sync = actions.add_parser("install", help="预览或传输暂存包到已连接 iPad")
    sync.add_argument("--stage", required=True, help="prepare 生成的目录")
    sync.add_argument("--bundle-id", required=True, help="设备上实际签名后的 Bundle ID")
    sync.add_argument("--afc-dll", help="libimobiledevice 动态库路径，也可设置 XRC_AFC_LIBRARY")
    sync.add_argument("--apply", action="store_true", help="实际传输；默认只预览")
    sync.set_defaults(run=install)
    args = parser.parse_args()
    try:
        args.run(args)
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile) as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
