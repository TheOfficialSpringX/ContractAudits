// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title IVault
 * @notice Interface for the asset custody vault.
 * @dev The vault is responsible for:
 *      - Accepting user deposits (ERC20 or native currency) via the mainChef.
 *      - Tracking per-user balances.
 *      - Optionally delegating funds to an IStrategy for yield generation.
 *      - Processing withdrawals back to users.
 *
 *      The vault does NOT directly interact with end users — all deposit/withdraw
 *      calls are routed through the mainChef contract for access control.
 */
interface IVault {

    /// @notice Deposits assets into the vault on behalf of a user.
    /// @dev Only callable by the mainChef. For native currency deposits, the amount
    ///      is determined by msg.value. For ERC20 deposits, tokens are transferred
    ///      from the mainChef to the vault. Handles fee-on-transfer tokens by
    ///      measuring actual received amount.
    /// @param _userAddr The address of the user making the deposit.
    /// @param _amount The nominal amount of ERC20 tokens to deposit (ignored for native deposits).
    /// @return The actual amount deposited after accounting for any transfer fees.
    function depositTokenToVault(address _userAddr, uint256 _amount) external payable returns (uint256);

    /// @notice Withdraws assets from the vault and sends them to the user.
    /// @dev Only callable by the mainChef. The user must have sufficient balance
    ///      recorded in the vault. Withdrawals are sourced from the strategy first
    ///      (if one is configured), otherwise directly from the vault.
    /// @param _userAddr The address of the user receiving the withdrawal.
    /// @param _amount The amount of assets to withdraw.
    /// @return The actual amount withdrawn.
    function withdrawTokenFromVault(address _userAddr, uint256 _amount) external returns (uint256);

    /// @notice Returns the total vault balance including any funds deployed to the strategy.
    /// @dev Aggregates the vault's local balance with the strategy's reported balance.
    /// @return The total asset balance (vault + strategy).
    function balance() external view returns (uint256);

    /// @notice Returns only the vault's local balance, excluding strategy-deployed funds.
    /// @dev Useful for determining how much liquidity is immediately available
    ///      without withdrawing from the strategy.
    /// @return The vault's local asset balance.
    function vaultBalance() external view returns (uint256);
}
