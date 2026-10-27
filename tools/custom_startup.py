#!/usr/bin/env python3
"""Render custom startup captions and replace only the selected XRC PNG assets."""
from __future__ import annotations

import argparse
import binascii
import hashlib
import io
import json
from pathlib import Path
import plistlib
import shutil
import struct
import sys
import tempfile
import zipfile

APP = 'Payload/Arc-mobile.app/'
STARTUP = APP + 'startup/'
SIZES = [(596, 159), (1541, 157), (1247, 159)]


def png_size(data):
    if len(data) > 32 * 1024 * 1024 or data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('需要有效的 PNG 文件，且不超过 32 MiB')
    pos, size, ended, image_data = 8, None, False, False
    while pos + 12 <= len(data):
        n = struct.unpack_from('>I', data, pos)[0]
        kind, body = data[pos+4:pos+8], data[pos+8:pos+8+n]
        if pos + n + 12 > len(data):
            raise ValueError('PNG 数据不完整')
        crc = struct.unpack_from('>I', data, pos+8+n)[0]
        if binascii.crc32(kind + body) & 0xffffffff != crc:
            raise ValueError('PNG CRC 不匹配')
        if kind == b'IHDR':
            if size is not None or pos != 8 or n != 13:
                raise ValueError('PNG IHDR 不合法')
            size = struct.unpack_from('>II', body)
        if kind == b'IDAT': image_data = True
        pos += n + 12
        if kind == b'IEND':
            ended = n == 0 and pos == len(data)
            break
    if not size or not all(size) or not ended or not image_data:
        raise ValueError('PNG 缺少有效的 IHDR / IDAT / IEND')
    return size


def check_app(archive):
    names = archive.namelist()
    if len(names) != len(set(names)):
        raise ValueError('IPA 包含重复路径')
    info = plistlib.loads(archive.read(APP + 'Info.plist'))
    if info.get('CFBundleIdentifier') != 'guy.guy.guy' or info.get('CFBundleDisplayName') != 'ArcaeaXRC':
        raise ValueError('仅接受 Bundle ID=guy.guy.guy、名称=ArcaeaXRC 的源 IPA')
    for i in range(1, 4):
        for suffix in ['', '_lephon']:
            name = STARTUP + f'm{i}{suffix}.png'
            if name not in names:
                raise ValueError(f'IPA 缺少 {name}')


def font_bytes(archive, name):
    return archive.read(APP + 'Fonts/' + name)


