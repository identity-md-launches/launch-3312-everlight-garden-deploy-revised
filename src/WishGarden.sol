// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EverlightBridgeQueue} from "./bridge/EverlightBridgeQueue.sol";
import {Utf8Wish} from "./Utf8Wish.sol";

/// @notice EVERLIGHT GARDEN: paid, permanent, nontransferable records. No NFT or free entitlement.
contract WishGarden is EverlightBridgeQueue {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    uint8 public constant STYLE_COUNT = 7;
    uint256 public constant MAX_PAGE_SIZE = 100;

    struct Candle {
        address purchaser;
        address beneficiary;
        uint64 createdAt;
        uint8 style;
        uint256 position;
        string wish;
    }
    mapping(uint256 => Candle) private _candles;
    mapping(address => uint256[]) private _purchaserCandles;
    error PurchasesDisabled();
    error InvalidStyle(uint8 style);
    error LengthMismatch();
    error CandleNotFound(uint256 candleId);
    error InvalidPage();
    event CandleCreated(
        uint256 indexed candleId,
        address indexed purchaser,
        address indexed beneficiary,
        uint256 position,
        uint8 style,
        uint64 createdAt,
        string wish
    );
    event CandlesPurchased(
        address indexed purchaser, uint256 indexed firstCandleId, uint256 quantity, uint256 totalIMD
    );

    /// @dev Factory-safe: no external calls, explicit owner, static argument, no ETH or initializer.
    constructor(address owner_) EverlightBridgeQueue(owner_) {}

    /// @notice Buy 1..50 candles with individual styles and public, immutable wishes (empty is optional).
    /// @dev Purchaser is always beneficiary. Only msg.sender's IMD can be spent.
    function buyCandles(uint8[] calldata styles, string[] calldata wishes)
        external
        nonReentrant
        returns (uint256 firstCandleId)
    {
        if (!activated || purchasesPaused) revert PurchasesDisabled();
        uint256 quantity = styles.length;
        _checkQuantity(quantity);
        if (quantity != wishes.length) revert LengthMismatch();
        // Bridge route state is NOT a purchase precondition: it is checked when burn funds are dispatched.
        _requireIMD();
        firstCandleId = totalCandles + 1;
        uint64 createdAt = block.timestamp.toUint64();
        for (uint256 i; i < quantity; ++i) {
            if (styles[i] >= STYLE_COUNT) revert InvalidStyle(styles[i]);
            Utf8Wish.validate(wishes[i]);
            _allocateCandle(msg.sender);
            uint256 id = totalCandles;
            _candles[id] = Candle(msg.sender, msg.sender, createdAt, styles[i], id - 1, wishes[i]);
            _purchaserCandles[msg.sender].push(id);
            emit CandleCreated(id, msg.sender, msg.sender, id - 1, styles[i], createdAt, wishes[i]);
        }
        uint256 payment = quantity * CANDLE_PRICE;
        IERC20 token = IERC20(IMD);
        uint256 heldBefore = token.balanceOf(address(this));
        uint256 buyerBefore = token.balanceOf(msg.sender);
        token.safeTransferFrom(msg.sender, address(this), payment);
        if (
            token.balanceOf(address(this)) != heldBefore + payment
                || token.balanceOf(msg.sender) != buyerBefore - payment
        ) {
            revert InexactTransfer();
        }
        emit CandlesPurchased(msg.sender, firstCandleId, quantity, payment);
    }

    function getCandle(uint256 id) external view returns (Candle memory) {
        if (id == 0 || id > totalCandles) revert CandleNotFound(id);
        return _candles[id];
    }

    function candleCountOf(address purchaser) external view returns (uint256) {
        return _purchaserCandles[purchaser].length;
    }

    function candleIdsOf(address purchaser, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 nextOffset)
    {
        uint256 length = _purchaserCandles[purchaser].length;
        if (limit == 0 || limit > MAX_PAGE_SIZE || offset > length) revert InvalidPage();
        uint256 count = length - offset;
        if (count > limit) count = limit;
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = _purchaserCandles[purchaser][offset + i];
        }
        nextOffset = offset + count;
    }

    function getCandles(uint256 firstId, uint256 limit)
        external
        view
        returns (Candle[] memory records, uint256 nextId)
    {
        if (limit == 0 || limit > MAX_PAGE_SIZE || firstId == 0 || firstId > totalCandles + 1) {
            revert InvalidPage();
        }
        uint256 count = totalCandles + 1 - firstId;
        if (count > limit) count = limit;
        records = new Candle[](count);
        for (uint256 i; i < count; ++i) {
            records[i] = _candles[firstId + i];
        }
        nextId = firstId + count;
    }
}
