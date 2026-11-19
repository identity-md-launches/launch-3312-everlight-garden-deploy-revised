// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WishGardenTreasury} from "../WishGardenTreasury.sol";
import {EverlightBurnReceiver} from "../base/EverlightBurnReceiver.sol";
import {
    IMDBridge,
    IIMDOFT,
    ILZEndpoint,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt,
    Origin
} from "./IMDBridge.sol";

/// @notice Restricted IMD -> official Base adapter -> source-pinned burn-only receiver route.
/// @dev The only possible destination is the CREATE2 address of this repository's EverlightBurnReceiver
///      (its creation code is compiled into this contract's constructor) deployed on Base through the
///      canonical deterministic deployer with this garden and its initial owner as constructor arguments.
///      The owner cannot name another destination, and no other address can author confirmations.
abstract contract EverlightBridgeQueue is WishGardenTreasury {
    enum BurnStatus {
        None,
        Queued,
        Failed,
        InTransit,
        Completed
    }

    struct BurnJob {
        uint256 amount;
        bytes32 guid;
        uint32 attempts;
        BurnStatus status;
    }
    uint256 public constant MAX_NATIVE_FEE = 0.05 ether;
    uint256 public constant SEND_GAS = 1_000_000;
    /// @notice Canonical deterministic-deployment proxy (same address on Ethereum and Base).
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant BASE_RECEIVER_SALT = keccak256("EVERLIGHT GARDEN Base burn receiver v1");
    /// @notice The fixed Base destination. Derived in the constructor without any external call.
    address public immutable pinnedBaseReceiver;
    address public baseReceiver;
    bytes32 public bridgeEvidence;
    bytes32 public bridgeConfigHash;
    bytes32 public imdCodeHash;
    bytes32 public endpointCodeHash;
    bool public baseReady;
    bool public activated;
    bool public purchasesPaused = true;
    uint256 public burnJobCount;
    uint256 public burnInTransit;
    uint256 public confirmedBurn;
    uint256 public failedBurnAmount;
    uint256 public totalSendFailures;
    uint256 public totalSendRetries;
    mapping(uint256 => BurnJob) public burnJobs;
    mapping(bytes32 => bool) public sentGuids;
    mapping(bytes32 => bool) public receivedGuids;

    error BridgeNotReady();
    error InvalidBridgeConfiguration();
    error ConfigurationFrozen();
    error InvalidBurnJob();
    error InvalidFee();
    error OnlySelf();
    error InsufficientExecutionGas();
    error RefundFailed();
    error InvalidMessage();
    event BridgeConfigured(address indexed receiver, bytes32 configHash, bytes32 evidenceHash);
    event BaseReadinessConfirmed(address indexed receiver, bytes32 configHash);
    event Activated(bytes32 indexed configHash);
    event PurchasesPaused(bool paused);
    event BurnQueued(uint256 indexed jobId, uint256 amount);
    event BurnDispatched(uint256 indexed jobId, bytes32 indexed guid, uint256 amount, uint32 attempt);
    event BurnSendFailed(uint256 indexed jobId, uint32 attempt, bytes32 reasonHash);
    event BurnConfirmed(uint256 indexed jobId, bytes32 indexed guid, uint256 amount);

    constructor(address owner_) WishGardenTreasury(owner_) {
        bytes32 initCodeHash = keccak256(
            bytes.concat(type(EverlightBurnReceiver).creationCode, abi.encode(owner_, address(this)))
        );
        pinnedBaseReceiver = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, BASE_RECEIVER_SALT, initCodeHash)
                    )
                )
            )
        );
    }

    /// @notice Owner confirms the source-pinned Base receiver and reviewed evidence before any purchase.
    /// @dev `receiver` MUST equal pinnedBaseReceiver: the owner cannot choose the destination. Token,
    ///      bridge, endpoints, chains, gas options, fee ceiling and all rates are fixed in source.
    function configureBridge(address receiver, bytes32 evidenceHash) external nonReentrant onlyOwner {
        if (activated) revert ConfigurationFrozen();
        _requireIMD();
        if (
            receiver != pinnedBaseReceiver || receiver == address(0) || receiver == IMDBridge.BASE_IMD
                || receiver == IMDBridge.BASE_ADAPTER || receiver == IMDBridge.ENDPOINT
                || evidenceHash == bytes32(0)
        ) revert InvalidBridgeConfiguration();
        _checkOfficialRoute();
        baseReceiver = receiver;
        bridgeEvidence = evidenceHash;
        imdCodeHash = IMD.codehash;
        endpointCodeHash = IMDBridge.ENDPOINT.codehash;
        bridgeConfigHash =
            keccak256(abi.encode(uint256(1), address(this), uint256(8453), receiver, evidenceHash));
        baseReady = false;
        emit BridgeConfigured(receiver, bridgeConfigHash, evidenceHash);
    }

    function activate() external nonReentrant onlyOwner {
        if (activated) revert ConfigurationFrozen();
        if (!baseReady) revert BridgeNotReady();
        _checkFrozenRoute();
        activated = true;
        purchasesPaused = false;
        emit Activated(bridgeConfigHash);
        emit PurchasesPaused(false);
    }

    function setPurchasesPaused(bool paused) external nonReentrant onlyOwner {
        if (!activated) revert BridgeNotReady();
        purchasesPaused = paused;
        emit PurchasesPaused(paused);
    }

    function queueBurn(uint256 maximumAmount) external nonReentrant onlyOwner returns (uint256 jobId) {
        if (!activated) revert BridgeNotReady();
        uint256 amount = maximumAmount < burnQueued ? maximumAmount : burnQueued;
        amount = amount / IMDBridge.CONVERSION_RATE * IMDBridge.CONVERSION_RATE;
        if (amount == 0 || amount / IMDBridge.CONVERSION_RATE > type(uint64).max) revert InvalidBurnJob();
        burnQueued -= amount;
        burnReserved += amount;
        jobId = ++burnJobCount;
        burnJobs[jobId] = BurnJob(amount, bytes32(0), 0, BurnStatus.Queued);
        emit BurnQueued(jobId, amount);
    }

    function bridgeDust() external view returns (uint256) {
        return burnQueued % IMDBridge.CONVERSION_RATE;
    }

    function quoteBurn(uint256 jobId) public view returns (MessagingFee memory fee) {
        BurnJob storage job = burnJobs[jobId];
        if (job.status != BurnStatus.Queued && job.status != BurnStatus.Failed) revert InvalidBurnJob();
        fee = IIMDOFT(IMD).quoteSend(_sendParam(jobId), false);
    }

    /// @notice A failed source send stays reserved and retryable under the SAME ID. No fund withdrawal.
    function dispatchBurn(uint256 jobId) external payable nonReentrant onlyOwner returns (bool sent) {
        _checkFrozenRoute();
        MessagingFee memory fee = quoteBurn(jobId);
        if (fee.nativeFee > MAX_NATIVE_FEE || fee.lzTokenFee != 0 || msg.value != fee.nativeFee) {
            revert InvalidFee();
        }
        BurnJob storage job = burnJobs[jobId];
        if (job.status == BurnStatus.Failed) {
            failedBurnAmount -= job.amount;
            ++totalSendRetries;
        }
        ++job.attempts;
        // Effects precede the bridge call; the catch restores custody if the atomic subcall fails.
        job.status = BurnStatus.InTransit;
        burnReserved -= job.amount;
        burnInTransit += job.amount;
        // EIP-150 headroom plus storage/log/refund margin. Underfunded outer calls MUST revert.
        if (gasleft() < SEND_GAS * 64 / 63 + 150_000) revert InsufficientExecutionGas();
        try this.performBridgeSend{value: msg.value, gas: SEND_GAS}(jobId, fee) returns (bytes32 guid) {
            job.guid = guid;
            sentGuids[guid] = true;
            emit BurnDispatched(jobId, guid, job.amount, job.attempts);
            return true;
        } catch (bytes memory reason) {
            job.status = BurnStatus.Failed;
            burnReserved += job.amount;
            burnInTransit -= job.amount;
            failedBurnAmount += job.amount;
            ++totalSendFailures;
            emit BurnSendFailed(jobId, job.attempts, keccak256(reason));
            if (msg.value != 0) {
                (bool refunded,) = payable(msg.sender).call{value: msg.value}("");
                if (!refunded) revert RefundFailed();
            }
            return false;
        }
    }

    /// @dev Isolated subcall makes malformed receipts/inexact debits atomic with bridge failure.
    ///      Only callable by dispatchBurn; the outer entrypoint holds the reentrancy guard.
    function performBridgeSend(uint256 jobId, MessagingFee calldata fee) external payable returns (bytes32) {
        if (msg.sender != address(this)) revert OnlySelf();
        uint256 beforeHeld = IERC20(IMD).balanceOf(address(this));
        uint256 amount = burnJobs[jobId].amount;
        // Official Ethereum OFT burns msg.sender's debit. approvalRequired() == false; allowance stays ZERO.
        (MessagingReceipt memory receipt, OFTReceipt memory oftReceipt) =
            IIMDOFT(IMD).send{value: msg.value}(_sendParam(jobId), fee, owner());
        if (
            receipt.guid == bytes32(0) || sentGuids[receipt.guid] || receipt.fee.nativeFee != fee.nativeFee
                || receipt.fee.lzTokenFee != 0 || oftReceipt.amountSentLD != amount
                || oftReceipt.amountReceivedLD != amount
                || IERC20(IMD).balanceOf(address(this)) != beforeHeld - amount
        ) revert InexactTransfer();
        return receipt.guid;
    }

    function allowInitializePath(Origin calldata origin) external view returns (bool) {
        return baseReceiver != address(0) && origin.srcEid == IMDBridge.BASE_EID
            && origin.sender == IMDBridge.asBytes32(baseReceiver);
    }

    function nextNonce(uint32, bytes32) external pure returns (uint64) {
        return 0;
    }

    /// @notice LayerZero authenticated readiness / burn acknowledgements; never owner attestations of a burn.
    function lzReceive(
        Origin calldata origin,
        bytes32 messageGuid,
        bytes calldata message,
        address,
        bytes calldata
    ) external payable nonReentrant {
        _requireEthereum();
        if (
            msg.sender != IMDBridge.ENDPOINT || baseReceiver == address(0)
                || origin.srcEid != IMDBridge.BASE_EID || origin.sender != IMDBridge.asBytes32(baseReceiver)
                || msg.value != 0 || messageGuid == bytes32(0) || receivedGuids[messageGuid]
                || message.length != 160
        ) {
            revert InvalidMessage();
        }
        (uint8 kind, bytes32 configHash, uint256 jobId, bytes32 burnGuid, uint256 amount) =
            abi.decode(message, (uint8, bytes32, uint256, bytes32, uint256));
        if (configHash != bridgeConfigHash) revert InvalidMessage();
        receivedGuids[messageGuid] = true;
        if (kind == 1) {
            if (jobId != 0 || burnGuid != bytes32(0) || amount != 0) revert InvalidMessage();
            baseReady = true;
            emit BaseReadinessConfirmed(baseReceiver, configHash);
        } else if (kind == 2) {
            BurnJob storage job = burnJobs[jobId];
            if (job.status != BurnStatus.InTransit || job.guid != burnGuid || job.amount != amount) {
                revert InvalidMessage();
            }
            job.status = BurnStatus.Completed;
            burnInTransit -= amount;
            confirmedBurn += amount;
            emit BurnConfirmed(jobId, burnGuid, amount);
        } else {
            revert InvalidMessage();
        }
    }

    function _sendParam(uint256 jobId) private view returns (SendParam memory) {
        uint256 amount = burnJobs[jobId].amount;
        return SendParam(
            IMDBridge.BASE_EID,
            IMDBridge.asBytes32(baseReceiver),
            amount,
            amount,
            IMDBridge.burnOptions(),
            abi.encode(jobId),
            bytes("")
        );
    }

    function _checkOfficialRoute() private view {
        IIMDOFT oft = IIMDOFT(IMD);
        if (
            oft.endpoint() != IMDBridge.ENDPOINT || IMDBridge.ENDPOINT.code.length == 0
                || ILZEndpoint(IMDBridge.ENDPOINT).eid() != IMDBridge.ETH_EID || oft.token() != IMD
                || oft.approvalRequired()
                || oft.peers(IMDBridge.BASE_EID) != IMDBridge.asBytes32(IMDBridge.BASE_ADAPTER)
                || oft.decimalConversionRate() != IMDBridge.CONVERSION_RATE
        ) revert InvalidBridgeConfiguration();
    }

    /// @dev Custody-relevant route only: token, endpoint, peer, debit mode, decimals and code hashes.
    ///      Enforced executor options belong to the IMD OFT owner and only change the quoted fee, which
    ///      dispatchBurn bounds by MAX_NATIVE_FEE; they are deliberately not part of the frozen route.
    ///      Purchases never call this: a purchase moves IMD into this contract and touches no bridge.
    function _checkFrozenRoute() internal view {
        _requireIMD();
        _checkOfficialRoute();
        if (IMD.codehash != imdCodeHash || IMDBridge.ENDPOINT.codehash != endpointCodeHash) {
            revert InvalidBridgeConfiguration();
        }
    }
}
