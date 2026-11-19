# Deployment and cutover

**Handoff state: purchases closed.** The launch service publishes the accepted source and tests, records the immutable GitHub revision, deploys and verifies the Ethereum garden. The owner deploys and verifies its Base receiver. Both production addresses await that sequence. The website config deliberately has null addresses and purchases disabled.

## Check the old deployment

The old garden on Ethereum is `0x39e55288f5b84dd867a784c95f110818ea8f3b31`. At block **26,448,570** it reported zero paid candles, zero owner balances, zero reward liability, zero burn allocations/jobs and zero IMD held. Purchases were paused and activation was false. Its configured receiver was ready. At Base block **59,471,144**, that receiver, `0xb525358f3f1c531522a27092e8aa1c054bb963fc`, reported the old garden as its immutable source, zero IMD held, zero pending and zero burned. Each read set includes its block hash. [Snapshot](evidence/cutover.json)

Immediately before cutover, repeat this read-only command with Ethereum and Base RPC URLs supplied to the shell variables. Archive the resulting JSON in the release record.

```sh
python3 scripts/read-cutover.py --ethereum-rpc "$ETH_RPC" --base-rpc "$BASE_RPC"
```

If any candles or liabilities have accrued, preserve the old records, claim entry point and owner and bridge accounting at their original addresses. Keep legacy claim instructions available to their beneficiaries. Reconcile any balances or in-flight jobs there separately. The new deployment starts its own IDs and weights from zero. No transaction in this setup targets the old garden or receiver.

## 1. Confirm the Ethereum deployment

Deploy only `src/WishGarden.sol:WishGarden` on chain **1**, with the single nonpayable constructor argument `address owner_ = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9`. Value is zero. The treasury and bridge queue compile into the garden. Compile the accepted revision using solc **0.8.26+commit.8a97fa7a**, Cancun, optimizer enabled, 200 runs, via IR disabled, metadata bytecode hash `none`. The generated handoff records the encoded argument and the hash of the creation bytecode with that argument appended. [Manifest handoff](deployment/manifest-handoff.json)

The launch service supplies the Ethereum factory and CREATE2 salt. Once available, independently calculate the expected address using the manifest's `initCodeKeccak256` and the launch service's actual values.

```sh
cast create2 --deployer "$ETH_FACTORY" --salt "$ETH_SALT" --init-code-hash "$GARDEN_INIT_CODE_HASH"
```

Match the result to the canonical deployment receipt and verified runtime, allowing for the compiled immutable `pinnedBaseReceiver`. Record the factory, salt, transaction, block hash, verified source/constructor, deployment addresses and accepted revision. Set `GARDEN` below from that receipt. Check `owner()`, `IMD()`, the price and all five allocation constants, zero accounting totals, `activated() == false` and `purchasesPaused() == true`.

## 2. Deploy the matching Base receiver

Read `pinnedBaseReceiver()` from the new garden on chain 1. Use the initial owner above even if garden ownership subsequently changes. The Base factory is the canonical deterministic deployer at `0x4e59b44847b379578588920cA78FbF26c0B4956C`, chain **8453**. Its observed runtime Keccak-256 is `0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989`. The salt is `keccak256("EVERLIGHT GARDEN Base burn receiver v1")`, or `0xe09dd7b91b0168191d78136fed79a755030ebc5b915c9d14b2635e6e73324323`.

```
initCode = receiver creation bytecode ++ abi.encode(initialOwner, GARDEN)
expectedReceiver = last20(keccak256(0xff ++ baseFactory ++ salt ++ keccak256(initCode)))
deployment calldata = salt ++ initCode
```

The different garden address changes the constructor encoding and requires a new receiver. The helper rejects both legacy addresses and compares its local derivation to the new garden's pin. Build from the accepted commit and compare the generated package before preparing a signature. [Receiver bytecode and build inputs](base/deployment-package.json) · [Base ABI](base/EverlightBurnReceiver.json)

```sh
forge build
python3 scripts/export-abis.py --check
PIN=$(cast call "$GARDEN" 'pinnedBaseReceiver()(address)' --rpc-url "$ETH_RPC")
python3 scripts/build-base-transaction.py --ethereum-garden "$GARDEN" --pinned-base-receiver "$PIN" --estimate-only
```

Check that the target factory on Base has the recorded code hash. Submit the returned `transaction` object to Base `eth_estimateGas` and obtain the owner's pending nonce and current EIP-1559 fee settings. Use the estimate plus margin for `GAS`. Generate the unsigned transaction as follows.

```sh
python3 scripts/build-base-transaction.py --ethereum-garden "$GARDEN" --pinned-base-receiver "$PIN" \
  --nonce "$NONCE" --gas "$GAS" --max-fee-per-gas "$MAX_FEE_WEI" \
  --max-priority-fee-per-gas "$PRIORITY_FEE_WEI"
```

The JSON envelope includes `expectedReceiver` and a separate `transaction` for the wallet. Review and execute the latter on Base. It calls the deterministic deployer with zero ETH and the exact calldata above. If the receiver already exists at the pin, verify the deployment there before proceeding. Record the transaction and confirm code at the pin. Verify the source and both constructor arguments against the accepted package, and check `owner()`, `ethereumGarden() == GARDEN`, `IMD()` and initial `activated() == false`.

## 3. Verify bridge readiness

