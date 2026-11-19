// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GardenTestBase, WishGarden, GardenEconomy} from "./helpers/GardenTestBase.sol";
import {WishGardenTreasury} from "../src/WishGardenTreasury.sol";
import {Utf8Wish} from "../src/Utf8Wish.sol";

contract WishGardenPurchasesTest is GardenTestBase {
    function test_firstRewardGoesToBurnThenExistingCandleEarns() public {
        assertEq(garden.ECOSYSTEM_PER_CANDLE(), 0);
        assertEq(garden.REWARD_PER_CANDLE(), 0.6e18);
        uint8[] memory styles = new uint8[](1);
        string[] memory wishes = new string[](1);
        vm.startPrank(alice);
        token.approve(address(garden), 2e18);
        vm.expectEmit(true, false, false, true, address(garden));
        emit WishGardenTreasury.BurnAllocated(1, 0.9e18);
        garden.buyCandles(styles, wishes);
        assertEq(garden.ecosystemBalance(), 0);
        assertEq(garden.claimableRewards(alice), 0);
        assertEq(garden.claimableRewards(OWNER), 0);
        assertEq(garden.rewardLiability(), 0);
        assertEq(garden.totalRewardsAllocated(), 0);
        assertEq(garden.totalBurnAllocated(), 0.9e18);
        assertEq(garden.burnQueued(), 0.9e18);
        assertEq(garden.operationsBalance(), 0.05e18);
        assertEq(garden.founderBalance(), 0.05e18);
        vm.expectEmit(true, false, false, true, address(garden));
        emit WishGardenTreasury.BurnAllocated(2, 0.3e18);
        garden.buyCandles(styles, wishes);
        vm.stopPrank();
        assertEq(garden.totalBurnAllocated(), 1.2e18);
        assertEq(garden.burnQueued(), 1.2e18);
        assertEq(garden.totalRewardsAllocated(), 0.6e18);
        assertEq(garden.ownerWithdrawable(), 0.2e18);
        assertEq(garden.claimableRewards(alice), 0.6e18);
        assertEq(garden.ecosystemBalance(), 0);
        assertEq(garden.operationsBalance(), 0.1e18);
        assertEq(garden.founderBalance(), 0.1e18);
        assertEq(garden.totalPayments(), 2e18);
        assertEq(garden.accountedBalance(), 2e18);
        _assertSolvent();
    }

    function test_candle101PaysThreeEarlierCandlesAndOnlyPurchasesAccrue() public {
        _buy(alice, 3, 0);
        _buy(bob, 50, 1);
        _buy(bob, 47, 2);
        uint256 aliceBefore = garden.claimableRewards(alice);
        uint256 bobBefore = garden.claimableRewards(bob);
        uint256 accumulator = garden.rewardPerCandle();
        _buy(carol, 1, 3);
        assertEq(garden.rewardPerCandle() - accumulator, 0.006e18 * 1e27);
        assertEq(garden.claimableRewards(alice) - aliceBefore, 0.018e18);
        assertEq(garden.claimableRewards(bob) - bobBefore, 0.582e18);
        assertEq(garden.claimableRewards(carol), 0);
        vm.warp(block.timestamp + 365 days);
        assertEq(garden.claimableRewards(alice), aliceBefore + 0.018e18);
        assertEq(garden.totalRewardsAllocated(), 60e18);
        assertEq(garden.totalBurnAllocated(), 30.9e18);
        _assertSolvent();
    }

    function test_stylesWishesPermanentAndPagination() public {
        uint8[] memory styles = new uint8[](7);
        string[] memory wishes = new string[](7);
        for (uint256 i; i < 7; ++i) {
            styles[i] = uint8(i);
            wishes[i] = string.concat("wish ", vm.toString(i));
        }
        vm.startPrank(alice);
        token.approve(address(garden), 7e18);
        garden.buyCandles(styles, wishes);
        vm.stopPrank();
        vm.warp(block.timestamp + 10 * 365 days);
        _buy(bob, 1, 0);
        for (uint256 i; i < 7; ++i) {
            WishGarden.Candle memory c = garden.getCandle(i + 1);
            assertEq(c.purchaser, alice);
            assertEq(c.beneficiary, alice);
            assertEq(c.style, i);
            assertEq(c.position, i);
            assertEq(c.createdAt, 1_800_000_000);
            assertEq(c.wish, wishes[i]);
        }
        (WishGarden.Candle[] memory records, uint256 next) = garden.getCandles(2, 3);
        assertEq(records.length, 3);
        assertEq(next, 5);
        assertEq(records[0].wish, "wish 1");
        (uint256[] memory ids, uint256 offset) = garden.candleIdsOf(alice, 3, 100);
        assertEq(ids.length, 4);
        assertEq(ids[0], 4);
        assertEq(offset, 7);
        (records, next) = garden.getCandles(9, 1);
        assertEq(records.length, 0);
        assertEq(next, 9);
    }

    function test_noTenThousandCap() public {
        vm.pauseGasMetering();
        for (uint256 i; i < 200; ++i) {
            _buy(alice, 50, 0);
        }
        _buy(bob, 1, 6);
        assertEq(garden.totalCandles(), 10001);
        assertEq(garden.getCandle(10001).beneficiary, bob);
        vm.resumeGasMetering();
    }

    function test_invalidBatchAndPagesAtomic() public {
        _rejectBuy(garden, 0, 0, abi.encodeWithSelector(GardenEconomy.InvalidQuantity.selector, 0));
    }

    function test_oversizeAndStyleRevert() public {
        _rejectBuy(garden, 51, 0, abi.encodeWithSelector(GardenEconomy.InvalidQuantity.selector, 51));
        _rejectBuy(garden, 1, 7, abi.encodeWithSelector(WishGarden.InvalidStyle.selector, 7));
        assertEq(garden.totalCandles(), 0);
        vm.expectRevert(WishGarden.InvalidPage.selector);
        garden.getCandles(0, 1);
        vm.expectRevert(WishGarden.InvalidPage.selector);
        garden.getCandles(1, 101);
        vm.expectRevert(WishGarden.InvalidPage.selector);
        garden.candleIdsOf(alice, 1, 1);
    }

    function test_lengthMismatchAndMalformedLateWishRevertWholeBatch() public {
        uint8[] memory styles = new uint8[](2);
        string[] memory wishes = new string[](1);
        vm.expectRevert(WishGarden.LengthMismatch.selector);
        garden.buyCandles(styles, wishes);
        wishes = new string[](2);
        wishes[0] = "good";
        wishes[1] = string(abi.encodePacked(hex"eda080"));
        vm.startPrank(alice);
        token.approve(address(garden), 2e18);
        vm.expectRevert(Utf8Wish.InvalidUTF8.selector);
        garden.buyCandles(styles, wishes);
        vm.stopPrank();
        assertEq(garden.totalCandles(), 0);
        assertEq(garden.accountedBalance(), 0);
        assertEq(token.allowance(alice, address(garden)), 2e18);
    }

    function test_noFreeNFTOrTransferEntrypoints() public {
        bytes[5] memory payloads = [
            abi.encodeWithSignature("claimFreeCandle(uint256,uint8)", 7, 0),
            abi.encodeWithSignature("confirmOfficialCollection(bytes32)", bytes32(uint256(1))),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", alice, bob, 1),
            abi.encodeWithSignature("bindGarden(address)", alice),
            abi.encodeWithSignature("recordPayment(address,uint256,uint256)", alice, 999, 1)
        ];
        for (uint256 i; i < payloads.length; ++i) {
            vm.prank(OWNER);
            (bool ok,) = address(garden).call(payloads[i]);
            assertFalse(ok);
        }
        assertEq(garden.totalCandles(), 0);
    }

    function test_noAllowanceOrInsufficientFundsReverts() public {
        uint8[] memory styles = new uint8[](1);
        string[] memory wishes = new string[](1);
        vm.prank(alice);
        vm.expectRevert();
        garden.buyCandles(styles, wishes);
        vm.startPrank(makeAddr("empty"));
        token.approve(address(garden), 1e18);
        vm.expectRevert();
        garden.buyCandles(styles, wishes);
        vm.stopPrank();
        assertEq(garden.totalCandles(), 0);
    }

    function test_donationsDoNotCreateRights() public {
        token.mint(address(garden), 17);
        _buy(alice, 2, 0);
        assertEq(garden.unallocatedBalance(), 17);
        assertEq(garden.claimableRewards(alice), 0.6e18);
        _assertSolvent();
    }

    function testFuzz_batchMatchesSequential(uint8 countSeed, uint8 styleSeed) public {
        uint256 count = bound(countSeed, 1, 50);
        uint8 style = uint8(bound(styleSeed, 0, 6));
        WishGarden other = new WishGarden(OWNER);
        _activate(other, other.pinnedBaseReceiver());
        _buy(alice, 3, 0);
        _buyIn(other, alice, 3, 0);
        _buy(bob, count, style);
        for (uint256 i; i < count; ++i) {
            _buyIn(other, bob, 1, style);
        }
        assertEq(garden.totalCandles(), other.totalCandles());
        assertEq(garden.rewardPerCandle(), other.rewardPerCandle());
        assertEq(garden.claimableRewards(alice), other.claimableRewards(alice));
        assertEq(garden.claimableRewards(bob), other.claimableRewards(bob));
        assertEq(garden.rewardDustScaled(), other.rewardDustScaled());
        assertEq(garden.accountedBalance(), other.accountedBalance());
        _assertSolvent();
    }
}
