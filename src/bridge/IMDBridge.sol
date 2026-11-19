// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ABI subset of the verified IMD OFT / LayerZero V2 source. See docs/verification.md.
struct SendParam {
    uint32 dstEid;
    bytes32 to;
    uint256 amountLD;
    uint256 minAmountLD;
    bytes extraOptions;
    bytes composeMsg;
    bytes oftCmd;
}

struct OFTReceipt {
    uint256 amountSentLD;
    uint256 amountReceivedLD;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

struct MessagingParams {
    uint32 dstEid;
    bytes32 receiver;
    bytes message;
    bytes options;
    bool payInLzToken;
}

struct Origin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

interface IIMDOFT {
    function token() external view returns (address);
    function approvalRequired() external view returns (bool);
    function endpoint() external view returns (address);
    function peers(uint32 eid) external view returns (bytes32);
    function decimalConversionRate() external view returns (uint256);
    function enforcedOptions(uint32 eid, uint16 msgType) external view returns (bytes memory);
    function quoteSend(SendParam calldata param, bool payInLzToken)
        external
        view
        returns (MessagingFee memory);
    function send(SendParam calldata param, MessagingFee calldata fee, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory);
}

interface ILZEndpoint {
    function eid() external view returns (uint32);
    function quote(MessagingParams calldata params, address sender)
        external
        view
        returns (MessagingFee memory);
    function send(MessagingParams calldata params, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory);
}

interface IBaseIMD {
    function burn(uint256 amount) external;
}

library IMDBridge {
    uint32 internal constant ETH_EID = 30101;
    uint32 internal constant BASE_EID = 30184;
    address internal constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address internal constant BASE_ADAPTER = 0xab152db8aaC047b6757fFCF495FfE88d7712690A;
    address internal constant BASE_IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    uint256 internal constant CONVERSION_RATE = 1e12;
    uint128 internal constant RECEIVE_GAS = 200_000;
    // The executor gives this to EndpointV2.lzCompose, whose queue bookkeeping and the 63/64 forwarding
    // rule come out of it. A first delivery measured about 466.5k that way (test/RevisionFindings.t.sol).
    uint128 internal constant COMPOSE_GAS = 650_000;

    function asBytes32(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    // LayerZero OptionsBuilder Type 3: executor worker=1; receive=1, compose=3.
    // Each option size includes its one-byte type; compose includes uint16 index 0.
    function receiveOptions() internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), RECEIVE_GAS);
    }

    function burnOptions() internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint16(3),
            uint8(1),
            uint16(17),
            uint8(1),
            RECEIVE_GAS,
            uint8(1),
            uint16(19),
            uint8(3),
            uint16(0),
            COMPOSE_GAS
        );
    }
}
