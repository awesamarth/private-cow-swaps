// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/CowServiceManager.sol";
import "../src/CowTaskManager.sol";
import "../src/FAFO.sol";
import "v4-core/interfaces/IPoolManager.sol";

/**
 * @title DeployCowAVS
 * @dev Deployment script for CoW AVS contracts on local foundry
 */
contract DeployCowAVS is Script {

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
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

        // Deploy FAFO hook (you'll need to provide a real PoolManager address)
        console.log("Deploying FAFO Hook...");
        // NOTE: For local testing, you might need to deploy a mock PoolManager first
        // For now, using a placeholder address
        address mockPoolManager = address(0x1234567890123456789012345678901234567890);
        FAFO fafoHook = new FAFO(IPoolManager(mockPoolManager));
        console.log("FAFO Hook deployed at:", address(fafoHook));

        console.log("");
        console.log(" Deployment Complete!");
        console.log("========================================");
        console.log(" Contract Addresses:");
        console.log("   CowServiceManager:", address(serviceManager));
        console.log("   CowTaskManager:", address(taskManager));
        console.log("   FAFO Hook:", address(fafoHook));
        console.log("");
        console.log(" Save these addresses to your .env file:");
        console.log("SERVICE_MANAGER_ADDRESS=", address(serviceManager));
        console.log("TASK_MANAGER_ADDRESS=", address(taskManager));
        console.log("PRIVATE_COW_ADDRESS=", address(fafoHook));
        console.log("");
        console.log(" Ready to start your operator!");

        vm.stopBroadcast();
    }
}