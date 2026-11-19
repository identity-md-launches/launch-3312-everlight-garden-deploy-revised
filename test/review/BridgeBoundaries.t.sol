// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    GardenTestBase,
    WishGarden,
    WishGardenTreasury,
    EverlightBridgeQueue,
    EverlightBurnReceiver,
    IMDBridge,
    Origin
} from "../helpers/GardenTestBase.sol";
import {IMDOFTDouble} from "../helpers/BridgeDoubles.sol";
import {WalletGas} from "../helpers/WalletGas.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Local owner wallet to exercise native refunds, including an authorized callback.
contract RefundOwner {
    WishGarden private immutable garden;
    bool public reject;
    bool public reenter;
    bytes public callbackResult;
    event RefundObserved(uint256 amount, bool callbackSucceeded);

    constructor(WishGarden g) {
        garden = g;
    }

    function accept() external {
        garden.acceptOwnership();
    }

    function mode(bool reject_, bool reenter_) external {
        reject = reject_;
        reenter = reenter_;
    }

    receive() external payable {
        require(!reject, "wallet rejects refund");
        bool success;
        if (reenter) {
            (success, callbackResult) = address(garden).call(abi.encodeCall(garden.queueBurn, (1e12)));
        }
        emit RefundObserved(msg.value, success);
    }
}

