// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GardenTestBase} from "./helpers/GardenTestBase.sol";
import {Utf8Wish} from "../src/Utf8Wish.sol";

contract WishValidator {
    function validate(string calldata wish) external pure {
        Utf8Wish.validate(wish);
    }
}

contract UnicodeTest is GardenTestBase {
    WishValidator internal validator;

    function setUp() public override {
        super.setUp();
        validator = new WishValidator();
    }

    function test_validEmptyAsciiBoundariesAndFourByteMaximum() public view {
        validator.validate("");
        validator.validate(unicode"🕯 health мир שלום 中文 é");
        bytes memory ascii = new bytes(280);
        validator.validate(string(ascii));
        bytes memory four = new bytes(1120);
        for (uint256 i; i < 280; ++i) {
            four[4 * i] = 0xf4;
            four[4 * i + 1] = 0x8f;
            four[4 * i + 2] = 0xbf;
            four[4 * i + 3] = 0xbf;
        }
        validator.validate(string(four));
        validator.validate(string(hex"007fc280dfbfe0a080ed9fbfefbfbff0908080f48fbfbf"));
    }

    function test_rejectsOverlongSurrogateOutOfRangeTruncatedAndStrayBytes() public {
        bytes[12] memory bad = [
            bytes(hex"80"),
            hex"c0af",
            hex"c1bf",
            hex"e080af",
            hex"eda080",
            hex"edbfbf",
            hex"f0808080",
            hex"f4908080",
            hex"f5808080",
            hex"ff",
            hex"e282",
            hex"c241"
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(Utf8Wish.InvalidUTF8.selector);
            validator.validate(string(bad[i]));
        }
        vm.expectRevert(Utf8Wish.WishTooLong.selector);
        validator.validate(string(new bytes(281)));
        vm.expectRevert(Utf8Wish.WishTooLong.selector);
        validator.validate(string(new bytes(1121)));
    }

    function testFuzz_rejectsAllSurrogates(uint16 seed) public {
        uint32 cp = uint32(bound(seed, 0xd800, 0xdfff));
        bytes memory encoded = abi.encodePacked(
            uint8(0xe0 | (cp >> 12)), uint8(0x80 | ((cp >> 6) & 0x3f)), uint8(0x80 | (cp & 0x3f))
        );
        vm.expectRevert(Utf8Wish.InvalidUTF8.selector);
        validator.validate(string(encoded));
    }

    function testFuzz_validUnicodeScalars(uint32 seed) public view {
        uint32 cp = uint32(bound(seed, 0, 0x10ffff));
        if (cp >= 0xd800 && cp <= 0xdfff) return;
        bytes memory encoded;
        if (cp < 0x80) {
            encoded = abi.encodePacked(uint8(cp));
        } else if (cp < 0x800) {
            encoded = abi.encodePacked(uint8(0xc0 | (cp >> 6)), uint8(0x80 | (cp & 0x3f)));
        } else if (cp < 0x10000) {
            encoded = abi.encodePacked(
                uint8(0xe0 | (cp >> 12)), uint8(0x80 | ((cp >> 6) & 0x3f)), uint8(0x80 | (cp & 0x3f))
            );
        } else {
            encoded = abi.encodePacked(
                uint8(0xf0 | (cp >> 18)),
                uint8(0x80 | ((cp >> 12) & 0x3f)),
                uint8(0x80 | ((cp >> 6) & 0x3f)),
                uint8(0x80 | (cp & 0x3f))
            );
        }
        validator.validate(string(encoded));
    }
}
