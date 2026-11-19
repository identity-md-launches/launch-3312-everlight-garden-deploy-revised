// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Fixed Ethereum IMD economy shared by the garden and its treasury.
abstract contract GardenEconomy {
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 public constant CHAIN_ID = 1;
    uint8 public constant IMD_DECIMALS = 18;
    uint256 public constant CANDLE_PRICE = 1e18;
    uint256 public constant MAX_BATCH_SIZE = 50;
    uint256 public constant BURN_ALLOCATION_PER_CANDLE = 0.3e18;
    uint256 public constant REWARD_PER_CANDLE = 0.6e18;
    uint256 public constant ECOSYSTEM_PER_CANDLE = 0;
    uint256 public constant OPERATIONS_PER_CANDLE = 0.05e18;
    uint256 public constant FOUNDER_PER_CANDLE = 0.05e18;

    error WrongChain(uint256 actualChainId);
    error IMDUnavailable();
    error UnexpectedIMDDecimals(uint8 actualDecimals);
    error InvalidQuantity(uint256 quantity);
    error InexactTransfer();
    error InvalidAddress();

    function _requireEthereum() internal view {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
    }

    function _requireIMD() internal view {
        _requireEthereum();
        if (IMD.code.length == 0) revert IMDUnavailable();
        uint8 decimals = IERC20Metadata(IMD).decimals();
        if (decimals != IMD_DECIMALS) revert UnexpectedIMDDecimals(decimals);
    }

    function _checkQuantity(uint256 quantity) internal pure {
        if (quantity == 0 || quantity > MAX_BATCH_SIZE) revert InvalidQuantity(quantity);
    }
}
