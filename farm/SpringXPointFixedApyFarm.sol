// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../interfaces/IVault.sol";
import "../tokens/SpringXPointToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @title SpringXPointFixedAPYFarm - Multi-reward fixed-APR staking farm
/// @notice Each pool supports multiple reward tokens, each with an independent annual rate.
///         Rewards are calculated per-user based on their staked amount and the annual rate
///         (e.g. stake 10000 USDT0 at 20% APR → daily reward = 10000 × 0.2 / 365 ≈ 5.4794).
///
///         Mintable rewards (PointToken) are minted on harvest; non-mintable rewards (e.g. USDT0)
///         are transferred from the Farm's pre-funded balance. If the Farm has insufficient balance
///         for a non-mintable reward, it is kept in accrued storage and distributed on the next harvest
///         to prevent deposit/withdraw from being DoS'd.
contract SpringXPointFixedAPYFarm is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    // ========================= Custom Errors =========================

    error PoolAlreadyExists();
    error PoolNotExist();
    error VaultAlreadyUsed();
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientStake();
    error NoStake();
    error NoReward();
    error EthAmountMismatch();
    error ERC20PoolNoEth();
    error DuplicateRewardToken();
    error InvalidRewardIndex();
    error MintableTokenMismatch();
    error RateTooHigh();

    // ========================= Constants =========================

    /// @dev 18-decimal precision for annual rate (100% = 1e18)
    uint256 private constant RATE_PRECISION = 1e18;

    /// @dev Seconds in one year (365 days), used as the time denominator for APR
    uint256 private constant ONE_YEAR = 365 days;

    // ========================= Structs =========================

    struct PoolInfo {
        address stakeToken;          // Token users stake (address(0) = native ETH)
        uint8 stakeDecimals;         // Cached stakeToken decimals (18 for native)
        IVault vault;                // Vault contract for fund custody
        uint64 lastRewardTime;       // Last timestamp rate integrals were updated
        uint256 totalStaked;         // Total amount staked in this pool
        bool exists;
    }

    struct RewardInfo {
        address token;               // Reward token address
        uint8 rewardDecimals;        // Cached reward token decimals (avoid repeated external calls)
        uint256 annualRate;          // Annual rate, 18 decimals (20% = 0.2e18, max 100% = 1e18)
        uint256 rateIntegral;        // ∫ annualRate × dt — accumulator enabling instant rate changes
        bool mintable;               // true = PointToken.mint(), false = IERC20.safeTransfer()
    }

    struct UserInfo {
        uint256 amount;              // Staked amount (actual amount from Vault, not nominal)
    }

    struct PoolTvlModel {
        uint256 pid;
        address assets;
        uint256 tvl;
    }

    // ========================= State =========================

    /// @notice PointToken contract used for minting rewards
    SpringXPointToken public pointToken;

    /// @notice Pool info by pool id
    mapping(uint256 => PoolInfo) public pools;

    /// @notice User info per pool: poolId => user => UserInfo
    mapping(uint256 => mapping(address => UserInfo)) public userInfos;

    /// @notice User set per pool for enumeration
    mapping(uint256 => EnumerableSet.AddressSet) private poolUsers;

    /// @notice Tracks whether a vault address is already bound to a pool (one-pool-per-vault)
    mapping(address => bool) public vaultUsed;

    /// @notice Ordered list of all pool ids
    uint256[] public poolIdList;

    /// @notice Reward configs per pool: poolId => RewardInfo[]
    mapping(uint256 => RewardInfo[]) internal poolRewards;

    /// @notice Per-reward debt: poolId => user => uint256[]
    ///         Each value is the rateIntegral snapshot at the user's last settlement.
    ///         Pending = amount × (currentIntegral - debt) × decimalScale / (ONE_YEAR × RATE_PRECISION)
    mapping(uint256 => mapping(address => uint256[])) internal userRewardDebts;

    /// @notice Per-reward accrued: poolId => user => uint256[]
    ///         Settled but unclaimed rewards, stored in reward token's native decimals.
    ///         Kept across interactions — non-mintable rewards stay here if Farm balance is insufficient.
    mapping(uint256 => mapping(address => uint256[])) internal userAccrued;

    /// @notice Per-reward claimed total: poolId => user => uint256[]
    mapping(uint256 => mapping(address => uint256[])) internal userClaimed;

    /// @dev Reserved storage gap for future upgrades (50 slots)
    uint256[50] private __gap;

    // ========================= Events =========================

    event PoolAdded(uint256 indexed poolId, address stakeToken, address vault);
    event PoolRewardAdded(uint256 indexed poolId, uint256 rewardIndex, address token, uint256 annualRate, bool mintable);
    event AnnualRateUpdated(uint256 indexed poolId, uint256 rewardIndex, uint256 oldRate, uint256 newRate);
    event Deposited(uint256 indexed poolId, address indexed user, uint256 amount);
    event Withdrawn(uint256 indexed poolId, address indexed user, uint256 amount);
    event Harvested(uint256 indexed poolId, address indexed user, address indexed rewardToken, uint256 reward);
    event EmergencyWithdrawn(uint256 indexed poolId, address indexed user, uint256 amount);

    // ========================= Constructor & Initializer =========================

    /// constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the farm
    /// @param pointToken_ PointToken contract address (must grant this farm minter role)
    function initialize(address pointToken_) public initializer {
        if (pointToken_ == address(0)) revert ZeroAddress();

        __Ownable_init(msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init();

        pointToken = SpringXPointToken(pointToken_);
    }

    // ========================= Admin Functions =========================

    /// @notice Add a new staking pool. Rewards are added separately via addPoolReward().
    /// @param poolId_ Unique pool identifier
    /// @param stakeToken_ Token to stake (address(0) for native ETH)
    /// @param vault_ Vault contract address for fund custody (each vault can only be used once)
    function addPool(
        uint256 poolId_,
        address stakeToken_,
        address vault_
    ) external onlyOwner {
        if (pools[poolId_].exists) revert PoolAlreadyExists();
        if (vault_ == address(0)) revert ZeroAddress();
        if (vaultUsed[vault_]) revert VaultAlreadyUsed();

        uint8 decimals;
        if (stakeToken_ == address(0)) {
            decimals = 18;
        } else {
            decimals = IERC20Metadata(stakeToken_).decimals();
            IERC20(stakeToken_).forceApprove(vault_, type(uint256).max);
        }

        vaultUsed[vault_] = true;

        pools[poolId_] = PoolInfo({
            stakeToken: stakeToken_,
            stakeDecimals: decimals,
            vault: IVault(vault_),
            lastRewardTime: uint64(block.timestamp),
            totalStaked: 0,
            exists: true
        });
        poolIdList.push(poolId_);

        emit PoolAdded(poolId_, stakeToken_, vault_);
    }

    /// @notice Add a reward token to a pool. Each reward has independent annualRate and accumulator.
    /// @param poolId_ Pool identifier
    /// @param token_ Reward token address
    /// @param annualRate_ Annual rate in 18 decimals (20% = 0.2e18, max 100% = 1e18)
    /// @param mintable_ true = mint via PointToken (token_ must equal pointToken address),
    ///                   false = transfer from Farm's pre-funded balance
    function addPoolReward(
        uint256 poolId_,
        address token_,
        uint256 annualRate_,
        bool mintable_
    ) external onlyOwner {
        if (!pools[poolId_].exists) revert PoolNotExist();
        if (token_ == address(0)) revert ZeroAddress();
        if (annualRate_ > RATE_PRECISION) revert RateTooHigh();
        // Enforce: mintable rewards must use pointToken to prevent display/mint mismatch
        if (mintable_ && token_ != address(pointToken)) revert MintableTokenMismatch();

        // Prevent adding the same reward token twice to one pool
        RewardInfo[] storage rewards = poolRewards[poolId_];
        for (uint256 i = 0; i < rewards.length;) {
            if (rewards[i].token == token_) revert DuplicateRewardToken();
            unchecked { ++i; }
        }

        // Settle existing integrals at current rates before adding a new reward
        _updatePool(poolId_);

        uint8 rewardDecimals = IERC20Metadata(token_).decimals();

        rewards.push(RewardInfo({
            token: token_,
            rewardDecimals: rewardDecimals,
            annualRate: annualRate_,
            rateIntegral: 0,
            mintable: mintable_
        }));

        emit PoolRewardAdded(poolId_, rewards.length - 1, token_, annualRate_, mintable_);
    }

    /// @notice Update annual rate for a specific reward in a pool.
    ///         Settles the rate integral at the old rate first, then applies new rate.
    ///         All users' future rewards use the new rate immediately (accumulator pattern).
    /// @param poolId_ Pool identifier
    /// @param rewardIndex_ Index in the pool's reward array (see getPoolRewards)
    /// @param newRate_ New annual rate in 18 decimals
    function setAnnualRate(
        uint256 poolId_,
        uint256 rewardIndex_,
        uint256 newRate_
    ) external onlyOwner {
        if (!pools[poolId_].exists) revert PoolNotExist();
        if (rewardIndex_ >= poolRewards[poolId_].length) revert InvalidRewardIndex();
        if (newRate_ > RATE_PRECISION) revert RateTooHigh();

        // Settle integral at old rate before switching — ensures correct accounting
        _updatePool(poolId_);

        RewardInfo storage reward = poolRewards[poolId_][rewardIndex_];
        uint256 oldRate = reward.annualRate;
        reward.annualRate = newRate_;

        emit AnnualRateUpdated(poolId_, rewardIndex_, oldRate, newRate_);
    }

    /// @notice Pause deposit, withdraw, and harvest. emergencyWithdraw remains available.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause all operations
    function unpause() external onlyOwner {
        _unpause();
    }

    // ========================= Core Functions =========================

    /// @notice Deposit staking tokens into a pool
    /// @param poolId_ Pool identifier
    /// @param amount_ Amount to deposit (for native ETH pools, must match msg.value)
    function deposit(uint256 poolId_, uint256 amount_) external payable nonReentrant whenNotPaused {
        if (!pools[poolId_].exists) revert PoolNotExist();
        if (amount_ == 0) revert ZeroAmount();

        PoolInfo storage pool = pools[poolId_];
        UserInfo storage user = userInfos[poolId_][msg.sender];

        // Update global rate integrals and sync user arrays
        _updatePool(poolId_);
        _syncUserArrays(poolId_, msg.sender);

        // Settle and auto-harvest all accrued rewards if user already has stake
        if (user.amount > 0) {
            _settleUser(poolId_, msg.sender);
            _updateAllRewardDebts(poolId_, msg.sender);
            _distributeRewards(poolId_, msg.sender);
        }

        // Transfer stake token to vault; use actual deposited amount for bookkeeping
        // (handles fee-on-transfer / rebasing tokens correctly)
        uint256 actualAmount;
        if (pool.stakeToken == address(0)) {
            if (amount_ != msg.value) revert EthAmountMismatch();
            actualAmount = pool.vault.depositTokenToVault{value: msg.value}(msg.sender, 0);
        } else {
            if (msg.value != 0) revert ERC20PoolNoEth();
            IERC20(pool.stakeToken).safeTransferFrom(msg.sender, address(this), amount_);
            actualAmount = pool.vault.depositTokenToVault(msg.sender, amount_);
        }

        // Effects — update amount after vault interaction (need actualAmount from vault return)
        user.amount += actualAmount;
        pool.totalStaked += actualAmount;
        _updateAllRewardDebts(poolId_, msg.sender);

        poolUsers[poolId_].add(msg.sender);

        emit Deposited(poolId_, msg.sender, actualAmount);
    }

    /// @notice Withdraw staking tokens and harvest all pending rewards
    /// @param poolId_ Pool identifier
    /// @param amount_ Amount to withdraw
    function withdraw(uint256 poolId_, uint256 amount_) external nonReentrant whenNotPaused {
        if (!pools[poolId_].exists) revert PoolNotExist();
        if (amount_ == 0) revert ZeroAmount();

        PoolInfo storage pool = pools[poolId_];
        UserInfo storage user = userInfos[poolId_][msg.sender];
        if (user.amount < amount_) revert InsufficientStake();

        _updatePool(poolId_);
        _syncUserArrays(poolId_, msg.sender);

        // Settle pending rewards at current (pre-withdrawal) amount
        _settleUser(poolId_, msg.sender);

        // Effects — update state before external calls (CEI pattern)
        user.amount -= amount_;
        pool.totalStaked -= amount_;
        _updateAllRewardDebts(poolId_, msg.sender);

        // Interactions — distribute accrued rewards, then withdraw from vault
        // Non-mintable rewards with insufficient Farm balance are kept in accrued (no revert)
        _distributeRewards(poolId_, msg.sender);
        pool.vault.withdrawTokenFromVault(msg.sender, amount_);

        emit Withdrawn(poolId_, msg.sender, amount_);
    }

    /// @notice Harvest all pending rewards without withdrawing stake
    /// @param poolId_ Pool identifier
    function harvest(uint256 poolId_) external nonReentrant whenNotPaused {
        if (!pools[poolId_].exists) revert PoolNotExist();

        UserInfo storage user = userInfos[poolId_][msg.sender];
        if (user.amount == 0) revert NoStake();

        _updatePool(poolId_);
        _syncUserArrays(poolId_, msg.sender);

        // Settle pending into accrued
        _settleUser(poolId_, msg.sender);
        _updateAllRewardDebts(poolId_, msg.sender);

        // Check if any accrued rewards exist
        uint256[] storage accrued = userAccrued[poolId_][msg.sender];
        bool hasReward;
        for (uint256 i = 0; i < accrued.length;) {
            if (accrued[i] > 0) { hasReward = true; break; }
            unchecked { ++i; }
        }
        if (!hasReward) revert NoReward();

        // Distribute accrued rewards
        _distributeRewards(poolId_, msg.sender);
    }

    /// @notice Emergency withdraw: forfeit all pending and accrued rewards, retrieve staked tokens.
    ///         Not affected by pause — users can always rescue their principal.
    /// @param poolId_ Pool identifier
    function emergencyWithdraw(uint256 poolId_) external nonReentrant {
        if (!pools[poolId_].exists) revert PoolNotExist();

        PoolInfo storage pool = pools[poolId_];
        UserInfo storage user = userInfos[poolId_][msg.sender];
        if (user.amount == 0) revert NoStake();

        // Settle pool integral so forfeited rewards don't affect future calculations
        _updatePool(poolId_);

        // Sync arrays BEFORE zeroing — ensures newly added reward entries are covered.
        // Without this, a re-depositing user could earn phantom rewards for reward tokens
        // added after their last interaction (debt would default to 0, not current integral).
        _syncUserArrays(poolId_, msg.sender);

        uint256 amount = user.amount;

        // Effects — zero out all user state, forfeit rewards
        user.amount = 0;
        pool.totalStaked -= amount;

        // Set debts to current integral (NOT zero) so that if the user re-deposits,
        // they start earning from the current point, not from integral=0.
        // Zero out accrued to forfeit any unsettled rewards.
        RewardInfo[] storage rewards = poolRewards[poolId_];
        uint256[] storage debts = userRewardDebts[poolId_][msg.sender];
        for (uint256 i = 0; i < debts.length;) {
            debts[i] = rewards[i].rateIntegral;
            unchecked { ++i; }
        }
        uint256[] storage accrued = userAccrued[poolId_][msg.sender];
        for (uint256 i = 0; i < accrued.length;) {
            accrued[i] = 0;
            unchecked { ++i; }
        }

        // Interactions
        pool.vault.withdrawTokenFromVault(msg.sender, amount);

        emit EmergencyWithdrawn(poolId_, msg.sender, amount);
    }

    // ========================= View Functions =========================

    /// @notice Get all pending rewards for a user in a pool (simulates settlement in memory)
    /// @param poolId_ Pool identifier
    /// @param userAddr_ User address
    /// @return tokens Reward token addresses
    /// @return amounts Pending reward amounts (accrued + unsettled)
    function pendingRewards(uint256 poolId_, address userAddr_) external view returns (
        address[] memory tokens,
        uint256[] memory amounts
    ) {
        RewardInfo[] storage rewards = poolRewards[poolId_];
        uint256 len = rewards.length;
        tokens = new address[](len);
        amounts = new uint256[](len);

        if (!pools[poolId_].exists) return (tokens, amounts);

        UserInfo storage user = userInfos[poolId_][userAddr_];
        uint256[] storage debts = userRewardDebts[poolId_][userAddr_];
        uint256[] storage accrued = userAccrued[poolId_][userAddr_];
        uint256[] memory simulated = _simulateIntegrals(poolId_);
        uint8 stakeDecimals = pools[poolId_].stakeDecimals;

        for (uint256 i = 0; i < len;) {
            tokens[i] = rewards[i].token;

            // Start with already-accrued (settled but unclaimed)
            uint256 total = (i < accrued.length) ? accrued[i] : 0;

            // Add unsettled pending
            if (user.amount > 0) {
                uint256 debt = (i < debts.length) ? debts[i] : 0;
                uint256 integralDelta = simulated[i] - debt;
                if (integralDelta > 0) {
                    total += _calcReward(
                        user.amount, integralDelta, stakeDecimals, rewards[i].rewardDecimals
                    );
                }
            }
            amounts[i] = total;
            unchecked { ++i; }
        }
    }

    /// @notice Get user staking info for a specific pool
    /// @param poolId_ Pool identifier
    /// @param user_ User address
    /// @return staked User's staked amount
    /// @return rewardTokens Reward token addresses
    /// @return claimedAmounts Total claimed per reward
    /// @return pendingAmounts Current pending per reward (accrued + unsettled)
    function getUserInfo(uint256 poolId_, address user_) external view returns (
        uint256 staked,
        address[] memory rewardTokens,
        uint256[] memory claimedAmounts,
        uint256[] memory pendingAmounts
    ) {
        staked = userInfos[poolId_][user_].amount;

        RewardInfo[] storage rewards = poolRewards[poolId_];
        uint256 len = rewards.length;
        rewardTokens = new address[](len);
        claimedAmounts = new uint256[](len);
        pendingAmounts = new uint256[](len);

        uint256[] storage claimed = userClaimed[poolId_][user_];
        uint256[] storage debts = userRewardDebts[poolId_][user_];
        uint256[] storage accrued = userAccrued[poolId_][user_];
        uint256[] memory simulated = _simulateIntegrals(poolId_);
        uint8 stakeDecimals = pools[poolId_].stakeDecimals;

        for (uint256 i = 0; i < len;) {
            rewardTokens[i] = rewards[i].token;
            claimedAmounts[i] = (i < claimed.length) ? claimed[i] : 0;

            uint256 total = (i < accrued.length) ? accrued[i] : 0;
            if (staked > 0) {
                uint256 debt = (i < debts.length) ? debts[i] : 0;
                uint256 integralDelta = simulated[i] - debt;
                if (integralDelta > 0) {
                    total += _calcReward(
                        staked, integralDelta, stakeDecimals, rewards[i].rewardDecimals
                    );
                }
            }
            pendingAmounts[i] = total;
            unchecked { ++i; }
        }
    }

    /// @notice Get all reward configs for a pool
    function getPoolRewards(uint256 poolId_) external view returns (RewardInfo[] memory) {
        return poolRewards[poolId_];
    }

    /// @notice Get number of reward tokens in a pool
    function getPoolRewardCount(uint256 poolId_) external view returns (uint256) {
        return poolRewards[poolId_].length;
    }

    /// @notice Get full pool info
    function getPoolInfo(uint256 poolId_) external view returns (PoolInfo memory) {
        return pools[poolId_];
    }

    /// @notice Get all pool ids
    function getAllPoolIds() external view returns (uint256[] memory) {
        return poolIdList;
    }

    /// @notice Get pool TVL from vault
    function getPoolTVL(uint256 poolId_) public view returns (uint256) {
        if (!pools[poolId_].exists) revert PoolNotExist();
        return pools[poolId_].vault.balance();
    }

    /// @notice Get TVL for all pools
    function getPoolTotalTvl() external view returns (PoolTvlModel[] memory) {
        uint256 n = poolIdList.length;
        PoolTvlModel[] memory result = new PoolTvlModel[](n);
        for (uint256 i = 0; i < n;) {
            uint256 pid = poolIdList[i];
            result[i] = PoolTvlModel({
                pid: pid,
                assets: pools[pid].stakeToken,
                tvl: getPoolTVL(pid)
            });
            unchecked { ++i; }
        }
        return result;
    }

    /// @notice Get user count in a pool
    function getPoolUserCount(uint256 poolId_) external view returns (uint256) {
        return poolUsers[poolId_].length();
    }

    /// @notice Get all user addresses in a pool (onlyOwner due to potential gas cost)
    function getPoolUserList(uint256 poolId_) external view onlyOwner returns (address[] memory) {
        return poolUsers[poolId_].values();
    }

    /// @notice Check if a user has ever interacted with a pool
    function isPoolUser(uint256 poolId_, address user_) external view returns (bool) {
        return poolUsers[poolId_].contains(user_);
    }

    /// @notice Get available balance of a reward token held by the Farm (for non-mintable rewards)
    function getRewardBalance(address token_) external view returns (uint256) {
        return IERC20(token_).balanceOf(address(this));
    }

    // ========================= Internal Functions =========================

    /// @dev Update all rate integrals for a pool up to current timestamp.
    ///      rateIntegral += annualRate × timeDelta for each reward.
    ///      This accumulates the "rate × time" product so that rate changes take effect instantly.
    ///      Unlike PointFarm's accRewardPerShare (which divides by totalStaked to share a fixed emission),
    ///      rateIntegral simply accumulates rate over time because APR rewards are per-user-independent.
    function _updatePool(uint256 poolId_) internal {
        PoolInfo storage pool = pools[poolId_];

        if (block.timestamp <= pool.lastRewardTime) return;

        // Skip integral accumulation when no one is staked — avoids wasteful state writes
        // and prevents rateIntegral from growing during idle periods (consistent with PointFarm).
        // Only advance lastRewardTime so the idle gap is skipped, not double-counted later.
        if (pool.totalStaked == 0) {
            pool.lastRewardTime = uint64(block.timestamp);
            return;
        }

        uint256 timeDelta = block.timestamp - pool.lastRewardTime;
        RewardInfo[] storage rewards = poolRewards[poolId_];
        for (uint256 i = 0; i < rewards.length;) {
            // annualRate (max 1e18) × timeDelta (max ~3.15e8 for 10 years) = max ~3.15e26
            // Cumulative integral stays well within uint256 even over decades
            rewards[i].rateIntegral += rewards[i].annualRate * timeDelta;
            unchecked { ++i; }
        }
        pool.lastRewardTime = uint64(block.timestamp);
    }

    /// @dev Ensure user's reward debt, accrued, and claimed arrays are aligned with pool reward count.
    ///      Called before any user operation to handle newly added rewards gracefully.
    ///      New entries are initialized to 0, meaning users don't earn retroactive rewards
    ///      for tokens added after they deposited — they start earning from their next interaction.
    function _syncUserArrays(uint256 poolId_, address user_) internal {
        uint256 count = poolRewards[poolId_].length;
        uint256[] storage debts = userRewardDebts[poolId_][user_];
        uint256[] storage accrued = userAccrued[poolId_][user_];
        uint256[] storage claimed = userClaimed[poolId_][user_];
        while (debts.length < count) debts.push(0);
        while (accrued.length < count) accrued.push(0);
        while (claimed.length < count) claimed.push(0);
    }

    /// @dev Settle all pending rewards for a user into userAccrued.
    ///      For each reward: pending = amount × (currentIntegral - userDebt) × decimalScale / (ONE_YEAR × RATE_PRECISION)
    ///      Must call _syncUserArrays before this to ensure array alignment.
    function _settleUser(uint256 poolId_, address user_) internal {
        RewardInfo[] storage rewards = poolRewards[poolId_];
        uint256 userAmount = userInfos[poolId_][user_].amount;
        uint256[] storage debts = userRewardDebts[poolId_][user_];
        uint256[] storage accrued = userAccrued[poolId_][user_];
        uint8 stakeDecimals = pools[poolId_].stakeDecimals;

        for (uint256 i = 0; i < rewards.length;) {
            uint256 integralDelta = rewards[i].rateIntegral - debts[i];
            if (integralDelta > 0 && userAmount > 0) {
                accrued[i] += _calcReward(
                    userAmount, integralDelta, stakeDecimals, rewards[i].rewardDecimals
                );
            }
            unchecked { ++i; }
        }
    }

    /// @dev Calculate reward amount with decimal adjustment between stake and reward tokens.
    ///      Handles both cases: rewardDecimals >= stakeDecimals (scale up) and < (scale down).
    ///      Uses Math.mulDiv for safe 512-bit intermediate to prevent overflow.
    ///
    ///      Example: stake 10000 USDT0 (6 dec), PointToken reward (18 dec), 20% APR, 1 day:
    ///        integralDelta = 0.2e18 × 86400 = 1.728e22
    ///        amount * scale = 1e10 × 10^12 = 1e22
    ///        reward = mulDiv(1e22, 1.728e22, 31536000 × 1e18) = 5.479e18 ≈ 5.4794 PointToken ✓
    function _calcReward(
        uint256 amount_,
        uint256 integralDelta_,
        uint8 stakeDecimals_,
        uint8 rewardDecimals_
    ) internal pure returns (uint256) {
        if (rewardDecimals_ >= stakeDecimals_) {
            // Scale up: multiply amount by 10^(rewardDecimals - stakeDecimals) before division
            // to maximize precision (multiplication before division is always more precise)
            uint256 scale = 10 ** (rewardDecimals_ - stakeDecimals_);
            return Math.mulDiv(amount_ * scale, integralDelta_, ONE_YEAR * RATE_PRECISION);
        } else {
            // Scale down: increase divisor by 10^(stakeDecimals - rewardDecimals)
            // Minimal precision loss — at most 1 unit per settlement
            uint256 scale = 10 ** (stakeDecimals_ - rewardDecimals_);
            return Math.mulDiv(amount_, integralDelta_, ONE_YEAR * RATE_PRECISION * scale);
        }
    }

    /// @dev Update all reward debts to current integral values.
    ///      Must be called after any change to user.amount or after _settleUser.
    function _updateAllRewardDebts(uint256 poolId_, address user_) internal {
        RewardInfo[] storage rewards = poolRewards[poolId_];
        uint256[] storage debts = userRewardDebts[poolId_][user_];

        for (uint256 i = 0; i < rewards.length;) {
            debts[i] = rewards[i].rateIntegral;
            unchecked { ++i; }
        }
    }

    /// @dev Distribute all accrued rewards to user.
    ///      - Mintable rewards: always minted via PointToken.mint()
    ///      - Non-mintable rewards: transferred only if Farm has sufficient balance,
    ///        otherwise kept in accrued for later harvest (prevents deposit/withdraw DoS)
    function _distributeRewards(uint256 poolId_, address user_) internal {
        RewardInfo[] storage rewards = poolRewards[poolId_];
        uint256[] storage accrued = userAccrued[poolId_][user_];
        uint256[] storage claimed = userClaimed[poolId_][user_];

        for (uint256 i = 0; i < rewards.length;) {
            if (accrued[i] > 0) {
                uint256 amount = accrued[i];

                if (rewards[i].mintable) {
                    // Mintable: mint to user (always succeeds if Farm has minter role)
                    accrued[i] = 0;
                    claimed[i] += amount;
                    pointToken.mint(user_, amount);
                    emit Harvested(poolId_, user_, rewards[i].token, amount);
                } else {
                    // Non-mintable: check Farm balance before transfer
                    // If insufficient, keep in accrued — user can harvest later when funded
                    uint256 farmBalance = IERC20(rewards[i].token).balanceOf(address(this));
                    if (farmBalance >= amount) {
                        accrued[i] = 0;
                        claimed[i] += amount;
                        IERC20(rewards[i].token).safeTransfer(user_, amount);
                        emit Harvested(poolId_, user_, rewards[i].token, amount);
                    }
                    // Insufficient balance: silently keep in accrued, no revert
                }
            }
            unchecked { ++i; }
        }
    }

    /// @dev Simulate rate integrals in memory for view functions without modifying state
    function _simulateIntegrals(uint256 poolId_) internal view returns (uint256[] memory) {
        PoolInfo storage pool = pools[poolId_];
        RewardInfo[] storage rewards = poolRewards[poolId_];
        uint256 len = rewards.length;
        uint256[] memory simulated = new uint256[](len);

        uint256 timeDelta = (block.timestamp > pool.lastRewardTime)
            ? block.timestamp - pool.lastRewardTime
            : 0;

        for (uint256 i = 0; i < len;) {
            simulated[i] = rewards[i].rateIntegral;
            if (timeDelta > 0) {
                simulated[i] += rewards[i].annualRate * timeDelta;
            }
            unchecked { ++i; }
        }
        return simulated;
    }

    receive() external payable {}
}
