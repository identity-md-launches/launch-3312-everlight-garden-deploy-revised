// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {WishGarden} from "src/WishGarden.sol";
import {EverlightBurnReceiver} from "src/base/EverlightBurnReceiver.sol";
import {IMDBridge, IIMDOFT, ILZEndpoint, Origin, MessagingFee} from "src/bridge/IMDBridge.sol";
import {WalletGas} from "../helpers/WalletGas.sol";

interface IForkAdapterDelivery {
    function lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata) external payable;
}

interface IForkComposer {
    function lzCompose(address, address, bytes32, uint16, bytes calldata, bytes calldata) external payable;
    function composeQueue(address, address, bytes32, uint16) external view returns (bytes32);
}

/// @notice Runs against the deployed Base token, adapter, endpoint, libraries and CREATE2 deployer.
/// @dev All application deployments and packets are LOCAL fork simulations. The only authentication
///      bypass is supplying an already-verified OFT packet at the adapter's endpoint-only entry point.
///      This does not prove DVN delivery or production deployment. No token storage is fabricated.
contract BasePinnedBurnTest is WalletGas {
    uint256 private constant PINNED_BLOCK = 59_474_551;
    address private constant OWNER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;
    address private constant OLD_GARDEN = 0x39E55288F5b84dD867a784c95F110818ea8f3B31;
    address private constant OLD_RECEIVER = 0xb525358F3F1c531522A27092e8Aa1C054Bb963Fc;
    IERC20 private constant TOKEN = IERC20(IMDBridge.BASE_IMD);
    IForkComposer private constant COMPOSER = IForkComposer(IMDBridge.ENDPOINT);

    WishGarden private garden;
    EverlightBurnReceiver private receiver;
    bytes32 private legacyState;

    function setUp() public {
        string memory url = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, PINNED_BLOCK);
        assertEq(block.chainid, 8453);
        assertEq(block.number, PINNED_BLOCK);
        assertGt(IMDBridge.BASE_IMD.code.length, 0);
        assertGt(IMDBridge.BASE_ADAPTER.code.length, 0);
        assertGt(IMDBridge.ENDPOINT.code.length, 0);
        legacyState = _legacyState();

        // Constructors are chain-independent; this garden represents a fresh Ethereum source.
        garden = new WishGarden(OWNER);
        bytes memory initCode =
            bytes.concat(type(EverlightBurnReceiver).creationCode, abi.encode(OWNER, address(garden)));
        address expected = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            garden.CREATE2_DEPLOYER(),
                            garden.BASE_RECEIVER_SALT(),
                            keccak256(initCode)
                        )
                    )
                )
            )
        );
        assertEq(expected, garden.pinnedBaseReceiver());
        assertGt(garden.CREATE2_DEPLOYER().code.length, 0);
        (bool ok, bytes memory result) =
            garden.CREATE2_DEPLOYER().call(bytes.concat(garden.BASE_RECEIVER_SALT(), initCode));
        assertTrue(ok, "live canonical CREATE2 deployment failed");
        assertEq(result.length, 20);
        receiver = EverlightBurnReceiver(address(bytes20(result)));
        assertEq(address(receiver), expected);
        vm.prank(OWNER);
        receiver.activate(keccak256("LOCAL pinned Base fork evidence; not deployment evidence"));
        vm.deal(address(this), 10 ether);
        vm.deal(OWNER, 10 ether);
    }

    function testFork_routeBindingsDeploymentAndLegacyIsolation() public view {
        IIMDOFT adapter = IIMDOFT(IMDBridge.BASE_ADAPTER);
        assertEq(adapter.token(), IMDBridge.BASE_IMD);
        assertEq(adapter.endpoint(), IMDBridge.ENDPOINT);
        assertTrue(adapter.approvalRequired());
        assertEq(adapter.decimalConversionRate(), 1e12);
        assertEq(adapter.peers(30101), IMDBridge.asBytes32(garden.IMD()));
        assertEq(ILZEndpoint(IMDBridge.ENDPOINT).eid(), 30184);
        assertEq(IERC20Metadata(IMDBridge.BASE_IMD).decimals(), 18);
        assertEq(receiver.owner(), OWNER);
        assertEq(receiver.ethereumGarden(), address(garden));
        assertNotEq(address(receiver), OLD_RECEIVER);
        assertNotEq(address(garden), OLD_GARDEN);
        assertEq(EverlightBurnReceiver(OLD_RECEIVER).ethereumGarden(), OLD_GARDEN);
        assertEq(receiver.tokenCodeHash(), IMDBridge.BASE_IMD.codehash);
        assertEq(receiver.adapterCodeHash(), IMDBridge.BASE_ADAPTER.codehash);
        assertEq(receiver.endpointCodeHash(), IMDBridge.ENDPOINT.codehash);
        assertFalse(garden.activated(), "the source must remain closed");
        assertTrue(garden.purchasesPaused());
        assertEq(garden.totalCandles(), 0);
        assertEq(_legacyState(), legacyState);
    }

    function testFork_firstAllocationCreditBurnAndReceiptAreDistinct() public {
        uint256 amount = 0.9e18;
        uint256 supply = TOKEN.totalSupply();
        uint256 collateral = TOKEN.balanceOf(IMDBridge.BASE_ADAPTER);
        bytes32 guid = keccak256("first candle allocation");
        bytes memory message = _credit(guid, 1, amount, address(garden));
        assertEq(TOKEN.balanceOf(IMDBridge.BASE_ADAPTER), collateral - amount);
        assertEq(TOKEN.balanceOf(address(receiver)), amount);
        assertEq(TOKEN.totalSupply(), supply, "credit must not masquerade as a burn");
        assertEq(receiver.totalReceived(), 0, "compose has not run");
        assertEq(receiver.totalBurned(), 0);
        assertEq(_queued(guid), keccak256(message));

        _compose(guid, message);
        _assertBurned(guid, 1, amount, supply);
        assertEq(TOKEN.balanceOf(address(receiver)), 0);
        (,,,, bool acknowledged) = receiver.deliveries(guid);
        assertFalse(acknowledged);
        _sendReceipt(guid);
        (,,,, acknowledged) = receiver.deliveries(guid);
        assertTrue(acknowledged);
        assertEq(TOKEN.totalSupply(), supply - amount, "sending a receipt cannot burn twice");
        assertEq(garden.confirmedBurn(), 0, "Ethereum has not received this packet");
        assertEq(_legacyState(), legacyState);
    }

    function testFork_endpointComposeMatchesWalletGasAndFitsAdvertisedBudget() public {
        bytes32 guid = keccak256("wallet gas through real endpoint");
        uint256 supply = TOKEN.totalSupply();
        bytes memory message = _credit(guid, 1, 0.9e18, address(garden));
        assertSameAtWalletGas(address(this), IMDBridge.ENDPOINT, _composeCall(guid, message));
        assertEq(receiver.totalBurned(), 0, "gas helper restores its snapshot");
        assertEq(_queued(guid), keccak256(message));
        _compose(guid, message);
        _assertBurned(guid, 1, 0.9e18, supply);
    }

    function testFork_insufficientComposeGasRevertsAndPreservesOriginalPacket() public {
        bytes32 guid = keccak256("retry original endpoint packet");
        uint256 supply = TOKEN.totalSupply();
        bytes memory message = _credit(guid, 1, 0.3e18, address(garden));
        (bool ok,) = IMDBridge.ENDPOINT.call{gas: 300_000}(_composeCall(guid, message));
        assertFalse(ok, "short gas must revert, never succeed without burning");
        assertEq(_queued(guid), keccak256(message));
        assertEq(TOKEN.totalSupply(), supply);
        assertEq(TOKEN.balanceOf(address(receiver)), 0.3e18);
        assertEq(receiver.totalReceived(), 0);
        assertEq(receiver.totalFailures(), 0);
        assertEq(receiver.jobGuids(1), bytes32(0));
        _compose(guid, message);
        _assertBurned(guid, 1, 0.3e18, supply);
    }

    function testFork_injectedBurnFailureRetainsRealCreditAndRetryBurnsRealSupply() public {
        bytes32 guid = keccak256("injected burn revert on live token");
        uint256 amount = 0.3e18;
        uint256 supply = TOKEN.totalSupply();
        bytes memory message = _credit(guid, 1, amount, address(garden));
        // Only this test injects a dependency failure; code, supply, balances and the retry are real.
        vm.mockCallRevert(
            IMDBridge.BASE_IMD,
            abi.encodeWithSignature("burn(uint256)", amount),
            abi.encodeWithSignature("Error(string)", "local burn failure")
        );
        assertSameAtWalletGas(address(this), IMDBridge.ENDPOINT, _composeCall(guid, message));
        _compose(guid, message);
        assertEq(receiver.pendingBurn(), amount);
        assertEq(receiver.failedBurn(), amount);
        assertEq(receiver.totalReceived(), amount);
        assertEq(receiver.totalBurned(), 0);
        assertEq(TOKEN.totalSupply(), supply);
        assertEq(TOKEN.balanceOf(address(receiver)), amount);
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        receiver.sendBurnReceipt(guid);
        vm.clearMockedCalls();

        assertSameAtWalletGas(address(this), address(receiver), abi.encodeCall(receiver.retryBurn, (guid)));
        receiver.retryBurn(guid); // Permissionless, with actual Base IMD burn().
        assertEq(receiver.totalRetries(), 1);
        assertEq(receiver.totalFailures(), 1);
        _assertBurned(guid, 1, amount, supply);
        (,, uint32 attempts,,) = receiver.deliveries(guid);
        assertEq(attempts, 2);
        assertEq(TOKEN.balanceOf(address(receiver)), 0);
        _sendReceipt(guid);
    }

    function testFork_wrongGardenCannotBurnAndCannotBlockCorrectPacket() public {
        uint256 supply = TOKEN.totalSupply();
        bytes32 wrongGuid = keccak256("legacy source is forbidden");
        bytes memory wrong = _credit(wrongGuid, 1, 0.3e18, OLD_GARDEN);
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        COMPOSER.lzCompose(IMDBridge.BASE_ADAPTER, address(receiver), wrongGuid, 0, wrong, "");
        assertEq(_queued(wrongGuid), keccak256(wrong));
        assertEq(receiver.jobGuids(1), bytes32(0));
        assertEq(receiver.totalReceived(), 0);
        assertEq(TOKEN.totalSupply(), supply);

        bytes32 validGuid = keccak256("correct source after rejected packet");
        bytes memory valid = _credit(validGuid, 1, 0.9e18, address(garden));
        _compose(validGuid, valid);
        _assertBurned(validGuid, 1, 0.9e18, supply);
        assertEq(TOKEN.balanceOf(address(receiver)), 0.3e18, "unauthenticated credit is not burned");
        assertEq(_legacyState(), legacyState);
    }

    function testFork_endpointRejectsWrongReceiverAlteredPayloadAndReplay() public {
        bytes32 guid = keccak256("endpoint authentication and replay");
        uint256 supply = TOKEN.totalSupply();
        bytes memory message = _credit(guid, 1, 0.3e18, address(garden));
        vm.expectRevert(); // Actual EndpointV2, not the application's error.
        COMPOSER.lzCompose(IMDBridge.BASE_ADAPTER, OLD_RECEIVER, guid, 0, message, "");
        vm.expectRevert();
        COMPOSER.lzCompose(
            IMDBridge.BASE_ADAPTER, address(receiver), guid, 0, bytes.concat(message, hex"00"), ""
        );
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        receiver.lzCompose(IMDBridge.BASE_ADAPTER, guid, message, address(this), "");
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        receiver.lzCompose(address(this), guid, message, address(this), "");
        assertEq(_queued(guid), keccak256(message));
        assertEq(receiver.totalReceived(), 0);

        _compose(guid, message);
        vm.expectRevert();
        COMPOSER.lzCompose(IMDBridge.BASE_ADAPTER, address(receiver), guid, 0, message, "");
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        receiver.lzCompose(IMDBridge.BASE_ADAPTER, guid, message, address(this), "");
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        receiver.retryBurn(guid);
        _assertBurned(guid, 1, 0.3e18, supply);
        _sendReceipt(guid);
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        receiver.sendBurnReceipt(guid);
        assertEq(TOKEN.totalSupply(), supply - 0.3e18);
    }

    function testFork_receiptFeeFailureIsAtomicAndActualQuoteCanRetry() public {
        bytes32 guid = keccak256("receipt retry");
        uint256 supply = TOKEN.totalSupply();
        _compose(guid, _credit(guid, 1, 0.3e18, address(garden)));
        MessagingFee memory fee = receiver.quoteReceipt(2, guid);
        vm.expectRevert(EverlightBurnReceiver.InvalidFee.selector);
        receiver.sendBurnReceipt{value: fee.nativeFee + 1}(guid);
        (,,,, bool acknowledged) = receiver.deliveries(guid);
        assertFalse(acknowledged);
        assertEq(address(receiver).balance, 0);
        _assertBurned(guid, 1, 0.3e18, supply);
        assertSameAtWalletGas(
            address(this), address(receiver), fee.nativeFee, abi.encodeCall(receiver.sendBurnReceipt, (guid))
        );
        _sendReceipt(guid);
    }

    function testFork_readinessUsesActualEndpointFeesAndLeavesPurchasesClosed() public {
        MessagingFee memory fee = receiver.quoteReceipt(1, bytes32(0));
        assertEq(fee.lzTokenFee, 0);
        assertLe(fee.nativeFee, receiver.MAX_NATIVE_FEE());
        assertSameAtWalletGas(
            OWNER, address(receiver), fee.nativeFee, abi.encodeCall(receiver.announceReady, ())
        );
        vm.prank(OWNER);
        receiver.announceReady{value: fee.nativeFee}();
        assertFalse(garden.activated());
        assertTrue(garden.purchasesPaused());
        assertEq(receiver.totalReceived(), 0);
        assertEq(receiver.totalBurned(), 0);
        assertEq(address(receiver).balance, 0);
        assertEq(_legacyState(), legacyState);
    }

    function _credit(bytes32 guid, uint256 job, uint256 amount, address sourceGarden)
        private
        returns (bytes memory composeMessage)
    {
        uint64 nonce = uint64(job);
        bytes memory packet = abi.encodePacked(
            IMDBridge.asBytes32(address(receiver)),
            uint64(amount / 1e12),
            IMDBridge.asBytes32(sourceGarden),
            job
        );
        Origin memory origin = Origin(30101, IMDBridge.asBytes32(garden.IMD()), nonce);
        vm.prank(IMDBridge.ENDPOINT);
        IForkAdapterDelivery(IMDBridge.BASE_ADAPTER).lzReceive(origin, guid, packet, address(this), "");
        composeMessage =
            abi.encodePacked(nonce, uint32(30101), amount, IMDBridge.asBytes32(sourceGarden), job);
    }

    function _compose(bytes32 guid, bytes memory message) private {
        COMPOSER.lzCompose{gas: IMDBridge.COMPOSE_GAS}(
            IMDBridge.BASE_ADAPTER, address(receiver), guid, 0, message, ""
        );
    }

    function _composeCall(bytes32 guid, bytes memory message) private view returns (bytes memory) {
        return abi.encodeCall(
            COMPOSER.lzCompose,
            (IMDBridge.BASE_ADAPTER, address(receiver), guid, uint16(0), message, bytes(""))
        );
    }

    function _queued(bytes32 guid) private view returns (bytes32) {
        return COMPOSER.composeQueue(IMDBridge.BASE_ADAPTER, address(receiver), guid, 0);
    }

    function _sendReceipt(bytes32 guid) private {
        MessagingFee memory fee = receiver.quoteReceipt(2, guid);
        assertEq(fee.lzTokenFee, 0);
        assertLe(fee.nativeFee, receiver.MAX_NATIVE_FEE());
        receiver.sendBurnReceipt{value: fee.nativeFee}(guid);
        (,,,, bool acknowledged) = receiver.deliveries(guid);
        assertTrue(acknowledged);
        assertEq(address(receiver).balance, 0);
    }

    function _assertBurned(bytes32 guid, uint256 job, uint256 amount, uint256 supplyBefore) private view {
        (uint256 id, uint256 received,, EverlightBurnReceiver.Status status,) = receiver.deliveries(guid);
        assertEq(id, job);
        assertEq(received, amount);
        assertEq(uint8(status), uint8(EverlightBurnReceiver.Status.Burned));
        assertEq(receiver.jobGuids(job), guid);
        assertEq(receiver.totalReceived(), amount);
        assertEq(receiver.totalBurned(), amount);
        assertEq(receiver.pendingBurn(), 0);
        assertEq(receiver.failedBurn(), 0);
        assertEq(TOKEN.totalSupply(), supplyBefore - amount);
        assertEq(TOKEN.allowance(address(receiver), IMDBridge.BASE_ADAPTER), 0);
    }

    function _legacyState() private view returns (bytes32) {
        EverlightBurnReceiver old = EverlightBurnReceiver(OLD_RECEIVER);
        return keccak256(
            abi.encode(
                old.ethereumGarden(),
                old.owner(),
                old.totalReceived(),
                old.totalBurned(),
                old.pendingBurn(),
                old.failedBurn(),
                old.totalFailures(),
                old.totalRetries(),
                TOKEN.balanceOf(OLD_RECEIVER),
                OLD_RECEIVER.balance
            )
        );
    }
}
