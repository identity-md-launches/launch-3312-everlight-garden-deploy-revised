// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only fault injection at the fixed IMD address. Never part of deployment.
contract AdversarialIMD is ERC20 {
    uint8 public pullMode;
    uint8 public pushMode;
    address public affectedDestination;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackOnPull;
    bool public callbackOnPush;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes public callbackResult;
    bool private _inCallback;

    constructor() ERC20("Test fault injector", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configureModes(uint8 pull, uint8 push, address destination) external {
        pullMode = pull;
        pushMode = push;
        affectedDestination = destination;
    }

    function configureCallback(address target, bytes calldata data, bool onPull, bool onPush) external {
        callbackTarget = target;
        callbackData = data;
        callbackOnPull = onPull;
        callbackOnPush = onPush;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (callbackOnPull) _callback();
        if (pullMode == 3) return true; // Lies about moving tokens.
        bool result = super.transferFrom(from, to, amount);
        if (pullMode == 1) return false;
        if (pullMode == 2) _burn(to, 1); // Recipient gets too little.
        if (pullMode == 4) _burn(from, 1); // Sender pays more than the exact candle price.
        if (pullMode == 5) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return result;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (callbackOnPush) _callback();
        uint8 mode = (affectedDestination == address(0) || affectedDestination == to) ? pushMode : 0;
        if (mode == 3) return true;
        bool result = super.transfer(to, amount);
        if (mode == 1) return false;
        if (mode == 2) _burn(to, 1);
        if (mode == 4) _burn(msg.sender, 1);
        if (mode == 5) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return result;
    }

    function _callback() private {
        if (_inCallback || callbackTarget == address(0)) return;
        _inCallback = true;
        callbackAttempted = true;
        (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        _inCallback = false;
    }
}