contract BridgeBoundariesTest is GardenTestBase, WalletGas {
    function test_walletGasSourceFailuresAndSubsequentRetry() public {
        _buy(alice, 2, 0);
        vm.prank(OWNER);
        uint256 id = garden.queueBurn(3e17);
        bytes memory data = abi.encodeCall(garden.dispatchBurn, (id));
        token.setSendFailure(true, false);
        assertSameAtWalletGas(OWNER, address(garden), 1e14, data);
        vm.prank(OWNER);
        assertFalse(garden.dispatchBurn{value: 1e14}(id));
        token.setSendFailure(false, true);
        assertSameAtWalletGas(OWNER, address(garden), 1e14, data);
        token.setSendFailure(false, false);
        assertSameAtWalletGas(OWNER, address(garden), 1e14, data);
        vm.prank(OWNER);
        assertTrue(garden.dispatchBurn{value: 1e14}(id));
        assertEq(garden.totalSendRetries(), 1);
        assertEq(garden.totalSendFailures(), 1);
        _assertSolvent();
    }

    function test_walletGasBaseComposeFailureAndRetryInEveryOutcome() public {
        _setupBase();
        IMDOFTDouble base = IMDOFTDouble(IMDBridge.BASE_IMD);
        base.mint(address(receiver), 3e17);
        bytes32 guid = keccak256("gas checks including failed burn");
        bytes memory payload = _baseMessage(1, 3e17);
        bytes memory compose = abi.encodeCall(
            receiver.lzCompose, (IMDBridge.BASE_ADAPTER, guid, payload, address(this), bytes(""))
        );
        base.setBurnFailure(true, false);
        assertSameAtWalletGas(IMDBridge.ENDPOINT, address(receiver), compose);
        _compose(guid, 1, 3e17);
        bytes memory retry = abi.encodeCall(receiver.retryBurn, (guid));
        assertSameAtWalletGas(alice, address(receiver), retry);
        base.setBurnFailure(false, true);
        assertSameAtWalletGas(alice, address(receiver), retry);
        base.setBurnFailure(false, false);
        assertSameAtWalletGas(alice, address(receiver), retry);
        vm.prank(alice);
        receiver.retryBurn(guid);
        assertEq(receiver.totalBurned(), 3e17);
        assertEq(receiver.totalRetries(), 1);
        assertEq(receiver.totalFailures(), 1);
        assertEq(base.totalSupply(), 0);
    }

    function test_refundRejectionRollsBackAttemptAndAuthorizedRefundReentryFails() public {
        _buy(alice, 2, 0);
        vm.prank(OWNER);
        uint256 id = garden.queueBurn(3e17);
        RefundOwner wallet = new RefundOwner(garden);
        vm.prank(OWNER);
        garden.transferOwnership(address(wallet));
        wallet.accept();
        vm.deal(address(wallet), 1 ether);
        token.setSendFailure(true, false);
        wallet.mode(true, false);
        vm.prank(address(wallet));
        vm.expectRevert(EverlightBridgeQueue.RefundFailed.selector);
        garden.dispatchBurn{value: 1e14}(id);
        (,, uint32 attempts, EverlightBridgeQueue.BurnStatus status) = garden.burnJobs(id);
        assertEq(attempts, 0);
        assertEq(uint256(status), uint256(EverlightBridgeQueue.BurnStatus.Queued));
        assertEq(garden.totalSendFailures(), 0);
        assertEq(garden.failedBurnAmount(), 0);
        assertEq(address(wallet).balance, 1 ether);
        assertEq(address(garden).balance, 0);
        wallet.mode(false, true);
        assertSameAtWalletGas(
            address(wallet), address(garden), 1e14, abi.encodeCall(garden.dispatchBurn, (id))
        );
        vm.prank(address(wallet));
        assertFalse(garden.dispatchBurn{value: 1e14}(id));
        assertEq(
            wallet.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(garden.burnJobCount(), 1);
        assertEq(garden.burnQueued(), 9e17);
        assertEq(garden.burnReserved(), 3e17);
        assertEq(address(wallet).balance, 1 ether);
        token.setSendFailure(false, false);
        vm.prank(address(wallet));
        assertTrue(garden.dispatchBurn{value: 1e14}(id));
        assertEq(address(wallet).balance, 1 ether - 1e14);
        _assertSolvent();
    }

    function testFuzz_acknowledgementAuthenticationAndRejectionAreAtomic(uint8 fieldSeed) public {
        _buy(alice, 1, 0);
        vm.prank(OWNER);
        uint256 id = garden.queueBurn(3e17);
        vm.prank(OWNER);
        garden.dispatchBurn{value: 1e14}(id);
        bytes32 burnGuid = token.lastGuid();
        bytes32 ackGuid = keccak256("acknowledgement field mutation");
        bytes32 config = garden.bridgeConfigHash();
        bytes memory valid = abi.encode(uint8(2), config, id, burnGuid, uint256(3e17));
        bytes memory payload = valid;
        Origin memory origin = Origin(30184, IMDBridge.asBytes32(address(receiver)), 2);
        address caller = IMDBridge.ENDPOINT;
        bytes32 submittedGuid = ackGuid;
        uint256 value;
        uint8 field = fieldSeed % 11;
        if (field == 0) caller = alice;
        if (field == 1) origin.srcEid = 30101;
        if (field == 2) origin.sender = IMDBridge.asBytes32(alice);
        if (field == 3) {
            payload = abi.encode(uint8(2), config ^ bytes32(uint256(1)), id, burnGuid, uint256(3e17));
        }
        if (field == 4) payload = abi.encode(uint8(3), config, id, burnGuid, uint256(3e17));
        if (field == 5) payload = abi.encode(uint8(2), config, id + 1, burnGuid, uint256(3e17));
        if (field == 6) {
            payload = abi.encode(uint8(2), config, id, burnGuid ^ bytes32(uint256(1)), uint256(3e17));
        }
        if (field == 7) payload = abi.encode(uint8(2), config, id, burnGuid, uint256(3e17 + 1));
        if (field == 8) submittedGuid = bytes32(0);
        if (field == 9) payload = bytes.concat(valid, hex"00");
        if (field == 10) value = 1;
        vm.deal(caller, 1 ether);
        vm.prank(caller);
        vm.expectRevert(EverlightBridgeQueue.InvalidMessage.selector);
        garden.lzReceive{value: value}(origin, submittedGuid, payload, address(this), "");
        assertFalse(garden.receivedGuids(submittedGuid));
        assertEq(garden.confirmedBurn(), 0);
        assertEq(garden.burnInTransit(), 3e17);
        vm.prank(IMDBridge.ENDPOINT);
        garden.lzReceive(Origin(30184, IMDBridge.asBytes32(address(receiver)), 2), ackGuid, valid, alice, "");
        assertEq(garden.confirmedBurn(), 3e17);
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBridgeQueue.InvalidMessage.selector);
        garden.lzReceive(
            Origin(30184, IMDBridge.asBytes32(address(receiver)), 3),
            keccak256("same receipt with new packet GUID"),
            valid,
            alice,
            ""
        );
        _assertSolvent();
    }

    function testFuzz_composeAuthenticationAndRejectionAreAtomic(uint8 fieldSeed) public {
        _setupBase();
        IMDOFTDouble base = IMDOFTDouble(IMDBridge.BASE_IMD);
        base.mint(address(receiver), 3e17);
        bytes32 guid = keccak256("compose field mutation");
        bytes32 submittedGuid = guid;
        bytes memory payload = _baseMessage(1, 3e17);
        address caller = IMDBridge.ENDPOINT;
        address from = IMDBridge.BASE_ADAPTER;
        uint256 value;
        uint8 field = fieldSeed % 11;
        if (field == 0) caller = alice;
        if (field == 1) from = alice;
        if (field == 2) {
            payload = abi.encodePacked(
                uint64(1), uint32(30184), uint256(3e17), IMDBridge.asBytes32(address(garden)), uint256(1)
            );
        }
        if (field == 3) {
            payload = abi.encodePacked(
                uint64(1), uint32(30101), uint256(3e17), IMDBridge.asBytes32(alice), uint256(1)
            );
        }
        if (field == 4) submittedGuid = bytes32(0);
        if (field == 5) payload = _baseMessage(0, 3e17);
        if (field == 6) payload = _baseMessage(1, 0);
        if (field == 7) payload = _baseMessage(1, 3e17 + 1);
        if (field == 8) payload = bytes.concat(payload, hex"00");
        if (field == 9) payload = _baseMessage(1, 3e17 + 1e12);
        if (field == 10) value = 1;
        vm.deal(caller, 1 ether);
        vm.prank(caller);
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        receiver.lzCompose{value: value}(from, submittedGuid, payload, address(this), "");
        assertEq(receiver.totalReceived(), 0);
        assertEq(receiver.totalBurned(), 0);
        assertEq(receiver.jobGuids(1), bytes32(0));
        assertEq(base.totalSupply(), 3e17);
        _compose(guid, 1, 3e17);
        assertEq(receiver.totalBurned(), 3e17);
        assertEq(base.totalSupply(), 0);
    }

    /// @dev Revised behaviour: a route change no longer gates purchases (they touch no bridge). It still
    ///      makes burn dispatch fail closed for every custody-relevant component, without consuming an
    ///      attempt, and the reserved job dispatches once the original component is restored. Enforced
    ///      options (component 2) are not part of the frozen route and only affect the bounded fee.
    function testFuzz_changedFrozenRouteStopsDispatchOnlyAndRecoversWhenRestored(uint8 componentSeed) public {
        _buy(alice, 2, 0);
        vm.prank(OWNER);
        uint256 id = garden.queueBurn(3e17);
        uint8 component = componentSeed % 5;
        bytes memory imdCode = IMD.code;
        bytes memory endpointCode = IMDBridge.ENDPOINT.code;
        if (component == 0) vm.etch(IMD, bytes.concat(imdCode, hex"00"));
        if (component == 1) vm.etch(IMDBridge.ENDPOINT, bytes.concat(endpointCode, hex"00"));
        if (component == 2) token.setOptions(hex"0003");
        if (component == 3) token.setPeer(IMDBridge.asBytes32(alice));
        if (component == 4) endpoint.setEid(30184);

        // Purchases and claims continue regardless of bridge state.
        _buy(bob, 1, 3);
        assertEq(garden.totalCandles(), 3);
        vm.prank(alice);
        assertEq(garden.claimRewards(), 12e17); // 0.6 from candle 2 + 2 x 0.3 from bob's candle

        if (component == 2) {
            vm.prank(OWNER);
            assertTrue(garden.dispatchBurn{value: 1e14}(id));
            assertEq(garden.burnInTransit(), 3e17);
            _assertSolvent();
            return;
        }
        vm.prank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.InvalidBridgeConfiguration.selector);
        garden.dispatchBurn{value: 1e14}(id);
        (,, uint32 attempts, EverlightBridgeQueue.BurnStatus status) = garden.burnJobs(id);
        assertEq(attempts, 0);
        assertEq(uint8(status), uint8(EverlightBridgeQueue.BurnStatus.Queued));
        assertEq(garden.burnReserved(), 3e17);
        assertEq(garden.totalSendFailures(), 0);
        _assertSolvent();

        if (component == 0) vm.etch(IMD, imdCode);
        if (component == 1) vm.etch(IMDBridge.ENDPOINT, endpointCode);
        if (component == 3) token.setPeer(IMDBridge.asBytes32(IMDBridge.BASE_ADAPTER));
        if (component == 4) endpoint.setEid(30101);
        vm.prank(OWNER);
        assertTrue(garden.dispatchBurn{value: 1e14}(id));
        assertEq(garden.burnInTransit(), 3e17);
        assertEq(garden.burnReserved(), 0);
        _assertSolvent();
    }

    function test_queueAndFeeBoundaryValues() public {
        _buy(alice, 1, 0);
        vm.startPrank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.InvalidBurnJob.selector);
        garden.queueBurn(0);
        vm.expectRevert(EverlightBridgeQueue.InvalidBurnJob.selector);
        garden.queueBurn(1e12 - 1);
        uint256 first = garden.queueBurn(1e12 + 1);
        uint256 second = garden.queueBurn(type(uint256).max);
        vm.expectRevert(EverlightBridgeQueue.InvalidBurnJob.selector);
        garden.queueBurn(type(uint256).max);
        vm.stopPrank();
        (uint256 a,,,) = garden.burnJobs(first);
        (uint256 b,,,) = garden.burnJobs(second);
        assertEq(a, 1e12);
        assertEq(a + b, 9e17);
        assertEq(garden.burnQueued(), 0);
        endpoint.setFee(0);
        vm.prank(OWNER);
        assertTrue(garden.dispatchBurn(first));
        endpoint.setFee(0.05 ether);
        vm.prank(OWNER);
        assertTrue(garden.dispatchBurn{value: 0.05 ether}(second));
        _assertSolvent();
    }

    function test_allSourceAdministrativeEntrypointsRejectStrangers() public {
        bytes[6] memory calls = [
            abi.encodeCall(garden.configureBridge, (address(receiver), EVIDENCE)),
            abi.encodeCall(garden.activate, ()),
            abi.encodeCall(garden.setPurchasesPaused, (true)),
            abi.encodeCall(garden.queueBurn, (1e12)),
            abi.encodeCall(garden.dispatchBurn, (1)),
            abi.encodeCall(garden.transferOwnership, (alice))
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(alice);
            (bool ok, bytes memory returned) = address(garden).call(calls[i]);
            assertFalse(ok);
            assertEq(returned, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        }
        assertEq(garden.owner(), OWNER);
        assertFalse(garden.purchasesPaused());
        assertEq(garden.burnJobCount(), 0);
    }

    function test_baseOwnershipRequiresAcceptanceAndCannotBeRenounced() public {
        _setupBase();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        receiver.announceReady();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        receiver.activate(EVIDENCE);
        vm.prank(OWNER);
        receiver.transferOwnership(bob);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        receiver.acceptOwnership();
        assertEq(receiver.owner(), OWNER);
        vm.prank(bob);
        receiver.acceptOwnership();
        assertEq(receiver.owner(), bob);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        receiver.announceReady();
        vm.prank(bob);
        vm.expectRevert(EverlightBurnReceiver.OwnershipRequired.selector);
        receiver.renounceOwnership();
        vm.prank(bob);
        vm.expectRevert(EverlightBurnReceiver.InvalidConfiguration.selector);
        receiver.activate(EVIDENCE);
    }

    function _baseMessage(uint256 id, uint256 amount) private view returns (bytes memory) {
        return abi.encodePacked(uint64(1), uint32(30101), amount, IMDBridge.asBytes32(address(garden)), id);
    }
}
