# Validation and evidence

## Source and reproducibility

The archive at commit `f3ae2915b2fc99c56079da2fc9addef2e94397e0` was fetched successfully. All 375 archive files matched the Git blob IDs in that commit's tree. The revised project includes the application sources, tests and ordinary-file dependencies for offline compilation. The receiver creation bytecode matches the pinned baseline byte for byte, with Keccak-256 `0x307048cd046bc2ab895923175449c7098d4ecb440ef9309524337b2e4c04c87f`. Its new deployment address depends on its new immutable garden argument. [Baseline tree](https://github.com/identity-md-launches/launch-3281-everlightgarden-everlighttreasury-everli/tree/f3ae2915b2fc99c56079da2fc9addef2e94397e0) · [Dependency provenance](THIRD_PARTY.md)

## Offline Foundry and package checks

With Foundry 1.9.0 and the pinned solc 0.8.26, the default suite passed **97 tests in 16 suites**, including fuzz and stateful invariants, using seed `0x1417ba575f468fb35fd8903d5f7fa85930aff6b24352b87ad0e8593ed9e03e3e`. The build, formatting check, generated artifact comparison and three Python package tests passed.

| Question | Evidence |
| --- | --- |
| Does the new economy conserve every payment? | First and second purchases check exact counters and emitted burn amounts. Candle 101 checks the three-candle 0.018 IMD example. Independent per-candle and custody models compare scaled earnings, dust, claims, withdrawals, donated tokens and each burn stage against the contract. |
| Who earns and who can withdraw? | Same-wallet, interleaved buyers, batch-versus-sequential, repeated claim and pause tests. Bucket 0 rejects withdrawals. Exhausting operations and founder leaves rewards and burn backed. Failed and inexact payments and payouts roll back. Reentrant calls and unauthorized owner calls are rejected. |
| Do wishes survive? | Purchase tests check permanent records, IDs beyond 10,000, seven styles, indexing, pages and atomic rejection. Unicode tests cover byte/codepoint boundaries and malformed sequences. |
| Can a failed or duplicated message move funds twice? | Local endpoint/OFT doubles exercise bad peers, wrong receiver, wrong GUID/amount/configuration, out-of-order receipts, duplicate messages, failed sends/burns and same-job retries. Invariants reconcile reserved, in-transit, received, failed, burned and confirmed amounts. |
| Do the expected contracts fit and bind? | Empty-chain constructor, ownership and opcode/size checks plus actual CREATE2 deployment to the predicted receiver. Offline runtime fixtures exercise the Ethereum OFT debit, Base adapter credit and Base token supply change with seeded storage. |
| Do the package and constructor encoding match? | The Python tests independently encode both arguments and calculate the CREATE2 address using Cast. A mismatched pin and both legacy addresses are rejected. |

## Fork simulations

Two additional tests passed against numbered blocks. Each creates fresh application instances in local fork state. Neither test signs or submits a transaction to the network.

| Fork | What executed |
| --- | --- |
| Ethereum 26,448,570 | The harness supplied a local buyer balance and an authenticated-readiness fixture. One local purchase funded a 0.90 IMD job. The deployed Ethereum OFT, endpoint and messaging libraries quoted and dispatched it. Ethereum supply fell by 0.90 IMD, the garden retained 0.10 IMD, the job was in transit and confirmed burn was zero. |
| Base 59,471,144 | The canonical deployer created the receiver at the local garden's pin. Starting at the adapter's authenticated entry point, the test supplied a packet from that garden. The deployed adapter credited 0.90 IMD from its collateral. Delivery through the deployed endpoint caused `burn()` to reduce both receiver balance and token supply by exactly 0.90 IMD. The receiver successfully sent a separately funded receipt into the endpoint. |

The two forks have independent state. The harness supplies the remote packet at the authentication boundary. Production DVN verification, interchain delivery/finality, deployed receiver ownership and the new pair's readiness require live deployment evidence. [Owner checks](deployment.md)

To reproduce, set the RPC arguments to services with archive state at the recorded heights. The default Foundry suite has no network dependency.

```sh
FOUNDRY_TEST=fork-test forge test --match-contract EthereumSendForkTest \
  --fork-url "$ETH_RPC" --fork-block-number 26448570 --fork-state-by-number --no-storage-caching
FOUNDRY_TEST=fork-test forge test --match-contract BaseBurnForkTest \
  --fork-url "$BASE_RPC" --fork-block-number 59471144 --fork-state-by-number --no-storage-caching
```

## Live observations and deployment status

The read-only snapshot records chain IDs, block numbers/hashes, runtime hashes, reciprocal OFT peers, conversion rate, approval modes, endpoint IDs and legacy custody. The Ethereum OFT, Base adapter, Base token and Base deterministic deployer runtime hashes match those in the pinned project's November 16 dependency evidence. The Base token's observed symbol was “Fren Pet”, trading was active, limits were enabled and the adapter held 4,303,670.601179 IMD at the Base snapshot. Its collateral and transfer policy must be checked again with the actual receiver at cutover. [November 19 reads](evidence/cutover.json) · [Imported historical dependency evidence](evidence/bridge-dependencies.json)

The old garden and receiver had zero IMD and zero outstanding liabilities at those blocks. The old receiver reported the old Ethereum garden. Production publication, the accepted revision, Ethereum deployment/verification, Base owner deployment/verification and authenticated readiness for the replacement pair are pending. Purchases start closed. There is no live transaction or burn receipt for the replacement in this release.
