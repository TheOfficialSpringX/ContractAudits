// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../common/TransferTokenHelper.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/IVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SpringXVault
 * @notice Upgradeable asset custody vault that supports both ERC20 tokens and native currency.
*/
contract SpringXVault is IVault, Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    //  Data Structures
    // ──────────────────────────────────────────────

    /// @dev Tracks the total amount of underlying tokens deposited by each user.
    ///      Used for balance accounting on withdrawals.
    struct VaultUserInfo {
        uint256 amount;
    }

    // ──────────────────────────────────────────────
    //  State Variables
    // ──────────────────────────────────────────────

    /// @notice The yield strategy contract that this vault delegates funds to.
    /// @dev Can be address(0) if no strategy is attached — vault simply holds funds.
    IStrategy public strategy;

    /// @notice The ERC20 token that this vault accepts as deposits.
    /// @dev If this equals `nativeAddress`, the vault operates in native currency mode.
    IERC20 public assets;

    /// @notice The total amount of assets deposited across all users.
    /// @dev Maintained independently from actual token balance to track user deposits accurately.
    uint256 public totalAssets;

    /// @notice The mainChef contract address — the only address allowed to call deposit/withdraw.
    /// @dev Acts as an access control gateway between end users and the vault.
    address public mainChef;

    /// @notice A sentinel address used to identify native currency (e.g., ETH) operations.
    /// @dev When `address(assets) == nativeAddress`, the vault uses msg.value and native transfers
    ///      instead of ERC20 transfer calls.
    address public nativeAddress;

    /// @notice Maps user addresses to their deposit information.
    mapping(address => VaultUserInfo) public userInfoMap;

    /// @dev Reserved storage gap for future upgrades (50 slots)
    uint256[50] private __gap;

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /// @notice Emitted when a user deposits assets into the vault.
    /// @param user The address that deposited.
    /// @param amount The actual deposited amount (after any transfer fees).
    event DepositTokenToVault(address indexed user, uint256 amount);

    /// @notice Emitted when a user withdraws assets from the vault.
    /// @param user The address that withdrew.
    /// @param amount The amount withdrawn.
    event WithdrawTokenFromVault(address indexed user, uint256 amount);

    /// @notice Emitted when the owner sets or updates the yield strategy.
    event SetVaultStrategy(address indexed strategyAddr);

    /// @notice Emitted when the owner updates the mainChef address.
    event SetMainChef(address indexed mainChef);

    /// @notice Emitted when the owner updates the native currency sentinel address.
    event SetCoreAddress(address indexed _ethAddr);

    /// @notice Emitted when the owner updates the vault's asset token.
    event SetAssets(address indexed _assetsAddr);

    /// constructor
    constructor() {
        _disableInitializers();
    }

    // ──────────────────────────────────────────────
    //  Initialization
    // ──────────────────────────────────────────────

    /// @notice Initializes the vault with core configuration.
    /// @dev Replaces the constructor for upgradeable contracts. Can only be called once.
    /// @param _assets The ERC20 token this vault manages (or native sentinel address).
    /// @param _nativeAddress The sentinel address representing native currency.
    /// @param _mainChef The mainChef contract authorized to call deposit/withdraw.
    function initialize(
        IERC20 _assets,
        address _nativeAddress,
        address _mainChef
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        assets = _assets;
        nativeAddress = _nativeAddress;
        mainChef = _mainChef;
    }

    // ──────────────────────────────────────────────
    //  Owner Configuration
    // ──────────────────────────────────────────────

    /// @notice Attaches or replaces the yield strategy for this vault.
    /// @dev When a new strategy is set:
    ///      - For ERC20 vaults: resets and grants max approval, then transfers all held tokens.
    ///      - For native vaults: transfers all held native currency to the strategy.
    ///      Setting strategy to address(0) detaches any existing strategy.
    /// @param _strategy The new strategy contract (or address(0) to detach).
    function setVaultStrategy(IStrategy _strategy) external onlyOwner {
        IStrategy oldStrategy = strategy;

        // Recall funds and revoke approval from old strategy before replacing.
        if (address(oldStrategy) != address(0)) {
            if (address(assets) != nativeAddress) {
                uint256 oldBal = oldStrategy.balanceOf();
                if (oldBal > 0) {
                    oldStrategy.withdraw(address(this), oldBal);
                }
                IERC20(assets).forceApprove(address(oldStrategy), 0);
            } else {
                uint256 oldBal = oldStrategy.balanceOf();
                if (oldBal > 0) {
                    oldStrategy.withdrawNative(address(this), oldBal);
                }
            }
        }

        strategy = _strategy;

        if (address(_strategy) != address(0)) {
            if (address(assets) != nativeAddress) {
                // forceApprove handles non-bool-returning tokens (e.g. USDT0)
                IERC20(assets).forceApprove(address(_strategy), type(uint256).max);
                transferERC20ToStrategy();
            } else {
                transferNativeToStrategy();
            }
        }

        emit SetVaultStrategy(address(_strategy));
    }

    /// @notice Updates the mainChef address that is authorized to call deposit/withdraw.
    /// @param _mainChef The new mainChef contract address.
    function setMainChef(address _mainChef) external onlyOwner {
        mainChef = _mainChef;

        emit SetMainChef(address(_mainChef));
    }

    /// @notice Updates the sentinel address used to identify native currency operations.
    /// @param _coreAddress The new native currency sentinel address.
    function setCoreAddress(address _coreAddress) external onlyOwner {
        require(totalAssets == 0, "Cannot change mode with active deposits");
        nativeAddress = _coreAddress;

        emit SetCoreAddress(_coreAddress);
    }

    /// @notice Updates the ERC20 asset token managed by this vault.
    /// @param _assets The new asset token address.
    function setAssets(IERC20 _assets) external onlyOwner {
        require(totalAssets == 0, "Cannot change asset with active deposits");
        assets = _assets;

        emit SetAssets(address(_assets));
    }

    // ──────────────────────────────────────────────
    //  View Functions
    // ──────────────────────────────────────────────

    /// @notice Returns the vault's local token balance, excluding any funds in the strategy.
    /// @dev For native currency vaults, this returns address(this).balance instead.
    ///      Useful for checking immediately available liquidity.
    /// @return The amount of assets held directly by the vault contract.
    function vaultBalance() external view returns (uint256) {
        if (address(assets) == nativeAddress) {
            return address(this).balance;
        }
        return assets.balanceOf(address(this));
    }

    /// @notice Returns the total vault balance including funds deployed to the strategy.
    /// @dev Aggregates:
    ///      - For ERC20: vault's token balance + strategy.balanceOf()
    ///      - For native: address(this).balance + strategy.balanceOf()
    ///      If no strategy is attached, only the local balance is returned.
    /// @return The total asset balance across vault and strategy.
    function balance() public view returns (uint256) {
        if (address(assets) == nativeAddress) {
            if (address(strategy) != address(0)) {
                return address(this).balance + IStrategy(strategy).balanceOf();
            } else {
                return address(this).balance;
            }
        } else {
            if (address(strategy) != address(0)) {
                return assets.balanceOf(address(this)) + IStrategy(strategy).balanceOf();
            } else {
                return assets.balanceOf(address(this));
            }
        }
    }

    // ──────────────────────────────────────────────
    //  Deposit Logic
    // ──────────────────────────────────────────────

    /// @notice Deposits assets into the vault on behalf of a user.
    /// @dev Access restricted to mainChef only. Flow:
    ///      1. Calls strategy.beforeDeposit() if a strategy is attached (for harvest/rebalance).
    ///      2. Routes to _depositETH() or _deposit() based on asset type.
    ///      3. Updates user balance and totalAssets.
    ///      4. Forwards funds to strategy if one is attached.
    /// @param _userAddr The user address to credit the deposit to.
    /// @param _amount The nominal amount of ERC20 tokens to deposit (ignored for native).
    /// @return The actual deposited amount (may differ from _amount for fee-on-transfer tokens).
    function depositTokenToVault(address _userAddr, uint256 _amount) public payable nonReentrant returns (uint256){
        require(msg.sender == mainChef, "!mainChef");
        require(_userAddr != address(0), "user address cannot be zero address");

        // Allow strategy to harvest or rebalance before accepting new funds.
        if (address(strategy) != address(0)) {
            strategy.beforeDeposit();
        }

        uint256 _depositAmount;
        if (address(assets) == nativeAddress) {
            // Native currency deposit: amount comes from msg.value.
            _depositAmount = _depositETH(_userAddr, msg.value);
        } else {
            // ERC20 deposit: tokens are pulled from the mainChef.
            _depositAmount = _deposit(_userAddr, mainChef, _amount);
        }

        emit DepositTokenToVault(_userAddr, _depositAmount);

        return _depositAmount;
    }

    /// @dev Processes a native currency (ETH) deposit.
    ///      Updates user balance tracking, then forwards to strategy if one is attached.
    /// @param _userAddr The user address to credit.
    /// @param _amount The amount of native currency received (msg.value).
    /// @return The deposited amount.
    function _depositETH(address _userAddr, uint256 _amount) private returns (uint256){
        VaultUserInfo storage _userInfo = userInfoMap[_userAddr];

        _userInfo.amount = _userInfo.amount + _amount;
        totalAssets = totalAssets + _amount;

        // Forward native currency to strategy for yield deployment.
        if (address(strategy) != address(0)) {
            IStrategy(strategy).depositNative{value: _amount}(address(this));
        }

        return _amount;
    }

    /// @dev Processes an ERC20 token deposit with fee-on-transfer support.
    ///      Measures actual received amount by comparing balance before and after transfer,
    ///      ensuring correct accounting for deflationary or fee-on-transfer tokens (VT-4 fix).
    /// @param _userAddr The user address to credit.
    /// @param _mainChef The address to pull tokens from (the mainChef contract).
    /// @param _amount The nominal amount of tokens to transfer.
    /// @return The actual amount received after any transfer fees.
    function _deposit(address _userAddr, address _mainChef, uint256 _amount) private returns (uint256){
        VaultUserInfo storage _userInfo = userInfoMap[_userAddr];

        // Snapshot balance before transfer to detect fee-on-transfer tokens.
        uint256 _poolBalance = balance();
        TransferTokenHelper.safeTokenTransferFrom(address(assets), _mainChef, address(this), _amount);

        // Calculate actual received amount by comparing balances.
        uint256 _afterPoolBalance = balance();
        uint256 _depositAmount = _afterPoolBalance - _poolBalance;

        _userInfo.amount = _userInfo.amount + _depositAmount;
        totalAssets = totalAssets + _depositAmount;

        // Forward to strategy using actual deposited amount, not nominal (VT-4 fix).
        if (address(strategy) != address(0)) {
            IStrategy(strategy).deposit(address(this), _depositAmount);
        }

        return _depositAmount;
    }

    // ──────────────────────────────────────────────
    //  Withdrawal Logic
    // ──────────────────────────────────────────────

    /// @notice Withdraws assets from the vault and sends them to the user.
    /// @dev Access restricted to mainChef only. Flow:
    ///      1. Validates user has sufficient balance.
    ///      2. Decrements user balance and totalAssets.
    ///      3. If strategy is attached: delegates withdrawal to strategy (sends directly to user).
    ///      4. If no strategy: transfers directly from vault to user.
    /// @param _userAddr The user address to send assets to.
    /// @param _amount The amount of assets to withdraw.
    /// @return The amount withdrawn.
    function withdrawTokenFromVault(address _userAddr, uint256 _amount) public nonReentrant returns (uint256){
        require(msg.sender == mainChef, "!mainChef");
        require(_userAddr != address(0), "User address cannot be zero address");

        VaultUserInfo storage _userInfo = userInfoMap[_userAddr];
        require(_userInfo.amount >= _amount, "Insufficient balance");

        // Update accounting before external calls (Checks-Effects-Interactions pattern).
        _userInfo.amount = _userInfo.amount - _amount;
        totalAssets = totalAssets - _amount;

        if (address(assets) == nativeAddress) {
            // Native currency withdrawal path.
            if (address(strategy) != address(0)) {
                // Strategy handles the withdrawal and sends native currency to user.
                IStrategy(strategy).withdrawNative(_userAddr, _amount);
            } else {
                // No strategy — send native currency directly from vault.
                TransferTokenHelper.safeTransferNative(_userAddr, _amount);
            }

            emit WithdrawTokenFromVault(_userAddr, _amount);
            return _amount;
        } else {
            // ERC20 withdrawal path.
            if (address(strategy) != address(0)) {
                // Strategy handles the withdrawal and sends tokens to user.
                IStrategy(strategy).withdraw(_userAddr, _amount);
            } else {
                // No strategy — send tokens directly from vault.
                TransferTokenHelper.safeTokenTransfer(address(assets), _userAddr, _amount);
            }

            emit WithdrawTokenFromVault(_userAddr, _amount);
            return _amount;
        }
    }

    // ──────────────────────────────────────────────
    //  Internal Helpers
    // ──────────────────────────────────────────────

    /// @dev Transfers all native currency held by the vault to the attached strategy.
    ///      Called when a new strategy is attached to migrate existing funds.
    function transferNativeToStrategy() internal {
        if (address(this).balance > 0) {
            TransferTokenHelper.safeTransferNative(address(strategy), address(this).balance);
        }
    }

    /// @dev Transfers all ERC20 tokens held by the vault to the attached strategy.
    ///      Called when a new strategy is attached to migrate existing funds.
    function transferERC20ToStrategy() internal {
        uint256 tokenBal = assets.balanceOf(address(this));
        if (tokenBal > 0) {
            assets.safeTransfer(address(strategy), tokenBal);
        }
    }

    /// @dev Allows the vault to receive native currency (ETH) transfers directly.
    ///      Required for strategy withdrawals that send native currency back to the vault.
    receive() external payable {}
}
