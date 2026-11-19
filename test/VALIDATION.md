# Independent validation additions

These additions retain the existing offline tests and dependencies. No application source,
deployment artifact, configuration or legacy contract is changed. The application sources
were compared with the actual archive of baseline commit
`f3ae2915b2fc99c56079da2fc9addef2e94397e0`: the differences are the revised constants and
treasury accounting. The bridge, receiver, purchase records and UTF-8 validator match that baseline.

## Pinned Base fork

`fork/BasePinnedBurn.t.sol` is inside Foundry's default test directory. It reads
`BASE_RPC_URL` with `vm.envOr`, skips only when that value is empty, and creates a fork
at Base block **59,474,551**. It passes the supplied value directly to Foundry, supporting
either an RPC URL or a socket path. No endpoint is embedded in the tests.

The nine tests exercise the deployed canonical CREATE2 deployer, official Base adapter,
Base IMD token, LayerZero endpoint and its configured message libraries:

- Derive and deploy the new receiver from actual receiver bytecode, initial owner and
  fresh garden; verify the route and immutable binding and keep source purchases closed.
- Credit the receiver from the adapter's actual collateral. Credit leaves total supply
  unchanged; compose calls the actual token `burn()` and reduces supply and custody by
  exactly the allocated amount. Sending a receipt causes no second burn and does not
  fabricate Ethereum acknowledgement.
- Exercise the supplied `WalletGas` helper through the actual endpoint for successful
  and failed compose, and through the receiver for retry, receipt and readiness calls.
  Compose also succeeds with the advertised 650,000-gas endpoint budget.
- Reject a 300,000-gas compose while retaining the original queued packet and credited
  balance; retry the original packet successfully.
- Inject one explicit token-call revert, check retained pending custody, clear the
  injected fault, then retry against the actual token and verify supply reduction.
- Reject legacy source gardens, wrong receivers/adapters/callers, altered payloads,
  duplicate deliveries and duplicate receipts. A rejected source packet cannot consume
  the job ID needed by a subsequent valid packet.
- Reject incorrect native receipt fees atomically, then use the actual quote to retry.
  Snapshot checks protect the old receiver's observed binding, owner, balances and counters.

These are fork simulations, not live deployment evidence. Fresh application contracts
exist only in local fork state. The harness supplies a verified-packet fixture by
impersonating the endpoint at the adapter's `lzReceive` boundary. It does not simulate
DVN verification, cross-chain finality or receipt arrival on Ethereum. The token's
storage and balances are not fabricated; the burn-failure test explicitly identifies
its temporary mock. No transaction is signed or broadcast.

## Offline random sequences

`independent/ClaimScheduleInvariant.t.sol` adds a handler over four buyers, including
the owner. One garden processes batches and frequent pull claims; a second processes
the identical candle order one candle at a time and defers claims. The handler mixes
purchases, claims, false/inexact transfers, donations, purchase pauses, elapsed time
and separate founder/operations withdrawals. It uses 256 runs of depth 64, configured
in the test file. The deterministic scenario also empties both owner buckets while paused.

The invariants check that:

- Batch grouping and claim timing cannot alter lifetime rewards or retained fractions.
- Paid claims account for the entire balance difference between the two gardens.
- Exact 30/60/0/5/5 allocation, first-candle 90/0/0/5/5 allocation, reward dust,
  donations, withdrawals and remaining liabilities reconcile with token custody.
- Record hashes constructed from purchase inputs remain identical after every sequence,
  including exact wish bytes, purchaser, beneficiary, timestamp, position and style.
  Purchaser indexes contain precisely their paid candles.

This compares observable executions instead of copying the production accumulator.
The existing independent per-candle reward oracle remains in
`independent/RewardModelInvariant.t.sol`, and the existing source and receiver custody
invariants remain in `review/BridgeCustodyInvariant.t.sol`.

## Property discovery

The five supplied Pashov discovery perspectives were applied directly, without subagents.
Each property below follows from the assignment or an exact accounting identity.

| Perspective | Grounding in source | Property and coverage |
| --- | --- | --- |
| Conservation | `WishGardenTreasury.sol:69`, `:141`; `EverlightBurnReceiver.sol:166` | Payments equal allocations; claims cannot consume other buckets; credits are pending or supply-burned exactly once. Existing custody models plus the new paired execution and fork supply checks. |
| Round trips and rounding | `WishGardenTreasury.sol:85`, `:102`, `:148` | Claiming frequently versus once retains the same lifetime earnings and fractions; batch versus individual execution has identical results. New paired invariant; existing per-candle oracle and rounding examples. |
| State transitions | `WishGarden.sol:50`, `:86`, `:95`; `EverlightBurnReceiver.sol:125`, `:150` | Failed payment creates no records; paid records stay permanent; failed burn remains retryable; acknowledged burns cannot reopen. New history invariant and fork retries/replays. |
| Adversarial value extraction | `WishGardenTreasury.sol:114`, `:172`; `EverlightBurnReceiver.sol:104` | Exact debits/credits, bucket separation, authenticated source, and replay protection. Existing unauthorized/reentrancy/fault tests plus new failed-payment sequences and endpoint rejection tests. |
| Protocol-specific | `EverlightBridgeQueue.sol:76`, `:253`; `EverlightBurnReceiver.sol:137` | CREATE2 binds the receiver to the new garden; allocation, credit, actual supply burn and acknowledgement are separate stages. New fork deployment and staged burn checks; existing source confirmation tests. |

Rewards are funded by subsequent candle purchases. Elapsed time and donations create no
new purchase-funded rewards. These tests make no yield or investment-return guarantee.

## Reproduction

Run with Foundry 1.8 and the repository's pinned Solidity compiler and dependencies:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x1417ba575f468fb35fd8903d5f7fa85930aff6b24352b87ad0e8593ed9e03e3e forge test
```

With `BASE_RPC_URL` supplied, the nine fork tests must pass, not skip. Without it, the
offline suite runs and the fork suite skips in `setUp`. No dependency download is required.
Production deployment, publication, Ethereum fork execution, owner setup and opening
sales are outside this tests-only change.

Local validation with Foundry 1.8.3 and the seed above: `forge build` passed;
the full suite reported **108 passing tests in 18 suites, zero failures and zero skips**.
All nine Base fork tests reached the pinned chain state and passed. The added invariant
campaign ran 256 sequences / 16,384 handler calls with zero unexpected reverts and both
properties passing. A separate run with `BASE_RPC_URL` absent confirmed the setup skip.
