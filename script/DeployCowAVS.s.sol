// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/CowServiceManager.sol";
import "../src/CowTaskManager.sol";

/**
 * @title DeployCowAVS
 * @dev Deployment script for CoW AVS contracts on local foundry
 */
contract DeployCowAVS is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("OPERATOR_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying CoW AVS contracts...");
        console.log("========================================");

        // Deploy ServiceManager first
        console.log("Deploying CowServiceManager...");
        CowServiceManager serviceManager = new CowServiceManager();
        console.log("  ServiceManager deployed at:", address(serviceManager));

        // Deploy TaskManager with ServiceManager address
        console.log(" Deploying CowTaskManager...");
        CowTaskManager taskManager = new CowTaskManager(address(serviceManager));
        console.log("  TaskManager deployed at:", address(taskManager));

        // Add TaskManager as authorized caller to ServiceManager
        console.log("Connecting TaskManager to ServiceManager...");
        serviceManager.addTaskManager(address(taskManager));
        console.log("    TaskManager authorized");

        console.log("");
        console.log("AVS Deployment Complete!");
        console.log("========================================");
        console.log("Contract Addresses:");
        console.log("  CowServiceManager:", address(serviceManager));
        console.log("  CowTaskManager:", address(taskManager));
        console.log("");
        console.log("Environment Variables:");
        console.log("SERVICE_MANAGER_ADDRESS=", address(serviceManager));
        console.log("TASK_MANAGER_ADDRESS=", address(taskManager));
        console.log("");
        console.log("Ready to start your operator!");

        vm.stopBroadcast();
    }
}
