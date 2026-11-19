// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    GardenTestBase,
    WishGarden,
    WishGardenTreasury,
    EverlightBridgeQueue,
    EverlightBurnReceiver,
    IMDBridge,
    Origin
} from "../helpers/GardenTestBase.sol";
import {IMDOFTDouble, EndpointDouble} from "../helpers/BridgeDoubles.sol";

/// @dev Model values come from submitted actions, not the application's accounting getters.
///      The doubles model atomic source sends, not a live bridge or a Base supply burn.
contract SourceCustodyHandler is Test {
    struct Job {
        uint256 amount;
        bytes32 guid;
        uint32 attempts;
        // 1 = queued, 2 = failed, 3 = sent, 4 = confirmed.
        uint8 state;
    }

    WishGarden public immutable garden;
    IMDOFTDouble public immutable token;
    address public immutable owner;
    address[3] public actors;
    Job[] private jobs;
    uint256 public purchases;
    uint256 public donated;
    uint256 public claimed;
    uint256[3] public withdrawn;
    uint256 public queued;
    uint256 public sent;
    uint256 public failures;
    uint256 public retries;
    uint256 public sends;
    uint64 private ackNonce;
    bool public paused;

    constructor(WishGarden g, IMDOFTDouble t, address o, address a, address b, address c) {
        garden = g;
        token = t;
        owner = o;
        actors = [a, b, c];
    }

    function buy(uint8 actorSeed, uint8 countSeed) external {
        uint256 quantity = 1 + uint256(countSeed) % 50;
        address buyer = actors[actorSeed % 3];
        uint8[] memory styles = new uint8[](quantity);
        string[] memory wishes = new string[](quantity);
        vm.startPrank(buyer);
        token.approve(address(garden), quantity * 1e18);
        if (paused) {
            vm.expectRevert(WishGarden.PurchasesDisabled.selector);
            garden.buyCandles(styles, wishes);
        } else {
            assertEq(garden.buyCandles(styles, wishes), purchases + 1);
            if (purchases == 0) queued += 6e17;
            purchases += quantity;
            queued += quantity * 3e17;
        }
        vm.stopPrank();
    }

    function queue(uint96 maximumSeed) external {
        // Include zero, sub-unit amounts, partial reservations, and amounts exceeding availability.
        uint256 maximum = uint256(maximumSeed) % (queued + 1e12 + 1);
        uint256 amount = (maximum < queued ? maximum : queued) / 1e12 * 1e12;
        vm.prank(owner);
        if (amount == 0) {
            vm.expectRevert(EverlightBridgeQueue.InvalidBurnJob.selector);
            garden.queueBurn(maximum);
        } else {
            assertEq(garden.queueBurn(maximum), jobs.length + 1);
            jobs.push(Job(amount, bytes32(0), 0, 1));
            queued -= amount;
        }
    }

    function dispatch(uint256 idSeed, uint8 faultSeed) external {
        uint256 id = jobs.length == 0 ? 1 : 1 + idSeed % jobs.length;
        uint8 fault = faultSeed % 3; // success, reverting bridge, malformed receipt after debit.
        token.setSendFailure(fault == 1, fault == 2);
        if (jobs.length == 0 || jobs[id - 1].state >= 3) {
            vm.prank(owner);
            vm.expectRevert(EverlightBridgeQueue.InvalidBurnJob.selector);
            garden.dispatchBurn{value: 1e14}(id);
        } else {
            Job storage j = jobs[id - 1];
            if (j.state == 2) ++retries;
            ++j.attempts;
            uint256 beforeNative = owner.balance;
            vm.prank(owner);
            assertEq(garden.dispatchBurn{value: 1e14}(id), fault == 0);
            if (fault == 0) {
                j.state = 3;
                // The fixture's GUID is derived independently of garden.burnJobs.
                j.guid = keccak256(abi.encode(uint64(++sends), address(garden)));
                sent += j.amount;
                assertEq(owner.balance, beforeNative - 1e14);
            } else {
                j.state = 2;
                ++failures;
                assertEq(owner.balance, beforeNative, "failed send must refund native fee");
            }
        }
        token.setSendFailure(false, false);
    }

    function acknowledge(uint256 idSeed, bool corrupt) external {
        if (jobs.length == 0) return;
        uint256 id = 1 + idSeed % jobs.length;
        Job storage j = jobs[id - 1];
        bool valid = j.state == 3 && !corrupt;
        bytes32 messageGuid = keccak256(abi.encode("source model ack", ++ackNonce));
        bytes memory payload =
            abi.encode(uint8(2), garden.bridgeConfigHash(), id, j.guid, j.amount + (corrupt ? 1 : 0));
        Origin memory origin = Origin(30184, IMDBridge.asBytes32(garden.baseReceiver()), ackNonce);
        vm.prank(IMDBridge.ENDPOINT);
        if (!valid) vm.expectRevert(EverlightBridgeQueue.InvalidMessage.selector);
        garden.lzReceive(origin, messageGuid, payload, address(this), "");
        if (valid) j.state = 4;
        assertEq(garden.receivedGuids(messageGuid), valid, "rejected acknowledgement must not consume GUID");
    }

    function claim(uint8 actorSeed) external {
        address beneficiary = actors[actorSeed % 3];
        uint256 beforeBalance = token.balanceOf(beneficiary);
        vm.prank(beneficiary);
        (bool ok, bytes memory returned) = address(garden).call(abi.encodeCall(garden.claimRewards, ()));
        if (ok) {
            uint256 amount = abi.decode(returned, (uint256));
            assertGt(amount, 0);
            assertEq(token.balanceOf(beneficiary), beforeBalance + amount);
            claimed += amount;
        } else {
            assertEq(returned, abi.encodeWithSelector(WishGardenTreasury.NothingToClaim.selector));
            assertEq(token.balanceOf(beneficiary), beforeBalance);
        }
    }

    function withdraw(uint8 bucketSeed, uint96 amountSeed) external {
        uint256 bucket = bucketSeed % 3;
        uint256 available = _grossBucket(bucket) - withdrawn[bucket];
        if (available == 0) return;
        uint256 amount = 1 + uint256(amountSeed) % available;
        address destination = actors[(bucket + 1) % 3];
        uint256 beforeBalance = token.balanceOf(destination);
        vm.prank(owner);
        garden.withdrawBucket(WishGardenTreasury.Bucket(bucket), destination, amount);
        withdrawn[bucket] += amount;
        assertEq(token.balanceOf(destination), beforeBalance + amount);
    }

    function donate(uint64 amount) external {
        token.mint(address(garden), amount);
        donated += amount;
    }

    function pause(bool value) external {
        vm.prank(owner);
        garden.setPurchasesPaused(value);
        paused = value;
    }

    function assertCustody() external view {
        uint256 reserved;
        uint256 inTransit;
        uint256 confirmed;
        uint256 failed;
        for (uint256 i; i < jobs.length; ++i) {
            Job memory j = jobs[i];
            (uint256 amount, bytes32 guid, uint32 attempts, EverlightBridgeQueue.BurnStatus status) =
                garden.burnJobs(i + 1);
            assertEq(amount, j.amount);
            assertEq(guid, j.guid);
            assertEq(attempts, j.attempts);
            assertEq(uint256(status), j.state);
            assertEq(amount % 1e12, 0);
            if (j.state <= 2) reserved += j.amount;
            if (j.state == 2) failed += j.amount;
            if (j.state == 3) inTransit += j.amount;
            if (j.state == 4) confirmed += j.amount;
            if (j.state >= 3) assertTrue(garden.sentGuids(j.guid));
        }
        assertEq(garden.totalCandles(), purchases);
        assertEq(garden.totalPayments(), purchases * 1e18);
        assertEq(garden.burnJobCount(), jobs.length);
        assertEq(garden.burnQueued(), queued);
        assertEq(garden.burnReserved(), reserved);
        assertEq(garden.burnInTransit(), inTransit);
        assertEq(garden.confirmedBurn(), confirmed);
        assertEq(garden.failedBurnAmount(), failed);
        assertEq(garden.totalSendFailures(), failures);
        assertEq(garden.totalSendRetries(), retries);
        uint256 burn = purchases * 3e17 + (purchases == 0 ? 0 : 6e17);
        assertEq(garden.totalBurnAllocated(), burn);
        assertEq(queued + reserved + inTransit + confirmed, burn);
        assertEq(sent, inTransit + confirmed);
        assertEq(garden.bridgeDust(), queued % 1e12);
        assertEq(garden.ecosystemBalance(), _grossBucket(0) - withdrawn[0]);
        assertEq(garden.operationsBalance(), _grossBucket(1) - withdrawn[1]);
        assertEq(garden.founderBalance(), _grossBucket(2) - withdrawn[2]);
        assertEq(garden.totalEcosystemWithdrawn(), withdrawn[0]);
        assertEq(garden.totalOperationsWithdrawn(), withdrawn[1]);
        assertEq(garden.totalFounderWithdrawn(), withdrawn[2]);
        assertEq(garden.totalRewardsClaimed(), claimed);
        uint256 rewards = purchases == 0 ? 0 : (purchases - 1) * 6e17;
        assertEq(garden.totalRewardsAllocated(), rewards);
        assertEq(garden.rewardLiability(), rewards - claimed);
        uint256 claimsOwed;
        uint256 earnedScaled;
        uint256 candleWeights;
        for (uint256 i; i < 3; ++i) {
            (uint256 weight, uint256 earned, uint256 paid, uint256 owing, uint256 fraction) =
                garden.rewardState(actors[i]);
            assertEq(earned, paid + owing);
            claimsOwed += owing;
            earnedScaled += earned * 1e27 + fraction;
            candleWeights += weight;
        }
        assertEq(candleWeights, purchases);
        assertEq(earnedScaled + garden.rewardDustScaled(), rewards * 1e27);
        assertLe(claimsOwed, rewards - claimed);
        uint256 expectedHeld =
            purchases * 1e18 + donated - sent - claimed - withdrawn[0] - withdrawn[1] - withdrawn[2];
        assertEq(token.balanceOf(address(garden)), expectedHeld);
        assertEq(expectedHeld, garden.accountedBalance() + donated);
        assertEq(garden.unallocatedBalance(), donated);
        assertEq(token.allowance(address(garden), address(token)), 0);
        assertEq(address(garden).balance, 0, "gas fees are never held as burn custody");
    }

    function _grossBucket(uint256 bucket) private view returns (uint256) {
        if (bucket == 0) return 0;
        return purchases * 5e16;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
contract SourceCustodyInvariantTest is GardenTestBase {
    SourceCustodyHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new SourceCustodyHandler(garden, token, OWNER, alice, bob, carol);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.queue.selector;
        selectors[2] = handler.dispatch.selector;
        selectors[3] = handler.acknowledge.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.withdraw.selector;
        selectors[6] = handler.donate.selector;
        selectors[7] = handler.pause.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_eachIMDRemainsInExactlyOneCustodyBucket() public view {
        handler.assertCustody();
    }

    function test_sourceModelExercisesRecoveryWhileClaimsAndWithdrawalsContinue() public {
        handler.buy(0, 49);
        handler.buy(1, 0);
        handler.queue(9e17 + 123);
        handler.dispatch(0, 1);
        handler.assertCustody();
        handler.claim(0);
        handler.withdraw(1, type(uint96).max);
        handler.pause(true);
        handler.buy(2, 0);
        handler.dispatch(0, 2);
        handler.dispatch(0, 0);
        handler.acknowledge(0, true);
        handler.acknowledge(0, false);
        handler.acknowledge(0, false);
        handler.dispatch(0, 0);
        handler.donate(17);
        handler.assertCustody();
        assertEq(handler.purchases(), 51);
        assertEq(handler.sends(), 1);
        assertEq(handler.failures(), 2);
        assertEq(handler.retries(), 2);
        assertEq(garden.confirmedBurn(), 9e17);
    }
}

/// @dev Base has its own supply/custody model. Minting below represents adapter credit or donation
///      in an offline fixture, never evidence that a real cross-chain transfer happened.
contract ReceiverCustodyHandler is Test {
    struct DeliveryModel {
        bytes32 guid;
        uint256 amount;
        uint32 attempts;
        bool burned;
        bool acknowledged;
    }

    EverlightBurnReceiver public immutable receiver;
    IMDOFTDouble public immutable token;
    EndpointDouble public immutable endpoint;
    address public immutable feePayer;
    DeliveryModel[] private deliveries;
    uint256 public donated;
    uint256 public received;
    uint256 public burned;
    uint256 public failures;
    uint256 public retries;
    uint256 public receipts;

    constructor(EverlightBurnReceiver r, address payer) {
        receiver = r;
        token = IMDOFTDouble(IMDBridge.BASE_IMD);
        endpoint = EndpointDouble(IMDBridge.ENDPOINT);
        feePayer = payer;
    }

    function deliver(uint64 unitsSeed, uint8 faultSeed) external {
        uint256 amount = (1 + uint256(unitsSeed) % 1_000_000) * 1e12;
        uint8 fault = faultSeed % 3;
        uint256 id = deliveries.length + 1;
        bytes32 guid = keccak256(abi.encode("receiver model", id));
        token.mint(address(receiver), amount);
        token.setBurnFailure(fault == 1, fault == 2);
        bytes memory payload = _message(id, amount);
        vm.prank(IMDBridge.ENDPOINT);
        receiver.lzCompose(IMDBridge.BASE_ADAPTER, guid, payload, address(this), "");
        deliveries.push(DeliveryModel(guid, amount, 1, fault == 0, false));
        received += amount;
        if (fault == 0) burned += amount;
        else ++failures;
        token.setBurnFailure(false, false);
    }

    function retry(uint256 indexSeed, uint8 faultSeed) external {
        if (deliveries.length == 0) return;
        DeliveryModel storage d = deliveries[indexSeed % deliveries.length];
        if (d.burned) {
            vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
            receiver.retryBurn(d.guid);
            return;
        }
        uint8 fault = faultSeed % 3;
        token.setBurnFailure(fault == 1, fault == 2);
        vm.prank(feePayer); // Permissionless recovery never acquires a withdrawal destination.
        receiver.retryBurn(d.guid);
        ++d.attempts;
        ++retries;
        if (fault == 0) {
            d.burned = true;
            burned += d.amount;
        } else {
            ++failures;
        }
        token.setBurnFailure(false, false);
    }

    function receipt(uint256 indexSeed, bool failEndpoint) external {
        if (deliveries.length == 0) return;
        DeliveryModel storage d = deliveries[indexSeed % deliveries.length];
        endpoint.setFailure(failEndpoint);
        uint256 beforeNative = feePayer.balance;
        vm.prank(feePayer);
        (bool ok, bytes memory result) =
            address(receiver).call{value: 1e14}(abi.encodeCall(receiver.sendBurnReceipt, (d.guid)));
        bool expected = d.burned && !d.acknowledged && !failEndpoint;
        assertEq(ok, expected);
        assertEq(feePayer.balance, beforeNative - (expected ? 1e14 : 0));
        if (expected) {
            d.acknowledged = true;
            ++receipts;
            assertEq(endpoint.lastReceiver(), IMDBridge.asBytes32(receiver.ethereumGarden()));
            assertEq(
                endpoint.lastMessage(),
                abi.encode(
                    uint8(2), receiver.configHash(), indexSeed % deliveries.length + 1, d.guid, d.amount
                )
            );
        } else if (!d.burned || d.acknowledged) {
            assertEq(result, abi.encodeWithSelector(EverlightBurnReceiver.InvalidDelivery.selector));
        } else {
            assertEq(result, abi.encodeWithSignature("Error(string)", "endpoint failure"));
        }
        endpoint.setFailure(false);
    }

    function replay(uint256 indexSeed, bool changeGuid) external {
        if (deliveries.length == 0) return;
        uint256 index = indexSeed % deliveries.length;
        DeliveryModel memory d = deliveries[index];
        bytes32 guid = changeGuid ? keccak256(abi.encode("duplicate job", d.guid)) : d.guid;
        bytes memory payload = _message(index + 1, d.amount);
        vm.prank(IMDBridge.ENDPOINT);
        vm.expectRevert(EverlightBurnReceiver.InvalidDelivery.selector);
        receiver.lzCompose(IMDBridge.BASE_ADAPTER, guid, payload, address(this), "");
    }

    function donate(uint64 amount) external {
        token.mint(address(receiver), amount);
        donated += amount;
    }

    function assertCustody() external view {
        uint256 pending;
        uint256 completed;
        uint256 acknowledged;
        for (uint256 i; i < deliveries.length; ++i) {
            DeliveryModel memory d = deliveries[i];
            (uint256 id, uint256 amount, uint32 attempts, EverlightBurnReceiver.Status status, bool ack) =
                receiver.deliveries(d.guid);
            assertEq(id, i + 1);
            assertEq(amount, d.amount);
            assertEq(attempts, d.attempts);
            assertEq(ack, d.acknowledged);
            assertEq(receiver.jobGuids(i + 1), d.guid);
            if (d.burned) {
                assertEq(uint256(status), uint256(EverlightBurnReceiver.Status.Burned));
                completed += amount;
            } else {
                assertEq(uint256(status), uint256(EverlightBurnReceiver.Status.Failed));
                assertFalse(ack, "unburned delivery cannot be acknowledged");
                pending += amount;
            }
            if (ack) ++acknowledged;
        }
        assertEq(receiver.totalReceived(), received);
        assertEq(receiver.totalBurned(), burned);
        assertEq(completed, burned);
        assertEq(pending + completed, received);
        assertEq(receiver.pendingBurn(), pending);
        assertEq(receiver.failedBurn(), pending);
        assertEq(receiver.totalFailures(), failures);
        assertEq(receiver.totalRetries(), retries);
        assertEq(receipts, acknowledged);
        assertEq(token.balanceOf(address(receiver)), donated + pending);
        assertEq(token.totalSupply(), donated + received - burned);
        assertEq(token.allowance(address(receiver), IMDBridge.BASE_ADAPTER), 0);
        assertEq(address(receiver).balance, 0);
    }

    function _message(uint256 id, uint256 amount) private view returns (bytes memory) {
        return abi.encodePacked(
            uint64(id), uint32(30101), amount, IMDBridge.asBytes32(receiver.ethereumGarden()), id
        );
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
contract ReceiverCustodyInvariantTest is GardenTestBase {
    ReceiverCustodyHandler private handler;

    function setUp() public override {
        super.setUp();
        _setupBase();
        handler = new ReceiverCustodyHandler(receiver, alice);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.deliver.selector;
        selectors[1] = handler.retry.selector;
        selectors[2] = handler.receipt.selector;
        selectors[3] = handler.replay.selector;
        selectors[4] = handler.donate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_deliveredTokensArePendingOrActuallySupplyBurnedExactlyOnce() public view {
        handler.assertCustody();
    }

    function test_receiverModelInterleavesFailuresOutOfOrderRecoveryAndReceiptRetry() public {
        handler.deliver(123, 1);
        handler.deliver(999, 0);
        handler.deliver(7, 2);
        handler.donate(27);
        handler.receipt(0, false);
        handler.receipt(1, true);
        handler.retry(2, 1);
        handler.retry(0, 0);
        handler.receipt(1, false);
        handler.retry(2, 0);
        handler.receipt(2, false);
        handler.replay(0, true);
        handler.replay(2, false);
        handler.retry(2, 0);
        handler.receipt(2, false);
        handler.assertCustody();
        assertEq(handler.receipts(), 2);
        assertEq(handler.failures(), 3);
        assertEq(handler.retries(), 3);
        assertEq(receiver.totalBurned(), 1132e12);
    }
}
