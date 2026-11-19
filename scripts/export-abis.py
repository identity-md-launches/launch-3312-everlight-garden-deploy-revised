#!/usr/bin/env python3
"""Export checked Ethereum ABI and a separate, reproducible Base artifact. Never signs or broadcasts."""
import argparse
import hashlib
import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("base_transaction", ROOT / "scripts/build-base-transaction.py")
base_transaction = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base_transaction)

def export(check=False):
    for name in ("WishGarden", "EverlightBurnReceiver"):
        source = ROOT / "out" / f"{name}.sol" / f"{name}.json"
        if not source.is_file():
            raise SystemExit(f"Missing {source.relative_to(ROOT)}; run forge build first")
        artifact = json.loads(source.read_text())
        if "__" in artifact["bytecode"]["object"] or artifact["bytecode"].get("linkReferences"):
            raise SystemExit(f"{name}: external library linkage is forbidden")
        outputs = {ROOT / "docs" / ("abi" if name == "WishGarden" else "base") / f"{name}.json": artifact["abi"]}
        bytecode = bytes.fromhex(artifact["bytecode"]["object"].removeprefix("0x"))
        creation_hash = "0x" + base_transaction.keccak256(bytecode).hex()
        settings = artifact["metadata"]["settings"]
        build = {
            "solc": artifact["metadata"]["compiler"]["version"], "evmVersion": settings["evmVersion"],
            "optimizer": settings["optimizer"], "viaIR": settings.get("viaIR", False),
            "bytecodeHash": settings["metadata"]["bytecodeHash"]
        }
        if name == "WishGarden":
            owner_arg = bytes.fromhex(base_transaction.address_word(base_transaction.OWNER))
            outputs[ROOT / "docs/deployment/manifest-handoff.json"] = {
                "kind": "evm_contracts", "chainId": 1,
                "baselineCommit": "f3ae2915b2fc99c56079da2fc9addef2e94397e0",
                "status": "pending launch service review, publication, Ethereum deployment and verification",
                "build": build, "applications": [{
                    "contract": name, "source": "src/WishGarden.sol", "abi": "docs/abi/WishGarden.json",
                    "constructorTypes": ["address"], "constructorArgs": [base_transaction.OWNER],
                    "encodedArgs": "0x" + owner_arg.hex(), "valueWei": "0",
                    "creationBytecodeKeccak256": creation_hash,
                    "initCodeKeccak256": "0x" + base_transaction.keccak256(bytecode + owner_arg).hex(),
                    "factory": None, "create2Salt": None, "expectedAddress": None,
                    "deploymentInputsFrom": "accepted launch manifest and launch service",
                    "initialState": {"activated": False, "purchasesPaused": True},
                }],
                "baseOwnerDeployment": "docs/base/deployment-package.json",
                "setup": "docs/deployment.md"
            }
        else:
            sources = {}
            for path in sorted((ROOT / "src").rglob("*.sol")):
                sources[str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
            outputs[ROOT / "docs/base/deployment-package.json"] = {
                "chainId": 8453,
                "contract": name,
                "excludedFromEthereumManifest": True,
                "owner": base_transaction.OWNER,
                "constructorTypes": ["address", "address"],
                "constructorFields": ["owner", "service-confirmed Ethereum WishGarden address"],
                "deployment": "CREATE2 through the canonical deterministic deployer; calldata = salt ++ "
                              "creationBytecode ++ abi.encode(owner, garden). The resulting address must equal "
                              "WishGarden.pinnedBaseReceiver() on Ethereum; any other address is rejected there.",
                "create2Deployer": base_transaction.CREATE2_DEPLOYER,
                "create2SaltPreimage": base_transaction.SALT_PREIMAGE.decode(),
                "create2Salt": "0x" + base_transaction.keccak256(base_transaction.SALT_PREIMAGE).hex(),
                "build": build, "creationBytecode": artifact["bytecode"]["object"],
                "creationBytecodeKeccak256": creation_hash,
                "sourceSHA256": sources,
                "status": "unsigned; Base deployment and activation are later owner steps"
            }
        for path, value in outputs.items():
            encoded = json.dumps(value, indent=2) + "\n"
            if check:
                if not path.is_file() or path.read_text() != encoded:
                    raise SystemExit(f"Artifact differs: {path.relative_to(ROOT)}")
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(encoded)
            print(f"{'Checked' if check else 'Exported'} {path.relative_to(ROOT)}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    export(parser.parse_args().check)