Review both routes for the **actual new pair** and archive the observations with chain IDs and block hashes.

| Check | Ethereum | Base |
| --- | --- | --- |
| Endpoint V2 | `0x1a44076050125825900e736c501f859c50fE728c`, EID 30101 | Same address, EID 30184 |
| Official OFT route | IMD `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`, own token, approvalRequired false, peer 30184 equals Base adapter | Adapter `0xab152db8aaC047b6757fFCF495FfE88d7712690A`, approvalRequired true, peer 30101 equals Ethereum IMD |
| Token and amount | 18 decimals, OFT conversion rate 10^12 | Adapter token `0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105`, 18 decimals, same conversion |
| Bindings | `pinnedBaseReceiver() == PIN` | Address equals PIN and `ethereumGarden() == GARDEN` |

Check current runtime hashes, adapter collateral, token transfer limits, migration and trading status, and blacklist/AMM treatment of the adapter and receiver. The supplied Base token reports the symbol “Fren Pet”. Use its address and verified official pairing. Check the LayerZero send/receive libraries, DVNs, confirmations, executor settings and fees for **both** the OFT route and the distinct Base-receiver → Ethereum-garden application receipt channel. These applications depend on endpoint defaults for the receipt channel. Bridge and token administrators can change external configuration.

Simulate packet delivery with current state. Fixed budgets are 200,000 gas for receive, 650,000 for compose index 0, 1,000,000 for the Ethereum send subcall and 150,000 for the Base burn subcall. Native-only quote ceiling is 0.05 ETH per message. Include both deployments, bytecode hashes, reciprocal bindings, checked route, liquidity, fees and security settings in the owner-reviewed evidence file. Use Keccak-256 of its exact bytes as the same nonzero `evidenceHash` on both chains.

## 4. Configure the pair and stop with sales closed

| Order | Chain and target | Owner call | Native value and confirmation |
| ---: | --- | --- | --- |
| 1 | 1, new garden | `configureBridge(PIN, evidenceHash)` | 0. Read `baseReceiver()`, `bridgeEvidence()` and `bridgeConfigHash()`. |
| 2 | 8453, pinned receiver | `activate(evidenceHash)` | 0. Base activation is one-time. Verify `ethereumGarden()`, `evidenceHash()` and `configHash() == garden.bridgeConfigHash()`. |
| 3 | 8453, pinned receiver | Read `quoteReceipt(1, bytes32(0))`, then call `announceReady()` | Pay exactly the quoted native fee with zero LZ-token fee. Kind 1 with empty GUID identifies readiness. Archive the receipt message GUID. |
| 4 | 1, new garden | Read `baseReady()`, `activated()` and `purchasesPaused()` | Require canonical `BaseReadinessConfirmed(PIN, bridgeConfigHash)`, then true, false and true respectively. |

The shared configuration hash is `keccak256(abi.encode(uint256(1), GARDEN, uint256(8453), PIN, evidenceHash))`. Reconfiguration on Ethereum before activation resets readiness. Keep the reviewed evidence bytes, quote, transaction receipts and the block containing the readiness event. This is the stopping point for the order.

The owner may **separately** authorize opening after review by calling Ethereum `activate()` with zero value. It freezes the configuration and opens purchases. The owner can later call `setPurchasesPaused(true)` to pause buying. Claims remain available during a pause. The website should require confirmed new contract addresses, the correct chains, `activated() == true` and `purchasesPaused() == false` before enabling purchases.

## Burn operations after opening

| Stage | Evidence and recovery |
| --- | --- |
| Allocation | `BurnAllocated`, `totalBurnAllocated` and `burnQueued` reflect restricted Ethereum IMD. |
| Reservation | Owner calls `queueBurn(maximumAmount)`. The job reserves whole 10^12-unit lots. `failedBurnAmount` is a subset of `burnReserved`. |
| Dispatch | Owner reads `quoteBurn(jobId)` and calls `dispatchBurn(jobId)` with the exact native fee. A caught failure returns false and retains the reservation. Retry the same ID. Success emits `BurnDispatched` and records an in-transit amount and GUID. Cumulative dispatched amount equals `burnInTransit + confirmedBurn`. |
| Base delivery | The adapter credits the receiver. An authenticated compose records `totalReceived`, burns IMD and verifies the exact receiver balance and total supply decreases. `SupplyBurned` and `totalBurned()` are Base burn evidence. A recorded failed burn stays in `pendingBurn` and can be retried with `retryBurn(originalGuid)`. A failed endpoint delivery uses the original LayerZero packet. |
| Return receipt | Anyone can pay the native fee from `quoteReceipt(2, originalGuid)` to `sendBurnReceipt(originalGuid)`. The receiver's acknowledged flag records a successful send. Ethereum finalizes only on the matching authenticated receipt and emits `BurnConfirmed`. Retry an undelivered receipt packet through LayerZero. |

Count a burn once. Ethereum's OFT debit, Base credit, Base supply reduction and Ethereum acknowledgement describe successive stages of the same amount. Out-of-order jobs retain their individual IDs and GUIDs. The owner has no override that pays out burn reserves or marks a job burned. Two-step ownership controls purchase pauses, gas-funded dispatch and withdrawals from buckets 1 (operations) and 2 (founder). For each withdrawal the current owner supplies a destination and amount. The initial designated operator and default fee recipient is the named owner.
