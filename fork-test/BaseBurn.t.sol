// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EverlightBurnReceiver} from "../src/base/EverlightBurnReceiver.sol";
import {IMDBridge, Origin, MessagingFee} from "../src/bridge/IMDBridge.sol";
import {WishGarden} from "../src/WishGarden.sol";
import {AdapterReceiver} from "../test/DeploymentAndDependencies.t.sol";
import {EndpointDouble} from "../test/helpers/BridgeDoubles.sol";

/// @dev Run explicitly against a Base fork. The source garden is a local deployment, and the
///      harness supplies an already-verified packet. Base contracts execute against forked state.
contract BaseBurnForkTest is Test {
    address private constant OWNER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;

    WishGarden private garden;
    EverlightBurnReceiver private receiver;

    function setUp() public {
        assertEq(block.chainid, 8453);
        garden = new WishGarden(OWNER);
        (bool deployed, bytes memory result) = garden.CREATE2_DEPLOYER()
            .call(
                bytes.concat(
                    garden.BASE_RECEIVER_SALT(),
                    type(EverlightBurnReceiver).creationCode,
                    abi.encode(OWNER, address(garden))
                )
            );
        assertTrue(deployed);
        assertEq(result.length, 20);
        receiver = EverlightBurnReceiver(address(bytes20(result)));
        assertEq(address(receiver), garden.pinnedBaseReceiver());
        assertEq(receiver.ethereumGarden(), address(garden));
        vm.prank(OWNER);
        receiver.activate(keccak256("local Base fork fixture"));
    }

    function test_firstAllocationCreditsPinnedReceiverAndReducesBaseSupply() public {
        IERC20 imd = IERC20(IMDBridge.BASE_IMD);
        uint256 supply = imd.totalSupply();
        uint256 collateral = imd.balanceOf(IMDBridge.BASE_ADAPTER);
        uint256 held = imd.balanceOf(address(receiver));
        uint256 amount = 0.9e18;
        bytes32 guid = keccak256(abi.encode(address(this), address(receiver), "local fork packet"));
        Origin memory origin = Origin(IMDBridge.ETH_EID, IMDBridge.asBytes32(garden.IMD()), 1);
        bytes memory source = abi.encodePacked(
            IMDBridge.asBytes32(address(receiver)),
            uint64(amount / IMDBridge.CONVERSION_RATE),
            IMDBridge.asBytes32(address(garden)),
            uint256(1)
        );
        vm.prank(IMDBridge.ENDPOINT);
        AdapterReceiver(IMDBridge.BASE_ADAPTER).lzReceive(origin, guid, source, address(this), "");
        assertEq(imd.balanceOf(address(receiver)), held + amount);
        assertEq(imd.balanceOf(IMDBridge.BASE_ADAPTER), collateral - amount);
        assertEq(imd.totalSupply(), supply);

        bytes memory message = abi.encodePacked(
            origin.nonce, origin.srcEid, amount, IMDBridge.asBytes32(address(garden)), uint256(1)
        );
        EndpointDouble(IMDBridge.ENDPOINT).lzCompose{gas: IMDBridge.COMPOSE_GAS}(
            IMDBridge.BASE_ADAPTER, address(receiver), guid, 0, message, ""
        );
        assertEq(imd.balanceOf(address(receiver)), held);
        assertEq(imd.totalSupply(), supply - amount);
        assertEq(receiver.totalBurned(), amount);
        assertEq(receiver.pendingBurn(), 0);
        MessagingFee memory fee = receiver.quoteReceipt(2, guid);
        receiver.sendBurnReceipt{value: fee.nativeFee}(guid);
        (,,,, bool receiptSent) = receiver.deliveries(guid);
        assertTrue(receiptSent);
        assertEq(garden.confirmedBurn(), 0);
    }
}
