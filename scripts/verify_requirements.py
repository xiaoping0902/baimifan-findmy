#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
校验签名里的 CS_REQUIREMENTS 是「空要求」。

用法：
    python3 scripts/verify_requirements.py <Mach-O 路径>

为什么需要这个
──────────────
ldid 在不带 -Q 时会自动生成一条开发证书指定要求（ldid.cpp:2062-2089）：

    identifier "FindMy" and anchor apple generic
      and certificate leaf[subject.CN] == "" and ...

而 TrollStore 重签时按 kSecCSPreserveRequirements 把它**原样保留**
（codesign.m:127），于是一路活到设备上。

问题是：ad-hoc 签名永远满足不了 "anchor apple generic"。
等于给自己挂了一条注定失败的设计要求。

白米饭那边这一项是 12 字节空要求：
    fa de 0c 01 00 00 00 0c 00 00 00 00

本脚本从 Mach-O 里把 CS_REQUIREMENTS blob 挖出来核对，
不是空要求就非零退出，让 CI 直接失败。

数据结构（全部来自 Apple 公开的 codesign 格式）
─────────────────────────────────────────────
  Mach-O header (arm64, magic 0xfeedfacf)
    → load commands 里找 LC_CODE_SIGNATURE (0x1d) = linkedit_data_command
    → 得到 signature 的 file offset / size
  CS_SuperBlob (magic 0xfade0cc0, 大端)
    → index[]: { type, offset }
    → type == 2 即 CS_REQUIREMENTS
  CS_RequirementsBlob: magic 0xfade0c01 + length，空要求时 length = 12
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_REQUIREMENTS = 0xFADE0C01
CSSLOT_REQUIREMENTS = 2

# 12 字节空要求，与白米饭逐字节一致
EMPTY_REQUIREMENTS = bytes([
    0xFA, 0xDE, 0x0C, 0x01,
    0x00, 0x00, 0x00, 0x0C,
    0x00, 0x00, 0x00, 0x00,
])


def find_code_signature(data: bytes):
    """返回 (offset, size)；找不到返回 (0, 0)。"""
    magic, _cpu, _sub, _ft, ncmds, _sz, _flags, _res = struct.unpack_from('<8I', data, 0)
    if magic != MH_MAGIC_64:
        raise ValueError(f'不是 arm64 Mach-O（magic=0x{magic:08x}）')

    off = 32   # sizeof(mach_header_64)
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<2I', data, off)
        if cmd == LC_CODE_SIGNATURE:
            return struct.unpack_from('<2I', data, off + 8)
        off += cmdsize
    return 0, 0


def find_requirements(data: bytes, sig_off: int, sig_size: int):
    """从 SuperBlob 里取出 CS_REQUIREMENTS 的原始字节；没有返回 None。"""
    if sig_off + sig_size > len(data) or sig_size < 12:
        raise ValueError('LC_CODE_SIGNATURE 范围越界')

    sb_magic, sb_len, sb_count = struct.unpack_from('>3I', data, sig_off)
    if sb_magic != CSMAGIC_EMBEDDED_SIGNATURE:
        raise ValueError(f'不是 CS_SuperBlob（magic=0x{sb_magic:08x}）')
    if sb_len > sig_size:
        raise ValueError(f'SuperBlob 长度 {sb_len} 超过签名区 {sig_size}')

    for i in range(sb_count):
        at = sig_off + 12 + i * 8
        if at + 8 > len(data):
            break
        slot, blob_off = struct.unpack_from('>2I', data, at)
        if slot != CSSLOT_REQUIREMENTS:
            continue
        blob_at = sig_off + blob_off
        if blob_at + 8 > len(data):
            raise ValueError('requirements blob 偏移越界')
        bmagic, blen = struct.unpack_from('>2I', data, blob_at)
        if bmagic != CSMAGIC_REQUIREMENTS:
            raise ValueError(f'requirements blob magic 不对：0x{bmagic:08x}')
        return data[blob_at:blob_at + blen]
    return None


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    path = sys.argv[1]
    with open(path, 'rb') as f:
        data = f.read()

    try:
        sig_off, sig_size = find_code_signature(data)
        if sig_off == 0 or sig_size == 0:
            print('::error::找不到 LC_CODE_SIGNATURE —— 这个二进制没签名')
            return 1

        req = find_requirements(data, sig_off, sig_size)
    except ValueError as e:
        print(f'::error::解析失败：{e}')
        return 1

    if req is None:
        print('  ✓ 没有 CS_REQUIREMENTS blob（同样算干净）')
        return 0

    if req == EMPTY_REQUIREMENTS:
        print('  ✓ CS_REQUIREMENTS = 12 字节空要求（与白米饭逐字节一致）')
        return 0

    if len(req) == 12:
        # 长度对但内容不同：给出内容但不判失败（不同 ldid 版本可能填法略有差别）
        print(f'  ✓ CS_REQUIREMENTS 长度 12（内容 {req.hex()}）')
        return 0

    print(f'::error::CS_REQUIREMENTS 是 {len(req)} 字节，不是空要求 —— '
          f'ldid 又自造 DR 了，ad-hoc 签名永远满足不了它')
    print('  内容:', req[:160].hex())
    return 1


if __name__ == '__main__':
    sys.exit(main())
