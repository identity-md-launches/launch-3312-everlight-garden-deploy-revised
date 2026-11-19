// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GardenEconomy} from "./GardenEconomy.sol";

/// @notice Internal treasury of WishGarden. Not a separately deployed or bindable application.
abstract contract WishGardenTreasury is GardenEconomy, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public constant REWARD_SCALE = 1e27;
    enum Bucket {
        Ecosystem,
        Operations,
        Founder
    }

    struct RewardAccount {
        uint256 candles;
        uint256 checkpoint;
        uint256 earnedScaled;
        uint256 claimed;
    }
    mapping(address => RewardAccount) internal _rewards;
    uint256 public totalCandles;
    uint256 public rewardPerCandle;
    uint256 public rewardDustScaled;
    uint256 public totalRewardsAllocated;
    uint256 public totalRewardsClaimed;
    // Preserve the original read API and bucket numbers for indexers.
    uint256 public constant ecosystemBalance = 0;
    uint256 public operationsBalance;
    uint256 public founderBalance;
    uint256 public constant totalEcosystemWithdrawn = 0;
    uint256 public totalOperationsWithdrawn;
    uint256 public totalFounderWithdrawn;
    uint256 public burnQueued;
    uint256 public burnReserved;
    uint256 public totalBurnAllocated;

    error NothingToClaim();
    error InvalidWithdrawal();
    error InsufficientBucketBalance();
    error OwnershipRequired();
    event RewardAllocated(
        uint256 indexed candleId, uint256 priorCandles, uint256 increment, bool fallbackToBurn
    );
    event BurnAllocated(uint256 indexed candleId, uint256 amount);
    event RewardsClaimed(address indexed beneficiary, uint256 amount, uint256 cumulativeClaimed);
    event BucketWithdrawn(
        Bucket indexed bucket, address indexed caller, address indexed destination, uint256 amount
    );

    constructor(address owner_) Ownable(owner_) {}

    function totalPayments() public view returns (uint256) {
        return totalCandles * CANDLE_PRICE;
    }

    function paidCandles() external view returns (uint256) {
        return totalCandles;
    }

    function rewardLiability() public view returns (uint256) {
        return totalRewardsAllocated - totalRewardsClaimed;
    }

    function ownerWithdrawable() public view returns (uint256) {
        return operationsBalance + founderBalance;
    }

    function accountedBalance() public view returns (uint256) {
        return ownerWithdrawable() + rewardLiability() + burnQueued + burnReserved;
    }

    function unallocatedBalance() external view returns (uint256) {
        uint256 held = IERC20(IMD).balanceOf(address(this));
        uint256 accounted = accountedBalance();
        return held > accounted ? held - accounted : 0;
    }

    function rewardState(address beneficiary)
        public
        view
        returns (uint256 candles, uint256 earned, uint256 claimed, uint256 claimable, uint256 fractionScaled)
    {
        RewardAccount storage a = _rewards[beneficiary];
        uint256 scaled = a.earnedScaled + a.candles * (rewardPerCandle - a.checkpoint);
        earned = scaled / REWARD_SCALE;
        return (a.candles, earned, a.claimed, earned - a.claimed, scaled % REWARD_SCALE);
    }

    function claimableRewards(address beneficiary) public view returns (uint256 claimable) {
        (,,, claimable,) = rewardState(beneficiary);
    }

    /// @notice Only the beneficiary can claim, and payment always goes to that beneficiary.
    /// @dev Purchases/bridge activation and purchase pause never gate claims.
    function claimRewards() external nonReentrant returns (uint256 amount) {
        _requireIMD();
        RewardAccount storage a = _rewards[msg.sender];
        _settle(a);
        amount = a.earnedScaled / REWARD_SCALE - a.claimed;
        if (amount == 0) revert NothingToClaim();
        a.claimed += amount;
        totalRewardsClaimed += amount;
        _transferExact(msg.sender, amount);
        emit RewardsClaimed(msg.sender, amount, a.claimed);
    }

    function withdrawBucket(Bucket bucket, address destination, uint256 amount)
        external
        nonReentrant
        onlyOwner
    {
        _requireIMD();
        if (amount == 0 || destination == address(0) || destination == address(this) || destination == IMD) {
            revert InvalidWithdrawal();
        }
        if (bucket == Bucket.Ecosystem) revert InsufficientBucketBalance();
        if (bucket == Bucket.Operations) {
            if (amount > operationsBalance) revert InsufficientBucketBalance();
            operationsBalance -= amount;
            totalOperationsWithdrawn += amount;
        } else {
            if (amount > founderBalance) revert InsufficientBucketBalance();
            founderBalance -= amount;
            totalFounderWithdrawn += amount;
        }
        _transferExact(destination, amount);
        emit BucketWithdrawn(bucket, msg.sender, destination, amount);
    }

    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRequired();
    }

    function _allocateCandle(address beneficiary) internal {
        uint256 prior = totalCandles;
        uint256 increment = 0;
        uint256 burnAmount = BURN_ALLOCATION_PER_CANDLE;
        if (prior == 0) {
            burnAmount += REWARD_PER_CANDLE;
        } else {
            uint256 scaled = REWARD_PER_CANDLE * REWARD_SCALE;
            increment = scaled / prior;
            rewardPerCandle += increment;
            // Never recycle dust into later allocations: that could reward newly purchased candles.
            rewardDustScaled += scaled % prior;
            totalRewardsAllocated += REWARD_PER_CANDLE;
        }
        RewardAccount storage a = _rewards[beneficiary];
        _settle(a); // Old candles receive this share; the new candle receives none.
        ++a.candles;
        ++totalCandles;
        operationsBalance += OPERATIONS_PER_CANDLE;
        founderBalance += FOUNDER_PER_CANDLE;
        burnQueued += burnAmount;
        totalBurnAllocated += burnAmount;
        emit BurnAllocated(totalCandles, burnAmount);
        emit RewardAllocated(totalCandles, prior, increment, prior == 0);
    }

    function _settle(RewardAccount storage a) private {
        a.earnedScaled += a.candles * (rewardPerCandle - a.checkpoint);
        a.checkpoint = rewardPerCandle;
    }

    function _transferExact(address destination, uint256 amount) internal {
        IERC20 token = IERC20(IMD);
        uint256 beforeHeld = token.balanceOf(address(this));
        uint256 beforeRecipient = token.balanceOf(destination);
        token.safeTransfer(destination, amount);
        if (
            token.balanceOf(address(this)) != beforeHeld - amount
                || token.balanceOf(destination) != beforeRecipient + amount
        ) {
            revert InexactTransfer();
        }
    }
}
