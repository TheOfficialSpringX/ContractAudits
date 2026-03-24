// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TransferTokenHelper
 * @notice A library for safe ERC20 token and native currency transfers.
 * @dev Uses low-level `call` to handle non-standard ERC20 tokens (e.g., USDT)
 *      that do not return a boolean value on transfer/approve operations.
 *      The safety check pattern `success && (data.length == 0 || abi.decode(data, (bool)))`
 *      ensures compatibility with both standard and non-standard ERC20 implementations.
 */
library TransferTokenHelper {

    /**
     * @notice Safely approves a spender to spend a specified amount of ERC20 tokens.
     * @dev Uses low-level call to support tokens that don't return bool on approve.
     * @param token The address of the ERC20 token contract.
     * @param to The address of the spender being approved.
     * @param value The amount of tokens to approve.
     */
    function safeTokenApprove(address token, address to, uint value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20.approve, (to, value)));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferTokenHelper -> safeTokenApprove: Approve Token FAILED');
    }

    /**
     * @notice Safely transfers ERC20 tokens from the calling contract to a recipient.
     * @dev Uses low-level call to support tokens that don't return bool on transfer.
     * @param token The address of the ERC20 token contract.
     * @param to The recipient address.
     * @param value The amount of tokens to transfer.
     */
    function safeTokenTransfer(address token, address to, uint value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20.transfer, (to, value)));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferTokenHelper -> safeTokenTransfer: Transfer Token FAILED');
    }

    /**
     * @notice Safely transfers ERC20 tokens from one address to another using transferFrom.
     * @dev Requires prior approval from the `from` address. Uses low-level call
     *      to support tokens that don't return bool on transferFrom.
     * @param token The address of the ERC20 token contract.
     * @param from The address to transfer tokens from (must have approved the caller).
     * @param to The recipient address.
     * @param value The amount of tokens to transfer.
     */
    function safeTokenTransferFrom(address token, address from, address to, uint value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20.transferFrom, (from, to, value)));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferTokenHelper -> safeTokenTransferFrom: Transfer Token From Origin FAILED');
    }

    /**
     * @notice Safely transfers native currency (e.g., ETH) to a recipient.
     * @dev Uses low-level call with empty data payload. Reverts if the transfer fails.
     * @param to The recipient address.
     * @param value The amount of native currency to transfer (in wei).
     */
    function safeTransferNative(address to, uint value) internal {
        (bool success,) = to.call{value: value}(new bytes(0));
        require(success, 'TransferTokenHelper -> safeTransferNative: Transfer Native FAILED');
    }
}
