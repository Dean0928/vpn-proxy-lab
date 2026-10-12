#!/usr/bin/env python3
"""对实验截图做可审计的脱敏处理（像素化）。

为什么把脚本放进仓库：
    截图脱敏最怕"说不清哪里被打码了"。把**矩形坐标与处理方式**作为代码版本化，
    任何人都能核对"敏感区域确实被不可逆地像素化"，而不是简单涂一层色块。

处理方式：
    对每个矩形区域做**强像素化**（先缩到 1/BLOCKS 再最近邻放大），
    信息不可逆丢失，且肉眼可辨认为"刻意打码"。

用法：
    python3 tools/redact-images.py --source-dir <原始截图目录> --out-dir images
    python3 tools/redact-images.py --source-dir ./raw --out-dir ./images --preview-only

矩形坐标是相对于**原始截图**像素的 (x0, y0, x1, y1)，闭开区间。
"""

from __future__ import annotations

import argparse
import pathlib
import sys

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    print("需要 Pillow：pip install Pillow", file=sys.stderr)
    sys.exit(2)

BLOCKS = 6

# (原始文件名, 输出文件名, [(x0, y0, x1, y1), ...])
# 坐标对应原始报告中的 8 张截图；被遮区域分别是：
#   IP 地址、端口、密码、ss:// 分享链接（base64 内含明文凭据）、
#   实例 UUID、云主机名、macOS 用户名、个人域名。
RULES: list[tuple[str, str, list[tuple[int, int, int, int]]]] = [
    ("image1.png", "01-vpn-principle-infographic.jpg", []),
    ("image2.png", "02-vultr-deploy-instance.png", []),
    ("image3.png", "03-vultr-instance-running.png", [
        (36, 226, 222, 252),    # 实例 UUID
        (580, 205, 730, 228),   # 公网 IP（保留 Public: IPv4 + IPv6 说明行）
    ]),
    ("image4.png", "04-ping-latency-test.png", [
        (198, 12, 714, 58),     # 终端窗口标题（含 macOS 用户名与 IP）
        (206, 76, 280, 732),    # 每行 "64 bytes from <IP>" 中的 IP 片段
    ]),
    ("image5.png", "05-shadowsocks-server-install.png", [
        (364, 100, 640, 127),   # Your Server IP
        (364, 128, 640, 155),   # Your Server Port
        (364, 156, 640, 184),   # Your Password
        (22, 264, 1004, 301),   # ss:// 分享链接（base64 内含 IP:端口:密码）
    ]),
    ("image6.png", "06-shadowrocket-node-list.png", [
        (84, 142, 322, 191),    # 当前节点名（含 IP）
        (84, 442, 306, 473),    # 本地节点 1：IP
        (84, 501, 306, 533),    # 本地节点 2：IP
        (84, 565, 306, 593),    # 本地节点 3：IP
        (84, 624, 306, 653),    # 本地节点 4：IP
    ]),
    ("image7.png", "07-ip-info-after-connect.png", [
        (438, 168, 900, 202),   # Address（出口 IP）
        (438, 220, 900, 252),   # Hostname（<IP>.vultrusercontent.com）
    ]),
    ("image8.png", "08-failure-timeline-review.png", [
        (523, 496, 648, 528),   # 个人域名（配置证书时使用）
    ]),
]


def flatten(image: Image.Image) -> Image.Image:
    """把带 alpha 的图合成到白底上，避免透明区域被当成黑色。"""
    if image.mode in ("RGBA", "LA", "P"):
        image = image.convert("RGBA")
        background = Image.new("RGBA", image.size, (255, 255, 255, 255))
        image = Image.alpha_composite(background, image)
    return image.convert("RGB")


def pixelate(image: Image.Image, box: tuple[int, int, int, int], blocks: int = BLOCKS) -> None:
    x0, y0, x1, y1 = box
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(x1, image.width), min(y1, image.height)
    if x1 <= x0 or y1 <= y0:
        return
    region = image.crop((x0, y0, x1, y1))
    width, height = region.size
    small = region.resize((max(2, width // blocks), max(2, height // blocks)), Image.BILINEAR)
    image.paste(small.resize((width, height), Image.NEAREST), (x0, y0))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="对实验截图做可审计的像素化脱敏")
    parser.add_argument("--source-dir", required=True, help="原始截图所在目录")
    parser.add_argument("--out-dir", required=True, help="输出目录")
    parser.add_argument("--blocks", type=int, default=BLOCKS, help=f"像素块大小，默认 {BLOCKS}")
    parser.add_argument("--preview-only", action="store_true", help="只打印将要处理的区域，不写文件")
    args = parser.parse_args(argv)

    source_dir = pathlib.Path(args.source_dir)
    out_dir = pathlib.Path(args.out_dir)
    if not source_dir.is_dir():
        print(f"找不到源目录：{source_dir}", file=sys.stderr)
        return 2
    if not args.preview_only:
        out_dir.mkdir(parents=True, exist_ok=True)

    missing, total = [], 0
    for src_name, dst_name, boxes in RULES:
        src = source_dir / src_name
        if not src.exists():
            missing.append(src_name)
            print(f"[跳过] {src_name}（不存在）")
            continue
        print(f"[处理] {src_name} -> {dst_name}  区域数={len(boxes)}")
        for box in boxes:
            print(f"         pixelate {box}")
        if args.preview_only:
            continue
        image = flatten(Image.open(src))
        for box in boxes:
            pixelate(image, box, args.blocks)
        target = out_dir / dst_name
        if target.suffix.lower() in (".jpg", ".jpeg"):
            image.save(target, quality=90)
        else:
            image.save(target)
        total += 1
        print(f"         已写出 {target} {image.size}")

    if missing:
        print(f"\n提示：{len(missing)} 个源文件缺失（{', '.join(missing)}）。"
              "本仓库只保留了处理后的 images/，原始截图不随仓库发布。", file=sys.stderr)

    if not args.preview_only:
        print(f"\n完成，共写出 {total} 张脱敏图。")
        print("发布前请再执行一次：./tools/secret-scan.sh --all")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
