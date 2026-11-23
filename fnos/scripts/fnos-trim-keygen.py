#!/usr/bin/env python3
"""无 SMBIOS 环境下按 /etc/machine-id 自愈 /usr/trim/etc/trim.key.enc（284 字节）。"""
import hashlib
import hmac
import os
import sys

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except Exception:
    sys.exit(0)

KEYFILE = "/usr/trim/etc/trim.key.enc"
UUID = b"00000000-0000-0000-0000-000000000000"

try:
    with open("/etc/machine-id", "rb") as f:
        mid = f.read(32)
except Exception:
    sys.exit(0)

if len(mid) < 32:
    sys.exit(0)

master = hmac.new(UUID, mid, hashlib.sha256).digest()

# 已有 key 且能用本机 master 解密时保留，避免重启后登录令牌失效
if os.path.exists(KEYFILE):
    try:
        with open(KEYFILE, "rb") as f:
            blob = f.read()
        if len(blob) == 284:
            AESGCM(master).decrypt(blob[:12], blob[12:], None)
            sys.exit(0)
    except Exception:
        pass

trim_key = os.urandom(256)
iv = os.urandom(12)
blob = iv + AESGCM(master).encrypt(iv, trim_key, None)
os.makedirs(os.path.dirname(KEYFILE), exist_ok=True)
with open(KEYFILE, "wb") as f:
    f.write(blob)
os.chmod(KEYFILE, 0o600)
