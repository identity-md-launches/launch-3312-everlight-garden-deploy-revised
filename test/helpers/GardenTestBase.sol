// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {WishGarden} from "../../src/WishGarden.sol";
import {WishGardenTreasury} from "../../src/WishGardenTreasury.sol";
import {EverlightBridgeQueue} from "../../src/bridge/EverlightBridgeQueue.sol";
import {EverlightBurnReceiver} from "../../src/base/EverlightBurnReceiver.sol";
import {GardenEconomy} from "../../src/GardenEconomy.sol";
import {IMDBridge, Origin, MessagingFee} from "../../src/bridge/IMDBridge.sol";
import {IMDOFTDouble, EndpointDouble, BaseAdapterDouble} from "./BridgeDoubles.sol";

abstract contract GardenTestBase is Test {
    address internal constant OWNER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    bytes32 internal constant EVIDENCE = keccak256("TEST ONLY: offline bridge verification");
    /// @dev Runtime of the canonical deterministic deployer as read from Base (docs/evidence).
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes internal constant CREATE2_DEPLOYER_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    WishGarden internal garden;
    EverlightBurnReceiver internal receiver;
    IMDOFTDouble internal token = IMDOFTDouble(IMD);
    EndpointDouble internal endpoint = EndpointDouble(IMDBridge.ENDPOINT);
    address internal alice;
    address internal bob;
    address internal carol;
    uint64 internal receiveNonce;

    function setUp() public virtual {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        vm.etch(IMD, address(new IMDOFTDouble()).code);
        vm.etch(IMDBridge.ENDPOINT, address(new EndpointDouble()).code);
        endpoint.setEid(30101);
        endpoint.setFee(1e14);
        token.setPeer(IMDBridge.asBytes32(IMDBridge.BASE_ADAPTER));
        garden = new WishGarden(OWNER);
        receiver = _deployReceiver(garden, OWNER);
        assertEq(address(receiver), garden.pinnedBaseReceiver(), "fixture receiver is not the pinned one");
        _activate(garden, address(receiver));
        token.mint(alice, 1_000_000e18);
        token.mint(bob, 1_000_000e18);
        token.mint(carol, 1_000_000e18);
        vm.deal(OWNER, 100 ether);
        vm.deal(alice, 100 ether);
    }

    /// @dev The owner's Base deployment: canonical deployer, source-fixed salt, (owner, garden) arguments.
    function _deployReceiver(WishGarden g, address receiverOwner) internal returns (EverlightBurnReceiver) {
        vm.etch(CREATE2_DEPLOYER, CREATE2_DEPLOYER_RUNTIME);
        (bool ok, bytes memory out) = CREATE2_DEPLOYER.call(
            bytes.concat(
                g.BASE_RECEIVER_SALT(),
                type(EverlightBurnReceiver).creationCode,
                abi.encode(receiverOwner, address(g))
            )
        );
        require(ok && out.length == 20, "deterministic deployment failed");
        return EverlightBurnReceiver(address(bytes20(out)));
    }

    function _activate(WishGarden g, address receiverAddress) internal {
        vm.prank(OWNER);
        g.configureBridge(receiverAddress, EVIDENCE);
        bytes memory readyMessage =
            abi.encode(uint8(1), g.bridgeConfigHash(), uint256(0), bytes32(0), uint256(0));
        vm.prank(IMDBridge.ENDPOINT);
        g.lzReceive(
            Origin(30184, IMDBridge.asBytes32(receiverAddress), ++receiveNonce),
            bytes32(uint256(receiveNonce)),
            readyMessage,
            address(this),
            ""
        );
        vm.prank(OWNER);
        g.activate();
    }

    function _buy(address purchaser, uint256 quantity, uint8 style) internal returns (uint256) {
        return _buyIn(garden, purchaser, quantity, style);
    }

    function _buyIn(WishGarden g, address purchaser, uint256 quantity, uint8 style)
        internal
        returns (uint256 id)
    {
        uint8[] memory styles = new uint8[](quantity);
        string[] memory wishes = new string[](quantity);
        for (uint256 i; i < quantity; ++i) {
            styles[i] = style;
        }
        vm.startPrank(purchaser);
        token.approve(address(g), quantity * 1e18);
        id = g.buyCandles(styles, wishes);
        vm.stopPrank();
    }

    function _rejectBuy(WishGarden g, uint256 quantity, uint8 style, bytes memory reason) internal {
        uint8[] memory styles = new uint8[](quantity);
        string[] memory wishes = new string[](quantity);
        for (uint256 i; i < quantity; ++i) {
            styles[i] = style;
        }
        vm.startPrank(alice);
        token.approve(address(g), quantity * 1e18);
        vm.expectRevert(reason);
        g.buyCandles(styles, wishes);
        vm.stopPrank();
    }

    function _assertSolvent() internal view {
        assertGe(token.balanceOf(address(garden)), garden.accountedBalance());
        assertEq(
            garden.totalBurnAllocated(),
            garden.burnQueued() + garden.burnReserved() + garden.burnInTransit() + garden.confirmedBurn()
        );
        assertLe(
            garden.claimableRewards(alice) + garden.claimableRewards(bob) + garden.claimableRewards(carol),
            garden.rewardLiability()
        );
    }

    function _setupBase() internal {
        vm.chainId(8453);
        endpoint.setEid(30184);
        vm.etch(IMDBridge.BASE_IMD, address(new IMDOFTDouble()).code);
        vm.etch(IMDBridge.BASE_ADAPTER, address(new BaseAdapterDouble()).code);
        BaseAdapterDouble(IMDBridge.BASE_ADAPTER).setPeer(IMDBridge.asBytes32(IMD));
        vm.prank(OWNER);
        receiver.activate(EVIDENCE);
    }

    function _compose(bytes32 guid, uint256 id, uint256 amount) internal {
        bytes memory message =
            abi.encodePacked(uint64(1), uint32(30101), amount, IMDBridge.asBytes32(address(garden)), id);
        vm.prank(IMDBridge.ENDPOINT);
        receiver.lzCompose(IMDBridge.BASE_ADAPTER, guid, message, address(this), "");
    }
}
