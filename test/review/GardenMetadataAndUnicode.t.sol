// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {GardenTestBase, WishGarden, WishGardenTreasury} from "../helpers/GardenTestBase.sol";
import {Utf8Wish} from "src/Utf8Wish.sol";

contract ReviewUtf8Harness {
    function validate(bytes calldata text) external pure {
        Utf8Wish.validate(string(text));
    }
}

contract GardenMetadataAndUnicodeTest is GardenTestBase {
    ReviewUtf8Harness private validator;
    event BucketWithdrawn(
        WishGardenTreasury.Bucket indexed bucket,
        address indexed caller,
        address indexed destination,
        uint256 amount
    );
    event RewardsClaimed(address indexed beneficiary, uint256 amount, uint256 cumulativeClaimed);

    function setUp() public override {
        super.setUp();
        validator = new ReviewUtf8Harness();
    }

    function test_indexingEventsContainEachOriginalWishAndCanonicalOrdering() public {
        uint8[] memory styles = new uint8[](3);
        styles[0] = 6;
        styles[1] = 0;
        styles[2] = 3;
        string[] memory wishes = new string[](3);
        wishes[0] = unicode"🕯 é <script>public text</script>";
        wishes[1] = "";
        wishes[2] = string(hex"410042e2808df48fbfbf");
        vm.prank(alice);
        token.approve(address(garden), 3e18);
        vm.recordLogs();
        vm.prank(alice);
        assertEq(garden.buyCandles(styles, wishes), 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 records;
        uint256 allocations;
        uint256 summaries;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(garden)) continue;
            if (entry.topics[0] == keccak256("RewardAllocated(uint256,uint256,uint256,bool)")) {
                ++allocations;
                assertEq(entry.topics.length, 2);
                assertEq(uint256(entry.topics[1]), allocations);
                (uint256 prior, uint256 increment, bool fallback_) =
                    abi.decode(entry.data, (uint256, uint256, bool));
                assertEq(prior, allocations - 1);
                assertEq(increment, prior == 0 ? 0 : uint256(6e17) * 1e27 / prior);
                assertEq(fallback_, prior == 0);
            } else if (
                entry.topics[0]
                    == keccak256("CandleCreated(uint256,address,address,uint256,uint8,uint64,string)")
            ) {
                assertEq(allocations, records + 1, "share must be allocated before the new record");
                assertEq(entry.topics.length, 4);
                assertEq(uint256(entry.topics[1]), records + 1);
                assertEq(entry.topics[2], bytes32(uint256(uint160(alice))));
                assertEq(entry.topics[3], bytes32(uint256(uint160(alice))));
                (uint256 position, uint8 style, uint64 createdAt, string memory wish) =
                    abi.decode(entry.data, (uint256, uint8, uint64, string));
                assertEq(position, records);
                assertEq(style, styles[records]);
                assertEq(createdAt, 1_800_000_000);
                assertEq(bytes(wish), bytes(wishes[records]));
                assertEq(
                    abi.encode(garden.getCandle(records + 1)),
                    abi.encode(WishGarden.Candle(alice, alice, createdAt, style, position, wish))
                );
                ++records;
            } else if (entry.topics[0] == keccak256("CandlesPurchased(address,uint256,uint256,uint256)")) {
                assertEq(records, 3);
                assertEq(entry.topics.length, 3);
                assertEq(entry.topics[1], bytes32(uint256(uint160(alice))));
                assertEq(uint256(entry.topics[2]), 1);
                assertEq(entry.data, abi.encode(uint256(3), uint256(3e18)));
                ++summaries;
            }
        }
        assertEq(records, 3);
        assertEq(allocations, 3);
        assertEq(summaries, 1);
    }

    function test_claimAndEveryFeeBucketEmitExactBeneficiaryDestinationAndAmount() public {
        _buy(alice, 2, 0);
        for (uint8 i = 1; i < 3; ++i) {
            vm.expectEmit(true, true, true, true, address(garden));
            emit BucketWithdrawn(WishGardenTreasury.Bucket(i), OWNER, carol, 101 + i);
            vm.prank(OWNER);
            garden.withdrawBucket(WishGardenTreasury.Bucket(i), carol, 101 + i);
        }
        vm.expectEmit(true, false, false, true, address(garden));
        emit RewardsClaimed(alice, 6e17, 6e17);
        vm.prank(alice);
        garden.claimRewards();
        _buy(bob, 1, 6);
        vm.expectEmit(true, false, false, true, address(garden));
        emit RewardsClaimed(alice, 6e17, 12e17);
        vm.prank(alice);
        garden.claimRewards();
        _assertSolvent();
    }

    function testFuzz_paginationReconstructsInterleavedRecordsWithoutDuplicates(
        uint8 countSeed,
        uint8 pageSeed
    ) public {
        uint256 n = 1 + uint256(countSeed) % 50;
        uint256 page = 1 + uint256(pageSeed) % 100;
        _buy(alice, n, 6);
        vm.warp(1_800_000_123);
        _buy(bob, n, 1);
        vm.warp(1_800_000_456);
        _buy(alice, n, 3);
        uint256 cursor = 1;
        while (cursor <= 3 * n) {
            (WishGarden.Candle[] memory candles, uint256 next) = garden.getCandles(cursor, page);
            assertGt(candles.length, 0);
            assertLe(candles.length, page);
            assertEq(next, cursor + candles.length);
            for (uint256 j; j < candles.length; ++j) {
                uint256 position = cursor + j - 1;
                uint256 phase = position / n;
                address expected = phase == 1 ? bob : alice;
                assertEq(candles[j].position, position);
                assertEq(candles[j].purchaser, expected);
                assertEq(candles[j].beneficiary, expected);
                assertEq(candles[j].style, phase == 0 ? 6 : phase == 1 ? 1 : 3);
                assertEq(
                    candles[j].createdAt,
                    phase == 0 ? 1_800_000_000 : phase == 1 ? 1_800_000_123 : 1_800_000_456
                );
            }
            cursor = next;
        }
        assertEq(cursor, 3 * n + 1);
        (WishGarden.Candle[] memory end, uint256 endCursor) = garden.getCandles(cursor, page);
        assertEq(end.length, 0);
        assertEq(endCursor, cursor);
        uint256 offset;
        while (offset < 2 * n) {
            (uint256[] memory ids, uint256 next) = garden.candleIdsOf(alice, offset, page);
            assertGt(ids.length, 0);
            assertLe(ids.length, page);
            for (uint256 j; j < ids.length; ++j) {
                uint256 index = offset + j;
                assertEq(ids[j], index < n ? index + 1 : index + n + 1);
            }
            assertEq(next, offset + ids.length);
            offset = next;
        }
        assertEq(garden.candleCountOf(alice), 2 * n);
        assertEq(garden.candleCountOf(bob), n);
        assertEq(garden.paidCandles(), 3 * n);
    }

    function test_emptyTerminalAndOutOfBoundsPages() public {
        (WishGarden.Candle[] memory empty, uint256 nextId) = garden.getCandles(1, 100);
        assertEq(empty.length, 0);
        assertEq(nextId, 1);
        (uint256[] memory ids, uint256 nextOffset) = garden.candleIdsOf(alice, 0, 100);
        assertEq(ids.length, 0);
        assertEq(nextOffset, 0);
        vm.expectRevert(abi.encodeWithSelector(WishGarden.CandleNotFound.selector, 0));
        garden.getCandle(0);
        vm.expectRevert(abi.encodeWithSelector(WishGarden.CandleNotFound.selector, 1));
        garden.getCandle(1);
        vm.expectRevert(WishGarden.InvalidPage.selector);
        garden.getCandles(type(uint256).max, 1);
        vm.expectRevert(WishGarden.InvalidPage.selector);
        garden.candleIdsOf(alice, type(uint256).max, 1);
        vm.expectRevert(WishGarden.InvalidPage.selector);
        garden.getCandles(1, 0);
        vm.expectRevert(WishGarden.InvalidPage.selector);
        garden.candleIdsOf(alice, 0, 0);
        vm.expectRevert(WishGarden.InvalidPage.selector);
        garden.candleIdsOf(alice, 0, 101);
    }

    function test_lateInvalidStyleRollsBackExistingRewardsAndEveryRecord() public {
        _buy(bob, 7, 0);
        bytes32 beforeState = _stateDigest();
        uint8[] memory styles = new uint8[](50);
        styles[49] = 7;
        string[] memory wishes = new string[](50);
        vm.startPrank(alice);
        token.approve(address(garden), 50e18);
        uint256 balance = token.balanceOf(alice);
        vm.expectRevert(abi.encodeWithSelector(WishGarden.InvalidStyle.selector, 7));
        garden.buyCandles(styles, wishes);
        vm.stopPrank();
        assertEq(_stateDigest(), beforeState);
        assertEq(garden.candleCountOf(alice), 0);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.allowance(alice, address(garden)), 50e18);
        vm.expectRevert(abi.encodeWithSelector(WishGarden.CandleNotFound.selector, 8));
        garden.getCandle(8);
    }

    /// @dev Independent byte-range grammar, while production decodes scalar values numerically.
    function testFuzz_arbitraryBytesAgreeWithStrictUtf8Grammar(bytes calldata text) public {
        bool valid = _validUtf8(text);
        if (!valid) vm.expectRevert();
        validator.validate(text);
    }

    function testFuzz_mixedWidthWishesCountCodepointsAndPersistExactBytes(uint16 countSeed, uint256 seed)
        public
    {
        uint256 count = bound(countSeed, 0, 281);
        bytes memory text;
        uint32[14] memory alphabet = [
            uint32(0),
            0x7f,
            0x80,
            0x7ff,
            0x800,
            0xd7ff,
            0xe000,
            0xffff,
            0x10000,
            0x10ffff,
            0x301,
            0x200d,
            0x1f56f,
            0xfe0f
        ];
        for (uint256 i; i < count; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            text = bytes.concat(text, _encode(alphabet[seed % alphabet.length]));
        }
        uint8[] memory styles = new uint8[](1);
        string[] memory wishes = new string[](1);
        wishes[0] = string(text);
        vm.startPrank(alice);
        token.approve(address(garden), 1e18);
        if (count > 280) vm.expectRevert(Utf8Wish.WishTooLong.selector);
        garden.buyCandles(styles, wishes);
        vm.stopPrank();
        if (count <= 280) {
            assertEq(bytes(garden.getCandle(1).wish), text);
            bytes32 original = keccak256(abi.encode(garden.getCandle(1)));
            vm.warp(block.timestamp + 100 * 365 days);
            _buy(bob, 1, 6);
            vm.prank(OWNER);
            garden.setPurchasesPaused(true);
            assertEq(keccak256(abi.encode(garden.getCandle(1))), original);
            vm.prank(alice);
            assertEq(garden.claimRewards(), 6e17, "permanent candle has no reward expiry");
        } else {
            assertEq(garden.totalCandles(), 0);
            assertEq(token.balanceOf(address(garden)), 0);
        }
    }

    function _stateDigest() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                garden.totalCandles(),
                garden.rewardPerCandle(),
                garden.rewardDustScaled(),
                garden.accountedBalance(),
                garden.claimableRewards(bob),
                garden.burnQueued(),
                garden.totalRewardsAllocated()
            )
        );
    }

    function _validUtf8(bytes calldata b) private pure returns (bool) {
        if (b.length > 1120) return false;
        uint256 count;
        uint256 i;
        while (i < b.length) {
            uint8 lead = uint8(b[i]);
            uint256 width;
            uint8 secondLow = 0x80;
            uint8 secondHigh = 0xbf;
            if (lead <= 0x7f) {
                width = 1;
            } else if (lead >= 0xc2 && lead <= 0xdf) {
                width = 2;
            } else if (lead >= 0xe0 && lead <= 0xef) {
                width = 3;
                if (lead == 0xe0) secondLow = 0xa0;
                if (lead == 0xed) secondHigh = 0x9f;
            } else if (lead >= 0xf0 && lead <= 0xf4) {
                width = 4;
                if (lead == 0xf0) secondLow = 0x90;
                if (lead == 0xf4) secondHigh = 0x8f;
            } else {
                return false;
            }
            if (i + width > b.length) return false;
            if (width > 1 && (uint8(b[i + 1]) < secondLow || uint8(b[i + 1]) > secondHigh)) return false;
            for (uint256 j = 2; j < width; ++j) {
                if (uint8(b[i + j]) < 0x80 || uint8(b[i + j]) > 0xbf) return false;
            }
            if (++count > 280) return false;
            i += width;
        }
        return true;
    }

    function _encode(uint32 cp) private pure returns (bytes memory) {
        if (cp < 0x80) return abi.encodePacked(uint8(cp));
        if (cp < 0x800) return abi.encodePacked(uint8(0xc0 | cp >> 6), uint8(0x80 | cp & 63));
        if (cp < 0x10000) {
            return
                abi.encodePacked(uint8(0xe0 | cp >> 12), uint8(0x80 | (cp >> 6) & 63), uint8(0x80 | cp & 63));
        }
        return abi.encodePacked(
            uint8(0xf0 | cp >> 18),
            uint8(0x80 | (cp >> 12) & 63),
            uint8(0x80 | (cp >> 6) & 63),
            uint8(0x80 | cp & 63)
        );
    }
}
