#!/usr/bin/env python3
"""Create a new local-content stage with generated video stand-ins.

The input stage is never modified.  Output media is silent black video, not a
copy of the game's original videos.  Requires ffmpeg and ffprobe on PATH.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from local_content_import import digest_stream, load_songlist, required_files, validate_stage


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def duration_seconds(ffprobe, source):
    value = float(run(ffprobe, "-v", "error", "-show_entries", "format=duration",
                      "-of", "default=noprint_wrappers=1:nokey=1", str(source)))
    if not math.isfinite(value) or value <= 0 or value > 3600:
        raise ValueError(f"音频时长异常：{source}")
    return math.ceil(value) + 2


def generate(ffmpeg, name, seconds, target):
    if name.endswith(".mp4"):
        resolution = "1920x1080" if name == "video_1080.mp4" else "1280x720"
        run(ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
            f"color=c=black:s={resolution}:r=15:d={seconds}", "-an", "-c:v", "libx264",
            "-preset", "ultrafast", "-crf", "35", "-pix_fmt", "yuv420p",
            "-movflags", "+faststart", "-y", str(target))
    elif name == "video_audio.ogg":
        run(ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
            "anullsrc=r=44100:cl=stereo", "-t", str(seconds), "-c:a", "libvorbis",
            "-q:a", "1", "-y", str(target))
    else:
        raise ValueError(f"不是可生成的媒体文件：{name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", type=Path, required=True, help="已有 prepare 暂存目录")
    parser.add_argument("--songlist", type=Path, required=True, help="同版本 songlist")
    parser.add_argument("--output", type=Path, required=True, help="新的完整暂存目录")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--ffprobe", default="ffprobe")
    args = parser.parse_args()
    source, output = args.stage.resolve(), args.output.resolve()
    if output.exists() or output == source or output in source.parents or source in output.parents:
        raise ValueError("输出目录已存在，或与输入目录相互包含")
    manifest = validate_stage(source)
    report = json.loads((source / "import-report.json").read_text(encoding="utf-8"))
    import hashlib
    if hashlib.sha256(args.songlist.read_bytes()).hexdigest() != report["songlist_sha256"]:
        raise ValueError("songlist 与暂存包版本不匹配")
    songs = load_songlist(args.songlist.read_bytes())
    ffmpeg, ffprobe = shutil.which(args.ffmpeg), shutil.which(args.ffprobe)
    if not ffmpeg or not ffprobe:
        raise FileNotFoundError("需要 ffmpeg 与 ffprobe；可用 --ffmpeg / --ffprobe 指定完整路径")
    output.parent.mkdir(parents=True, exist_ok=True)
    temp = Path(tempfile.mkdtemp(prefix=output.name + ".partial-", dir=output.parent))
    generated = []
    try:
        for entry in manifest["songs"]:
            sid = entry["id"]
            song = songs.get(sid)
            required = required_files(song) if song is not None else None
            if required is None or not set(entry["files"]).issubset(required):
                raise ValueError(f"曲目清单不匹配：{sid}")
            old_dir = source / "Documents" / "cb" / "active" / "songs" / f"dl_{sid}"
            new_dir = temp / "Documents" / "cb" / "active" / "songs" / f"dl_{sid}"
            new_dir.mkdir(parents=True)
            for name in entry["files"]:
                old, new = old_dir / name, new_dir / name
                try:
                    os.link(old, new)
                except OSError:
                    shutil.copy2(old, new)
            seconds = None
            for name in required:
                if name in entry["files"]:
                    continue
                if seconds is None:
                    seconds = duration_seconds(ffprobe, old_dir / "base.ogg")
                new = new_dir / name
                generate(ffmpeg, name, seconds, new)
                with new.open("rb") as stream:
                    info, _ = digest_stream(stream)
                entry["files"][name] = info
                generated.append({"id": sid, "file": name, "seconds": seconds})
        target = temp / "Documents" / "xrc-local-content.json"
        target.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        report["total_bytes"] = sum(info["bytes"] for row in manifest["songs"]
                                    for info in row["files"].values())
        report["placeholder_files"] = generated
        (temp / "import-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                                                 encoding="utf-8")
        temp.rename(output)
    except Exception:
        shutil.rmtree(temp, ignore_errors=True)
        raise
    print(json.dumps({"output": str(output), "songs": len(manifest["songs"]),
                      "placeholder_files": len(generated), "placeholder_songs": len({x["id"] for x in generated})},
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
