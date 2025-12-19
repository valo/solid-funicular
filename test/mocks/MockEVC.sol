// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IEVCMinimal} from "../../src/refinance/EulerRefinanceAdapter.sol";

/// @dev Minimal mock of the Ethereum Vault Connector to forward batch calls.
contract MockEVC is IEVCMinimal {
    address public currentAccount;

    function batch(BatchItem[] calldata items) external payable {
        for (uint256 i = 0; i < items.length; i++) {
            currentAccount = items[i].onBehalfOfAccount;
            (bool ok,) = items[i].targetContract.call{value: items[i].value}(items[i].data);
            if (!ok) {
                revert("batch-failed");
            }
        }
        currentAccount = address(0);
    }
}
