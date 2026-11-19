// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GardenTestBase, WishGardenTreasury} from "./helpers/GardenTestBase.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract WishGardenClaimsTest is GardenTestBase {
    function test_earlierOnlyLateEntrantAndPartialSelfShare() public {
        _buy(alice, 1, 0);
        _buy(bob, 1, 0);
        assertEq(garden.claimableRewards(alice), 0.6e18);
        assertEq(garden.claimableRewards(bob), 0);
        _buy(bob, 1, 0);
        assertEq(garden.claimableRewards(alice), 0.9e18);
        assertEq(garden.claimableRewards(bob), 0.3e18);
        uint256 before = token.balanceOf(bob);
        vm.prank(bob);
        assertEq(garden.claimRewards(), 0.3e18);
        assertEq(token.balanceOf(bob), before + 0.3e18);
        (uint256 count, uint256 earned, uint256 claimed, uint256 claimable,) = garden.rewardState(bob);
        assertEq(count, 2);
        assertEq(earned, 0.3e18);
        assertEq(claimed, 0.3e18);
        assertEq(claimable, 0);
        vm.prank(bob);
        vm.expectRevert(WishGardenTreasury.NothingToClaim.selector);
        garden.claimRewards();
        _buy(carol, 1, 0);
        assertEq(garden.claimableRewards(carol), 0);
        assertEq(garden.claimableRewards(bob), 0.4e18);
        _assertSolvent();
    }

    function test_claimBeneficiaryOnlyAndPauseDoesNotLockClaims() public {
        _buy(alice, 2, 0);
        vm.prank(OWNER);
        garden.setPurchasesPaused(true);
        vm.prank(OWNER);
        vm.expectRevert(WishGardenTreasury.NothingToClaim.selector);
        garden.claimRewards();
        vm.prank(bob);
        vm.expectRevert(WishGardenTreasury.NothingToClaim.selector);
        garden.claimRewards();
        vm.prank(alice);
        garden.claimRewards();
        assertEq(garden.totalRewardsClaimed(), 0.6e18);
        _assertSolvent();
    }

    function test_allBucketsBelongToCurrentOwnerWithoutRewardOrBurnAccess() public {
        _buy(alice, 2, 0);
        vm.prank(OWNER);
        garden.transferOwnership(bob);
        vm.prank(bob);
        garden.acceptOwnership();
        vm.startPrank(bob);
        garden.withdrawBucket(WishGardenTreasury.Bucket.Operations, carol, 0.1e18);
        garden.withdrawBucket(WishGardenTreasury.Bucket.Founder, carol, 0.1e18);
        vm.expectRevert(WishGardenTreasury.InsufficientBucketBalance.selector);
        garden.withdrawBucket(WishGardenTreasury.Bucket.Ecosystem, carol, 1);
        vm.expectRevert(WishGardenTreasury.InsufficientBucketBalance.selector);
        garden.withdrawBucket(WishGardenTreasury.Bucket.Operations, carol, 1);
        vm.expectRevert(WishGardenTreasury.InsufficientBucketBalance.selector);
        garden.withdrawBucket(WishGardenTreasury.Bucket.Founder, carol, 1);
        vm.stopPrank();
        assertEq(garden.ownerWithdrawable(), 0);
        assertEq(token.balanceOf(address(garden)), 1.8e18);
        vm.prank(alice);
        garden.claimRewards();
        assertEq(token.balanceOf(address(garden)), 1.2e18);
        _assertSolvent();
    }

    function test_unauthorizedInvalidWithdrawalsRenounceAndZeroAmounts() public {
        _buy(alice, 1, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        garden.withdrawBucket(WishGardenTreasury.Bucket.Operations, alice, 1);
        vm.startPrank(OWNER);
        vm.expectRevert(WishGardenTreasury.InvalidWithdrawal.selector);
        garden.withdrawBucket(WishGardenTreasury.Bucket.Ecosystem, address(0), 1);
        vm.expectRevert(WishGardenTreasury.InvalidWithdrawal.selector);
        garden.withdrawBucket(WishGardenTreasury.Bucket.Ecosystem, address(garden), 1);
        vm.expectRevert(WishGardenTreasury.InvalidWithdrawal.selector);
        garden.withdrawBucket(WishGardenTreasury.Bucket.Ecosystem, OWNER, 0);
        vm.expectRevert(WishGardenTreasury.OwnershipRequired.selector);
        garden.renounceOwnership();
        vm.stopPrank();
        assertEq(garden.ownerWithdrawable(), 0.1e18);
    }

    function test_frequentClaimsKeepFractionsAndNoEntrantReceivesOldDust() public {
        _buy(alice, 7, 0);
        _buy(bob, 1, 0);
        uint256 old = garden.claimableRewards(alice);
        vm.prank(alice);
        garden.claimRewards();
        _buy(carol, 1, 0);
        assertEq(garden.claimableRewards(carol), 0);
        (,, uint256 claimed,,) = garden.rewardState(alice);
        assertEq(claimed, old);
        for (uint256 i; i < 12; ++i) {
            _buy(bob, 1, 0);
            vm.prank(alice);
            garden.claimRewards();
        }
        address[3] memory actors = [alice, bob, carol];
        uint256 sumScaled;
        uint256 sumCount;
        for (uint256 i; i < 3; ++i) {
            (uint256 count, uint256 earned, uint256 claimed_, uint256 pending, uint256 fraction) =
                garden.rewardState(actors[i]);
            assertEq(earned, claimed_ + pending);
            sumScaled += earned * 1e27 + fraction;
            sumCount += count;
        }
        assertEq(sumCount, garden.totalCandles());
        assertEq(sumScaled + garden.rewardDustScaled(), garden.totalRewardsAllocated() * 1e27);
        _assertSolvent();
    }
}
