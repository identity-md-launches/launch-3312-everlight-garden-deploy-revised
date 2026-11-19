// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WishGarden} from "../src/WishGarden.sol";
import {IMDBridge, Origin, MessagingFee} from "../src/bridge/IMDBridge.sol";

/// @dev Fresh garden and local buyer balance. Readiness is supplied by the harness. The actual
///      Ethereum OFT, endpoint and message libraries execute in the fork with their deployed storage.
contract EthereumSendForkTest is Test {
    address private constant OWNER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;

    function test_firstCandleDispatchesExactlyTheBurnAllocation() public {
        assertEq(block.chainid, 1);
        WishGarden garden = new WishGarden(OWNER);
        address receiver = garden.pinnedBaseReceiver();
        vm.prank(OWNER);
        garden.configureBridge(receiver, keccak256("local Ethereum fork fixture"));
        bytes memory ready =
            abi.encode(uint8(1), garden.bridgeConfigHash(), uint256(0), bytes32(0), uint256(0));
        vm.prank(IMDBridge.ENDPOINT);
        garden.lzReceive(
            Origin(30184, IMDBridge.asBytes32(receiver), 1),
            keccak256("local readiness"),
            ready,
            address(this),
            ""
        );
        vm.prank(OWNER);
        garden.activate();

        IERC20 imd = IERC20(garden.IMD());
        deal(address(imd), address(this), 1e18, true);
        imd.approve(address(garden), 1e18);
        garden.buyCandles(new uint8[](1), new string[](1));
        uint256 supply = imd.totalSupply();
        vm.prank(OWNER);
        uint256 id = garden.queueBurn(type(uint256).max);
        MessagingFee memory fee = garden.quoteBurn(id);
        vm.deal(OWNER, fee.nativeFee);
        vm.prank(OWNER);
        assertTrue(garden.dispatchBurn{value: fee.nativeFee}(id));
        assertEq(imd.totalSupply(), supply - 0.9e18);
        assertEq(imd.balanceOf(address(garden)), 0.1e18);
        assertEq(garden.burnInTransit(), 0.9e18);
        assertEq(garden.confirmedBurn(), 0);
    }
}
