#!/usr/bin/env python3
"""Build an unsigned EIP-1559 Base deployment request for the owner's wallet. No network, keys or signing.

The receiver is deployed with CREATE2 through the canonical deterministic deployer, because the
Ethereum garden accepts exactly one Base destination: pinnedBaseReceiver(), the CREATE2 address of
this creation bytecode with (owner, garden) arguments and the source-fixed salt."""
import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OWNER = "0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9"
CREATE2_DEPLOYER = "0x4e59b44847b379578588920cA78FbF26c0B4956C"
SALT_PREIMAGE = b"EVERLIGHT GARDEN Base burn receiver v1"
LEGACY_ADDRESSES = {"0x39e55288f5b84dd867a784c95f110818ea8f3b31", "0xb525358f3f1c531522a27092e8aa1c054bb963fc"}

_RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000, 0x000000000000808B,
       0x0000000080000001, 0x8000000080008081, 0x8000000000008009, 0x000000000000008A, 0x0000000000000088,
       0x0000000080008009, 0x000000008000000A, 0x000000008000808B, 0x800000000000008B, 0x8000000000008089,
       0x8000000000008003, 0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
       0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_MASK = (1 << 64) - 1

def keccak256(data):
    """Ethereum's Keccak-256 (not hashlib's SHA3-256, which pads differently). Standard library only."""
    rol = lambda value, shift: ((value << shift) | (value >> (64 - shift))) & _MASK if shift else value
    padded = bytearray(data)
    padded.append(0x01)
    padded.extend(b"\x00" * (-len(padded) % 136))
    padded[-1] |= 0x80
    a = [[0] * 5 for _ in range(5)]
    for offset in range(0, len(padded), 136):
        for i in range(17):
            a[i % 5][i // 5] ^= int.from_bytes(padded[offset + 8 * i:offset + 8 * i + 8], "little")
        for constant in _RC:
            c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
            d = [c[(x - 1) % 5] ^ rol(c[(x + 1) % 5], 1) for x in range(5)]
            a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
            b = [[0] * 5 for _ in range(5)]
            for x in range(5):
                for y in range(5):
                    b[y][(2 * x + 3 * y) % 5] = rol(a[x][y], _ROT[x][y])
            a = [[b[x][y] ^ (~b[(x + 1) % 5][y] & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
            a[0][0] ^= constant
    return b"".join(a[i % 5][i // 5].to_bytes(8, "little") for i in range(4))

def receiver_address(init_code):
    """CREATE2 address of `init_code` from the canonical deployer with the source-fixed salt."""
    digest = keccak256(b"\xff" + bytes.fromhex(CREATE2_DEPLOYER[2:]) + keccak256(SALT_PREIMAGE) + keccak256(init_code))
    return "0x" + digest[12:].hex()

def address_word(value):
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value) or int(value, 16) == 0:
        raise ValueError("a nonzero, service-confirmed Ethereum garden address is required")
    return value[2:].lower().rjust(64, "0")

def deployment(garden, pinned):
    if garden.lower() in LEGACY_ADDRESSES or pinned.lower() in LEGACY_ADDRESSES:
        raise ValueError("a legacy address was supplied for the new deployment")
    package = json.loads((ROOT / "docs/base/deployment-package.json").read_text())
    for relative, expected in package["sourceSHA256"].items():
        path = ROOT / relative
        if not relative.startswith("src/") or ".." in Path(relative).parts:
            raise ValueError("invalid source path in Base package")
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError("stale Base package; rebuild and rerun scripts/export-abis.py")
    salt = keccak256(SALT_PREIMAGE).hex()
    if package.get("create2Salt") != "0x" + salt or package.get("create2Deployer") != CREATE2_DEPLOYER:
        raise ValueError("stale Base package; rebuild and rerun scripts/export-abis.py")
    bytecode = package["creationBytecode"].removeprefix("0x")
    if "0x" + keccak256(bytes.fromhex(bytecode)).hex() != package["creationBytecodeKeccak256"]:
        raise ValueError("receiver creation bytecode differs from the package hash")
    init_code = bytecode + address_word(OWNER) + address_word(garden)
    expected = receiver_address(bytes.fromhex(init_code))
    if expected != pinned.lower():
        raise ValueError("derived receiver differs from pinnedBaseReceiver()")
    return {"expectedReceiver": expected, "transaction": {
        "from": OWNER, "to": CREATE2_DEPLOYER, "value": "0x0", "data": "0x" + salt + init_code}}

def build(garden, pinned, nonce, gas, max_fee, priority_fee):
    if nonce < 0 or gas <= 0 or max_fee <= 0 or priority_fee < 0 or priority_fee > max_fee:
        raise ValueError("invalid transaction gas, fee or nonce")
    result = deployment(garden, pinned)
    result["transaction"].update(type="0x2", chainId=hex(8453), nonce=hex(nonce), gas=hex(gas),
                                 maxFeePerGas=hex(max_fee), maxPriorityFeePerGas=hex(priority_fee), accessList=[])
    return result

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ethereum-garden", required=True)
    parser.add_argument("--pinned-base-receiver", required=True, help="read pinnedBaseReceiver() on the new garden")
    parser.add_argument("--estimate-only", action="store_true", help="prepare the call for Base eth_estimateGas")
    parser.add_argument("--nonce", type=int)
    parser.add_argument("--gas", type=int, help="Base node-estimated deployment gas plus margin")
    parser.add_argument("--max-fee-per-gas", type=int, help="wei")
    parser.add_argument("--max-priority-fee-per-gas", type=int, help="wei")
    args = parser.parse_args()
    try:
        fields = [args.nonce, args.gas, args.max_fee_per_gas, args.max_priority_fee_per_gas]
        if args.estimate_only:
            tx = deployment(args.ethereum_garden, args.pinned_base_receiver)
        elif None in fields:
            parser.error("provide nonce, gas and both fees, or use --estimate-only")
        else:
            tx = build(args.ethereum_garden, args.pinned_base_receiver, *fields)
    except ValueError as exc:
        parser.error(str(exc))
    print(json.dumps(tx, indent=2))
