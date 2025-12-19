// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract ReentrantERC20 is MockERC20 {
    address public reenterTarget;
    bytes public reenterData;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_, decimals_) {}

    function setReenter(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        _maybeReenter();
        return ok;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        _maybeReenter();
        return ok;
    }

    function _maybeReenter() internal {
        if (reenterTarget != address(0)) {
            (bool success, ) = reenterTarget.call(reenterData);
            require(success, "reenter failed");
        }
    }
}
