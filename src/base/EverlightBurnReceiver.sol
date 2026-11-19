// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    IMDBridge,
    IIMDOFT,
    IBaseIMD,
    ILZEndpoint,
    MessagingParams,
    MessagingFee,
    MessagingReceipt
} from "../bridge/IMDBridge.sol";

/// @notice BASE ONLY. Separate owner deployment, explicitly excluded from Ethereum's launch manifest.
/// @dev No token withdrawal, approval, arbitrary call, token creation, or owner-reported burns.
contract EverlightBurnReceiver is Ownable2Step, ReentrancyGuard {
    address public constant IMD = IMDBridge.BASE_IMD;
    address public constant ETHEREUM_IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 public constant BURN_GAS = 150_000;
    uint256 public constant MAX_NATIVE_FEE = 0.05 ether;
    address public immutable ethereumGarden;
    bool public activated;
    bytes32 public configHash;
    bytes32 public evidenceHash;
    bytes32 public tokenCodeHash;
    bytes32 public adapterCodeHash;
    bytes32 public endpointCodeHash;
    enum Status {
        None,
        Received,
        Failed,
        Burned
    }

    struct Delivery {
        uint256 jobId;
        uint256 amount;
        uint32 attempts;
        Status status;
        bool acknowledged;
    }
    mapping(bytes32 => Delivery) public deliveries;
    mapping(uint256 => bytes32) public jobGuids;
    uint256 public pendingBurn;
    uint256 public failedBurn;
    uint256 public totalReceived;
    uint256 public totalBurned;
    uint256 public totalFailures;
    uint256 public totalRetries;
    error WrongChain();
    error InvalidConfiguration();
    error InvalidDelivery();
    error InvalidFee();
    error OnlySelf();
    error InexactBurn();
    error InsufficientExecutionGas();
    error OwnershipRequired();
    event ReceiverActivated(bytes32 indexed configHash, bytes32 evidenceHash);
    event BurnReceived(bytes32 indexed guid, uint256 indexed jobId, uint256 amount);
    event BurnFailed(bytes32 indexed guid, uint32 attempt, bytes32 reasonHash);
    event SupplyBurned(bytes32 indexed guid, uint256 indexed jobId, uint256 amount, uint256 cumulativeBurned);
    event ReceiptSent(bytes32 indexed burnGuid, bytes32 indexed messageGuid, uint8 kind);

    constructor(address owner_, address ethereumGarden_) Ownable(owner_) {
        if (ethereumGarden_ == address(0)) revert InvalidConfiguration();
        ethereumGarden = ethereumGarden_;
    }

    function activate(bytes32 evidence) external nonReentrant onlyOwner {
        _requireBase();
        if (activated || evidence == bytes32(0)) revert InvalidConfiguration();
        _checkRoute();
        activated = true;
        evidenceHash = evidence;
        configHash = keccak256(abi.encode(uint256(1), ethereumGarden, uint256(8453), address(this), evidence));
        tokenCodeHash = IMD.codehash;
        adapterCodeHash = IMDBridge.BASE_ADAPTER.codehash;
        endpointCodeHash = IMDBridge.ENDPOINT.codehash;
        emit ReceiverActivated(configHash, evidence);
    }

    /// @notice Separate native-gas payment for readiness; does not move IMD.
    function announceReady() external payable nonReentrant onlyOwner {
        _requireReady();
        _sendReceipt(1, bytes32(0));
    }

    /// @notice Official OFT compose format: nonce[8], srcEid[4], amount[32], composeFrom[32], jobId[32].
    function lzCompose(address from, bytes32 guid, bytes calldata message, address, bytes calldata)
        external
        payable
        nonReentrant
    {
        _requireBase();
        // The adapter credited this delivery in its own earlier lzReceive. A later adapter peer or code
        // change must not strand it unrecorded: authenticate by endpoint + adapter + message only, as
        // retryBurn does. The full live route check still gates activate and announceReady.
        if (!activated || IMD.codehash != tokenCodeHash) revert InvalidConfiguration();
        if (
            msg.sender != IMDBridge.ENDPOINT || from != IMDBridge.BASE_ADAPTER || msg.value != 0
                || message.length != 108 || guid == bytes32(0) || deliveries[guid].status != Status.None
                || uint32(bytes4(message[8:12])) != IMDBridge.ETH_EID
                || bytes32(message[44:76]) != IMDBridge.asBytes32(ethereumGarden)
        ) revert InvalidDelivery();
        uint256 amount = uint256(bytes32(message[12:44]));
        uint256 jobId = abi.decode(message[76:], (uint256));
        if (
            amount == 0 || amount % IMDBridge.CONVERSION_RATE != 0 || jobId == 0
                || jobGuids[jobId] != bytes32(0)
                || IERC20(IMD).balanceOf(address(this)) < pendingBurn + amount
        ) revert InvalidDelivery();
        jobGuids[jobId] = guid;
        deliveries[guid] = Delivery(jobId, amount, 0, Status.Received, false);
        totalReceived += amount;
        pendingBurn += amount;
        emit BurnReceived(guid, jobId, amount);
        _attemptBurn(guid);
    }

    /// @notice Anyone can pay gas to retry the same authenticated, funded delivery. Cannot redirect it.
    function retryBurn(bytes32 guid) external nonReentrant {
        _requireBase();
        // This delivery was already authenticated and funded. A later bridge-peer change must not
        // prevent burning its retained balance; only the fixed token is involved in a retry.
        if (!activated || IMD.codehash != tokenCodeHash) revert InvalidConfiguration();
        if (deliveries[guid].status != Status.Failed) revert InvalidDelivery();
        failedBurn -= deliveries[guid].amount;
        ++totalRetries;
        _attemptBurn(guid);
    }

    function performBurn(uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        IERC20 token = IERC20(IMD);
        uint256 held = token.balanceOf(address(this));
        uint256 supply = token.totalSupply();
        IBaseIMD(IMD).burn(amount);
        if (token.balanceOf(address(this)) != held - amount || token.totalSupply() != supply - amount) {
            revert InexactBurn();
        }
    }

    /// @notice Send a confirmed burn back to Ethereum, funded by caller's native ETH, exactly once.
    /// @dev A delivery failure is retried on LayerZero using this SAME packet; never burn or send tokens again.
    function sendBurnReceipt(bytes32 guid) external payable nonReentrant {
        _requireBase();
        Delivery storage d = deliveries[guid];
        if (d.status != Status.Burned || d.acknowledged) revert InvalidDelivery();
        d.acknowledged = true;
        _sendReceipt(2, guid);
    }

    function quoteReceipt(uint8 kind, bytes32 guid) external view returns (MessagingFee memory) {
        return ILZEndpoint(IMDBridge.ENDPOINT).quote(_receiptParams(kind, guid), address(this));
    }

    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRequired();
    }

    function _attemptBurn(bytes32 guid) private {
        Delivery storage d = deliveries[guid];
        ++d.attempts;
        // Effects precede the token call; failure restores pending custody below.
        d.status = Status.Burned;
        pendingBurn -= d.amount;
        totalBurned += d.amount;
        if (gasleft() < BURN_GAS * 64 / 63 + 120_000) revert InsufficientExecutionGas();
        try this.performBurn{gas: BURN_GAS}(d.amount) {
            emit SupplyBurned(guid, d.jobId, d.amount, totalBurned);
        } catch (bytes memory reason) {
            d.status = Status.Failed;
            pendingBurn += d.amount;
            totalBurned -= d.amount;
            failedBurn += d.amount;
            ++totalFailures;
            emit BurnFailed(guid, d.attempts, keccak256(reason));
        }
    }

    function _sendReceipt(uint8 kind, bytes32 guid) private {
        MessagingParams memory params = _receiptParams(kind, guid);
        MessagingFee memory fee = ILZEndpoint(IMDBridge.ENDPOINT).quote(params, address(this));
        if (fee.lzTokenFee != 0 || fee.nativeFee > MAX_NATIVE_FEE || msg.value != fee.nativeFee) {
            revert InvalidFee();
        }
        MessagingReceipt memory receipt =
            ILZEndpoint(IMDBridge.ENDPOINT).send{value: msg.value}(params, msg.sender);
        if (
            receipt.guid == bytes32(0) || receipt.fee.nativeFee != fee.nativeFee
                || receipt.fee.lzTokenFee != 0
        ) revert InvalidFee();
        emit ReceiptSent(guid, receipt.guid, kind);
    }

    function _receiptParams(uint8 kind, bytes32 guid) private view returns (MessagingParams memory) {
        Delivery storage d = deliveries[guid];
        if (
            !activated || (kind != 1 && kind != 2) || (kind == 1 && guid != bytes32(0))
                || (kind == 2 && d.status != Status.Burned)
        ) revert InvalidDelivery();
        return MessagingParams(
            IMDBridge.ETH_EID,
            IMDBridge.asBytes32(ethereumGarden),
            abi.encode(kind, configHash, d.jobId, guid, d.amount),
            IMDBridge.receiveOptions(),
            false
        );
    }

    function _requireBase() private view {
        if (block.chainid != 8453) revert WrongChain();
    }

    function _requireReady() private view {
        _requireBase();
        if (
            !activated || IMD.codehash != tokenCodeHash || IMDBridge.BASE_ADAPTER.codehash != adapterCodeHash
                || IMDBridge.ENDPOINT.codehash != endpointCodeHash
        ) revert InvalidConfiguration();
        _checkRoute();
    }

    function _checkRoute() private view {
        IIMDOFT adapter = IIMDOFT(IMDBridge.BASE_ADAPTER);
        if (
            IMD.code.length == 0 || IERC20Metadata(IMD).decimals() != 18 || adapter.token() != IMD
                || !adapter.approvalRequired() || adapter.endpoint() != IMDBridge.ENDPOINT
                || adapter.decimalConversionRate() != IMDBridge.CONVERSION_RATE
                || adapter.peers(IMDBridge.ETH_EID) != IMDBridge.asBytes32(ETHEREUM_IMD)
                || ILZEndpoint(IMDBridge.ENDPOINT).eid() != IMDBridge.BASE_EID
        ) revert InvalidConfiguration();
    }
}
