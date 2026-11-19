#!/usr/bin/env python3
"""Read legacy liabilities and bridge dependencies at one numbered block per chain."""
import argparse
import json
import subprocess
from datetime import datetime, timezone
from urllib.request import Request, urlopen

GARDEN = "0x39e55288f5b84dd867a784c95f110818ea8f3b31"
RECEIVER = "0xb525358f3f1c531522a27092e8aa1c054bb963fc"
OFT = "0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7"
TOKEN = "0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105"
ADAPTER = "0xab152db8aaC047b6757fFCF495FfE88d7712690A"
ENDPOINT = "0x1a44076050125825900e736c501f859c50fE728c"
DEPLOYER = "0x4e59b44847b379578588920cA78FbF26c0B4956C"


def cast(*args):
    return subprocess.check_output(["cast", *args], text=True).strip()


def snapshot(url, chain_id, tag):
    def rpc(method, params):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
        request = Request(url, body.encode(), {"Content-Type": "application/json"})
        with urlopen(request, timeout=45) as response:
            reply = json.load(response)
        if "error" in reply:
            raise RuntimeError(f"{method} on chain {chain_id}: {reply['error']['message']}")
        return reply["result"]

    if int(rpc("eth_chainId", []), 16) != chain_id:
        raise ValueError(f"Expected chain {chain_id}")
    header = rpc("eth_getBlockByNumber", [tag, False])
    number = header["number"]
    contracts = {}

    def read_contract(address, counters="", views=()):
        code = rpc("eth_getCode", [address, number])
        if code == "0x":
            raise ValueError(f"Missing code at {address} in block {number}")
        result = {"runtimeKeccak256": cast("keccak", code), "reads": {}}
        contracts[address] = result
        for method, output, *args in [(k + "()", "uint256") for k in counters.split()] + list(views):
            data = cast("calldata", method, *args)
            raw = rpc("eth_call", [{"to": address, "data": data}, number])
            value = cast("abi-decode", method + "(" + output + ")", raw)
            if output.startswith("uint"):
                value = str(int(raw, 16))
            elif output == "bool":
                value = value == "true"
            elif output == "string":
                value = json.loads(value)
            result["reads"][method.split("(")[0] + "(" + ",".join(args) + ")"] = value

    def route_views(remote_eid):
        return [
            ("token()", "address"), ("endpoint()", "address"), ("peers(uint32)", "bytes32", remote_eid),
            ("approvalRequired()", "bool"), ("decimalConversionRate()", "uint256"),
        ]

    read_contract(ENDPOINT, views=[("eid()", "uint32")])
    if chain_id == 1:
        read_contract(GARDEN, """
            totalCandles totalPayments rewardLiability totalRewardsAllocated totalRewardsClaimed
            rewardDustScaled ownerWithdrawable founderBalance operationsBalance ecosystemBalance
            totalEcosystemWithdrawn totalFounderWithdrawn totalOperationsWithdrawn accountedBalance
            unallocatedBalance totalBurnAllocated burnQueued burnReserved burnInTransit failedBurnAmount
            confirmedBurn burnJobCount
        """, [("owner()", "address"), ("activated()", "bool"), ("purchasesPaused()", "bool"),
              ("pinnedBaseReceiver()", "address"), ("baseReceiver()", "address"), ("baseReady()", "bool")])
        read_contract(OFT, views=route_views("30184") + [
            ("symbol()", "string"), ("decimals()", "uint8"), ("balanceOf(address)", "uint256", GARDEN)])
    else:
        read_contract(RECEIVER, "totalReceived pendingBurn totalBurned failedBurn",
                      [("owner()", "address"), ("activated()", "bool"), ("ethereumGarden()", "address")])
        read_contract(ADAPTER, views=route_views("30101"))
        read_contract(TOKEN, views=[
            ("symbol()", "string"), ("decimals()", "uint8"), ("balanceOf(address)", "uint256", RECEIVER),
            ("balanceOf(address)", "uint256", ADAPTER), ("preMigrationPhase()", "bool"),
            ("tradingActive()", "bool"), ("limitsInEffect()", "bool"), ("maxWallet()", "uint256"),
            ("isBlacklisted(address)", "bool", ADAPTER),
        ])
        read_contract(DEPLOYER)
    if rpc("eth_getBlockByNumber", [number, False])["hash"] != header["hash"]:
        raise RuntimeError("Chain reorganized during snapshot. Repeat the reads.")
    return {"chainId": chain_id, "block": int(number, 16), "blockHash": header["hash"],
            "blockTimeUTC": datetime.fromtimestamp(int(header["timestamp"], 16), timezone.utc).isoformat(),
            "contracts": contracts}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ethereum-rpc", required=True)
    parser.add_argument("--base-rpc", required=True)
    parser.add_argument("--ethereum-block", default="latest", help="hex block number or tag")
    parser.add_argument("--base-block", default="latest", help="hex block number or tag")
    args = parser.parse_args()
    evidence = {
        "purpose": "Read-only legacy and dependency state. Amounts are raw token units.",
        "ethereum": snapshot(args.ethereum_rpc, 1, args.ethereum_block),
        "base": snapshot(args.base_rpc, 8453, args.base_block),
    }
    print(json.dumps(evidence, indent=2))
