// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {AdversarialIMD} from "./AdversarialIMD.sol";
import {
    IMDBridge,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    MessagingParams,
    OFTReceipt,
    Origin
} from "../../src/bridge/IMDBridge.sol";

interface IComposerDouble {
    function lzCompose(address, bytes32, bytes calldata, address, bytes calldata) external payable;
}

contract EndpointDouble {
    uint32 public eid = 30101;
    uint256 public nativeFee = 1e14;
    uint64 public nonce;
    bool public failSend;
    bytes public lastMessage;
    bytes public lastOptions;
    bytes32 public lastReceiver;
    address public lastSender;

    mapping(bytes32 => bytes32) public composeQueue;

    event ComposeDelivered(address from, address to, bytes32 guid, uint16 index);

    function sendCompose(address to, bytes32 guid, uint16 index, bytes calldata message) external {
        lastMessage = message;
        lastReceiver = IMDBridge.asBytes32(to);
        lastSender = msg.sender;
        composeQueue[keccak256(abi.encode(msg.sender, to, guid, index))] = keccak256(message);
    }

    /// @dev Same steps as EndpointV2.lzCompose (MessagingComposer): verify and clear the queued hash,
    ///      forward the remaining gas (so the EVM's 63/64 rule applies), then log. The executor gives
    ///      THIS call the compose gas option, not the composer directly.
    function lzCompose(
        address from,
        address to,
        bytes32 guid,
        uint16 index,
        bytes calldata message,
        bytes calldata extraData
    ) external payable {
        bytes32 key = keccak256(abi.encode(from, to, guid, index));
        require(composeQueue[key] == keccak256(message), "compose not queued");
        composeQueue[key] = bytes32(uint256(1));
        IComposerDouble(to).lzCompose{value: msg.value}(from, guid, message, msg.sender, extraData);
        emit ComposeDelivered(from, to, guid, index);
    }

    function setEid(uint32 id) external {
        eid = id;
    }

    function setFee(uint256 fee) external {
        nativeFee = fee;
    }

    function setFailure(bool failure) external {
        failSend = failure;
    }

    function quote(MessagingParams calldata, address) external view returns (MessagingFee memory) {
        return MessagingFee(nativeFee, 0);
    }

    function send(MessagingParams calldata p, address) external payable returns (MessagingReceipt memory) {
        require(!failSend, "endpoint failure");
        require(msg.value == nativeFee && !p.payInLzToken, "fee");
        lastMessage = p.message;
        lastOptions = p.options;
        lastReceiver = p.receiver;
        lastSender = msg.sender;
        ++nonce;
        return MessagingReceipt(
            keccak256(abi.encode(nonce, msg.sender, block.chainid)), nonce, MessagingFee(nativeFee, 0)
        );
    }
}

contract IMDOFTDouble is AdversarialIMD {
    uint256 public constant decimalConversionRate = 1e12;
    bool public failSend;
    bool public badReceipt;
    bool public failBurn;
    bool public fakeBurn;
    bytes32 public peer;
    uint64 public sendNonce;
    bytes32 public lastGuid;
    bytes public lastCompose;
    bytes32 public lastDestination;
    bytes public options;

    function setPeer(bytes32 value) external {
        peer = value;
    }

    function setOptions(bytes calldata value) external {
        options = value;
    }

    function setSendFailure(bool failure, bool wrongReceipt) external {
        failSend = failure;
        badReceipt = wrongReceipt;
    }

    function setBurnFailure(bool failure, bool fake) external {
        failBurn = failure;
        fakeBurn = fake;
    }

    function token() external view returns (address) {
        return address(this);
    }

    function endpoint() external pure returns (address) {
        return IMDBridge.ENDPOINT;
    }

    function approvalRequired() external pure returns (bool) {
        return false;
    }

    function peers(uint32) external view returns (bytes32) {
        return peer;
    }

    function enforcedOptions(uint32, uint16) external view returns (bytes memory) {
        return options;
    }

    function quoteSend(SendParam calldata, bool) external view returns (MessagingFee memory) {
        return MessagingFee(EndpointDouble(IMDBridge.ENDPOINT).nativeFee(), 0);
    }

    function send(SendParam calldata p, MessagingFee calldata f, address)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory)
    {
        require(!failSend, "bridge failure");
        require(p.dstEid == 30184 && p.amountLD == p.minAmountLD && p.oftCmd.length == 0, "route");
        require(msg.value == f.nativeFee && f.lzTokenFee == 0, "fee");
        _burn(msg.sender, p.amountLD);
        lastCompose = p.composeMsg;
        lastDestination = p.to;
        lastGuid = keccak256(abi.encode(++sendNonce, msg.sender));
        return
            (
                MessagingReceipt(lastGuid, sendNonce, f),
                OFTReceipt(p.amountLD, p.amountLD - (badReceipt ? 1 : 0))
            );
    }

    function burn(uint256 amount) external {
        require(!failBurn, "burn failure");
        if (!fakeBurn) _burn(msg.sender, amount);
    }
}

contract BaseAdapterDouble {
    bytes32 public peer;

    function setPeer(bytes32 value) external {
        peer = value;
    }

    function token() external pure returns (address) {
        return IMDBridge.BASE_IMD;
    }

    function endpoint() external pure returns (address) {
        return IMDBridge.ENDPOINT;
    }

    function approvalRequired() external pure returns (bool) {
        return true;
    }

    function peers(uint32) external view returns (bytes32) {
        return peer;
    }

    function decimalConversionRate() external pure returns (uint256) {
        return 1e12;
    }
}
