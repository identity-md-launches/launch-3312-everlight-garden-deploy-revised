// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Strict Unicode scalar-value UTF-8. No normalization: original bytes are permanent.
library Utf8Wish {
    error InvalidUTF8();
    error WishTooLong();

    function validate(string calldata text) internal pure {
        bytes calldata b = bytes(text);
        if (b.length > 1120) revert WishTooLong();
        uint256 count = 0;
        uint256 i = 0;
        while (i < b.length) {
            uint8 c = uint8(b[i]);
            uint256 n;
            uint32 cp;
            uint32 minimum = 0;
            if (c < 0x80) {
                n = 1;
                cp = c;
            } else if (c >= 0xc2 && c <= 0xdf) {
                n = 2;
                cp = c & 0x1f;
                minimum = 0x80;
            } else if (c >= 0xe0 && c <= 0xef) {
                n = 3;
                cp = c & 0x0f;
                minimum = 0x800;
            } else if (c >= 0xf0 && c <= 0xf4) {
                n = 4;
                cp = c & 0x07;
                minimum = 0x10000;
            } else {
                revert InvalidUTF8();
            }
            if (i + n > b.length) revert InvalidUTF8();
            for (uint256 j = 1; j < n; ++j) {
                uint8 continuation = uint8(b[i + j]);
                if (continuation < 0x80 || continuation > 0xbf) revert InvalidUTF8();
                cp = (cp << 6) | (continuation & 0x3f);
            }
            if (cp < minimum || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) revert InvalidUTF8();
            if (++count > 280) revert WishTooLong();
            i += n;
        }
    }
}
