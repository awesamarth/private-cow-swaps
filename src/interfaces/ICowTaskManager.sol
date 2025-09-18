// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ICowTaskManager
 * @dev Interface for the CoW AVS task manager
 */
interface ICowTaskManager {
    // Task structure for CoW matching validation
    struct Task {
        bytes32 matchHash; // Hash of the CoW match data
        uint32 quorumThreshold; // Percentage of operators needed for consensus
        bytes quorumNumbers; // Quorum configuration
        uint256 createdBlock; // Block when task was created
        address creator; // Operator who created the task
        bool isCompleted; // Whether consensus was reached
        uint256 reward; // Reward for successful validation
    }

    // Response tracking for consensus
    struct TaskResponse {
        bytes32 response; // Operator's response hash
        address operator; // Operator who responded
        bytes signature; // Operator's signature
        uint256 timestamp; // When response was submitted
    }

    // Events
    event TaskCreated(uint32 indexed taskIndex, bytes32 indexed matchHash, address indexed creator, uint256 reward);

    event TaskResponded(uint32 indexed taskIndex, address indexed operator, bytes32 response);

    event QuorumReached(uint32 indexed taskIndex, bytes32 response, uint32 votes);

    event ConsensusAchieved(uint32 indexed taskIndex, bytes32 consensusResponse);

    /**
     * @dev Create a new task for CoW match validation
     * @param matchHash Hash of the CoW match data to validate
     * @param quorumThreshold Percentage of operators needed (e.g., 67 for 67%)
     * @param quorumNumbers Quorum configuration bytes
     */
    function createNewTask(bytes32 matchHash, uint32 quorumThreshold, bytes calldata quorumNumbers) external payable;

    /**
     * @dev Respond to a task with validation result
     * @param matchHash Hash of the match being validated
     * @param response Operator's validation response hash
     * @param signature Operator's signature on the response
     */
    function respondToTask(bytes32 matchHash, bytes32 response, bytes calldata signature) external;

    /**
     * @dev Get the latest task number
     */
    function latestTaskNum() external view returns (uint32);

    /**
     * @dev Get task details by index
     */
    function getTask(uint32 taskIndex) external view returns (Task memory);

    /**
     * @dev Get responses for a specific task
     */
    function getTaskResponses(uint32 taskIndex) external view returns (TaskResponse[] memory);

    /**
     * @dev Check if consensus has been reached for a task
     */
    function hasConsensus(uint32 taskIndex) external view returns (bool, bytes32);

    /**
     * @dev Get the consensus response for a completed task
     */
    function getConsensusResponse(uint32 taskIndex) external view returns (bytes32);
}
