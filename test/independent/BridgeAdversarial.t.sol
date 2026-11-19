// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {
    GardenTestBase,
    EverlightBridgeQueue,
    EverlightBurnReceiver,
    IMDBridge,
    Origin
} from "../helpers/GardenTestBase.sol";
import {IMDOFTDouble, BaseAdapterDouble} from "../helpers/BridgeDoubles.sol";
import {WalletGas} from "../helpers/WalletGas.sol";

contract BridgeAdversarialTest is GardenTestBase, WalletGas {
    function test_composeAtAdvertisedGasAndMinimumWalletGas() public {
        _setupBase();
        IMDOFTDouble(IMDBridge.BASE_IMD).mint(address(receiver), 0.3e18);
        bytes memory message = abi.encodePacked(
            uint64(1), uint32(30101), uint256(0.3e18), IMDBridge.asBytes32(address(garden)), uint256(1)
        );
        bytes memory callData = abi.encodeCall(
            receiver.lzCompose, (IMDBridge.BASE_ADAPTER, keccak256("gas"), message, address(this), bytes(""))
        );
        assertSameAtWalletGas(IMDBridge.ENDPOINT, address(receiver), callData);
        vm.prank(IMDBridge.ENDPOINT);
        (bool ok,) = address(receiver).call{gas: 500000}(callData);
        assertTrue(ok);
        assertEq(receiver.totalBurned(), 0.3e18);
    }

    function test_lowGasComposeRevertsInsteadOfRecordingAnUntriedFailure() public {
        _setupBase();
        IMDOFTDouble(IMDBridge.BASE_IMD).mint(address(receiver), 0.3e18);
        bytes memory message = abi.encodePacked(
            uint64(1), uint32(30101), uint256(0.3e18), IMDBridge.asBytes32(address(garden)), uint256(1)
        );
        vm.prank(IMDBridge.ENDPOINT);
        (bool ok,) = address(receiver).call{gas: 300000}(
            abi.encodeCall(
                receiver.lzCompose,
                (IMDBridge.BASE_ADAPTER, keccak256("low gas"), message, address(this), bytes(""))
            )
        );
        assertFalse(ok);
        assertEq(receiver.totalReceived(), 0);
        assertEq(receiver.totalFailures(), 0);
    }

    function test_inFlightMessagesOutOfOrderAndReceiptReplay() public {
        _buy(alice, 3, 0);
        uint256[3] memory ids;
        bytes32[3] memory guids;
        for (uint256 i; i < 3; ++i) {
            vm.prank(OWNER);
            ids[i] = garden.queueBurn(0.3e18);
            vm.prank(OWNER);
            garden.dispatchBurn{value: 1e14}(ids[i]);
            guids[i] = token.lastGuid();
        }
        assertEq(garden.burnInTransit(), 0.9e18);
        _setupBase();
        IMDOFTDouble(IMDBridge.BASE_IMD).mint(address(receiver), 0.9e18);
        _compose(guids[2], ids[2], 0.3e18);
        _compose(guids[0], ids[0], 0.3e18);
        _compose(guids[1], ids[1], 0.3e18);
        assertEq(receiver.totalBurned(), 0.9e18);
        bytes[3] memory acks;
        for (uint256 i; i < 3; ++i) {
            vm.prank(alice);
            receiver.sendBurnReceipt{value: 1e14}(guids[i]);
            acks[i] = endpoint.lastMessage();
        }
        vm.chainId(1);
        endpoint.setEid(30101);
        for (uint256 i = 3; i > 0; --i) {
            vm.prank(IMDBridge.ENDPOINT);
            garden.lzReceive(
                Origin(30184, IMDBridge.asBytes32(address(receiver)), uint64(i)),
                bytes32(i + 100),
                acks[i - 1],
                address(this),
                ""
            );
        }
        assertEq(garden.confirmedBurn(), 0.9e18);
        assertEq(garden.burnInTransit(), 0);
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBridgeQueue.InvalidMessage.selector);
        garden.lzReceive(
            Origin(30184, IMDBridge.asBytes32(address(receiver)), 1),
            bytes32(uint256(101)),
            acks[0],
            address(this),
            ""
        );
        _assertSolvent();
    }

    function test_baseHasNoTokenRescueOrApprovalAndDoesNotBurnDonations() public {
        _setupBase();
        IMDOFTDouble base = IMDOFTDouble(IMDBridge.BASE_IMD);
        base.mint(address(receiver), 5e18);
        _compose(keccak256("donation"), 1, 0.3e18);
        assertEq(base.balanceOf(address(receiver)), 4.7e18);
        assertEq(receiver.totalBurned(), 0.3e18);
        vm.prank(OWNER);
        (bool ok,) =
            address(receiver).call(abi.encodeWithSignature("withdraw(address,uint256)", OWNER, 4.7e18));
        assertFalse(ok);
        assertEq(base.allowance(address(receiver), IMDBridge.BASE_ADAPTER), 0);
    }

    function test_previouslyAuthenticatedBurnSurvivesLaterBridgePeerChange() public {
        _setupBase();
        IMDOFTDouble base = IMDOFTDouble(IMDBridge.BASE_IMD);
        base.mint(address(receiver), 0.3e18);
        base.setBurnFailure(true, false);
        bytes32 guid = keccak256("peer change after receipt");
        _compose(guid, 1, 0.3e18);
        BaseAdapterDouble(IMDBridge.BASE_ADAPTER).setPeer(IMDBridge.asBytes32(alice));
        base.setBurnFailure(false, false);
        receiver.retryBurn(guid);
        assertEq(receiver.totalBurned(), 0.3e18);
        assertEq(receiver.pendingBurn(), 0);
        vm.prank(alice);
        receiver.sendBurnReceipt{value: 1e14}(guid);
        assertEq(base.totalSupply(), 0);
    }

    function testFuzz_failedRetriesRemainFunded(uint8 retriesSeed) public {
        uint256 retries = bound(retriesSeed, 1, 8);
        _buy(alice, 1, 0);
        vm.prank(OWNER);
        uint256 id = garden.queueBurn(0.3e18);
        uint256 nativeBefore = OWNER.balance;
        token.setSendFailure(true, false);
        for (uint256 i; i < retries; ++i) {
            vm.prank(OWNER);
            assertFalse(garden.dispatchBurn{value: 1e14}(id));
            _assertSolvent();
        }
        assertEq(OWNER.balance, nativeBefore);
        assertEq(garden.failedBurnAmount(), 0.3e18);
        assertEq(garden.totalSendFailures(), retries);
        token.setSendFailure(false, false);
        vm.prank(OWNER);
        assertTrue(garden.dispatchBurn{value: 1e14}(id));
        assertEq(garden.burnInTransit(), 0.3e18);
        assertEq(garden.totalSendRetries(), retries);
        _assertSolvent();
    }
}
