#!/usr/bin/env python3
"""
bech32_helper.py — derive cosmos-sdk bech32 addresses for Story L1.

Story uses secp256k1 for validator consensus keys. The cons address is
derived as ripemd160(sha256(compressed_pubkey)). Operator address is the
EVM-style 20-byte hash from delegator key derivation; this helper handles
the consensus-key path.

Modes (positional args):
  pub-to-cons  <pubkey_b64> <hrp>   -> bech32 cons addr (e.g., storyvalcons1...)
  pub-to-hex   <pubkey_b64>         -> hex cons addr (UPPERCASE, no prefix; matches CometBFT /validators .address)
  hex-to-bech32 <hex_str> <hrp>     -> bech32 addr from raw hex bytes

Reference: BIP-173 bech32 encoding + cosmos-sdk
  crypto/keys/secp256k1/secp256k1.go Address() -> ripemd160(sha256(.))
"""
import hashlib
import base64
import sys
from binascii import unhexlify

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]


def bech32_polymod(values):
    chk = 1
    for v in values:
        b = chk >> 25
        chk = (chk & 0x1ffffff) << 5 ^ v
        for i in range(5):
            chk ^= GEN[i] if (b >> i) & 1 else 0
    return chk


def bech32_hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]


def bech32_create_checksum(hrp, data):
    values = bech32_hrp_expand(hrp) + data
    polymod = bech32_polymod(values + [0, 0, 0, 0, 0, 0]) ^ 1
    return [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]


def convertbits(data, frombits, tobits, pad=True):
    acc = 0
    bits = 0
    ret = []
    maxv = (1 << tobits) - 1
    max_acc = (1 << (frombits + tobits - 1)) - 1
    for value in data:
        if value < 0 or (value >> frombits):
            return None
        acc = ((acc << frombits) | value) & max_acc
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad:
        if bits:
            ret.append((acc << (tobits - bits)) & maxv)
    elif bits >= frombits or ((acc << (tobits - bits)) & maxv):
        return None
    return ret


def bech32_encode(hrp, data):
    combined = data + bech32_create_checksum(hrp, data)
    return hrp + '1' + ''.join([CHARSET[d] for d in combined])


def addr_bytes_to_bech32(addr_bytes, hrp):
    data = convertbits(addr_bytes, 8, 5)
    return bech32_encode(hrp, data)


def secp256k1_cons_addr_bytes(pub_b64):
    pub_bytes = base64.b64decode(pub_b64)
    sha = hashlib.sha256(pub_bytes).digest()
    rip = hashlib.new('ripemd160')
    rip.update(sha)
    return rip.digest()


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    mode = sys.argv[1]
    if mode == "pub-to-cons":
        pub_b64, hrp = sys.argv[2], sys.argv[3]
        addr20 = secp256k1_cons_addr_bytes(pub_b64)
        print(addr_bytes_to_bech32(addr20, hrp))
    elif mode == "pub-to-hex":
        pub_b64 = sys.argv[2]
        addr20 = secp256k1_cons_addr_bytes(pub_b64)
        print(addr20.hex().upper())
    elif mode == "hex-to-bech32":
        hex_str, hrp = sys.argv[2], sys.argv[3]
        addr_bytes = unhexlify(hex_str)
        print(addr_bytes_to_bech32(addr_bytes, hrp))
    else:
        print(f"unknown mode: {mode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
