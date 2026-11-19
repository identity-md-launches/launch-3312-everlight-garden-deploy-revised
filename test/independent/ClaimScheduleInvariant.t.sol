// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GardenTestBase, WishGarden, WishGardenTreasury, GardenEconomy} from "../helpers/GardenTestBase.sol";
import {IMDOFTDouble} from "../helpers/BridgeDoubles.sol";

/// @dev Metamorphic oracle: the same ordered candles are bought in batches with interleaved claims,
///      and individually with all claims deferred. Neither side reimplements the accumulator.
///      Input-derived record hashes and token deltas supply an independent persistence/custody oracle.
contract ClaimScheduleHandler is Test {
    WishGarden public immutable frequent;
    WishGarden public immutable deferred;
    IMDOFTDouble public immutable token;
    address public immutable owner;
    address[4] public actors;
    uint256[4] public weights;
    uint256[4] public claims;
    bytes32[] private recordHashes;
    uint256[] private actorForRecord;
    uint256 public donated;
    uint256 public operationsWithdrawn;
    uint256 public founderWithdrawn;
    uint256 public paidClaims;
    uint256 public successfulBatches;
    uint256 public rejectedBatches;
    bool public paused;

    constructor(WishGarden f, WishGarden d, IMDOFTDouble t, address o, address a, address b, address c) {
        frequent = f;
        deferred = d;
        token = t;
        owner = o;
        actors = [a, b, c, o];
    }

    function buy(uint8 actorSeed, uint8 quantitySeed, uint256 textSeed) external {
        uint256 actor = uint256(actorSeed) % actors.length;
        uint256 quantity = bound(quantitySeed, 1, 8);
        uint256 first = recordHashes.length + 1;
        (uint8[] memory styles, string[] memory wishes) = _inputs(quantity, textSeed);
        vm.startPrank(actors[actor]);
        token.approve(address(frequent), quantity * 1e18);
        token.approve(address(deferred), quantity * 1e18);
        if (paused) {
            vm.expectRevert(WishGarden.PurchasesDisabled.selector);
            frequent.buyCandles(styles, wishes);
            vm.expectRevert(WishGarden.PurchasesDisabled.selector);
            deferred.buyCandles(styles, wishes);
            vm.stopPrank();
            ++rejectedBatches;
            return;
        }
        uint256 beforeBalance = token.balanceOf(actors[actor]);
        assertEq(frequent.buyCandles(styles, wishes), first);
        uint8[] memory oneStyle = new uint8[](1);
        string[] memory oneWish = new string[](1);
        for (uint256 i; i < quantity; ++i) {
            oneStyle[0] = styles[i];
            oneWish[0] = wishes[i];
            assertEq(deferred.buyCandles(oneStyle, oneWish), first + i);
            // Build from the submitted inputs, never from getCandle().
            recordHashes.push(
                keccak256(
                    abi.encode(
                        WishGarden.Candle(
                            actors[actor],
                            actors[actor],
                            uint64(block.timestamp),
                            styles[i],
                            first + i - 1,
                            wishes[i]
                        )
                    )
                )
            );
            actorForRecord.push(actor);
        }
        assertEq(token.balanceOf(actors[actor]), beforeBalance - 2 * quantity * 1e18);
        vm.stopPrank();
        weights[actor] += quantity;
        ++successfulBatches;
    }

    function claim(uint8 actorSeed) public {
        uint256 actor = uint256(actorSeed) % actors.length;
        uint256 expected = deferred.claimableRewards(actors[actor]) - claims[actor];
        uint256 beforeBalance = token.balanceOf(actors[actor]);
        uint256 protectedBalance = frequent.burnQueued() + frequent.burnReserved()
            + frequent.operationsBalance() + frequent.founderBalance();
        vm.prank(actors[actor]);
        if (expected == 0) {
            vm.expectRevert(WishGardenTreasury.NothingToClaim.selector);
            frequent.claimRewards();
        } else {
            assertEq(frequent.claimRewards(), expected);
            claims[actor] += expected;
            paidClaims += expected;
        }
        assertEq(token.balanceOf(actors[actor]), beforeBalance + expected);
        assertEq(
            frequent.burnQueued() + frequent.burnReserved() + frequent.operationsBalance()
                + frequent.founderBalance(),
            protectedBalance
        );
    }

    function failedPayment(uint8 actorSeed, uint8 modeSeed, uint8 quantitySeed) external {
        uint256 actor = uint256(actorSeed) % actors.length;
        uint256 quantity = bound(quantitySeed, 1, 8);
        uint8 mode = uint8(bound(modeSeed, 1, 4));
        (uint8[] memory styles, string[] memory wishes) = _inputs(quantity, 123);
        uint256 beforeBalance = token.balanceOf(actors[actor]);
        token.configureModes(mode, 0, address(0));
        bytes memory reason = paused
            ? abi.encodeWithSelector(WishGarden.PurchasesDisabled.selector)
            : mode == 1
                ? abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token))
                : abi.encodeWithSelector(GardenEconomy.InexactTransfer.selector);
        vm.startPrank(actors[actor]);
        token.approve(address(frequent), quantity * 1e18);
        token.approve(address(deferred), quantity * 1e18);
        vm.expectRevert(reason);
        frequent.buyCandles(styles, wishes);
        vm.expectRevert(reason);
        deferred.buyCandles(styles, wishes);
        vm.stopPrank();
        token.configureModes(0, 0, address(0));
        assertEq(token.balanceOf(actors[actor]), beforeBalance);
        assertEq(token.allowance(actors[actor], address(frequent)), quantity * 1e18);
        assertEq(token.allowance(actors[actor], address(deferred)), quantity * 1e18);
        ++rejectedBatches;
    }

    function donate(uint64 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 1e18);
        // Supply fixture tokens, not reward-funded purchases.
        token.mint(address(frequent), amount);
        token.mint(address(deferred), amount);
        donated += amount;
    }

    function pause(bool value) external {
        vm.startPrank(owner);
        frequent.setPurchasesPaused(value);
        deferred.setPurchasesPaused(value);
        vm.stopPrank();
        paused = value;
    }

    function timePasses(uint32 secondsSeed) external {
        uint256 beforeIndex = frequent.rewardPerCandle();
        uint256 beforeRewards = deferred.totalRewardsAllocated();
        vm.warp(block.timestamp + bound(secondsSeed, 1, 365 days));
        assertEq(frequent.rewardPerCandle(), beforeIndex);
        assertEq(deferred.totalRewardsAllocated(), beforeRewards);
    }

    function withdraw(bool founder, uint96 amountSeed) external {
        uint256 gross = recordHashes.length * 0.05e18;
        uint256 available = gross - (founder ? founderWithdrawn : operationsWithdrawn);
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available);
        WishGardenTreasury.Bucket bucket =
            founder ? WishGardenTreasury.Bucket.Founder : WishGardenTreasury.Bucket.Operations;
        uint256 beforeBalance = token.balanceOf(owner);
        vm.startPrank(owner);
        frequent.withdrawBucket(bucket, owner, amount);
        deferred.withdrawBucket(bucket, owner, amount);
        vm.stopPrank();
        assertEq(token.balanceOf(owner), beforeBalance + 2 * amount);
        if (founder) founderWithdrawn += amount;
        else operationsWithdrawn += amount;
    }

    function assertRewardsAndCustody() external view {
        uint256 count = recordHashes.length;
        uint256 rewards = count == 0 ? 0 : (count - 1) * 0.6e18;
        uint256 burn = count == 0 ? 0 : count * 0.3e18 + 0.6e18;
        uint256 scaled;
        for (uint256 i; i < actors.length; ++i) {
            (uint256 weight, uint256 earned, uint256 claimed, uint256 claimable, uint256 fraction) =
                frequent.rewardState(actors[i]);
            (uint256 dWeight, uint256 dEarned, uint256 dClaimed, uint256 dClaimable, uint256 dFraction) =
                deferred.rewardState(actors[i]);
            assertEq(weight, weights[i]);
            assertEq(dWeight, weights[i]);
            assertEq(earned, dEarned, "claim timing or batch grouping changed lifetime rewards");
            assertEq(fraction, dFraction, "claims discarded fractional rewards");
            assertEq(claimed, claims[i]);
            assertEq(dClaimed, 0);
            assertEq(claimable + claims[i], dClaimable);
            scaled += earned * 1e27 + fraction;
        }
        assertEq(scaled + frequent.rewardDustScaled(), rewards * 1e27);
        assertEq(frequent.rewardDustScaled(), deferred.rewardDustScaled());
        assertEq(frequent.totalRewardsClaimed(), paidClaims);
        assertEq(deferred.totalRewardsClaimed(), 0);
        assertEq(frequent.rewardLiability(), rewards - paidClaims);
        assertEq(deferred.rewardLiability(), rewards);
        assertEq(token.balanceOf(address(frequent)) + paidClaims, token.balanceOf(address(deferred)));
        assertEq(
            token.balanceOf(address(deferred)),
            count * 1e18 + donated - operationsWithdrawn - founderWithdrawn
        );
        _assertCommon(frequent, count, rewards, burn);
        _assertCommon(deferred, count, rewards, burn);
    }

    function assertPermanentRecords() external view {
        uint256[4] memory offsets;
        for (uint256 i; i < recordHashes.length; ++i) {
            assertEq(keccak256(abi.encode(frequent.getCandle(i + 1))), recordHashes[i]);
            assertEq(keccak256(abi.encode(deferred.getCandle(i + 1))), recordHashes[i]);
            uint256 actor = actorForRecord[i];
            (uint256[] memory ids, uint256 next) = frequent.candleIdsOf(actors[actor], offsets[actor], 1);
            assertEq(ids.length, 1);
            assertEq(ids[0], i + 1);
            assertEq(next, ++offsets[actor]);
        }
        for (uint256 i; i < actors.length; ++i) {
            assertEq(frequent.candleCountOf(actors[i]), weights[i]);
            assertEq(deferred.candleCountOf(actors[i]), weights[i]);
            assertEq(offsets[i], weights[i]);
        }
    }

    function _assertCommon(WishGarden g, uint256 count, uint256 rewards, uint256 burn) private view {
        assertEq(g.totalCandles(), count);
        assertEq(g.totalPayments(), count * 1e18);
        assertEq(g.totalRewardsAllocated(), rewards);
        assertEq(g.totalBurnAllocated(), burn);
        assertEq(g.burnQueued(), burn);
        assertEq(g.totalOperationsWithdrawn(), operationsWithdrawn);
        assertEq(g.totalFounderWithdrawn(), founderWithdrawn);
        assertEq(g.operationsBalance(), count * 0.05e18 - operationsWithdrawn);
        assertEq(g.founderBalance(), count * 0.05e18 - founderWithdrawn);
        assertEq(g.ecosystemBalance(), 0);
        assertEq(g.totalEcosystemWithdrawn(), 0);
        assertEq(g.unallocatedBalance(), donated);
        assertEq(token.balanceOf(address(g)), g.accountedBalance() + donated);
        assertEq(g.purchasesPaused(), paused);
    }

    function _inputs(uint256 quantity, uint256 seed)
        private
        pure
        returns (uint8[] memory styles, string[] memory wishes)
    {
        styles = new uint8[](quantity);
        wishes = new string[](quantity);
        for (uint256 i; i < quantity; ++i) {
            styles[i] = uint8(uint256(keccak256(abi.encode(seed, i))) % 7);
            // All widths, empty wishes and embedded NUL are valid; preserve bytes without normalization.
            uint256 choice = (seed % 5 + i) % 5;
            if (choice == 0) wishes[i] = "";
            if (choice == 1) wishes[i] = "forever";
            if (choice == 2) wishes[i] = unicode"光 🕯";
            if (choice == 3) wishes[i] = string(hex"00c2a2e282acf09f9880");
            if (choice == 4) wishes[i] = string(hex"65cc81");
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
contract ClaimScheduleInvariantTest is GardenTestBase {
    ClaimScheduleHandler private handler;

    function setUp() public override {
        super.setUp();
        WishGarden deferred = new WishGarden(OWNER);
        _activate(deferred, deferred.pinnedBaseReceiver());
        token.mint(OWNER, 1_000_000e18);
        handler = new ClaimScheduleHandler(garden, deferred, token, OWNER, alice, bob, carol);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.claim.selector;
        selectors[2] = handler.failedPayment.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.pause.selector;
        selectors[5] = handler.timePasses.selector;
        selectors[6] = handler.withdraw.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_claimTimingAndBatchGroupingCannotChangeRewardsOrCustody() public view {
        handler.assertRewardsAndCustody();
    }

    function invariant_paidRecordsAndPurchaserIndexesRemainPermanent() public view {
        handler.assertPermanentRecords();
    }

    function test_claimScheduleExercisesFractionsFailuresPausesAndOwnerPurchases() public {
        handler.buy(0, 7, 2);
        handler.buy(1, 1, 3);
        handler.claim(0);
        handler.failedPayment(0, 2, 8);
        handler.buy(2, 5, 4);
        handler.buy(0, 3, 0);
        handler.donate(19);
        handler.pause(true);
        handler.buy(1, 2, 0);
        handler.claim(1);
        handler.timePasses(365 days);
        handler.withdraw(false, uint96(garden.operationsBalance()));
        handler.withdraw(true, uint96(garden.founderBalance()));
        handler.pause(false);
        handler.buy(3, 1, 1); // The owner only earns by buying candles like every other purchaser.
        handler.buy(1, 2, 3);
        for (uint8 i; i < 4; ++i) {
            handler.claim(i);
        }
        handler.assertRewardsAndCustody();
        handler.assertPermanentRecords();
        assertEq(handler.successfulBatches(), 6);
        assertEq(handler.rejectedBatches(), 2);
        assertGt(handler.paidClaims(), 0);
        assertGt(garden.rewardDustScaled(), 0);
    }
}
