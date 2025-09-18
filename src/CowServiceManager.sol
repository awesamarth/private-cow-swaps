// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/ICowServiceManager.sol";

/**
 * @title CowServiceManager
 * @dev Service manager for the CoW AVS with operator management and economic security
 */
contract CowServiceManager is ICowServiceManager {
    // Minimum stake required for operators (0.01 ETH for testing)
    uint256 public constant MIN_OPERATOR_STAKE = 1e16; // 0.01 ETH

    // Slashing parameters
    uint256 public constant SLASHING_PERCENTAGE = 1000; // 10% (basis points)
    uint256 public constant MAX_SLASHING_PERCENTAGE = 10000; // 100%

    // Operator tracking
    mapping(address => bool) public operators;
    mapping(address => uint256) public operatorStake;
    mapping(address => bool) public isSlashed;
    mapping(address => uint256) public rewardAccumulated;
    uint256 public operatorCount;

    // Task validation tracking
    mapping(uint32 => mapping(address => bool)) public hasValidated;
    mapping(uint32 => uint256) public taskRewards;

    // Access control
    address public owner;
    mapping(address => bool) public taskManagers;

    modifier onlyValidOperator() {
        require(operators[msg.sender] && !isSlashed[msg.sender], "Invalid or slashed operator");
        _;
    }

    modifier onlyTaskManager() {
        require(taskManagers[msg.sender], "Only task manager");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /**
     * @dev Add a task manager contract
     */
    function addTaskManager(address taskManager) external onlyOwner {
        taskManagers[taskManager] = true;
    }

    /**
     * @dev Register as an operator with minimum stake
     */
    function registerOperator() external payable override {
        require(msg.value >= MIN_OPERATOR_STAKE, "Insufficient stake");
        require(!operators[msg.sender], "Already registered");

        operators[msg.sender] = true;
        operatorStake[msg.sender] = msg.value;
        operatorCount++;

        emit OperatorRegistered(msg.sender, msg.value);
    }

    /**
     * @dev Deregister operator and return stake
     */
    function deregisterOperator() external override {
        require(operators[msg.sender], "Not registered");
        require(!isSlashed[msg.sender], "Cannot deregister while slashed");

        uint256 stake = operatorStake[msg.sender];
        uint256 rewards = rewardAccumulated[msg.sender];

        operators[msg.sender] = false;
        operatorStake[msg.sender] = 0;
        rewardAccumulated[msg.sender] = 0;
        operatorCount--;

        // Return stake and accumulated rewards
        payable(msg.sender).transfer(stake + rewards);

        emit OperatorDeregistered(msg.sender);
    }

    /**
     * @dev Add more stake to existing registration
     */
    function addStake() external payable override {
        require(operators[msg.sender], "Not registered");
        require(msg.value > 0, "No stake provided");

        operatorStake[msg.sender] += msg.value;

        emit StakeUpdated(msg.sender, operatorStake[msg.sender]);
    }

    /**
     * @dev Check if an address is a valid operator
     */
    function isValidOperator(address operator) external view override returns (bool) {
        return operators[operator] && !isSlashed[operator];
    }

    /**
     * @dev Get operator stake amount
     */
    function getOperatorStake(address operator) external view override returns (uint256) {
        return operatorStake[operator];
    }

    /**
     * @dev Record task validation by operator (called by TaskManager)
     */
    function recordTaskValidation(uint32 taskIndex, address operator) external override onlyTaskManager {
        require(operators[operator] && !isSlashed[operator], "Invalid operator");

        hasValidated[taskIndex][operator] = true;
    }

    /**
     * @dev Set reward amount for a task
     */
    function setTaskReward(uint32 taskIndex, uint256 rewardAmount) external payable override onlyTaskManager {
        require(msg.value >= rewardAmount, "Insufficient reward funding");

        taskRewards[taskIndex] = rewardAmount;
    }

    /**
     * @dev Distribute rewards to operators who validated CoW matches correctly
     */
    function distributeTaskReward(uint32 taskIndex, address[] calldata validOperators)
        external
        override
        onlyTaskManager
    {
        uint256 totalReward = taskRewards[taskIndex];
        require(totalReward > 0, "No reward set");
        require(validOperators.length > 0, "No valid operators");

        uint256 rewardPerOperator = totalReward / validOperators.length;

        for (uint256 i = 0; i < validOperators.length; i++) {
            address operator = validOperators[i];
            require(hasValidated[taskIndex][operator], "Operator did not validate");

            rewardAccumulated[operator] += rewardPerOperator;

            emit TaskValidationRewarded(taskIndex, operator, rewardPerOperator);
        }

        // Reset task reward
        taskRewards[taskIndex] = 0;
    }

    /**
     * @dev Slash operator for malicious behavior
     */
    function slashOperator(address operator, uint256 amount) external override onlyOwner {
        require(operators[operator], "Not an operator");
        require(amount <= operatorStake[operator], "Slash amount exceeds stake");

        operatorStake[operator] -= amount;

        // If stake falls below minimum, mark as slashed
        if (operatorStake[operator] < MIN_OPERATOR_STAKE) {
            isSlashed[operator] = true;
        }

        emit OperatorSlashed(operator, amount);
    }

    /**
     * @dev Claim accumulated rewards
     */
    function claimRewards() external override {
        require(operators[msg.sender], "Not an operator");

        uint256 rewards = rewardAccumulated[msg.sender];
        require(rewards > 0, "No rewards to claim");

        rewardAccumulated[msg.sender] = 0;
        payable(msg.sender).transfer(rewards);

        emit RewardDistributed(msg.sender, rewards);
    }

    /**
     * @dev Emergency withdraw (owner only)
     */
    function emergencyWithdraw() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }

    /**
     * @dev Get total number of active operators
     */
    function getActiveOperatorCount() external view returns (uint256) {
        return operatorCount;
    }

    /**
     * @dev Check if operator has validated a specific task
     */
    function hasOperatorValidated(uint32 taskIndex, address operator) external view returns (bool) {
        return hasValidated[taskIndex][operator];
    }
}
