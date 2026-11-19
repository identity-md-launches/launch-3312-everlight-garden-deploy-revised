// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    GardenTestBase,
    WishGarden,
    EverlightBridgeQueue,
    EverlightBurnReceiver,
    IMDBridge,
    Origin
} from "../helpers/GardenTestBase.sol";
import {WalletGas} from "../helpers/WalletGas.sol";
import {IIMDOFT, ILZEndpoint} from "src/bridge/IMDBridge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IMDRuntime} from "../fixtures/IMDRuntime.sol";
import {BaseIMDRuntime} from "../fixtures/BaseIMDRuntime.sol";
import {BaseAdapterRuntime} from "../fixtures/BaseAdapterRuntime.sol";

interface ReviewPeerAdmin {
    function setPeer(uint32 eid, bytes32 peer) external;
}

contract ActivationAndRuntimeTest is GardenTestBase, WalletGas {
    function test_reconfiguringBeforeActivationInvalidatesOldReadinessAndOldPackets() public {
        WishGarden fresh = new WishGarden(OWNER);
        address pinned = fresh.pinnedBaseReceiver();
        vm.prank(OWNER);
        fresh.configureBridge(pinned, EVIDENCE);
        bytes memory oldReady =
            abi.encode(uint8(1), fresh.bridgeConfigHash(), uint256(0), bytes32(0), uint256(0));
        Origin memory origin = Origin(30184, IMDBridge.asBytes32(pinned), 1);
        vm.prank(IMDBridge.ENDPOINT);
        fresh.lzReceive(origin, keccak256("first readiness"), oldReady, alice, "");
        assertTrue(fresh.baseReady());
        vm.prank(OWNER);
        fresh.configureBridge(pinned, keccak256("revised offline evidence"));
        assertFalse(fresh.baseReady());
        vm.prank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.BridgeNotReady.selector);
        fresh.activate();
        bytes32 delayedGuid = keccak256("delayed packet from prior configuration");
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBridgeQueue.InvalidMessage.selector);
        fresh.lzReceive(origin, delayedGuid, oldReady, alice, "");
        assertFalse(fresh.receivedGuids(delayedGuid));
        bytes memory currentReady =
            abi.encode(uint8(1), fresh.bridgeConfigHash(), uint256(0), bytes32(0), uint256(0));
        assertTrue(fresh.allowInitializePath(origin));
        assertFalse(fresh.allowInitializePath(Origin(30101, origin.sender, 0)));
        assertFalse(fresh.allowInitializePath(Origin(30184, IMDBridge.asBytes32(alice), 0)));
        vm.prank(IMDBridge.ENDPOINT);
        fresh.lzReceive(origin, delayedGuid, currentReady, alice, "");
        vm.prank(OWNER);
        fresh.activate();
        assertTrue(fresh.activated());
        assertFalse(fresh.purchasesPaused());
    }

    function test_eachOfficialSourceRouteFactIsRequiredBeforeConfiguration() public {
        WishGarden fresh = new WishGarden(OWNER);
        address pinned = fresh.pinnedBaseReceiver();
        bytes[6] memory calls = [
            abi.encodeCall(IIMDOFT.endpoint, ()),
            abi.encodeCall(IIMDOFT.token, ()),
            abi.encodeCall(IIMDOFT.approvalRequired, ()),
            abi.encodeCall(IIMDOFT.peers, (uint32(30184))),
            abi.encodeCall(IIMDOFT.decimalConversionRate, ()),
            abi.encodeCall(ILZEndpoint.eid, ())
        ];
        bytes[6] memory invalid = [
            abi.encode(alice),
            abi.encode(alice),
            abi.encode(true),
            abi.encode(IMDBridge.asBytes32(alice)),
            abi.encode(uint256(1e11)),
            abi.encode(uint32(30184))
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.mockCall(i == 5 ? IMDBridge.ENDPOINT : IMD, calls[i], invalid[i]);
            vm.prank(OWNER);
            vm.expectRevert(EverlightBridgeQueue.InvalidBridgeConfiguration.selector);
            fresh.configureBridge(pinned, EVIDENCE);
            assertEq(fresh.baseReceiver(), address(0));
            assertEq(fresh.bridgeConfigHash(), bytes32(0));
            vm.clearMockedCalls();
        }
        vm.prank(OWNER);
        fresh.configureBridge(pinned, EVIDENCE);
        assertEq(fresh.baseReceiver(), pinned);
        assertFalse(fresh.baseReady());
        assertFalse(fresh.activated());
    }

    function test_eachOfficialBaseRouteFactIsRequiredBeforeActivation() public {
        _setupBase();
        EverlightBurnReceiver fresh = new EverlightBurnReceiver(OWNER, address(garden));
        bytes[7] memory calls = [
            abi.encodeCall(IIMDOFT.endpoint, ()),
            abi.encodeCall(IIMDOFT.token, ()),
            abi.encodeCall(IIMDOFT.approvalRequired, ()),
            abi.encodeCall(IIMDOFT.peers, (uint32(30101))),
            abi.encodeCall(IIMDOFT.decimalConversionRate, ()),
            abi.encodeCall(ILZEndpoint.eid, ()),
            abi.encodeCall(IERC20Metadata.decimals, ())
        ];
        bytes[7] memory invalid = [
            abi.encode(alice),
            abi.encode(alice),
            abi.encode(false),
            abi.encode(IMDBridge.asBytes32(alice)),
            abi.encode(uint256(1e11)),
            abi.encode(uint32(30101)),
            abi.encode(uint8(6))
        ];
        for (uint256 i; i < calls.length; ++i) {
            address target =
                i == 5 ? IMDBridge.ENDPOINT : i == 6 ? IMDBridge.BASE_IMD : IMDBridge.BASE_ADAPTER;
            vm.mockCall(target, calls[i], invalid[i]);
            vm.prank(OWNER);
            vm.expectRevert(EverlightBurnReceiver.InvalidConfiguration.selector);
            fresh.activate(EVIDENCE);
            assertFalse(fresh.activated());
            assertEq(fresh.configHash(), bytes32(0));
            vm.clearMockedCalls();
        }
        vm.prank(OWNER);
        fresh.activate(EVIDENCE);
        assertTrue(fresh.activated());
    }

    function test_malformedReadinessCannotUnlockPurchases() public {
        WishGarden fresh = new WishGarden(OWNER);
        address pinned = fresh.pinnedBaseReceiver();
        vm.prank(OWNER);
        fresh.configureBridge(pinned, EVIDENCE);
        bytes32 config = fresh.bridgeConfigHash();
        for (uint256 field; field < 3; ++field) {
            bytes memory payload = abi.encode(
                uint8(1),
                config,
                field == 0 ? uint256(1) : uint256(0),
                field == 1 ? keccak256("not a readiness packet") : bytes32(0),
                field == 2 ? uint256(1) : uint256(0)
            );
            vm.prank(IMDBridge.ENDPOINT);
            vm.expectRevert(EverlightBridgeQueue.InvalidMessage.selector);
            fresh.lzReceive(
                Origin(30184, IMDBridge.asBytes32(pinned), uint64(field)),
                keccak256(abi.encode("malformed readiness", field)),
                payload,
                alice,
                ""
            );
            assertFalse(fresh.baseReady());
        }
        _rejectBuy(fresh, 1, 0, abi.encodeWithSelector(WishGarden.PurchasesDisabled.selector));
    }

    // These are captured deployed bytecodes with LOCAL storage and a mocked endpoint, not fork/live tests.
    function test_pinnedEthereumOFTDispatchAtWalletGas() public {
        vm.etch(IMD, IMDRuntime.code());
        vm.prank(address(0)); // The captured runtime has fresh local Ownable storage.
        ReviewPeerAdmin(IMD).setPeer(30184, IMDBridge.asBytes32(IMDBridge.BASE_ADAPTER));
        WishGarden fresh = new WishGarden(OWNER);
        address pinned = fresh.pinnedBaseReceiver();
        _activate(fresh, pinned);
        deal(IMD, alice, 2e18, true);
        uint8[] memory styles = new uint8[](2);
        string[] memory wishes = new string[](2);
        vm.startPrank(alice);
        IERC20(IMD).approve(address(fresh), 2e18);
        fresh.buyCandles(styles, wishes);
        vm.stopPrank();
        vm.prank(OWNER);
        uint256 id = fresh.queueBurn(6e17);
        assertSameAtWalletGas(OWNER, address(fresh), 1e14, abi.encodeCall(fresh.dispatchBurn, (id)));
        vm.prank(OWNER);
        assertTrue(fresh.dispatchBurn{value: 1e14}(id));
        assertEq(fresh.burnInTransit(), 6e17);
        assertEq(fresh.confirmedBurn(), 0, "source send is not confirmation of Base supply burn");
    }

    function test_pinnedBaseBurnComposeAtWalletAndAdvertisedGas() public {
        vm.chainId(8453);
        endpoint.setEid(30184);
        vm.etch(IMDBridge.BASE_IMD, BaseIMDRuntime.code());
        vm.etch(IMDBridge.BASE_ADAPTER, BaseAdapterRuntime.code());
        vm.prank(address(0));
        ReviewPeerAdmin(IMDBridge.BASE_ADAPTER).setPeer(30101, IMDBridge.asBytes32(IMD));
        vm.prank(OWNER);
        receiver.activate(EVIDENCE);
        deal(IMDBridge.BASE_IMD, address(receiver), 3e17, true);
        uint256 supplyBefore = IERC20(IMDBridge.BASE_IMD).totalSupply();
        bytes memory message = abi.encodePacked(
            uint64(1), uint32(30101), uint256(3e17), IMDBridge.asBytes32(address(garden)), uint256(1)
        );
        bytes memory data = abi.encodeCall(
            receiver.lzCompose,
            (IMDBridge.BASE_ADAPTER, keccak256("pinned Base runtime wallet gas"), message, alice, bytes(""))
        );
        assertSameAtWalletGas(IMDBridge.ENDPOINT, address(receiver), data);
        vm.prank(IMDBridge.ENDPOINT);
        (bool ok,) = address(receiver).call{gas: 500_000}(data);
        assertTrue(ok);
        assertEq(receiver.totalBurned(), 3e17);
        assertEq(IERC20(IMDBridge.BASE_IMD).totalSupply(), supplyBefore - 3e17);
        assertEq(IERC20(IMDBridge.BASE_IMD).balanceOf(address(receiver)), 0);
    }
}
