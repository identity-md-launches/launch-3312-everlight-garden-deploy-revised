# Everlight Garden

The revised Ethereum garden charges **1 IMD per paid candle**. Purchases start **closed**. Deploy one `WishGarden(address owner_)` on Ethereum and its matching `EverlightBurnReceiver(address owner_, address ethereumGarden_)` on Base. The garden contains its treasury and bridge queue. The owner is `0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9`.

| Allocation in IMD | First candle | Each later candle |
| --- | ---: | ---: |
| Restricted burn queue | 0.90 | 0.30 |
| All earlier paid candles | 0 | 0.60 |
| Ecosystem | 0 | 0 |
| Operations | 0.05 | 0.05 |
| Founder | 0.05 | 0.05 |

**Rewards come from subsequent candle purchases. Without new purchases, no new purchase-funded rewards accrue.** The rates and price are compile-time constants. The owner may withdraw the operations and founder balances separately. Ecosystem getters always return zero and bucket 0 rejects withdrawals.

## What a candle earns

Each candle increases the accumulator by `floor(0.60e18 × 10^27 / priorPaidCandles)` when earlier candles exist. Before adding the new weight, the contract settles the buyer's older candles through this increment. Other buyers' balances settle lazily on a read, claim or purchase. A batch follows the input array in order, so its earlier candles earn shares from its later ones. Work per candle is independent of the number of holders.

For example, candle 101 contributes 0.006 IMD to each of the first 100. A wallet holding three earns 0.018 IMD from that purchase. When a wallet buys again, its older candles share in its payment. Its new candle starts with zero accrued rewards.

`rewardState(wallet)` returns candle weight, lifetime earned whole base units, claimed, claimable and the retained scaled fraction. `claimRewards()` pays the calling beneficiary, including during a purchase pause. Division remainders accumulate in `rewardDustScaled`. They stay in the reward reserve permanently. Sub-unit wallet fractions carry across claims. Accounting in Ethereum IMD base units satisfies

```
rewardLiability     = totalRewardsAllocated - totalRewardsClaimed
accountedBalance    = operationsBalance + founderBalance + rewardLiability + burnQueued + burnReserved
totalBurnAllocated  = burnQueued + burnReserved + burnInTransit + confirmedBurn
totalPayments       = totalBurnAllocated + totalRewardsAllocated
                      + operationsBalance + totalOperationsWithdrawn
                      + founderBalance + totalFounderWithdrawn
```

Unsolicited transfers appear in `unallocatedBalance()`. For rewards in scaled units, the sum of all wallets' lifetime scaled earnings plus `rewardDustScaled` equals `totalRewardsAllocated × 10^27`.

## Purchases and wishes

`buyCandles(styles, wishes)` atomically collects exactly `styles.length × 10^18` units of the existing Ethereum IMD from the caller. A failed payment rolls back the entire batch. Each purchase takes 1–50 styles and the same number of wishes. Seven styles (0–6) have identical economics. The paying caller owns each permanent candle and its reward rights. Sequential IDs start at 1, with position equal to ID minus one.

Wishes are public forever in storage and events. An empty string omits the wish. The contract preserves strict UTF-8 up to 280 Unicode scalar values and 1,120 bytes per wish. Clients should render the original text as text, estimate gas with the actual batch and split long batches to fit transaction gas limits. Records are nontransferable and carry no NFT, lottery or expiry mechanism.

## Release materials

| Deliverable | File |
| --- | --- |
| Ethereum constructor, compiler settings, init-code hash and ABI | [Manifest handoff](docs/deployment/manifest-handoff.json) · [WishGarden ABI](docs/abi/WishGarden.json) |
| Base source, creation bytecode, salt and ABI | [Receiver](src/base/EverlightBurnReceiver.sol) · [Deployment package](docs/base/deployment-package.json) · [Receiver ABI](docs/base/EverlightBurnReceiver.json) |
| Address derivation, owner transactions, cutover and recovery | [Owner instructions](docs/deployment.md) |
| Website handoff | [Integration config](docs/integration.json) |
| Test results and dependency observations | [Validation](docs/verification.md) · [Block-pinned legacy and bridge reads](docs/evidence/cutover.json) |

The implementation started from commit `f3ae2915b2fc99c56079da2fc9addef2e94397e0`. The bridge interfaces, queue, receiver, purchase records and UTF-8 validator come from that source. This revision changes the economy and treasury allocation, retains the original bucket numbers and changes the reward event's fallback field to `fallbackToBurn`. Index the new garden separately. [Pinned source](https://github.com/identity-md-launches/launch-3281-everlightgarden-everlighttreasury-everli/tree/f3ae2915b2fc99c56079da2fc9addef2e94397e0)

This package is ready for the launch service's publication and Ethereum deployment review. The published revision, final factory salt, confirmed addresses, transactions and explorer verification belong to the deployment handoff after acceptance. Base deployment is pending owner execution. Opening purchases is a separate owner decision.

## Build and check

Dependencies are vendored as ordinary files. Use Foundry and solc 0.8.26. The optional fork checks are documented in the validation report.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x1417ba575f468fb35fd8903d5f7fa85930aff6b24352b87ad0e8593ed9e03e3e forge test
forge fmt --check
python3 scripts/export-abis.py --check
python3 test/base_package_test.py
```
