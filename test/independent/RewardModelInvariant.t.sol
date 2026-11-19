// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {GardenTestBase, WishGarden, WishGardenTreasury} from "../helpers/GardenTestBase.sol";
import {IMDOFTDouble} from "../helpers/BridgeDoubles.sol";

/// @dev Specification model: visits EACH earlier candle on every purchase, unlike production's accumulator.
contract RewardModelHandler is Test {
    WishGarden public immutable garden;
    IMDOFTDouble public immutable token;
    address public immutable owner;
    address[3] public actors;
    uint8[] public beneficiaries;
    uint256[3] public earnedScaled;
    uint256[3] public claimed;
    uint256[3] public withdrawn;
    uint256 public modelDustScaled;
    uint256 public donations;

    constructor(WishGarden g, IMDOFTDouble t, address o, address a, address b, address c) {
        garden = g;
        token = t;
        owner = o;
        actors = [a, b, c];
    }

    function buy(uint8 actorSeed, uint8 quantitySeed) external {
        uint256 actor = uint256(actorSeed) % 3;
        uint256 quantity = 1 + uint256(quantitySeed) % 5;
        uint8[] memory styles = new uint8[](quantity);
        string[] memory wishes = new string[](quantity);
        vm.startPrank(actors[actor]);
        token.approve(address(garden), quantity * 1e18);
        garden.buyCandles(styles, wishes);
        vm.stopPrank();
        for (uint256 i; i < quantity; ++i) {
            uint256 n = beneficiaries.length;
            if (n > 0) {
                uint256 each = uint256(6e17) * 1e27 / n;
                for (uint256 prior; prior < n; ++prior) {
                    earnedScaled[beneficiaries[prior]] += each;
                }
                modelDustScaled += uint256(6e17) * 1e27 - each * n;
            }
            beneficiaries.push(uint8(actor));
        }
        assertModel();
    }

    function claim(uint8 actorSeed) external {
        uint256 actor = uint256(actorSeed) % 3;
        uint256 amount = earnedScaled[actor] / 1e27 - claimed[actor];
        if (amount == 0) return;
        claimed[actor] += amount;
        vm.prank(actors[actor]);
        assertEq(garden.claimRewards(), amount);
        assertModel();
    }

    function withdraw(uint8 bucketSeed, uint96 amountSeed) external {
        uint256 bucket = uint256(bucketSeed) % 3;
        uint256 limit = _grossBucket(bucket) - withdrawn[bucket];
        if (limit == 0) return;
        uint256 amount = 1 + uint256(amountSeed) % limit;
        withdrawn[bucket] += amount;
        vm.prank(owner);
        garden.withdrawBucket(WishGardenTreasury.Bucket(bucket), owner, amount);
        assertModel();
    }

    function donate(uint64 amount) external {
        token.mint(address(garden), amount);
        donations += amount;
        assertModel();
    }

    function pausedClaim(uint8 actorSeed) external {
        vm.prank(owner);
        garden.setPurchasesPaused(true);
        uint256 actor = uint256(actorSeed) % 3;
        uint256 amount = earnedScaled[actor] / 1e27 - claimed[actor];
        if (amount > 0) {
            claimed[actor] += amount;
            vm.prank(actors[actor]);
            assertEq(garden.claimRewards(), amount);
        }
        vm.prank(owner);
        garden.setPurchasesPaused(false);
        assertModel();
    }

    function assertModel() public view {
        uint256 n = beneficiaries.length;
        uint256 paidClaims;
        uint256 scaled;
        for (uint256 i; i < 3; ++i) {
            (, uint256 earned, uint256 actualClaimed, uint256 claimable, uint256 fraction) =
                garden.rewardState(actors[i]);
            assertEq(earned * 1e27 + fraction, earnedScaled[i]);
            assertEq(actualClaimed, claimed[i]);
            assertEq(claimable, earnedScaled[i] / 1e27 - claimed[i]);
            paidClaims += claimed[i];
            scaled += earnedScaled[i];
        }
        uint256 rewardAllocation = n == 0 ? 0 : (n - 1) * 6e17;
        assertEq(scaled + modelDustScaled, rewardAllocation * 1e27);
        assertEq(garden.rewardDustScaled(), modelDustScaled);
        assertEq(garden.totalRewardsClaimed(), paidClaims);
        assertEq(garden.rewardLiability(), rewardAllocation - paidClaims);
        assertEq(garden.totalCandles(), n);
        assertEq(garden.ecosystemBalance(), _grossBucket(0) - withdrawn[0]);
        assertEq(garden.operationsBalance(), _grossBucket(1) - withdrawn[1]);
        assertEq(garden.founderBalance(), _grossBucket(2) - withdrawn[2]);
        assertEq(garden.burnQueued(), n * 3e17 + (n == 0 ? 0 : 6e17));
        assertEq(
            token.balanceOf(address(garden)),
            n * 1e18 - paidClaims - withdrawn[0] - withdrawn[1] - withdrawn[2] + donations
        );
        assertEq(token.balanceOf(address(garden)), garden.accountedBalance() + donations);
    }

    function _grossBucket(uint256 bucket) private view returns (uint256) {
        uint256 n = beneficiaries.length;
        if (bucket == 0) return 0;
        return n * 5e16;
    }
}

contract RewardModelInvariantTest is GardenTestBase {
    RewardModelHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new RewardModelHandler(garden, token, OWNER, alice, bob, carol);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.claim.selector;
        selectors[2] = handler.withdraw.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.pausedClaim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_rewardsAndCustodyMatchPerCandleModel() public view {
        handler.assertModel();
    }

    function test_specificationModelMixedSequence() public {
        handler.buy(0, 0);
        handler.buy(1, 4);
        handler.claim(0);
        handler.buy(1, 1);
        handler.donate(17);
        handler.buy(2, 2);
        handler.withdraw(2, type(uint96).max);
        handler.withdraw(1, 9);
        handler.pausedClaim(2);
        handler.claim(1);
        handler.assertModel();
    }
}
