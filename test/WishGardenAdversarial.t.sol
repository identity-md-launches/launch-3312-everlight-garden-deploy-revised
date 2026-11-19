// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GardenTestBase, GardenEconomy, WishGardenTreasury, WishGarden} from "./helpers/GardenTestBase.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {WalletGas} from "./helpers/WalletGas.sol";

contract WishGardenAdversarialTest is GardenTestBase, WalletGas {
    function testFuzz_everyPaymentFailureRollsBackAndCanRetry(uint8 modeSeed) public {
        uint8 mode = uint8(bound(modeSeed, 1, 4));
        _buy(bob, 2, 0);
        token.mint(address(garden), 100);
        uint256 before = token.balanceOf(alice);
        uint256 state = garden.accountedBalance();
        token.configureModes(mode, 0, address(0));
        uint8[] memory styles = new uint8[](3);
        string[] memory wishes = new string[](3);
        vm.startPrank(alice);
        token.approve(address(garden), 3e18);
        vm.expectRevert();
        garden.buyCandles(styles, wishes);
        vm.stopPrank();
        assertEq(garden.totalCandles(), 2);
        assertEq(token.balanceOf(alice), before);
        assertEq(garden.accountedBalance(), state);
        assertEq(garden.claimableRewards(alice), 0);
        assertEq(token.allowance(alice, address(garden)), 3e18);
        token.configureModes(0, 0, address(0));
        _buy(alice, 3, 0);
        _assertSolvent();
    }

    function testFuzz_claimFailurePreservesEntitlement(uint8 modeSeed) public {
        uint8 mode = uint8(bound(modeSeed, 1, 4));
        _buy(alice, 2, 0);
        token.configureModes(0, mode, alice);
        vm.prank(alice);
        vm.expectRevert();
        garden.claimRewards();
        assertEq(garden.claimableRewards(alice), 0.6e18);
        assertEq(garden.totalRewardsClaimed(), 0);
        token.configureModes(0, 0, address(0));
        vm.prank(alice);
        garden.claimRewards();
        _assertSolvent();
    }

    function testFuzz_bucketFailureAtomic(uint8 modeSeed, uint8 bucketSeed) public {
        _buy(alice, 3, 0);
        uint8 mode = uint8(bound(modeSeed, 1, 4));
        WishGardenTreasury.Bucket bucket = WishGardenTreasury.Bucket(bound(bucketSeed, 1, 2));
        uint256 before = garden.ownerWithdrawable();
        token.configureModes(0, mode, OWNER);
        vm.prank(OWNER);
        vm.expectRevert();
        garden.withdrawBucket(bucket, OWNER, 100);
        assertEq(garden.ownerWithdrawable(), before);
        token.configureModes(0, 0, address(0));
        vm.prank(OWNER);
        garden.withdrawBucket(bucket, OWNER, 100);
        _assertSolvent();
    }

    function test_noReturnTokenExactDeltasWorkForPaymentsClaimsAndBuckets() public {
        token.configureModes(5, 5, address(0));
        _buy(alice, 2, 0);
        vm.prank(alice);
        garden.claimRewards();
        vm.prank(OWNER);
        garden.withdrawBucket(WishGardenTreasury.Bucket.Operations, OWNER, 1);
        _assertSolvent();
    }

    function test_crossFunctionPurchaseReentrancyRejected() public {
        uint8[] memory styles = new uint8[](1);
        string[] memory wishes = new string[](1);
        token.configureCallback(
            address(garden), abi.encodeCall(garden.buyCandles, (styles, wishes)), true, false
        );
        _buy(alice, 2, 0);
        assertTrue(token.callbackAttempted());
        assertFalse(token.callbackSucceeded());
        assertEq(
            token.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(garden.totalCandles(), 2);
        _assertSolvent();
    }

    function test_claimReentryAndAuthorizedOwnerCrossBucketReentryRejected() public {
        token.mint(IMD, 2e18);
        _buy(IMD, 2, 0);
        token.configureCallback(address(garden), abi.encodeCall(garden.claimRewards, ()), false, true);
        vm.prank(IMD);
        garden.claimRewards();
        assertFalse(token.callbackSucceeded());
        assertEq(
            token.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        vm.prank(OWNER);
        garden.transferOwnership(IMD);
        vm.prank(IMD);
        garden.acceptOwnership();
        token.configureCallback(
            address(garden),
            abi.encodeCall(garden.withdrawBucket, (WishGardenTreasury.Bucket.Founder, alice, 1)),
            false,
            true
        );
        vm.prank(IMD);
        garden.withdrawBucket(WishGardenTreasury.Bucket.Operations, alice, 1);
        assertFalse(token.callbackSucceeded());
        assertEq(garden.totalFounderWithdrawn(), 0);
        token.configureCallback(address(0), "", false, false);
        vm.prank(IMD);
        garden.withdrawBucket(WishGardenTreasury.Bucket.Founder, alice, 1);
        assertEq(garden.totalFounderWithdrawn(), 1);
        _assertSolvent();
    }

    function test_purchaseClaimWithdrawalAtMinimumWalletGas() public {
        uint8[] memory styles = new uint8[](50);
        string[] memory wishes = new string[](50);
        vm.prank(alice);
        token.approve(address(garden), 50e18);
        assertSameAtWalletGas(alice, address(garden), abi.encodeCall(garden.buyCandles, (styles, wishes)));
        _buy(alice, 2, 0);
        assertSameAtWalletGas(alice, address(garden), abi.encodeCall(garden.claimRewards, ()));
        assertSameAtWalletGas(
            OWNER,
            address(garden),
            abi.encodeCall(garden.withdrawBucket, (WishGardenTreasury.Bucket.Operations, OWNER, 1))
        );
    }

    function test_dispatchAtMinimumWalletGasCannotSilentlySkip() public {
        _buy(alice, 1, 0);
        vm.prank(OWNER);
        uint256 id = garden.queueBurn(0.3e18);
        assertSameAtWalletGas(OWNER, address(garden), 1e14, abi.encodeCall(garden.dispatchBurn, (id)));
    }
}