def render_images(ipa, config, output):
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError as e:
        raise RuntimeError('生成图片需要 Pillow；请运行 python -m pip install Pillow') from e
    rows = json.loads(config.read_text(encoding='utf-8-sig')).get('lines')
    if not isinstance(rows, list) or len(rows) != 3:
        raise ValueError('JSON 的 lines 必须有三项，每项包含 main 和 sub')
    for row in rows:
        if not isinstance(row, dict) or set(row) - {'main', 'sub'}:
            raise ValueError('每项只支持 main 与 sub')
        for key in ['main', 'sub']:
            text = row.get(key, '')
            if not isinstance(text, str) or len(text) > 256 or any(ord(c) < 32 and c != '\n' for c in text):
                raise ValueError('文字必须是最多 256 字符的字符串，可使用换行')
    if output.exists():
        raise FileExistsError(f'图片输出目录已存在：{output}')
    scale, pad = 3, 5
    reports = []
    images = []
    with zipfile.ZipFile(ipa) as archive:
        check_app(archive)
        latin = font_bytes(archive, 'GeosansLight.ttf')
        cjk = font_bytes(archive, 'NotoSansCJKsc-Regular.otf')
        for i, (row, size) in enumerate(zip(rows, SIZES), 1):
            image = Image.new('RGBA', (size[0]*scale, size[1]*scale), (0, 0, 0, 0))
            draw = ImageDraw.Draw(image)
            main, sub = row.get('main', ''), row.get('sub', '')
            bands = [('main', main, pad, 93 if sub else size[1]-2*pad, 92),
                     ('sub', sub, 105, size[1]-110, 45)]
            fitted = {}
            for key, text, top, height, maximum in bands:
                if not text: continue
                data = cjk if key == 'sub' or any(ord(c) > 127 for c in text) else latin
                for point in range(maximum, 7, -1):
                    font = ImageFont.truetype(io.BytesIO(data), point*scale)
                    box = draw.multiline_textbbox((0, 0), text, font=font, spacing=2*scale)
                    if box[2]-box[0] <= (size[0]-2*pad-2)*scale and box[3]-box[1] <= (height-2)*scale:
                        break
                else:
                    raise ValueError(f'第 {i} 段 {key} 文字过长，无法清晰排入原图尺寸')
                xy = (pad*scale-box[0], top*scale-box[1])
                draw.multiline_text((xy[0]+scale, xy[1]+scale), text, font=font,
                                    fill=(0, 0, 0, 210), spacing=2*scale)
                draw.multiline_text(xy, text, font=font, fill='white', spacing=2*scale)
                fitted[key] = point
            image = image.resize(size, Image.Resampling.LANCZOS)
            images.append(image)
            reports.append({'file':f'm{i}.png', 'size':list(size), 'text':row, 'font_sizes':fitted})
    output.mkdir(parents=True)
    for i, image in enumerate(images, 1): image.save(output / f'm{i}.png')
    (output / 'render-report.json').write_text(json.dumps(reports, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    return reports


def pack(ipa, images, output, theme, apply):
    if output.resolve() == ipa.resolve() or output.exists():
        raise FileExistsError('输出 IPA 必须是尚不存在的新文件，不能覆盖源文件')
    replacements = {}
    with zipfile.ZipFile(ipa) as archive:
        check_app(archive)
        for i in range(1, 4):
            for suffix in ['', '_lephon']:
                if theme != 'both' and (suffix == '_lephon') != (theme == 'lephon'): continue
                exact = images / f'm{i}{suffix}.png'
                path = exact if exact.exists() else images / f'm{i}.png'
                if not path.is_file(): continue
                data = path.read_bytes()
                target = STARTUP + f'm{i}{suffix}.png'
                expected = png_size(archive.read(target))
                if png_size(data) != expected:
                    raise ValueError(f'{path.name} 尺寸应为 {expected[0]}×{expected[1]}')
                replacements[target] = data
        if not replacements: raise ValueError('图片目录中没有可替换的 m1.png / m2.png / m3.png')
        plan = {'mode':'apply' if apply else 'preview', 'ipa':str(ipa), 'output':str(output),
                'replacements':{n:hashlib.sha256(d).hexdigest() for n,d in replacements.items()},
                'requires_resigning':True}
        if not apply: return plan
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(prefix='.xrc-startup-', suffix='.ipa', dir=output.parent, delete=False) as f:
            temporary = Path(f.name)
        try:
            with zipfile.ZipFile(temporary, 'w', allowZip64=True) as target:
                for entry in archive.infolist():
                    if entry.filename in replacements: target.writestr(entry, replacements[entry.filename])
                    elif entry.is_dir(): target.writestr(entry, b'')
                    else:
                        with archive.open(entry) as src, target.open(entry, 'w', force_zip64=True) as dst:
                            shutil.copyfileobj(src, dst, 1024*1024)
            with zipfile.ZipFile(temporary) as target:
                if target.testzip() is not None: raise ValueError('输出 IPA 的 CRC 核对失败')
                if target.namelist() != archive.namelist(): raise ValueError('输出 IPA 路径清单改变')
                for entry in archive.infolist():
                    if entry.filename in replacements:
                        if target.read(entry.filename) != replacements[entry.filename]: raise ValueError('替换图片读回不一致')
                    else:
                        other = target.getinfo(entry.filename)
                        if (entry.CRC, entry.file_size) != (other.CRC, other.file_size):
                            raise ValueError(f'非目标文件改变：{entry.filename}')
            temporary.replace(output)
        finally:
            temporary.unlink(missing_ok=True)
    plan['bytes'] = output.stat().st_size
    (output.with_suffix('.startup-report.json')).write_text(json.dumps(plan, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    return plan


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest='action', required=True)
    render = actions.add_parser('render', help='按文字配置生成三张透明 PNG')
    render.add_argument('--ipa', type=Path, required=True)
    render.add_argument('--config', type=Path, required=True)
    render.add_argument('--output', type=Path, required=True, help='新的图片目录')
    change = actions.add_parser('pack', help='替换启动图片；默认只预览，--apply 才输出 IPA')
    change.add_argument('--ipa', type=Path, required=True)
    change.add_argument('--images', type=Path, required=True)
    change.add_argument('--output', type=Path, required=True)
    change.add_argument('--theme', choices=['both', 'base', 'lephon'], default='both')
    change.add_argument('--apply', action='store_true')
    build = actions.add_parser('build', help='从文字生成图片并打包；--apply 才输出 IPA')
    build.add_argument('--ipa', type=Path, required=True)
    build.add_argument('--config', type=Path, required=True)
    build.add_argument('--output', type=Path, required=True)
    build.add_argument('--theme', choices=['both', 'base', 'lephon'], default='both')
    build.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    try:
        if args.action == 'render':
            result = render_images(args.ipa, args.config, args.output)
        elif args.action == 'build':
            if args.output.exists() or args.output.resolve() == args.ipa.resolve():
                raise FileExistsError('输出 IPA 必须是尚不存在的新文件')
            images = args.output.with_name(args.output.stem + '-images')
            render_images(args.ipa, args.config, images)
            result = pack(args.ipa, images, args.output, args.theme, args.apply)
        else:
            result = pack(args.ipa, args.images, args.output, args.theme, args.apply)
        print(json.dumps(result, ensure_ascii=True, indent=2))
    except (OSError, ValueError, RuntimeError, KeyError, zipfile.BadZipFile) as e:
        print(f'错误：{e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
