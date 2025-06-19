// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SyntorStaking
 * @dev A staking contract that allows users to stake ERC20 tokens and earn rewards
 * @notice This contract implements a time-based staking mechanism with configurable fees
 * @author Syntor Team
 */
contract SyntorStaking is Ownable, ReentrancyGuard {

    // ============ STATE VARIABLES ============
    
    /// @notice The ERC20 token used for staking and rewards
    IERC20 public immutable token;

    /// @notice Staking fee in basis points (100 = 1%)
    uint256 public stakingFee = 100;
    
    /// @notice Unstaking fee in basis points (100 = 1%)
    uint256 public unstakingFee = 100;


    /// @notice Mapping of user addresses to their staked amounts
    mapping(address => uint256) public stakes;

    /// @notice Total amount of tokens currently staked
    uint256 public totalStaked;

    // Owner funds tracking
    /// @notice Total fees collected by the owner
    uint256 public ownerFeesCollected;

    /// @notice Total rewards deposited by the owner
    uint256 public ownerRewardDeposits;

    /// @notice Total amount withdrawn by the owner
    uint256 public ownerWithdrawals;

    // User rewards tracking
    /// @notice Mapping of user addresses to their total claimed rewards
    mapping(address => uint256) public claimedRewards;

    /// @notice Total rewards claimed by all users
    uint256 public totalRewardsClaimed;

    // Program parameters
    /// @notice Duration of the staking program (365 days)
    uint256 public constant STAKING_DURATION = 365 days;

    /// @notice Timestamp when the staking program started
    uint256 public programStartTime;

    /// @notice Timestamp when the staking program ends
    uint256 public programEndTime;

    /// @notice Total budget allocated for rewards
    uint256 public totalRewardBudget = 100_000 ether;

    /// @notice Last time rewards were updated
    uint256 public lastUpdateTime;

    /// @notice Stored reward per token value
    uint256 public rewardPerTokenStored;

    /// @notice Whether staking is currently enabled
    bool public stakingEnabled = true;

    /// @notice Whether the staking program is currently active
    bool public programActive = false;

    // Reward calculation mappings
    /// @notice Mapping of user addresses to their paid reward per token
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice Mapping of user addresses to their pending rewards
    mapping(address => uint256) public pendingRewards;

     /// @notice Maximum minimum stake (100,000 tokens)
    uint256 public constant MAX_MINIMUM_STAKE = 100_000 ether;

    /// @notice Minimum minimum stake (0.01 tokens)
    uint256 public constant MIN_MINIMUM_STAKE = 0.01 ether;

    /// @notice Minimum amount required to stake
    uint256 public minimumStake = MIN_MINIMUM_STAKE;

    /// @notice Maximum total reward budget (1 million tokens)
    uint256 public constant MAX_TOTAL_REWARD_BUDGET = 1_000_000 ether;

    /// @notice Minimum total reward budget (1000 tokens)
    uint256 public constant MIN_TOTAL_REWARD_BUDGET = 1_000 ether;

    // ============ EVENTS ============
    
    event Staked(address indexed user, uint256 grossAmount, uint256 netAmount, uint256 fee);
    event Unstaked(address indexed user, uint256 grossAmount, uint256 netAmount, uint256 fee);
    event RewardClaimed(address indexed user, uint256 amount);
    event RewardDeposited(address indexed depositor, uint256 amount);
    event FeesWithdrawn(address indexed owner, uint256 amount);
    event ProgramStarted(uint256 startTime, uint256 endTime, uint256 totalBudget);
    event ProgramEnded(uint256 endTime);
    event StakingPaused();
    event StakingResumed();
    event EmergencyWithdrawal(address indexed owner, uint256 amount);
    event FeesUpdated(uint256 newStakingFee, uint256 newUnstakingFee);

    // ============ MODIFIERS ============
    
    /**
     * @dev Updates rewards before executing the function
     * @param account The account to update rewards for
     */
    modifier updateReward(address account) {
        _updateGlobalReward();
        if (account != address(0)) {
            _updateUserReward(account);
        }
        _;
    }

    /**
     * @dev Validates that the amount is greater than zero
     * @param amount The amount to validate
     */
    modifier validAmount(uint256 amount) {
        require(amount > 0, "Amount must be greater than zero");
        _;
    }

    /**
     * @dev Ensures staking is currently enabled
     */
    modifier onlyWhenStakingEnabled() {
        require(stakingEnabled, "Staking is currently disabled");
        _;
    }

    /**
     * @dev Ensures the staking program is currently active
     */
    modifier onlyWhenProgramActive() {
        require(programActive && block.timestamp <= programEndTime, "Staking program not active");
        _;
    }

    // ============ CONSTRUCTOR ============
    
    /**
     * @dev Initializes the contract with the specified token
     * @param _token Address of the ERC20 token to be used for staking
     */
    constructor(address _token) Ownable(msg.sender) {
        require(_token != address(0), "Token address cannot be zero");
        token = IERC20(_token);
        lastUpdateTime = block.timestamp;
    }

    // ============ OWNER FUNCTIONS ============

    /**
     * @dev Starts the staking program
     * @notice Can only be called by the owner when program is not active
     */
    function startProgram() external onlyOwner {
        require(!programActive, "Program already started");
        require(_getAvailableRewardFunds() >= totalRewardBudget, "Insufficient reward funds for full program");

        programActive = true;
        programStartTime = block.timestamp;
        programEndTime = block.timestamp + STAKING_DURATION;
        lastUpdateTime = block.timestamp;

        emit ProgramStarted(programStartTime, programEndTime, totalRewardBudget);
    }

    /**
     * @dev Ends the staking program and disables staking
     * @notice Can only be called by the owner when program is active
     */
    function endProgram() external onlyOwner {
        require(programActive, "Program not active");
        
        programActive = false;
        stakingEnabled = false;
        
        emit ProgramEnded(block.timestamp);
    }

    /**
     * @dev Pauses staking functionality
     * @notice Can only be called by the owner
     */
    function pauseStaking() external onlyOwner {
        stakingEnabled = false;
        emit StakingPaused();
    }

    /**
     * @dev Resumes staking functionality
     * @notice Can only be called by the owner when program is active
     */
    function resumeStaking() external onlyOwner {
        require(programActive, "Program not active");
        stakingEnabled = true;
        emit StakingResumed();
    }

    /**
     * @dev Sets the staking and unstaking fees
     * @param _stakingFee New staking fee in basis points (max 1000 = 10%)
     * @param _unstakingFee New unstaking fee in basis points (max 1000 = 10%)
     */
    function setFees(uint256 _stakingFee, uint256 _unstakingFee) external onlyOwner {
        require(_stakingFee <= 1000, "Staking fee cannot exceed 10%");
        require(_unstakingFee <= 1000, "Unstaking fee cannot exceed 10%");
        stakingFee = _stakingFee;
        unstakingFee = _unstakingFee;
        emit FeesUpdated(_stakingFee, _unstakingFee);
    }

    /**
     * @dev Sets the minimum stake amount
     * @param _minimumStake New minimum stake amount
     */
    function setMinimumStake(uint256 _minimumStake) external onlyOwner {
        require(_minimumStake >= MIN_MINIMUM_STAKE, "Minimum stake too low");
        require(_minimumStake <= MAX_MINIMUM_STAKE, "Minimum stake too high");
        minimumStake = _minimumStake;
    }

    /**
     * @dev Sets the total reward budget
     * @param _totalRewardBudget New total reward budget
     * @notice Can only be called when program is not active
     */
    function setTotalRewardBudget(uint256 _totalRewardBudget) external onlyOwner validAmount(_totalRewardBudget) {
        require(!programActive, "Cannot change budget while program is active");
        require(_totalRewardBudget >= MIN_TOTAL_REWARD_BUDGET, "Total reward budget too low");
        require(_totalRewardBudget <= MAX_TOTAL_REWARD_BUDGET, "Total reward budget too high");
        totalRewardBudget = _totalRewardBudget;
    }

    /**
     * @dev Deposits the full year's rewards at once
     * @notice Transfers totalRewardBudget from caller to contract
     */
    function depositRewardsForFullYear() external nonReentrant {
        require(token.transferFrom(msg.sender, address(this), totalRewardBudget), "Transfer failed");
        ownerRewardDeposits += totalRewardBudget;
        emit RewardDeposited(msg.sender, totalRewardBudget);
    }

    /**
     * @dev Adds additional rewards to the contract
     * @param amount Amount of rewards to add
     */
    function addRewards(uint256 amount) external validAmount(amount) updateReward(address(0)) nonReentrant onlyOwner {
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        ownerRewardDeposits += amount;
        totalRewardBudget += amount;
        emit RewardDeposited(msg.sender, amount);
    }

    /**
     * @dev Withdraws collected fees to the owner
     * @notice Transfers all collected fees to the owner
     */
    function withdrawFees() external onlyOwner nonReentrant {
        uint256 amount = ownerFeesCollected;
        require(amount > 0, "No fees to withdraw");

        ownerFeesCollected = 0;
        ownerWithdrawals += amount;

        require(token.transfer(owner(), amount), "Transfer failed");
        emit FeesWithdrawn(owner(), amount);
    }

    /**
     * @dev Emergency withdrawal of specified amount
     * @param amount Amount to withdraw
     * @notice Only withdraws from fees and unused rewards, not user stakes
     */
    function emergencyWithdrawOwner(uint256 amount) external onlyOwner validAmount(amount) nonReentrant {
        uint256 availableFees = ownerFeesCollected;
        uint256 availableUnusedRewards = _getAvailableRewardFunds();
        uint256 totalAvailableOwnerFunds = availableFees + availableUnusedRewards;

        require(amount <= totalAvailableOwnerFunds, "Insufficient owner funds for emergency withdrawal");

        // Deduct from fees first, then from unused rewards
        if (amount <= availableFees) {
            ownerFeesCollected -= amount;
        } else {
            ownerFeesCollected = 0;
            uint256 remainingAmount = amount - availableFees;
            ownerRewardDeposits -= remainingAmount;
            totalRewardBudget -= remainingAmount;
        }

        ownerWithdrawals += amount;
        require(token.transfer(owner(), amount), "Emergency transfer failed");
        emit EmergencyWithdrawal(owner(), amount);
    }

    // ============ USER FUNCTIONS ============

    /**
     * @dev Stakes tokens for the caller
     * @param amount Amount of tokens to stake
     * @notice Charges a staking fee and updates rewards
     */
    function stake(uint256 amount) external validAmount(amount) onlyWhenStakingEnabled onlyWhenProgramActive updateReward(msg.sender) nonReentrant {
        require(amount >= minimumStake, "Amount below minimum stake");
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        uint256 fee = (amount * stakingFee) / 10000;
        uint256 netStake = amount - fee;

        stakes[msg.sender] += netStake;
        totalStaked += netStake;
        ownerFeesCollected += fee;

        emit Staked(msg.sender, amount, netStake, fee);
    }

    /**
     * @dev Unstakes tokens for the caller
     * @param amount Amount of tokens to unstake
     * @notice Charges an unstaking fee and updates rewards
     */
    function unstake(uint256 amount) external validAmount(amount) updateReward(msg.sender) nonReentrant {
        require(stakes[msg.sender] >= amount, "Insufficient staked balance");

        uint256 fee = (amount * unstakingFee) / 10000;
        uint256 netReturn = amount - fee;

        // Ensure sufficient funds are available for unstaking
        uint256 contractBalance = token.balanceOf(address(this));
        uint256 protectedFunds = _getAvailableRewardFunds() + ownerFeesCollected;
        uint256 availableForUnstaking = contractBalance - protectedFunds;

        require(netReturn <= availableForUnstaking, "Insufficient funds available for unstaking");

        stakes[msg.sender] -= amount;
        totalStaked -= amount;
        ownerFeesCollected += fee;

        require(token.transfer(msg.sender, netReturn), "Transfer failed");
        emit Unstaked(msg.sender, amount, netReturn, fee);
    }

    /**
     * @dev Claims pending rewards for the caller
     * @notice Transfers all pending rewards to the caller
     */
    function claimReward() external updateReward(msg.sender) nonReentrant {
        uint256 reward = pendingRewards[msg.sender];
        require(reward > 0, "No rewards to claim");
        require(_getAvailableRewardFunds() >= reward, "Insufficient reward funds");

        pendingRewards[msg.sender] = 0;
        claimedRewards[msg.sender] += reward;
        totalRewardsClaimed += reward;

        require(token.transfer(msg.sender, reward), "Reward transfer failed");
        emit RewardClaimed(msg.sender, reward);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @dev Returns staking information for a user
     * @param user Address of the user
     * @return stakedAmount Amount of tokens staked by the user
     * @return pendingReward Pending rewards for the user
     * @return totalClaimed Total rewards claimed by the user
     */
    function getStakeInfo(address user) external view returns (
        uint256 stakedAmount,
        uint256 pendingReward,
        uint256 totalClaimed
    ) {
        require(user != address(0), "Invalid user address");
        stakedAmount = stakes[user];
        pendingReward = _calculatePendingReward(user);
        totalClaimed = claimedRewards[user];
    }

    /**
     * @dev Returns comprehensive contract information
     * @return totalUserStaked Total amount staked by all users
     * @return totalFeesCollected Total fees collected by owner
     * @return totalRewardDeposits Total rewards deposited by owner
     * @return totalOwnerWithdrawals Total amount withdrawn by owner
     * @return totalUserRewardsClaimed Total rewards claimed by users
     * @return availableRewardFunds Available reward funds
     * @return availableOwnerFunds Available owner funds
     * @return contractBalance Total contract token balance
     * @return currentAPY Current APY in basis points
     * @return daysUntilProgramEnd Days until program ends
     * @return isProgramActive Whether program is active
     * @return isStakingEnabled Whether staking is enabled
     */
    function getContractInfo() external view returns (
        uint256 totalUserStaked,
        uint256 totalFeesCollected,
        uint256 totalRewardDeposits,
        uint256 totalOwnerWithdrawals,
        uint256 totalUserRewardsClaimed,
        uint256 availableRewardFunds,
        uint256 availableOwnerFunds,
        uint256 contractBalance,
        uint256 currentAPY,
        uint256 daysUntilProgramEnd,
        bool isProgramActive,
        bool isStakingEnabled
    ) {
        totalUserStaked = totalStaked;
        totalFeesCollected = ownerFeesCollected;
        totalRewardDeposits = ownerRewardDeposits;
        totalOwnerWithdrawals = ownerWithdrawals;
        totalUserRewardsClaimed = totalRewardsClaimed;
        availableRewardFunds = _getAvailableRewardFunds();
        availableOwnerFunds = _getAvailableOwnerFunds();
        contractBalance = token.balanceOf(address(this));
        currentAPY = _getCurrentAPY();
        daysUntilProgramEnd = (programActive && programEndTime > block.timestamp) ? 
            (programEndTime - block.timestamp) / 1 days : 0;
        isProgramActive = programActive && block.timestamp <= programEndTime;
        isStakingEnabled = stakingEnabled;
    }

    /**
     * @dev Returns the last time rewards were applicable
     * @return The timestamp of the last applicable reward time
     */
    function lastTimeRewardApplicable() public view returns (uint256) {
        if (!programActive) return lastUpdateTime;
        return block.timestamp < programEndTime ? block.timestamp : programEndTime;
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @dev Calculates pending rewards for a user
     * @param user Address of the user
     * @return Pending reward amount
     */
    function _calculatePendingReward(address user) internal view returns (uint256) {
        uint256 currentRewardPerToken = _getCurrentRewardPerToken();
        uint256 userPaidPerToken = userRewardPerTokenPaid[user];
        uint256 userStake = stakes[user];

        uint256 accruedReward = 0;
        if (userStake > 0 && currentRewardPerToken > userPaidPerToken) {
            accruedReward = (userStake * (currentRewardPerToken - userPaidPerToken)) / 1 ether;
        }

        return pendingRewards[user] + accruedReward;
    }

    /**
     * @dev Calculates the current reward per token
     * @return Current reward per token value
     */
    function _getCurrentRewardPerToken() internal view returns (uint256) {
        if (totalStaked == 0 || !programActive) {
            return rewardPerTokenStored;
        }

        uint256 timeApplicable = lastTimeRewardApplicable();
        uint256 timeDelta = timeApplicable - lastUpdateTime;

        if (timeDelta == 0) {
            return rewardPerTokenStored;
        }

        uint256 rewardRatePerSecond = totalRewardBudget / STAKING_DURATION;
        uint256 additionalRewardPerToken = (timeDelta * rewardRatePerSecond * 1 ether) / totalStaked;
        return rewardPerTokenStored + additionalRewardPerToken;
    }

    /**
     * @dev Updates the global reward state
     */
    function _updateGlobalReward() internal {
        rewardPerTokenStored = _getCurrentRewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
    }

    /**
     * @dev Updates rewards for a specific user
     * @param user Address of the user
     */
    function _updateUserReward(address user) internal {
        uint256 currentRewardPerToken = rewardPerTokenStored;
        uint256 userPaidPerToken = userRewardPerTokenPaid[user];

        if (stakes[user] > 0 && currentRewardPerToken > userPaidPerToken) {
            uint256 earned = (stakes[user] * (currentRewardPerToken - userPaidPerToken)) / 1 ether;
            pendingRewards[user] += earned;
        }
        
        userRewardPerTokenPaid[user] = currentRewardPerToken;
    }

    /**
     * @dev Returns available reward funds
     * @return Amount of reward funds available
     */
    function _getAvailableRewardFunds() internal view returns (uint256) {
        if (ownerRewardDeposits <= totalRewardsClaimed) {
            return 0;
        }
        return ownerRewardDeposits - totalRewardsClaimed;
    }

    /**
     * @dev Returns available owner funds (fees + unused rewards)
     * @return Total available owner funds
     */
    function _getAvailableOwnerFunds() internal view returns (uint256) {
        return ownerFeesCollected + _getAvailableRewardFunds();
    }

    /**
     * @dev Calculates the current APY
     * @return Current APY in basis points
     */
    function _getCurrentAPY() internal view returns (uint256) {
        if (totalStaked == 0 || !programActive) return 0;
        uint256 annualReturn = (totalRewardBudget * 10000) / totalStaked;
        return annualReturn;
    }
}
