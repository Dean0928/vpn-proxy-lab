#!/usr/bin/env python3
"""生成 Shadowsocks SIP002 分享链接（ss:// URI）。

两种格式：
  * SIP002（默认）：ss://base64url(method:password)@host:port#tag
  * Legacy（--legacy）：ss://base64(method:password@host:port)#tag

⚠️ 生成的链接里含明文凭据（base64 不是加密），等同于密码。
   请不要把生成结果提交到仓库、贴到聊天群或发布到公网。

示例：
    ./ss-uri.py --host 203.0.113.10 --port 8388 \
        --method xchacha20-ietf-poly1305 --password 'your-pass' --tag vps-node

    ./ss-uri.py --host 203.0.113.10 --port 8388 --method aes-256-gcm \
        --password 'your-pass' --plugin 'obfs-local;obfs=http;obfs-host=www.bing.com'
"""

from __future__ import annotations

import argparse
import base64
import binascii
import sys
from urllib.parse import quote, urlencode

SUPPORTED_METHODS = (
    "aes-128-gcm",
    "aes-192-gcm",
    "aes-256-gcm",
    "chacha20-ietf-poly1305",
    "xchacha20-ietf-poly1305",
    "aes-128-cfb",
    "aes-192-cfb",
    "aes-256-cfb",
    "chacha20-ietf",
    "rc4-md5",
)


def b64url_encode(raw: bytes) -> str:
    """SIP002 要求 base64url 且去掉尾部 padding。"""
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def b64_standard_encode(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def b64_decode(text: str) -> bytes:
    """宽容解码：自动补齐 padding，兼容 urlsafe 与标准字母表。"""
    padded = text + "=" * (-len(text) % 4)
    try:
        return base64.urlsafe_b64decode(padded)
    except (binascii.Error, ValueError):
        return base64.b64decode(padded)


def build_uri(host: str, port: int, method: str, password: str,
              tag: str = "", plugin: str = "", legacy: bool = False) -> str:
    userinfo = f"{method}:{password}"
    if legacy:
        payload = f"{userinfo}@{host}:{port}"
        uri = f"ss://{b64_standard_encode(payload.encode('utf-8'))}"
    else:
        uri = f"ss://{b64url_encode(userinfo.encode('utf-8'))}@{host}:{port}"
        if plugin:
            uri += "/?" + urlencode({"plugin": plugin})
    if tag:
        uri += "#" + quote(tag)
    return uri


def parse_uri(uri: str) -> dict:
    """把 ss:// 链接还原成字段，便于验证生成结果。"""
    body = uri[len("ss://"):]
    tag = ""
    if "#" in body:
        body, tag = body.split("#", 1)
        tag = tag.replace("+", " ")
    if body.startswith("ss://"):
        body = body[len("ss://"):]

    if "@" in body:                      # SIP002
        userinfo_b64, hostpart = body.split("@", 1)
        userinfo = b64_decode(userinfo_b64).decode("utf-8")
        method, password = userinfo.split(":", 1)
    else:                                # legacy：整体 base64
        hostpart = ""
        decoded = b64_decode(body).decode("utf-8")
        userinfo, hostpart = decoded.split("@", 1)
        method, password = userinfo.split(":", 1)
        if "#" in hostpart:
            hostpart = hostpart.split("#", 1)[0]

    plugin = ""
    if "/?" in hostpart:
        hostpart, query = hostpart.split("/?", 1)
        for pair in query.split("&"):
            if pair.startswith("plugin="):
                plugin = pair[len("plugin="):]
    host, _, port = hostpart.rpartition(":")
    return {
        "method": method,
        "password": password,
        "host": host,
        "port": int(port) if port.isdigit() else port,
        "plugin": plugin,
        "tag": tag,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="生成 Shadowsocks（SIP002）分享链接",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例：\n  %(prog)s --host 203.0.113.10 --port 8388 "
               "--method xchacha20-ietf-poly1305 --password 'pass' --tag my-node",
    )
    parser.add_argument("--host", required=True, help="服务器地址（IP 或域名）")
    parser.add_argument("--port", required=True, type=int, help="服务端口")
    parser.add_argument("--method", required=True, help="加密方式，如 xchacha20-ietf-poly1305")
    parser.add_argument("--password", required=True, help="密码")
    parser.add_argument("--tag", default="", help="备注名（显示在客户端节点列表）")
    parser.add_argument("--plugin", default="", help="插件参数，如 obfs-local;obfs=http")
    parser.add_argument("--legacy", action="store_true", help="输出旧版整体 base64 格式")
    parser.add_argument("--verify", action="store_true", help="生成后回解验证字段一致")
    parser.add_argument("--quiet", action="store_true", help="只输出链接本身")
    args = parser.parse_args(argv)

    if not 1 <= args.port <= 65535:
        parser.error(f"端口超出范围：{args.port}")

    if args.method not in SUPPORTED_METHODS and not args.quiet:
        print(f"[WARN] 加密方式 '{args.method}' 不在常见列表内，请确认服务端支持。",
              file=sys.stderr)

    uri = build_uri(args.host, args.port, args.method, args.password,
                    tag=args.tag, plugin=args.plugin, legacy=args.legacy)

    if args.verify:
        parsed = parse_uri(uri)
        expected = {"method": args.method, "password": args.password,
                    "host": args.host, "port": args.port}
        for key, value in expected.items():
            if parsed[key] != value:
                print(f"[FAIL] 回解字段不一致：{key} -> {parsed[key]!r} != {value!r}",
                      file=sys.stderr)
                return 1
        if not args.quiet:
            print("[ OK ] 回解验证通过（method / password / host / port 一致）", file=sys.stderr)

    print(uri)
    sys.stdout.flush()
    if not args.quiet:
        print("\n⚠️  该链接含明文凭据（base64 仅编码，不是加密），请勿外发或提交到仓库。",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
