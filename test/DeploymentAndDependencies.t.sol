// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {
    GardenTestBase,
    WishGarden,
    EverlightBurnReceiver,
    IMDBridge,
    Origin
} from "./helpers/GardenTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IMDRuntime} from "./fixtures/IMDRuntime.sol";
import {BaseIMDRuntime} from "./fixtures/BaseIMDRuntime.sol";
import {BaseAdapterRuntime} from "./fixtures/BaseAdapterRuntime.sol";
import {IIMDOFT} from "../src/bridge/IMDBridge.sol";

interface PeerAdmin {
    function setPeer(uint32, bytes32) external;
}

interface AdapterReceiver {
    function lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata) external payable;
}

contract FactoryRehearsal {
    function deploy(address owner) external returns (WishGarden, EverlightBurnReceiver) {
        WishGarden g = new WishGarden(owner);
        EverlightBurnReceiver r = new EverlightBurnReceiver(owner, address(g));
        return (g, r);
    }
}

contract DeploymentAndDependenciesTest is GardenTestBase {
    function test_constructorEmptyChainExplicitOwnerAndNoInitializationCalls() public {
        vm.etch(IMD, "");
        vm.etch(IMDBridge.ENDPOINT, "");
        (WishGarden g, EverlightBurnReceiver r) = new FactoryRehearsal().deploy(OWNER);
        assertEq(g.owner(), OWNER);
        assertEq(r.owner(), OWNER);
        assertEq(r.ethereumGarden(), address(g));
        assertTrue(g.purchasesPaused());
        assertFalse(g.activated());
        assertFalse(r.activated());
        vm.expectRevert();
        new WishGarden(address(0));
        vm.expectRevert();
        new EverlightBurnReceiver(OWNER, address(0));
    }

    function test_deploymentCodeSizesAndReachableOpcodes() public view {
        _scan(address(garden));
        _scan(address(receiver));
        assertLe(type(WishGarden).creationCode.length + 32, 49152);
        assertLe(type(EverlightBurnReceiver).creationCode.length + 64, 49152);
    }

    function _scan(address target) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden reachable opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                reachable = false;
            }
        }
    }

    function test_verifiedEthereumRuntimePaymentAndOfficialOFTSend() public {
        vm.etch(IMD, IMDRuntime.code());
        assertEq(IMD.codehash, 0x79a1ae149d27d4aae006d4dd75cb834222c9623799bbf34359428aaf66fec3bf);
        // Real runtime with local zero storage; only test harness seeds the official peer.
        vm.prank(address(0));
        PeerAdmin(IMD).setPeer(30184, IMDBridge.asBytes32(IMDBridge.BASE_ADAPTER));
        WishGarden g = new WishGarden(OWNER);
        _activate(g, g.pinnedBaseReceiver());
        deal(IMD, alice, 2e18, true);
        uint8[] memory styles = new uint8[](2);
        string[] memory wishes = new string[](2);
        vm.startPrank(alice);
        IERC20(IMD).approve(address(g), 2e18);
        g.buyCandles(styles, wishes);
        vm.stopPrank();
        assertEq(g.claimableRewards(alice), 0.6e18);
        uint256 supply = IERC20(IMD).totalSupply();
        vm.prank(OWNER);
        uint256 id = g.queueBurn(0.6e18);
        vm.prank(OWNER);
        assertTrue(g.dispatchBurn{value: 1e14}(id));
        assertEq(IERC20(IMD).totalSupply(), supply - 0.6e18);
        assertEq(g.confirmedBurn(), 0);
        assertEq(IERC20(IMD).balanceOf(address(g)), 1.4e18);
        assertEq(IERC20(IMD).allowance(address(g), IMD), 0);
        bytes memory packet = endpoint.lastMessage();
        // Actual OFTMsgCodec: receiver[32], amountSD[8], composeFrom[32], application payload[32].
        assertEq(packet.length, 104);
        assertEq(_word(packet, 0), IMDBridge.asBytes32(g.pinnedBaseReceiver()));
        assertEq(_word(packet, 40), IMDBridge.asBytes32(address(g)));
        assertEq(uint256(_word(packet, 72)), id);
        assertEq(endpoint.lastOptions(), IMDBridge.burnOptions());
        (bool publicBurn,) = IMD.call(abi.encodeWithSignature("burn(uint256)", 0));
        assertFalse(publicBurn);
    }

    function test_verifiedBaseRuntimeActuallyReducesSupply() public {
        vm.chainId(8453);
        endpoint.setEid(30184);
        vm.etch(IMDBridge.BASE_IMD, BaseIMDRuntime.code());
        vm.etch(IMDBridge.BASE_ADAPTER, BaseAdapterRuntime.code());
        assertEq(
            IMDBridge.BASE_IMD.codehash, 0x15021fda4613ae853a7e3199f62df75e6f547ca11d32df53c0b1616f4a80ef4f
        );
        assertEq(
            IMDBridge.BASE_ADAPTER.codehash,
            0x1ad0c62178c048836ae25bc3c56a69579ae1ac8498209281c36acd344063e4da
        );
        vm.prank(address(0));
        PeerAdmin(IMDBridge.BASE_ADAPTER).setPeer(30101, IMDBridge.asBytes32(IMD));
        assertEq(IIMDOFT(IMDBridge.BASE_ADAPTER).token(), IMDBridge.BASE_IMD);
        assertEq(IERC20Metadata(IMDBridge.BASE_IMD).decimals(), 18);
        vm.prank(OWNER);
        receiver.activate(EVIDENCE);
        deal(IMDBridge.BASE_IMD, address(receiver), 0.3e18, true);
        uint256 beforeSupply = IERC20(IMDBridge.BASE_IMD).totalSupply();
        _compose(keccak256("verified base burn"), 1, 0.3e18);
        assertEq(IERC20(IMDBridge.BASE_IMD).totalSupply(), beforeSupply - 0.3e18);
        assertEq(IERC20(IMDBridge.BASE_IMD).balanceOf(address(receiver)), 0);
        assertEq(receiver.totalBurned(), 0.3e18);
    }

    function test_verifiedAdapterCreditAndComposeMatchReceiverFormat() public {
        vm.chainId(8453);
        endpoint.setEid(30184);
        vm.etch(IMDBridge.BASE_IMD, BaseIMDRuntime.code());
        vm.etch(IMDBridge.BASE_ADAPTER, BaseAdapterRuntime.code());
        vm.prank(address(0));
        PeerAdmin(IMDBridge.BASE_ADAPTER).setPeer(30101, IMDBridge.asBytes32(IMD));
        vm.prank(OWNER);
        receiver.activate(EVIDENCE);
        deal(IMDBridge.BASE_IMD, IMDBridge.BASE_ADAPTER, 0.3e18, true);
        bytes32 guid = keccak256("adapter actual credit");
        bytes memory packet = abi.encodePacked(
            IMDBridge.asBytes32(address(receiver)),
            uint64(300000),
            IMDBridge.asBytes32(address(garden)),
            uint256(1)
        );
        vm.prank(IMDBridge.ENDPOINT);
        AdapterReceiver(IMDBridge.BASE_ADAPTER)
            .lzReceive(Origin(30101, IMDBridge.asBytes32(IMD), 7), guid, packet, address(this), "");
        assertEq(IERC20(IMDBridge.BASE_IMD).balanceOf(address(receiver)), 0.3e18);
        bytes memory compose = endpoint.lastMessage();
        assertEq(compose.length, 108);
        vm.prank(IMDBridge.ENDPOINT);
        receiver.lzCompose(IMDBridge.BASE_ADAPTER, guid, compose, address(this), "");
        assertEq(receiver.totalBurned(), 0.3e18);
    }

    function _word(bytes memory data, uint256 offset) private pure returns (bytes32 result) {
        assembly ("memory-safe") { result := mload(add(add(data, 32), offset)) }
    }
}
