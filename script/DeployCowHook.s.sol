// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {PrivateCow} from "../src/PrivateCow.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {console} from "forge-std/console.sol";

contract DeployCowHook is Script, Deployers {
    // Override to fix address(this) issue in scripts
    function deployFreshManager() internal override {
        manager = new PoolManager(msg.sender); // Use msg.sender instead of address(this)
    }

    function run() public {
        vm.startBroadcast();

        console.log("Deploying CoW Hook and related contracts...");

        // Deploy manager and routers
        deployFreshManagerAndRouters();

        // Calculate hook flags and address
        uint160 flags =
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

        console.log("Mining hook address...");

        // Use HookMiner to find correct salt for deployment
        bytes memory constructorArgs = abi.encode(manager);
        (address minedAddress, bytes32 salt) = HookMiner.find(
            0x4e59b44847b379578588920cA78FbF26c0B4956C, // CREATE2_DEPLOYER
            flags,
            type(PrivateCow).creationCode,
            constructorArgs
        );

        console.log("Mined address:", minedAddress);

        // Deploy hook using CREATE2 with mined salt
        PrivateCow hook = new PrivateCow{salt: salt}(manager);
        require(address(hook) == minedAddress, "Hook deployment failed");
        console.log("PrivateCow Hook deployed at:", address(hook));
        console.log("PoolManager deployed at:", address(manager));

        vm.stopBroadcast();

    }
}
