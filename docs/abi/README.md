# Reading the new garden

Use the confirmed chain and address together with the release ABI. Until the launch records both addresses and the owner opens purchases, leave buying disabled. Read `rewardState(purchaser)` for lifetime earnings, claims and outstanding pull rewards. Only confirmed `CandleCreated` events create records. Page them with `getCandles(1, limit)` and advance by the returned ID. For one purchaser start `candleIdsOf(purchaser, offset, limit)` at offset 0. Page limits are 1–100. Render wishes as plain text. [Integration settings](../integration.json) · [Economics and permanent records](../../README.md)

`RewardAllocated` reports the increment scaled by 10^27 and whether the fallback went to burn. `BurnAllocated` reports the restricted allocation for that candle. Use `SupplyBurned` from the pinned Base receiver to index actual burns and `BurnConfirmed` from the Ethereum garden to index authenticated acknowledgements. Filter all events by chain and deployment address and handle chain reorganizations. [State transitions](../deployment.md#burn-operations-after-opening)

## Batch gas

An allowance of exactly `quantity × 10^18` base units covers a batch. Simulate with the buyer address, actual strings and zero native value to estimate gas. Both quantity and UTF-8 byte length affect storage cost. The regression suite checks representative batches against `300,000 + 170,000 × candles + 1,300 × totalWishBytes` gas using a local token. Fifty full-length wishes exceed the Ethereum transaction gas cap in that test. Split large batches and treat each confirmed purchase as a separate atomic transaction.
