// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IStrategy
 * @notice Interface for vault yield strategies.
 * @dev A strategy is responsible for deploying vault assets into external DeFi protocols
 *      to generate yield. The Vault delegates fund management to a strategy implementation
 *      that conforms to this interface.
 *
 *      Lifecycle:
 *        1. Vault calls `beforeDeposit()` — strategy can harvest or rebalance before new funds arrive.
 *        2. Vault calls `deposit()` / `depositNative()` — strategy deploys the funds.
 *        3. Vault calls `withdraw()` / `withdrawNative()` — strategy returns funds to the user.
 *        4. Anyone can call `earn()` to query pending yield, or `claim()` to collect rewards.
 */
interface IStrategy {

    /// @notice Returns the underlying ERC20 asset token managed by this strategy.
    /// @return The IERC20 token address that this strategy operates on.
    function asset() external view returns (IERC20);

    /// @notice Hook called by the vault before a new deposit is processed.
    /// @dev Strategies can use this to harvest pending rewards or rebalance positions
    ///      to ensure accurate share pricing for the incoming deposit.
    function beforeDeposit() external;

    /// @notice Deposits ERC20 tokens into the strategy for yield generation.
    /// @dev Called by the vault after transferring tokens to the strategy.
    ///      The strategy should deploy these funds into the underlying protocol.
    /// @param vault The address of the vault initiating the deposit.
    /// @param amount The amount of ERC20 tokens to deploy.
    function deposit(address vault, uint256 amount) external;

    /// @notice Deposits native currency (e.g., ETH) into the strategy for yield generation.
    /// @dev Called by the vault with native currency attached via msg.value.
    /// @param vault The address of the vault initiating the deposit.
    function depositNative(address vault) external payable;

    /// @notice Withdraws ERC20 tokens from the strategy and sends them to the recipient.
    /// @dev The strategy should unwind positions as needed and transfer tokens directly
    ///      to the specified user address.
    /// @param user The recipient address to receive the withdrawn tokens.
    /// @param amount The amount of ERC20 tokens to withdraw.
    function withdraw(address user, uint256 amount) external;

    /// @notice Withdraws native currency from the strategy and sends it to the recipient.
    /// @dev The strategy should unwind positions as needed and transfer native currency
    ///      directly to the specified user address.
    /// @param user The recipient address to receive the withdrawn native currency.
    /// @param amount The amount of native currency (in wei) to withdraw.
    function withdrawNative(address user, uint256 amount) external payable;

    /// @notice Returns the total balance of assets currently managed by this strategy.
    /// @dev Should include both idle and deployed assets within the strategy.
    /// @return The total asset balance held by the strategy.
    function balanceOf() external view returns (uint256);

    /// @notice Returns the amount of pending yield that has not yet been harvested.
    /// @return The amount of unharvested yield/rewards.
    function earn() external view returns (uint256);

    /// @notice Claims accumulated rewards and sends them to the specified address.
    /// @param user The address to receive the claimed rewards.
    function claim(address user) external;
}
