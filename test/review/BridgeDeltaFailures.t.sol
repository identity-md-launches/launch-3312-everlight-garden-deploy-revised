// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    GardenTestBase,
    WishGarden,
    EverlightBurnReceiver,
    EverlightBridgeQueue,
    IMDBridge
} from "../helpers/GardenTestBase.sol";
import {EndpointDouble, IMDOFTDouble} from "../helpers/BridgeDoubles.sol";
import {WalletGas} from "../helpers/WalletGas.sol";
import {ILZEndpoint, SendParam, MessagingFee, MessagingReceipt, OFTReceipt} from "src/bridge/IMDBridge.sol";

/// @dev Test-only OFT fault injection. All modes except 7 really debit the sender, so a bad
///      receipt is tested independently from the missing-debit check.
contract ReceiptFaultIMD is ERC20 {
    uint8 public mode;
    uint64 public nonce;
    bytes32 public lastGuid;
    uint256 public quoteTokenFee;

    constructor() ERC20("Offline source fault fixture", "TEST") {}

    function reset() external {
        mode = 0;
        nonce = 0;
        lastGuid = bytes32(0);
        quoteTokenFee = 0;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function setQuoteTokenFee(uint256 value) external {
        quoteTokenFee = value;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function token() external view returns (address) {
        return address(this);
    }

    function approvalRequired() external pure returns (bool) {
        return false;
    }

    function endpoint() external pure returns (address) {
        return IMDBridge.ENDPOINT;
    }

    function peers(uint32) external pure returns (bytes32) {
        return IMDBridge.asBytes32(IMDBridge.BASE_ADAPTER);
    }

    function decimalConversionRate() external pure returns (uint256) {
        return 1e12;
    }

    function enforcedOptions(uint32, uint16) external pure returns (bytes memory) {
        return "";
    }

    function quoteSend(SendParam calldata, bool) external view returns (MessagingFee memory) {
        return MessagingFee(EndpointDouble(IMDBridge.ENDPOINT).nativeFee(), quoteTokenFee);
    }

    function send(SendParam calldata p, MessagingFee calldata fee, address)
        external
        payable
        returns (MessagingReceipt memory receipt, OFTReceipt memory oft)
    {
        if (mode != 7) _burn(msg.sender, p.amountLD + (mode == 8 ? 1 : 0) - (mode == 9 ? 1 : 0));
        bytes32 previousGuid = lastGuid;
        lastGuid = keccak256(abi.encode(++nonce, msg.sender));
        receipt = MessagingReceipt(lastGuid, nonce, fee);
        oft = OFTReceipt(p.amountLD, p.amountLD);
        if (mode == 1) receipt.guid = bytes32(0);
        if (mode == 2) receipt.guid = previousGuid;
        if (mode == 3) ++receipt.fee.nativeFee;
        if (mode == 4) receipt.fee.lzTokenFee = 1;
        if (mode == 5) --oft.amountSentLD;
        if (mode == 6) --oft.amountReceivedLD;
    }
}

/// @dev Test-only Base token. Several modes lower the receiver balance WITHOUT lowering supply,
///      or lower supply WITHOUT the required receiver debit. Those must never count as a burn.
contract BurnDeltaFaultIMD is ERC20 {
    uint8 public mode;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;

    constructor() ERC20("Offline burn fault fixture", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function setCallback(address to, bytes calldata data) external {
        callbackTarget = to;
        callbackData = data;
    }

    function burn(uint256 amount) external {
        if (callbackTarget != address(0)) {
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        }
        if (mode == 1) {
            _transfer(msg.sender, address(this), amount);
        } else if (mode == 2) {
            _burn(msg.sender, amount);
            _mint(address(this), amount);
        } else if (mode == 3) {
            _burn(msg.sender, amount - 1);
        } else if (mode == 4) {
            _burn(msg.sender, amount + 1);
        } else if (mode == 5) {
            _burn(address(this), amount);
        } else {
            _burn(msg.sender, amount);
        }
    }
}

contract BridgeDeltaFailuresTest is GardenTestBase, WalletGas {
    function testFuzz_everyMalformedReceiptAndDebitRestoresSourceFunds(uint8 faultSeed) public {
        ReceiptFaultIMD fixture = new ReceiptFaultIMD();
        vm.etch(IMD, address(fixture).code);
        ReceiptFaultIMD source = ReceiptFaultIMD(IMD);
        source.reset();
        garden = new WishGarden(OWNER);
        receiver = _deployReceiver(garden, OWNER);
        _activate(garden, address(receiver));
        _buy(alice, 2, 0);
        vm.startPrank(OWNER);
        uint256 first = garden.queueBurn(3e17);
        uint256 second = garden.queueBurn(3e17);
        assertTrue(garden.dispatchBurn{value: 1e14}(first));
        vm.stopPrank();
        bytes32 originalGuid = source.lastGuid();
        uint256 held = source.balanceOf(address(garden));
        uint256 supply = source.totalSupply();
        uint256 nativeBefore = OWNER.balance;
        uint256 bridgeNativeBefore = IMD.balance;
        source.setMode(uint8(1 + uint256(faultSeed) % 9));
        vm.prank(OWNER);
        assertFalse(garden.dispatchBurn{value: 1e14}(second));
        assertEq(source.balanceOf(address(garden)), held, "invalid bridge result must roll back actual debit");
        assertEq(source.totalSupply(), supply);
        assertEq(OWNER.balance, nativeBefore);
        assertEq(IMD.balance, bridgeNativeBefore);
        assertEq(source.nonce(), 1, "external send must be rolled back too");
        assertEq(source.lastGuid(), originalGuid);
        assertTrue(garden.sentGuids(originalGuid));
        (uint256 amount, bytes32 guid, uint32 attempts, EverlightBridgeQueue.BurnStatus status) =
            garden.burnJobs(second);
        assertEq(amount, 3e17);
        assertEq(guid, bytes32(0));
        assertEq(attempts, 1);
        assertEq(uint256(status), uint256(EverlightBridgeQueue.BurnStatus.Failed));
        assertEq(garden.burnReserved(), 3e17);
        assertEq(garden.burnInTransit(), 3e17);
        assertEq(garden.failedBurnAmount(), 3e17);
        assertEq(garden.confirmedBurn(), 0);
        source.setMode(0);
        vm.prank(OWNER);
        assertTrue(garden.dispatchBurn{value: 1e14}(second));
        assertEq(garden.burnReserved(), 0);
        assertEq(garden.burnInTransit(), 6e17);
        assertEq(garden.totalSendRetries(), 1);
        assertEq(garden.failedBurnAmount(), 0);
        _assertSolvent();
    }

    function testFuzz_balanceOrSupplyDeltaAloneNeverConfirmsBurn(uint8 faultSeed) public {
        BurnDeltaFaultIMD base = _faultBase();
        base.mint(address(receiver), 3e17 + 1);
        base.mint(address(base), 3e17);
        uint256 supply = base.totalSupply();
        base.setMode(uint8(1 + uint256(faultSeed) % 5));
        bytes32 guid = keccak256("inexact Base supply burn");
        _compose(guid, 1, 3e17);
        assertEq(base.totalSupply(), supply, "inexact burn and all its side effects must revert");
        assertEq(base.balanceOf(address(receiver)), 3e17 + 1);
        assertEq(base.balanceOf(address(base)), 3e17);
        assertEq(receiver.totalReceived(), 3e17);
        assertEq(receiver.totalBurned(), 0);
        assertEq(receiver.pendingBurn(), 3e17);
        assertEq(receiver.failedBurn(), 3e17);
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        receiver.sendBurnReceipt(guid);
        base.setMode(0);
        vm.prank(alice);
        receiver.retryBurn(guid);
        assertEq(base.totalSupply(), supply - 3e17);
        assertEq(base.balanceOf(address(receiver)), 1);
        assertEq(receiver.totalBurned(), 3e17);
        assertEq(receiver.pendingBurn(), 0);
        assertEq(receiver.failedBurn(), 0);
    }

    function test_baseBurnCallbacksCannotAcknowledgeOrRetryUnfinishedBurn() public {
        BurnDeltaFaultIMD base = _faultBase();
        base.mint(address(receiver), 6e17);
        bytes32 first = keccak256("reentrant premature acknowledgement");
        base.setCallback(address(receiver), abi.encodeCall(receiver.sendBurnReceipt, (first)));
        _compose(first, 1, 3e17);
        assertFalse(base.callbackSucceeded());
        assertEq(
            base.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        (,,,, bool acknowledged) = receiver.deliveries(first);
        assertFalse(acknowledged);
        bytes32 second = keccak256("reentrant burn retry");
        base.setMode(3);
        base.setCallback(address(0), "");
        _compose(second, 2, 3e17);
        base.setMode(0);
        base.setCallback(address(receiver), abi.encodeCall(receiver.retryBurn, (second)));
        assertSameAtWalletGas(alice, address(receiver), abi.encodeCall(receiver.retryBurn, (second)));
        receiver.retryBurn(second);
        assertFalse(base.callbackSucceeded());
        assertEq(
            base.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(base.totalSupply(), 0);
        assertEq(receiver.totalBurned(), 6e17);
        assertEq(receiver.totalRetries(), 1);
    }

    function testFuzz_malformedEndpointReceiptRollsBackAcknowledgement(uint8 faultSeed) public {
        _setupBase();
        // Existing fixture at this address supplies exact burns for this receipt-only test.
        IMDOFTDouble(IMDBridge.BASE_IMD).mint(address(receiver), 3e17);
        bytes32 guid = keccak256("malformed acknowledgement receipt");
        _compose(guid, 1, 3e17);
        uint256 nativeBefore = alice.balance;
        uint256 endpointBefore = IMDBridge.ENDPOINT.balance;
        MessagingReceipt memory malformed = MessagingReceipt(keccak256("message"), 1, MessagingFee(1e14, 0));
        uint8 mode = faultSeed % 3;
        if (mode == 0) malformed.guid = bytes32(0);
        if (mode == 1) ++malformed.fee.nativeFee;
        if (mode == 2) malformed.fee.lzTokenFee = 1;
        vm.mockCall(
            IMDBridge.ENDPOINT, abi.encodeWithSelector(ILZEndpoint.send.selector), abi.encode(malformed)
        );
        vm.prank(alice);
        vm.expectRevert(EverlightBurnReceiver.InvalidFee.selector);
        receiver.sendBurnReceipt{value: 1e14}(guid);
        (,,,, bool ack) = receiver.deliveries(guid);
        assertFalse(ack);
        assertEq(alice.balance, nativeBefore);
        assertEq(IMDBridge.ENDPOINT.balance, endpointBefore);
        assertEq(receiver.totalBurned(), 3e17);
        vm.clearMockedCalls();
        vm.prank(alice);
        receiver.sendBurnReceipt{value: 1e14}(guid);
        (,,,, ack) = receiver.deliveries(guid);
        assertTrue(ack);
        assertEq(receiver.totalBurned(), 3e17);
    }

    function test_sourceRefusesPaymentInLayerZeroTokenBeforeTryingTheSend() public {
        ReceiptFaultIMD fixture = new ReceiptFaultIMD();
        vm.etch(IMD, address(fixture).code);
        ReceiptFaultIMD source = ReceiptFaultIMD(IMD);
        source.reset();
        garden = new WishGarden(OWNER);
        _activate(garden, garden.pinnedBaseReceiver());
        _buy(alice, 1, 0);
        vm.prank(OWNER);
        uint256 id = garden.queueBurn(3e17);
        source.setQuoteTokenFee(1);
        vm.prank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.InvalidFee.selector);
        garden.dispatchBurn{value: 1e14}(id);
        (,, uint32 attempts,) = garden.burnJobs(id);
        assertEq(attempts, 0);
        assertEq(source.nonce(), 0);
        assertEq(garden.totalSendFailures(), 0);
        assertEq(garden.burnReserved(), 3e17);
    }

    function _faultBase() private returns (BurnDeltaFaultIMD base) {
        _setupBase();
        vm.etch(IMDBridge.BASE_IMD, address(new BurnDeltaFaultIMD()).code);
        // Freeze the fault fixture before activation, not by bypassing a production codehash check.
        receiver = new EverlightBurnReceiver(OWNER, address(garden));
        vm.prank(OWNER);
        receiver.activate(EVIDENCE);
        base = BurnDeltaFaultIMD(IMDBridge.BASE_IMD);
    }
}
