#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 OTA 安装用的 manifest.plist。

iOS 的无线安装（"从空中投送"）只有一种官方形式：
    itms-services://?action=download-manifest&url=<manifest.plist 的 HTTPS 地址>

manifest 是个 XML，指向真正的 ipa 地址和它的元数据。iPad 用 Safari 打开那个
itms-services 链接，系统就会弹安装确认。

三个必须满足的硬条件，缺一个都装不上：
  1. ipa 与 manifest 必须通过 HTTPS 提供（http 会被直接拒掉）
  2. 服务器证书必须被设备信任（自签证书要先把根证书装进设备并信任）
  3. ipa 必须已经用含本机 UDID 的 Ad Hoc profile 签名

用法：
    python3 tools/make_manifest.py \
        --ipa-url https://example.com/recoilpad/RecoilPad.ipa \
        --version 1.0
"""

import argparse
import plistlib
from pathlib import Path
from urllib.parse import urljoin


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipa-url", required=True, help="ipa 的完整 HTTPS 地址")
    ap.add_argument("--bundle-id", default="com.yg.recoilpad")
    ap.add_argument("--version", default="1.0")
    ap.add_argument("--title", default="RecoilPad")
    ap.add_argument("--out", default="manifest.plist")
    args = ap.parse_args()

    if not args.ipa_url.lower().startswith("https://"):
        print("警告: itms-services 只接受 HTTPS，当前的 url 不是 https，设备会拒绝安装。")

    manifest = {
        "items": [
            {
                "assets": [
                    {"kind": "software-package", "url": args.ipa_url}
                ],
                "metadata": {
                    "bundle-identifier": args.bundle_id,
                    "bundle-version": args.version,
                    "kind": "software",
                    "title": args.title,
                },
            }
        ]
    }

    out = Path(args.out)
    out.write_bytes(plistlib.dumps(manifest, fmt=plistlib.FMT_XML))

    # 安装链接指向 manifest 本身，不是 ipa —— 这是最容易搞反的一处
    manifest_url = urljoin(args.ipa_url, out.name)
    install_url = (
        "itms-services://?action=download-manifest&url=" + manifest_url
    )

    print(f"已写入 {out}")
    print()
    print("ipa 地址      :", args.ipa_url)
    print("manifest 地址 :", manifest_url)
    print()
    print("在 iPad 上让 Safari 打开这个（发到微信/备忘录里点开也行）：")
    print()
    print("  " + install_url)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
