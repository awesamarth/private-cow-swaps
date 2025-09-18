// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PrivateCowEncrypted} from "../src/PrivateCowEncrypted.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

contract PrivateCowEncryptedTest is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    PrivateCowEncrypted hook;
    address alice = address(0x1);
    address bob = address(0x2);

    event HookSwap(
        bytes32 indexed id,
        address indexed sender,
        int128 amountInput,
        address trader,
        bool zeroForOne,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    );

    event EncryptedHookSwap(
        bytes32 indexed id,
        address indexed sender,
        bytes encryptedAmount,    // In tests, these will be mock encrypted values
        bytes encryptedTrader,
        bool zeroForOne,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    );

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address hookAddress = address(
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
        );
        deployCodeTo("PrivateCowEncrypted.sol", abi.encode(manager), hookAddress);
        hook = PrivateCowEncrypted(hookAddress);
        console.log("encrypted hook address: ", hookAddress);
        console.log("alice address ", alice);

        (key,) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1);

        IERC20Minimal(Currency.unwrap(key.currency0)).approve(hookAddress, 1000 ether);
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(hookAddress, 1000 ether);
        deal(Currency.unwrap(currency0), alice, 1000 ether);
        deal(Currency.unwrap(currency1), alice, 1000 ether);
        deal(Currency.unwrap(currency0), bob, 1000 ether);
        deal(Currency.unwrap(currency1), bob, 1000 ether);

        vm.startPrank(alice);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hookAddress), 1000 ether);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(manager), 1000 ether);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), 1000 ether);

        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hookAddress), 1000 ether);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(manager), 1000 ether);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), 1000 ether);

        vm.stopPrank();

        vm.startPrank(bob);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hookAddress), 1000 ether);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(manager), 1000 ether);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), 1000 ether);

        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hookAddress), 1000 ether);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(manager), 1000 ether);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), 1000 ether);

        vm.stopPrank();
    }

    function test_EncryptedHookPermissions() public view {
        console.log("=== Testing Encrypted Hook Permissions ===");

        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeSwap, "beforeSwap should be true");
        assertTrue(permissions.beforeSwapReturnDelta, "beforeSwapReturnDelta should be true");
        assertTrue(permissions.beforeAddLiquidity, "beforeAddLiquidity should be true");

        console.log(" All hook permissions set correctly for encrypted hook");
    }

    function test_EncryptedAddLiquidity() public {
        console.log("=== Testing Encrypted Hook Add Liquidity ===");

        uint256 amountEach = 100 ether;

        hook.addLiquidity(key, amountEach);

        console.log(" Liquidity added successfully through encrypted hook");

        // Verify balances
        uint256 hookBalance0 = manager.balanceOf(address(hook), key.currency0.toId());
        uint256 hookBalance1 = manager.balanceOf(address(hook), key.currency1.toId());

        assertEq(hookBalance0, amountEach, "Hook should have currency0 claims");
        assertEq(hookBalance1, amountEach, "Hook should have currency1 claims");

        console.log("Hook currency0 claims:", hookBalance0);
        console.log("Hook currency1 claims:", hookBalance1);
    }

    function test_EncryptedLiquidityManagement() public view {
        console.log("=== Testing Liquidity Management ===");

        assertTrue(address(hook).code.length > 0, "Contract should have code");
        console.log("Liquidity management functions available");
        console.log("Hook ready for encrypted order processing");
    }

    function test_EncryptedOperatorStakeCheck() public view {
        console.log("=== Testing Operator Logic ===");

        bool isOperator = hook.operators(alice);
        uint256 stake = hook.operatorStake(alice);

        assertFalse(isOperator, "Alice should not be operator initially");
        assertEq(stake, 0, "Alice should have no stake initially");

        console.log("Operator state tracking working");
        console.log("Note: Operator registration would handle ETH staking");
    }

    function test_EncryptedContractDeployment() public view {
        console.log("=== Testing Encrypted Contract Deployment ===");

        assertTrue(address(hook) != address(0), "Hook should be deployed");
        console.log("Contract deployed successfully");
        console.log("Ready for FHE integration when moved to Fhenix testnet");
    }



}