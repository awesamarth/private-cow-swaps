// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/ICowTaskManager.sol";
import "./interfaces/ICowServiceManager.sol";

/**
 * @title CowTaskManager
 * @dev Task coordination and consensus mechanism for CoW match validation
 */
contract CowTaskManager is ICowTaskManager {
    ICowServiceManager public immutable serviceManager;

    // Task storage
    mapping(uint32 => Task) public tasks;
    mapping(uint32 => TaskResponse[]) public taskResponses;
    mapping(uint32 => mapping(bytes32 => uint256)) public responseVotes;
    mapping(uint32 => mapping(address => bool)) public hasResponded;

    uint32 public latestTaskNum;

    // Configuration
    uint256 public constant TASK_RESPONSE_WINDOW = 1 hours;
    uint256 public constant MIN_QUORUM_THRESHOLD = 51; // 51%
    uint256 public constant MAX_QUORUM_THRESHOLD = 100; // 100%

    modifier onlyValidOperator() {
        require(serviceManager.isValidOperator(msg.sender), "Invalid operator");
        _;
    }

    constructor(address _serviceManager) {
        serviceManager = ICowServiceManager(_serviceManager);
    }

    /**
     * @dev Create a new task for CoW match validation
     */
    function createNewTask(bytes32 matchHash, uint32 quorumThreshold, bytes calldata quorumNumbers)
        external
        payable
        override
        onlyValidOperator
    {
        require(matchHash != bytes32(0), "Invalid match hash");
        require(
            quorumThreshold >= MIN_QUORUM_THRESHOLD && quorumThreshold <= MAX_QUORUM_THRESHOLD,
            "Invalid quorum threshold"
        );

        uint32 taskIndex = latestTaskNum++;

        tasks[taskIndex] = Task({
            matchHash: matchHash,
            quorumThreshold: quorumThreshold,
            quorumNumbers: quorumNumbers,
            createdBlock: block.number,
            creator: msg.sender,
            isCompleted: false,
            reward: msg.value
        });

        // Set reward in service manager
        if (msg.value > 0) {
            serviceManager.setTaskReward{value: msg.value}(taskIndex, msg.value);
        }

        emit TaskCreated(taskIndex, matchHash, msg.sender, msg.value);
    }

    /**
     * @dev Respond to a task with validation result
     */
    function respondToTask(bytes32 matchHash, bytes32 response, bytes calldata signature)
        external
        override
        onlyValidOperator
    {
        uint32 taskIndex = _findTaskByMatchHash(matchHash);
        require(taskIndex < latestTaskNum, "Task not found");

        Task storage task = tasks[taskIndex];
        require(!task.isCompleted, "Task already completed");
        require(!hasResponded[taskIndex][msg.sender], "Already responded");
        require(
            block.number <= task.createdBlock + (TASK_RESPONSE_WINDOW / 12), // ~12 sec/block
            "Response window closed"
        );

        // Verify signature (simplified - in production would verify against match data)
        require(signature.length > 0, "Invalid signature");

        // Record response
        taskResponses[taskIndex].push(
            TaskResponse({response: response, operator: msg.sender, signature: signature, timestamp: block.timestamp})
        );

        hasResponded[taskIndex][msg.sender] = true;
        responseVotes[taskIndex][response]++;

        // Record validation in service manager
        serviceManager.recordTaskValidation(taskIndex, msg.sender);

        emit TaskResponded(taskIndex, msg.sender, response);

        // Check if quorum reached
        _checkQuorum(taskIndex);
    }

    /**
     * @dev Check if consensus has been reached and complete task if so
     */
    function _checkQuorum(uint32 taskIndex) internal {
        Task storage task = tasks[taskIndex];
        if (task.isCompleted) return;

        uint256 totalOperators = serviceManager.getActiveOperatorCount();
        uint256 totalResponses = taskResponses[taskIndex].length;

        // Need minimum percentage of operators to respond
        if (totalResponses * 100 < totalOperators * task.quorumThreshold) {
            return;
        }

        // Find the response with most votes
        bytes32 consensusResponse;
        uint256 maxVotes = 0;

        for (uint256 i = 0; i < taskResponses[taskIndex].length; i++) {
            bytes32 response = taskResponses[taskIndex][i].response;
            uint256 votes = responseVotes[taskIndex][response];

            if (votes > maxVotes) {
                maxVotes = votes;
                consensusResponse = response;
            }
        }

        // Check if consensus response has enough votes
        if (maxVotes * 100 >= totalResponses * task.quorumThreshold) {
            task.isCompleted = true;

            emit QuorumReached(taskIndex, consensusResponse, uint32(maxVotes));
            emit ConsensusAchieved(taskIndex, consensusResponse);

            // Distribute rewards to operators who gave the consensus response
            _distributeRewards(taskIndex, consensusResponse);
        }
    }

    /**
     * @dev Distribute rewards to operators who provided the consensus response
     */
    function _distributeRewards(uint32 taskIndex, bytes32 consensusResponse) internal {
        // Find all operators who gave the consensus response
        address[] memory validOperators = new address[](responseVotes[taskIndex][consensusResponse]);
        uint256 count = 0;

        for (uint256 i = 0; i < taskResponses[taskIndex].length; i++) {
            TaskResponse memory taskResponse = taskResponses[taskIndex][i];
            if (taskResponse.response == consensusResponse) {
                validOperators[count] = taskResponse.operator;
                count++;
            }
        }

        // Resize array to actual count
        assembly {
            mstore(validOperators, count)
        }

        // Distribute rewards via service manager
        if (count > 0) {
            serviceManager.distributeTaskReward(taskIndex, validOperators);
        }
    }

    /**
     * @dev Find task index by match hash
     */
    function _findTaskByMatchHash(bytes32 matchHash) internal view returns (uint32) {
        for (uint32 i = 0; i < latestTaskNum; i++) {
            if (tasks[i].matchHash == matchHash) {
                return i;
            }
        }
        revert("Task not found");
    }

    /**
     * @dev Get task details by index
     */
    function getTask(uint32 taskIndex) external view override returns (Task memory) {
        require(taskIndex < latestTaskNum, "Task does not exist");
        return tasks[taskIndex];
    }

    /**
     * @dev Get responses for a specific task
     */
    function getTaskResponses(uint32 taskIndex) external view override returns (TaskResponse[] memory) {
        require(taskIndex < latestTaskNum, "Task does not exist");
        return taskResponses[taskIndex];
    }

    /**
     * @dev Check if consensus has been reached for a task
     */
    function hasConsensus(uint32 taskIndex) external view override returns (bool, bytes32) {
        require(taskIndex < latestTaskNum, "Task does not exist");

        Task memory task = tasks[taskIndex];
        if (!task.isCompleted) {
            return (false, bytes32(0));
        }

        // Find consensus response
        bytes32 consensusResponse;
        uint256 maxVotes = 0;

        for (uint256 i = 0; i < taskResponses[taskIndex].length; i++) {
            bytes32 response = taskResponses[taskIndex][i].response;
            uint256 votes = responseVotes[taskIndex][response];

            if (votes > maxVotes) {
                maxVotes = votes;
                consensusResponse = response;
            }
        }

        return (true, consensusResponse);
    }

    /**
     * @dev Get the consensus response for a completed task
     */
    function getConsensusResponse(uint32 taskIndex) external view override returns (bytes32) {
        (bool hasReached, bytes32 response) = this.hasConsensus(taskIndex);
        require(hasReached, "No consensus reached");
        return response;
    }

    /**
     * @dev Force complete a task (emergency function)
     */
    function forceCompleteTask(uint32 taskIndex) external {
        require(taskIndex < latestTaskNum, "Task does not exist");

        Task storage task = tasks[taskIndex];
        require(!task.isCompleted, "Task already completed");
        require(
            block.number > task.createdBlock + (TASK_RESPONSE_WINDOW / 12) + 100, // Grace period
            "Cannot force complete yet"
        );

        task.isCompleted = true;
        emit ConsensusAchieved(taskIndex, bytes32(0)); // No consensus
    }
}
