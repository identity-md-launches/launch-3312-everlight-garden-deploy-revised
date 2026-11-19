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
import {IMDOFTDouble, BaseAdapterDouble, EndpointDouble} from "../helpers/BridgeDoubles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice MOCKED adversarial tests for the revised route: source-pinned CREATE2 Base receiver, purchases no
///         longer gated by bridge state, adapter-peer-independent compose. No fork, no live funds.
contract PinnedRouteRevisionTest is GardenTestBase, WalletGas {
    address internal stranger = makeAddr("stranger");

    function _deployerCall(WishGarden g, address receiverOwner) private view returns (bytes memory) {
        return bytes.concat(
            g.BASE_RECEIVER_SALT(),
            type(EverlightBurnReceiver).creationCode,
            abi.encode(receiverOwner, address(g))
        );
    }

    /// Anyone may run the deterministic deployment first; the result is the owner's receiver, not theirs.
    function test_strangerFrontRunningPinnedDeploymentStillYieldsOwnersReceiver() public {
        WishGarden fresh = new WishGarden(OWNER);
        address pinned = fresh.pinnedBaseReceiver();
        vm.etch(CREATE2_DEPLOYER, CREATE2_DEPLOYER_RUNTIME);
        vm.prank(stranger);
        (bool ok, bytes memory out) = CREATE2_DEPLOYER.call(_deployerCall(fresh, OWNER));
        assertTrue(ok);
        assertEq(address(bytes20(out)), pinned);
        EverlightBurnReceiver r = EverlightBurnReceiver(pinned);
        assertEq(r.owner(), OWNER);
        assertEq(r.ethereumGarden(), address(fresh));
        // The same salt/initcode cannot be deployed a second time over it.
        bytes memory again = _deployerCall(fresh, OWNER);
        vm.prank(OWNER);
        (ok,) = CREATE2_DEPLOYER.call{gas: 5_000_000}(again);
        assertFalse(ok);
        // The stranger gains no Base authority.
        vm.chainId(8453);
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        r.activate(EVIDENCE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        r.announceReady();
        vm.stopPrank();
        // A receiver the stranger owns lands elsewhere and is refused by the garden.
        vm.prank(stranger);
        (ok, out) = CREATE2_DEPLOYER.call(_deployerCall(fresh, stranger));
        assertTrue(ok);
        address strangers = address(bytes20(out));
        assertTrue(strangers != pinned);
        vm.chainId(1);
        vm.prank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.InvalidBridgeConfiguration.selector);
        fresh.configureBridge(strangers, EVIDENCE);
    }

    /// A receiver pinned to another garden of the same owner cannot speak for this one.
    function test_otherGardensPinnedReceiverCannotConfigureOrConfirm() public {
        WishGarden other = new WishGarden(OWNER);
        address otherPinned = other.pinnedBaseReceiver();
        assertTrue(otherPinned != garden.pinnedBaseReceiver());
        WishGarden fresh = new WishGarden(OWNER);
        vm.prank(OWNER);
        vm.expectRevert(EverlightBridgeQueue.InvalidBridgeConfiguration.selector);
        fresh.configureBridge(otherPinned, EVIDENCE);

        _buy(alice, 2, 0);
        vm.prank(OWNER);
        uint256 id = garden.queueBurn(3e17);
        vm.prank(OWNER);
        assertTrue(garden.dispatchBurn{value: 1e14}(id));
        (, bytes32 guid,,) = garden.burnJobs(id);
        bytes memory receipt = abi.encode(uint8(2), garden.bridgeConfigHash(), id, guid, uint256(3e17));
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBridgeQueue.InvalidMessage.selector);
        garden.lzReceive(
            Origin(30184, IMDBridge.asBytes32(otherPinned), 1), keccak256("x"), receipt, alice, ""
        );
        assertEq(garden.confirmedBurn(), 0);
        assertEq(garden.burnInTransit(), 3e17);
        // The garden's own pinned receiver confirms it once.
        vm.prank(IMDBridge.ENDPOINT);
        garden.lzReceive(
            Origin(30184, IMDBridge.asBytes32(address(receiver)), 1), keccak256("x"), receipt, alice, ""
        );
        assertEq(garden.confirmedBurn(), 3e17);
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBridgeQueue.InvalidMessage.selector);
        garden.lzReceive(
            Origin(30184, IMDBridge.asBytes32(address(receiver)), 2), keccak256("y"), receipt, alice, ""
        );
        _assertSolvent();
    }

    /// Disclosure, not a defect: the pinned Base receiver's owner is the constructor owner forever. A later
    /// garden owner can configure the garden but the Base receiver remains with the original owner until
    /// that owner transfers it through Ownable2Step on Base.
    function test_gardenOwnershipTransferDoesNotMoveThePinnedDestination() public {
        WishGarden fresh = new WishGarden(OWNER);
        address pinned = fresh.pinnedBaseReceiver();
        vm.prank(OWNER);
        fresh.transferOwnership(bob);
        vm.prank(bob);
        fresh.acceptOwnership();
        assertEq(fresh.pinnedBaseReceiver(), pinned);
        address bobs = _create2(fresh, bob);
        vm.prank(bob);
        vm.expectRevert(EverlightBridgeQueue.InvalidBridgeConfiguration.selector);
        fresh.configureBridge(bobs, EVIDENCE);
        vm.prank(bob);
        fresh.configureBridge(pinned, EVIDENCE);
        assertEq(fresh.baseReceiver(), pinned);
    }

    function _create2(WishGarden g, address receiverOwner) private view returns (address) {
        return vm.computeCreate2Address(
            g.BASE_RECEIVER_SALT(),
            keccak256(
                bytes.concat(type(EverlightBurnReceiver).creationCode, abi.encode(receiverOwner, address(g)))
            ),
            CREATE2_DEPLOYER
        );
    }

    /// Purchases never consult the bridge, yet every one still requires the exact IMD debit and credit.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_anyPeerValuePurchasesConserveAndOnlyOfficialPeerDispatches(bytes32 peer, uint8 qty)
        public
    {
        uint256 quantity = bound(qty, 1, 50);
        _buy(alice, 1, 0);
        token.setPeer(peer);
        uint256 held = token.balanceOf(address(garden));
        uint256 aliceBefore = token.balanceOf(bob);
        _buy(bob, quantity, 6);
        assertEq(token.balanceOf(address(garden)), held + quantity * 1e18);
        assertEq(token.balanceOf(bob), aliceBefore - quantity * 1e18);
        vm.prank(OWNER);
        uint256 id = garden.queueBurn(type(uint256).max);
        vm.prank(OWNER);
        if (peer != IMDBridge.asBytes32(IMDBridge.BASE_ADAPTER)) {
            vm.expectRevert(EverlightBridgeQueue.InvalidBridgeConfiguration.selector);
            garden.dispatchBurn{value: 1e14}(id);
            assertEq(garden.burnInTransit(), 0);
        } else {
            assertTrue(garden.dispatchBurn{value: 1e14}(id));
        }
        _assertSolvent();
    }

    /// A compose the endpoint could not deliver before Base activation stays queued at the endpoint and is
    /// delivered by a permissionless retry afterwards, exactly once.
    function test_composeQueuedBeforeActivationDeliversOnceAfterIt() public {
        vm.chainId(8453);
        endpoint.setEid(30184);
        vm.etch(IMDBridge.BASE_IMD, address(new IMDOFTDouble()).code);
        vm.etch(IMDBridge.BASE_ADAPTER, address(new BaseAdapterDouble()).code);
        BaseAdapterDouble(IMDBridge.BASE_ADAPTER).setPeer(IMDBridge.asBytes32(IMD));
        IMDOFTDouble(IMDBridge.BASE_IMD).mint(address(receiver), 3e17);
        bytes32 guid = keccak256("early delivery");
        bytes memory message = abi.encodePacked(
            uint64(1), uint32(30101), uint256(3e17), IMDBridge.asBytes32(address(garden)), uint256(1)
        );
        vm.prank(IMDBridge.BASE_ADAPTER);
        endpoint.sendCompose(address(receiver), guid, 0, message);
        bytes memory data = abi.encodeCall(
            EndpointDouble.lzCompose, (IMDBridge.BASE_ADAPTER, address(receiver), guid, 0, message, bytes(""))
        );
        vm.prank(stranger);
        (bool ok,) = IMDBridge.ENDPOINT.call(data);
        assertFalse(ok, "unactivated receiver must revert so the compose stays retryable");
        assertEq(receiver.totalReceived(), 0);
        vm.prank(OWNER);
        receiver.activate(EVIDENCE);
        uint256 supply = IERC20(IMDBridge.BASE_IMD).totalSupply();
        assertSameAtWalletGas(stranger, IMDBridge.ENDPOINT, data);
        vm.prank(stranger);
        (ok,) = IMDBridge.ENDPOINT.call(data);
        assertTrue(ok);
        assertEq(receiver.totalBurned(), 3e17);
        assertEq(IERC20(IMDBridge.BASE_IMD).totalSupply(), supply - 3e17);
        vm.prank(stranger);
        (ok,) = IMDBridge.ENDPOINT.call(data);
        assertFalse(ok, "a delivered compose cannot run twice");
        assertEq(receiver.totalReceived(), 3e17);
        assertEq(receiver.pendingBurn(), 0);
    }
}
