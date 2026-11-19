// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {
    GardenTestBase,
    WishGarden,
    EverlightBridgeQueue,
    EverlightBurnReceiver,
    IMDBridge,
    Origin,
    MessagingFee
} from "./helpers/GardenTestBase.sol";
import {IMDOFTDouble, BaseAdapterDouble} from "./helpers/BridgeDoubles.sol";

contract BridgeTest is GardenTestBase {
    function test_disabledAtDeploymentAndRequiresAuthenticatedBaseReadiness() public {
        WishGarden fresh = new WishGarden(OWNER);
        address pinned = fresh.pinnedBaseReceiver();
        assertFalse(fresh.activated());
        assertTrue(fresh.purchasesPaused());
        _rejectBuy(fresh, 1, 0, abi.encodeWithSelector(WishGarden.PurchasesDisabled.selector));
        vm.prank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.BridgeNotReady.selector);
        fresh.activate();
        vm.prank(alice);
        vm.expectRevert();
        fresh.configureBridge(pinned, EVIDENCE);
        vm.prank(OWNER);
        fresh.configureBridge(pinned, EVIDENCE);
        vm.prank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.BridgeNotReady.selector);
        fresh.activate();
        bytes memory ready =
            abi.encode(uint8(1), fresh.bridgeConfigHash(), uint256(0), bytes32(0), uint256(0));
        vm.expectRevert(EverlightBridgeQueue.InvalidMessage.selector);
        fresh.lzReceive(
            Origin(30184, IMDBridge.asBytes32(pinned), 1), bytes32(uint256(55)), ready, address(this), ""
        );
        vm.prank(IMDBridge.ENDPOINT);
        fresh.lzReceive(
            Origin(30184, IMDBridge.asBytes32(pinned), 1), bytes32(uint256(55)), ready, address(this), ""
        );
        vm.prank(OWNER);
        fresh.activate();
        assertTrue(fresh.activated());
        vm.prank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.ConfigurationFrozen.selector);
        fresh.configureBridge(alice, EVIDENCE);
        vm.prank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.ConfigurationFrozen.selector);
        fresh.activate();
    }

    /// @dev Changed with the behaviour (review finding 3a1155f9): a third-party OFT peer or
    ///      enforced-options change no longer disables purchases; only burn dispatch fails closed
    ///      on a custody-relevant change (peer), and resumes when the official peer is restored.
    function test_configurationChangeFailsClosedForDispatchOnlyAndClaimsStayAvailable() public {
        _buy(alice, 2, 0);
        vm.prank(OWNER);
        uint256 id = garden.queueBurn(type(uint256).max);
        token.setPeer(IMDBridge.asBytes32(alice));
        vm.prank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.InvalidBridgeConfiguration.selector);
        garden.dispatchBurn{value: 1e14}(id);
        assertEq(garden.burnReserved(), 1.2e18);
        _buy(alice, 1, 0);
        assertEq(garden.totalCandles(), 3);
        vm.prank(alice);
        garden.claimRewards();
        assertEq(garden.totalRewardsClaimed(), 1.2e18);
        token.setPeer(IMDBridge.asBytes32(IMDBridge.BASE_ADAPTER));
        token.setOptions(hex"0003");
        _buy(alice, 1, 0);
        vm.prank(OWNER);
        assertTrue(garden.dispatchBurn{value: 1e14}(id));
        assertEq(garden.burnInTransit(), 1.2e18);
        _assertSolvent();
    }

    function test_queueDustFailureRetryAndNoDoubleSend() public {
        _buy(alice, 2, 0);
        vm.prank(OWNER);
        uint256 id = garden.queueBurn(0.3e18 + 123);
        (uint256 amount,,, EverlightBridgeQueue.BurnStatus status) = garden.burnJobs(id);
        assertEq(amount, 0.3e18);
        assertEq(uint256(status), uint256(EverlightBridgeQueue.BurnStatus.Queued));
        assertEq(garden.burnQueued(), 0.9e18);
        assertEq(garden.bridgeDust(), 0);
        token.setSendFailure(true, false);
        vm.prank(OWNER);
        assertFalse(garden.dispatchBurn{value: 1e14}(id));
        assertEq(garden.failedBurnAmount(), amount);
        assertEq(garden.burnReserved(), amount);
        assertEq(garden.burnInTransit(), 0);
        assertEq(garden.totalSendFailures(), 1);
        _assertSolvent();
        token.setSendFailure(false, true);
        vm.prank(OWNER);
        assertFalse(garden.dispatchBurn{value: 1e14}(id));
        assertEq(token.balanceOf(address(garden)), 2e18);
        assertEq(token.sendNonce(), 0);
        token.setSendFailure(false, false);
        vm.prank(OWNER);
        assertTrue(garden.dispatchBurn{value: 1e14}(id));
        assertEq(garden.failedBurnAmount(), 0);
        assertEq(garden.burnReserved(), 0);
        assertEq(garden.burnInTransit(), amount);
        assertEq(garden.totalSendRetries(), 2);
        assertEq(garden.confirmedBurn(), 0);
        assertEq(token.allowance(address(garden), IMD), 0);
        assertEq(token.lastDestination(), IMDBridge.asBytes32(address(receiver)));
        assertEq(abi.decode(token.lastCompose(), (uint256)), id);
        vm.prank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.InvalidBurnJob.selector);
        garden.dispatchBurn{value: 1e14}(id);
        _assertSolvent();
    }

    function test_feeAuthorizationAndGasGuards() public {
        _buy(alice, 1, 0);
        vm.prank(OWNER);
        uint256 id = garden.queueBurn(0.3e18);
        vm.prank(alice);
        vm.expectRevert();
        garden.dispatchBurn{value: 1e14}(id);
        vm.prank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.InvalidFee.selector);
        garden.dispatchBurn{value: 1}(id);
        vm.prank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.InsufficientExecutionGas.selector);
        garden.dispatchBurn{value: 1e14, gas: 500000}(id);
        endpoint.setFee(0.06 ether);
        vm.prank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.InvalidFee.selector);
        garden.dispatchBurn{value: 0.06 ether}(id);
        vm.expectRevert(EverlightBridgeQueue.OnlySelf.selector);
        garden.performBridgeSend(id, MessagingFee(0, 0));
        assertEq(garden.totalSendFailures(), 0);
        assertEq(garden.burnReserved(), 0.3e18);
    }

    function test_fullFlowConfirmedOnlyAfterRealBaseBurnAndAuthenticatedAck() public {
        _buy(alice, 2, 0);
        vm.prank(OWNER);
        uint256 id = garden.queueBurn(0.6e18);
        vm.prank(OWNER);
        garden.dispatchBurn{value: 1e14}(id);
        bytes32 guid = token.lastGuid();
        assertEq(garden.confirmedBurn(), 0);
        _setupBase();
        IMDOFTDouble base = IMDOFTDouble(IMDBridge.BASE_IMD);
        base.mint(address(receiver), 0.6e18);
        uint256 supply = base.totalSupply();
        _compose(guid, id, 0.6e18);
        assertEq(base.totalSupply(), supply - 0.6e18);
        assertEq(base.balanceOf(address(receiver)), 0);
        assertEq(receiver.totalBurned(), 0.6e18);
        assertEq(receiver.pendingBurn(), 0);
        vm.prank(alice);
        receiver.sendBurnReceipt{value: 1e14}(guid);
        bytes memory ack = endpoint.lastMessage();
        assertEq(endpoint.lastReceiver(), IMDBridge.asBytes32(address(garden)));
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        receiver.sendBurnReceipt(guid);
        vm.chainId(1);
        endpoint.setEid(30101);
        vm.prank(IMDBridge.ENDPOINT);
        garden.lzReceive(
            Origin(30184, IMDBridge.asBytes32(address(receiver)), 2),
            bytes32(uint256(777)),
            ack,
            address(this),
            ""
        );
        assertEq(garden.confirmedBurn(), 0.6e18);
        assertEq(garden.burnInTransit(), 0);
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBridgeQueue.InvalidMessage.selector);
        garden.lzReceive(
            Origin(30184, IMDBridge.asBytes32(address(receiver)), 2),
            bytes32(uint256(778)),
            ack,
            address(this),
            ""
        );
        _assertSolvent();
    }

    function test_burnFailsOrNoopsThenRetryNeverDoubleBurns() public {
        _setupBase();
        IMDOFTDouble base = IMDOFTDouble(IMDBridge.BASE_IMD);
        base.mint(address(receiver), 0.3e18);
        base.setBurnFailure(true, false);
        bytes32 guid = keccak256("failure");
        _compose(guid, 1, 0.3e18);
        assertEq(receiver.failedBurn(), 0.3e18);
        assertEq(receiver.pendingBurn(), 0.3e18);
        assertEq(receiver.totalBurned(), 0);
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        receiver.sendBurnReceipt(guid);
        base.setBurnFailure(false, true);
        receiver.retryBurn(guid);
        assertEq(receiver.totalFailures(), 2);
        assertEq(base.totalSupply(), 0.3e18);
        base.setBurnFailure(false, false);
        receiver.retryBurn(guid);
        assertEq(receiver.totalRetries(), 2);
        assertEq(receiver.totalBurned(), 0.3e18);
        assertEq(receiver.failedBurn(), 0);
        assertEq(receiver.pendingBurn(), 0);
        assertEq(base.totalSupply(), 0);
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        receiver.retryBurn(guid);
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        _compose(guid, 1, 0.3e18);
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        _compose(keccak256("new guid same ID"), 1, 0.3e18);
    }

    function test_composeAuthenticationWrongOriginWrongPeerWrongLengthAndUnfunded() public {
        _setupBase();
        bytes32 guid = keccak256("bad");
        bytes memory valid = abi.encodePacked(
            uint64(1), uint32(30101), uint256(0.3e18), IMDBridge.asBytes32(address(garden)), uint256(1)
        );
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        receiver.lzCompose(IMDBridge.BASE_ADAPTER, guid, valid, address(this), "");
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        receiver.lzCompose(alice, guid, valid, address(this), "");
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        receiver.lzCompose(IMDBridge.BASE_ADAPTER, guid, hex"00", address(this), "");
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        _compose(guid, 1, 0.3e18);
        IMDOFTDouble(IMDBridge.BASE_IMD).mint(address(receiver), 0.3e18);
        valid = abi.encodePacked(
            uint64(1), uint32(30101), uint256(0.3e18), IMDBridge.asBytes32(alice), uint256(1)
        );
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        receiver.lzCompose(IMDBridge.BASE_ADAPTER, guid, valid, address(this), "");
        vm.expectRevert(EverlightBurnReceiver.OnlySelf.selector);
        receiver.performBurn(0.3e18);
        assertEq(receiver.totalReceived(), 0);
    }

    function test_ackRetryDoesNotRepeatBurnAndReadyIsARealMessage() public {
        _setupBase();
        vm.prank(OWNER);
        receiver.announceReady{value: 1e14}();
        (uint8 kind, bytes32 config,,,) =
            abi.decode(endpoint.lastMessage(), (uint8, bytes32, uint256, bytes32, uint256));
        assertEq(kind, 1);
        assertEq(config, garden.bridgeConfigHash());
        bytes32 guid = keccak256("ackretry");
        IMDOFTDouble(IMDBridge.BASE_IMD).mint(address(receiver), 0.3e18);
        _compose(guid, 1, 0.3e18);
        endpoint.setFailure(true);
        vm.prank(alice);
        vm.expectRevert();
        receiver.sendBurnReceipt{value: 1e14}(guid);
        (,,,, bool acknowledged) = receiver.deliveries(guid);
        assertFalse(acknowledged);
        endpoint.setFailure(false);
        vm.prank(alice);
        receiver.sendBurnReceipt{value: 1e14}(guid);
        assertEq(receiver.totalBurned(), 0.3e18);
    }

    function test_wrongAckAmountsAndUnsentJobsCannotConfirm() public {
        _buy(alice, 1, 0);
        vm.prank(OWNER);
        uint256 id = garden.queueBurn(0.3e18);
        bytes memory ack =
            abi.encode(uint8(2), garden.bridgeConfigHash(), id, keccak256("unknown"), uint256(0.3e18));
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBridgeQueue.InvalidMessage.selector);
        garden.lzReceive(
            Origin(30184, IMDBridge.asBytes32(address(receiver)), 2),
            bytes32(uint256(900)),
            ack,
            address(this),
            ""
        );
        vm.prank(OWNER);
        garden.dispatchBurn{value: 1e14}(id);
        ack = abi.encode(uint8(2), garden.bridgeConfigHash(), id, token.lastGuid(), uint256(0.3e18 + 1));
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBridgeQueue.InvalidMessage.selector);
        garden.lzReceive(
            Origin(30184, IMDBridge.asBytes32(address(receiver)), 2),
            bytes32(uint256(900)),
            ack,
            address(this),
            ""
        );
        assertEq(garden.confirmedBurn(), 0);
        assertEq(garden.burnInTransit(), 0.3e18);
    }
}
