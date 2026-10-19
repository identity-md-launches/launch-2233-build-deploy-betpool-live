// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only code etched at the two fixed token addresses. Never a launch application.
contract MockToken is ERC20 {
    bool public failTransfer;
    bool public returnFalse;
    bool public returnNothing;
    uint256 public transferTax;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackOnTransferFrom;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes public callbackResult;
    bool private inCallback;

    constructor() ERC20("Test Token", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBehavior(bool fail, bool falseReturn, bool noReturn, uint256 tax) external {
        failTransfer = fail;
        returnFalse = falseReturn;
        returnNothing = noReturn;
        transferTax = tax;
    }

    function setCallback(address target, bytes calldata data, bool onTransferFrom) external {
        callbackTarget = target;
        callbackData = data;
        callbackOnTransferFrom = onTransferFrom;
        callbackAttempted = false;
        callbackSucceeded = false;
        delete callbackResult;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!failTransfer, "mock transfer failure");
        super.transfer(to, amount);
        if (!callbackOnTransferFrom) _callback();
        if (returnNothing) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return !returnFalse;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!failTransfer, "mock transfer failure");
        super.transferFrom(from, to, amount);
        if (callbackOnTransferFrom) _callback();
        if (returnNothing) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return !returnFalse;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && transferTax != 0) {
            uint256 tax = amount * transferTax / 10_000;
            super._update(from, address(0), tax);
            amount -= tax;
        }
        super._update(from, to, amount);
    }

    function _callback() private {
        if (callbackTarget == address(0) || inCallback) return;
        inCallback = true;
        callbackAttempted = true;
        (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        inCallback = false;
    }
}
