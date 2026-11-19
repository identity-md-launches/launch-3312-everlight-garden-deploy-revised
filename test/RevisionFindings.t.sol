// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    GardenTestBase,
    WishGarden,
    EverlightBridgeQueue,
    EverlightBurnReceiver,
    IMDBridge,
    Origin
} from "./helpers/GardenTestBase.sol";
import {IMDOFTDouble, BaseAdapterDouble, EndpointDouble} from "./helpers/BridgeDoubles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseIMDRuntime} from "./fixtures/BaseIMDRuntime.sol";
import {BaseAdapterRuntime} from "./fixtures/BaseAdapterRuntime.sol";

interface PeerAdminLike {
    function setPeer(uint32, bytes32) external;
}

interface AdapterReceiverLike {
    function lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata) external payable;
}

/// @notice MOCKED regression tests for the independent review of the first accepted round.
///         Each test names the finding it answers. No fork, no live funds.
contract RevisionFindingsTest is GardenTestBase {
    /// @dev The most gas one Ethereum transaction may carry (EIP-7825); the block limit is higher.
    uint256 internal constant TX_GAS_CAP = 16_777_216;
    bytes internal constant THIRD_PARTY_OPTIONS = hex"0003010011010000000000000000000000000000ea60";

    // ------------------------------------------------------------------ e1e37d73: pinned destination

    function test_pinnedReceiverIsThisSourceDeployedThroughTheCanonicalDeployer() public view {
        bytes32 initCodeHash = keccak256(
            bytes.concat(type(EverlightBurnReceiver).creationCode, abi.encode(OWNER, address(garden)))
        );
        address expected =
            vm.computeCreate2Address(garden.BASE_RECEIVER_SALT(), initCodeHash, garden.CREATE2_DEPLOYER());
        assertEq(garden.CREATE2_DEPLOYER(), CREATE2_DEPLOYER);
        // Same literal as docs/base/deployment-package.json `create2Salt`.
        assertEq(
            garden.BASE_RECEIVER_SALT(), 0xe09dd7b91b0168191d78136fed79a755030ebc5b915c9d14b2635e6e73324323
        );
        assertEq(
            keccak256(CREATE2_DEPLOYER_RUNTIME),
            0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989
        );
        assertEq(garden.pinnedBaseReceiver(), expected);
        assertEq(garden.baseReceiver(), expected);
        assertEq(address(receiver), expected);
        assertEq(receiver.owner(), OWNER);
        assertEq(receiver.ethereumGarden(), address(garden));
    }

    function testFuzz_ownerCannotNameAnyOtherDestination(address other, bytes32 evidence) public {
        WishGarden fresh = new WishGarden(OWNER);
        address pinned = fresh.pinnedBaseReceiver();
        vm.assume(other != pinned && evidence != bytes32(0));
        vm.prank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.InvalidBridgeConfiguration.selector);
        fresh.configureBridge(other, evidence);
        assertEq(fresh.baseReceiver(), address(0));
        assertEq(fresh.bridgeConfigHash(), bytes32(0));
        // Nothing can be authenticated from the rejected address either.
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBridgeQueue.InvalidMessage.selector);
        fresh.lzReceive(
            Origin(30184, IMDBridge.asBytes32(other), 1),
            bytes32(uint256(1)),
            abi.encode(uint8(1), bytes32(0), uint256(0), bytes32(0), uint256(0)),
            address(this),
            ""
        );
        vm.prank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.BridgeNotReady.selector);
        fresh.activate();
    }

    function test_receiverBuiltForAnotherOwnerOrGardenIsNotThePinnedOne() public {
        WishGarden other = new WishGarden(OWNER);
        assertTrue(other.pinnedBaseReceiver() != garden.pinnedBaseReceiver(), "pin must bind the garden");
        assertTrue(address(_deployReceiver(garden, alice)) != garden.pinnedBaseReceiver(), "pin binds owner");
        assertEq(address(_deployReceiver(other, OWNER)), other.pinnedBaseReceiver());
        assertTrue(new WishGarden(alice).pinnedBaseReceiver() != address(0));
    }

    /// @dev The reviewer's scenario end to end: burn funds only ever go to the pinned receiver and a
    ///      confirmation from the owner's own Base wallet is refused.
    function test_ownerWalletCannotReceiveBurnFundsOrReportABurn() public {
        address ownerBaseWallet = makeAddr("ownerBaseWallet");
        _buy(alice, 10, 0);
        vm.startPrank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.ConfigurationFrozen.selector);
        garden.configureBridge(ownerBaseWallet, keccak256("any evidence"));
        uint256 job = garden.queueBurn(type(uint256).max);
        assertTrue(garden.dispatchBurn{value: 1e14}(job));
        vm.stopPrank();
        (uint256 amount, bytes32 guid,,) = garden.burnJobs(job);
        assertEq(amount, 3.6e18);
        assertEq(token.lastDestination(), IMDBridge.asBytes32(garden.pinnedBaseReceiver()));
        bytes memory fake = abi.encode(uint8(2), garden.bridgeConfigHash(), job, guid, amount);
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBridgeQueue.InvalidMessage.selector);
        garden.lzReceive(
            Origin(30184, IMDBridge.asBytes32(ownerBaseWallet), 2), bytes32(uint256(77)), fake, address(0), ""
        );
        assertEq(garden.confirmedBurn(), 0);
        assertEq(garden.burnInTransit(), 3.6e18);
        _assertSolvent();
    }

    // ------------------------------------------------- 3a1155f9: third-party OFT changes after activation

    function test_purchasesSurviveThirdPartyEnforcedOptionsChange() public {
        _buy(alice, 2, 0);
        token.setOptions(THIRD_PARTY_OPTIONS);
        address pinned = garden.pinnedBaseReceiver();
        vm.prank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.ConfigurationFrozen.selector);
        garden.configureBridge(pinned, EVIDENCE);
        _buy(alice, 1, 0);
        assertEq(garden.totalCandles(), 3);
        _assertSolvent();
    }

    function test_burnDispatchSurvivesThirdPartyEnforcedOptionsChange() public {
        _buy(alice, 2, 0);
        vm.prank(OWNER);
        uint256 job = garden.queueBurn(type(uint256).max);
        token.setOptions(THIRD_PARTY_OPTIONS);
        vm.prank(OWNER);
        assertTrue(garden.dispatchBurn{value: 1e14}(job));
        assertEq(garden.burnInTransit(), 1.2e18);
        assertEq(garden.burnReserved(), 0);
    }

    function test_peerRotationStopsOnlyDispatchAndOnlyUntilRestored() public {
        _buy(alice, 2, 0);
        vm.prank(OWNER);
        uint256 job = garden.queueBurn(type(uint256).max);
        token.setPeer(bytes32(uint256(1)));
        _buy(bob, 1, 0); // purchases move IMD into the garden and do not touch the bridge
        vm.prank(alice);
        garden.claimRewards();
        vm.prank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.InvalidBridgeConfiguration.selector);
        garden.dispatchBurn{value: 1e14}(job);
        (,,, EverlightBridgeQueue.BurnStatus status) = garden.burnJobs(job);
        assertEq(uint256(status), uint256(EverlightBridgeQueue.BurnStatus.Queued));
        assertEq(garden.burnReserved(), 1.2e18);
        token.setPeer(IMDBridge.asBytes32(IMDBridge.BASE_ADAPTER));
        vm.prank(OWNER);
        assertTrue(garden.dispatchBurn{value: 1e14}(job));
        _assertSolvent();
    }

    // ------------------------------------------------------- 14107f84: credited compose after re-peering

    function test_creditedComposeBurnsAfterAdapterPeerChangeButOutboundStaysGated() public {
        _setupBase();
        IMDOFTDouble(IMDBridge.BASE_IMD).mint(address(receiver), 3e18);
        BaseAdapterDouble(IMDBridge.BASE_ADAPTER).setPeer(bytes32(uint256(1)));
        vm.prank(OWNER);
        vm.expectRevert(EverlightBurnReceiver.InvalidConfiguration.selector);
        receiver.announceReady{value: 1e14}();
        uint256 supply = IERC20(IMDBridge.BASE_IMD).totalSupply();
        bytes32 guid = keccak256("credited before re-peer");
        _compose(guid, 1, 3e18);
        assertEq(receiver.totalBurned(), 3e18);
        assertEq(receiver.pendingBurn(), 0);
        assertEq(IERC20(IMDBridge.BASE_IMD).totalSupply(), supply - 3e18);
        assertEq(IERC20(IMDBridge.BASE_IMD).balanceOf(address(receiver)), 0);
        (,,, EverlightBurnReceiver.Status status,) = receiver.deliveries(guid);
        assertEq(uint256(status), uint256(EverlightBurnReceiver.Status.Burned));
    }

    function test_composeStillRequiresActivationFixedTokenAndAuthentication() public {
        bytes memory message = abi.encodePacked(
            uint64(1), uint32(30101), uint256(3e18), IMDBridge.asBytes32(address(garden)), uint256(1)
        );
        vm.chainId(8453);
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBurnReceiver.InvalidConfiguration.selector); // not activated
        receiver.lzCompose(IMDBridge.BASE_ADAPTER, keccak256("a"), message, address(this), "");
        _setupBase();
        IMDOFTDouble(IMDBridge.BASE_IMD).mint(address(receiver), 3e18);
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector); // not the endpoint
        receiver.lzCompose(IMDBridge.BASE_ADAPTER, keccak256("a"), message, address(this), "");
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector); // not composed by the adapter
        receiver.lzCompose(alice, keccak256("a"), message, address(this), "");
        vm.etch(IMDBridge.BASE_IMD, address(new BaseAdapterDouble()).code);
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBurnReceiver.InvalidConfiguration.selector); // token code changed
        receiver.lzCompose(IMDBridge.BASE_ADAPTER, keccak256("a"), message, address(this), "");
        assertEq(receiver.totalReceived(), 0);
    }

    // ------------------------------------- 772340d3: compose gas through the endpoint, pinned Base runtimes

    function test_executorComposeGasCoversEndpointForwardingWithMargin() public {
        vm.chainId(8453);
        endpoint.setEid(30184);
        vm.etch(IMDBridge.BASE_IMD, BaseIMDRuntime.code());
        vm.etch(IMDBridge.BASE_ADAPTER, BaseAdapterRuntime.code());
        vm.prank(address(0));
        PeerAdminLike(IMDBridge.BASE_ADAPTER).setPeer(30101, IMDBridge.asBytes32(IMD));
        vm.prank(OWNER);
        receiver.activate(EVIDENCE);
        deal(IMDBridge.BASE_IMD, IMDBridge.BASE_ADAPTER, 0.3e18, true);
        bytes32 guid = keccak256("adapter credit then executor compose");
        bytes memory packet = abi.encodePacked(
            IMDBridge.asBytes32(address(receiver)),
            uint64(300000),
            IMDBridge.asBytes32(address(garden)),
            uint256(1)
        );
        vm.prank(IMDBridge.ENDPOINT);
        AdapterReceiverLike(IMDBridge.BASE_ADAPTER)
            .lzReceive(Origin(30101, IMDBridge.asBytes32(IMD), 7), guid, packet, address(this), "");
        bytes memory data = abi.encodeCall(
            EndpointDouble.lzCompose,
            (IMDBridge.BASE_ADAPTER, address(receiver), guid, 0, endpoint.lastMessage(), bytes(""))
        );
        // The option the garden sends is the gas the executor gives EndpointV2.lzCompose.
        bytes memory options = IMDBridge.burnOptions();
        uint256 composeGas;
        assembly ("memory-safe") {
            composeGas := and(mload(add(options, mload(options))), 0xffffffffffffffffffffffffffffffff)
        }
        assertEq(composeGas, 650_000);
        // A first delivery must also fit in 80% of it, every account cold: margin for real Base costs.
        assertTrue(_composeBurns(data, composeGas * 80 / 100), "less than 25% compose gas margin");
        assertFalse(_composeBurns(data, 300_000), "underfunded compose must revert, never skip the burn");
        vm.prank(bob);
        (bool ok,) = IMDBridge.ENDPOINT.call{gas: composeGas}(data);
        assertTrue(ok);
        assertEq(receiver.totalBurned(), 0.3e18);
        assertEq(IERC20(IMDBridge.BASE_IMD).balanceOf(address(receiver)), 0);
    }

    function _composeBurns(bytes memory data, uint256 gasLimit) private returns (bool burned) {
        uint256 snapshot = vm.snapshotState();
        vm.cool(address(receiver));
        vm.cool(IMDBridge.BASE_IMD);
        vm.cool(IMDBridge.BASE_ADAPTER);
        vm.cool(IMDBridge.ENDPOINT);
        vm.prank(bob);
        (bool ok,) = IMDBridge.ENDPOINT.call{gas: gasLimit}(data);
        burned = ok && receiver.totalBurned() == 0.3e18;
        vm.revertToState(snapshot);
    }

    // ------------------------------------------------ 29960a92: joint bound of batch size and wish bytes

    /// @dev docs/abi/README.md "Batch gas": transaction gas <= 300,000 + 170,000 per candle + 1,300 per
    ///      wish byte. The limits 50 candles and 1120 bytes hold separately, not together.
    function test_documentedBatchGasBoundHoldsAndFullBatchOfFullWishesCannotFit() public {
        uint256[3][10] memory rows = [
            [uint256(1), 0, 1],
            [uint256(50), 0, 1],
            [uint256(50), 1, 1],
            [uint256(50), 32, 1],
            [uint256(50), 120, 1],
            [uint256(30), 280, 1],
            [uint256(18), 560, 2],
            [uint256(10), 1120, 4],
            [uint256(1), 1120, 4],
            [uint256(50), 1120, 4]
        ];
        for (uint256 i; i < rows.length; ++i) {
            uint256 used = _batchGas(rows[i][0], rows[i][1], rows[i][2]);
            uint256 bound = 300_000 + 170_000 * rows[i][0] + 1_300 * rows[i][0] * rows[i][1];
            emit log_named_uint(
                string.concat(vm.toString(rows[i][0]), " x ", vm.toString(rows[i][1]), " bytes"), used
            );
            assertLe(used, bound, "documented gas bound understates a batch");
            if (i + 1 < rows.length) {
                assertLe(bound, TX_GAS_CAP, "a documented example does not fit one transaction");
            } else {
                assertGt(used, TX_GAS_CAP, "50 full-length wishes fit after all: update the docs");
            }
        }
    }

    /// @dev Execution gas plus intrinsic gas (21,000 and calldata) of one buyCandles transaction.
    function _batchGas(uint256 quantity, uint256 wishBytes, uint256 bytesPerCodepoint)
        private
        returns (uint256 used)
    {
        bytes memory text = new bytes(wishBytes);
        for (uint256 i; i < wishBytes; ++i) {
            if (bytesPerCodepoint == 1) text[i] = "a";
            else if (bytesPerCodepoint == 2) text[i] = i % 2 == 0 ? bytes1(0xC3) : bytes1(0xA9);
            else text[i] = i % 4 == 0 ? bytes1(0xF0) : (i % 4 == 1 ? bytes1(0x90) : bytes1(0x80));
        }
        uint8[] memory styles = new uint8[](quantity);
        string[] memory wishes = new string[](quantity);
        for (uint256 i; i < quantity; ++i) {
            wishes[i] = string(text);
        }
        bytes memory data = abi.encodeCall(garden.buyCandles, (styles, wishes));
        uint256 nonZero;
        for (uint256 i; i < data.length; ++i) {
            if (data[i] != 0) ++nonZero;
        }
        address buyer = makeAddr(string.concat("buyer", vm.toString(quantity), "/", vm.toString(wishBytes)));
        token.mint(buyer, quantity * 1e18);
        vm.startPrank(buyer);
        token.approve(address(garden), quantity * 1e18);
        uint256 before = gasleft();
        (bool ok,) = address(garden).call(data);
        used = before - gasleft() + 21_000 + nonZero * 16 + (data.length - nonZero) * 4;
        vm.stopPrank();
        assertTrue(ok, "purchase failed");
        assertEq(bytes(garden.getCandle(garden.totalCandles()).wish).length, wishBytes);
    }
}
