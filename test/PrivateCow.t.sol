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
import {PrivateCowHook} from "../src/PrivateCow.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {CurrencyDelta} from "v4-core/libraries/CurrencyDelta.sol";


contract PrivateCowHookTest is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    PrivateCowHook hook;
    address alice = address(0x1);
    address bob = address(0x2);

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        console.log("currency 0 :", Currency.unwrap(currency0));
        console.log("currency 1 :", Currency.unwrap(currency1));
        

        // Deploy hook with proper permissions
        address hookAddress = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));

        deployCodeTo("PrivateCow.sol", abi.encode(manager), hookAddress);
        hook = PrivateCowHook(hookAddress);

        console.log("hook address is here: ", hookAddress);

        // Initialize pool
        (key,) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1);

        IERC20Minimal(Currency.unwrap(key.currency0)).approve(hookAddress, 1000 ether);
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(hookAddress, 1000 ether);
        console.log("reached here one");

        // Fund alice and bob
        deal(Currency.unwrap(currency0), alice, 1000e18);
        deal(Currency.unwrap(currency1), alice, 1000e18);
        deal(Currency.unwrap(currency0), bob, 1000e18);
        deal(Currency.unwrap(currency1), bob, 1000e18);
        console.log("reached here  two");

        // Approve hook to spend tokens
        vm.startPrank(alice);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hookAddress), 1000 ether);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(manager), 1000 ether);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hookAddress), 1000 ether);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(manager), 1000 ether);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), 1000 ether);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), 1000 ether);
        
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hookAddress), 1000 ether);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(manager), 1000 ether);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hookAddress), 1000 ether);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(manager), 1000 ether);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), 1000 ether);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), 1000 ether);
        
        vm.stopPrank();
        console.log("reached here  three");
        // hook.addLiquidity(key, 1000e18);
    }

    function test_firstOrderCreation() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 balanceAliceToken0Before = currency0.balanceOf(alice);
        console.log("Alice balance:", currency0.balanceOf(alice));
        console.log(
            "Alice allowance to manager:", IERC20Minimal(Currency.unwrap(currency0)).allowance(alice, address(manager))
        );

        // Alice wants to swap 100 Token0 for Token1 (to be stored in hook)
        vm.prank(alice);
        int delta0 = CurrencyDelta.getDelta(currency0, alice);
        console.log("alice ka delta", delta0);
        int delta1 = CurrencyDelta.getDelta(currency0, alice);
        console.log("alice ka delta", delta1);


        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings,
            ZERO_BYTES
        );

        uint256 balanceAliceToken0After = currency0.balanceOf(alice);
        console.log("balance of alice token 0 after: ", balanceAliceToken0After);

        // Alice should have lost 100 Token0 (held by hook for Cow matching)
        assertEq(balanceAliceToken0Before - balanceAliceToken0After, 100e18);
        
        // Check order was created
        assertEq(hook.nextOrderId(), 2); // Should be 2 (started at 1, incremented to 2)

        // Check order details
        PrivateCowHook.CowOrder memory order = hook.getOrder(1);

        assertEq(order.trader, alice);
        assertEq(order.amountIn, 100e18);
        assertEq(order.zeroForOne, true);
        assertEq(order.isActive, true);
    }

    function test_deployment() public view {
        // Check hook is deployed
        assertTrue(address(hook).code.length > 0);

        // Check hook permissions
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.beforeSwapReturnDelta);

        console.log("Hook deployed at:", address(hook));
        console.log("Pool initialized");
    }

    // function test_twoOrdersCreated() public {
    //     PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
    //         takeClaims: false,
    //         settleUsingBurn: false
    //     });

    //     // Alice creates order (100 Token0 -> Token1)
    //     vm.prank(alice);
    //     swapRouter.swap(
    //         key,
    //         SwapParams({
    //             zeroForOne: true,
    //             amountSpecified: -100e18,
    //             sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //         }),
    //         settings,
    //         ZERO_BYTES
    //     );

    //     // Bob creates opposite order (100 Token1 -> Token0)
    //     vm.prank(bob);
    //     swapRouter.swap(
    //         key,
    //         SwapParams({
    //             zeroForOne: false,
    //             amountSpecified: -100e18,
    //             sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
    //         }),
    //         settings,
    //         ZERO_BYTES
    //     );

    //     // Both orders should be created and active (no immediate matching)
    //     assertEq(hook.nextOrderId(), 3); // Started at 1, now should be 3

    //     // Check Alice's order
    //     PrivateCowHook.CowOrder memory aliceOrder = hook.getOrder(1);
    //     assertEq(aliceOrder.trader, alice);
    //     assertEq(aliceOrder.amountIn, 100e18);
    //     assertTrue(aliceOrder.zeroForOne);
    //     assertTrue(aliceOrder.isActive);

    //     // Check Bob's order
    //     PrivateCowHook.CowOrder memory bobOrder = hook.getOrder(2);
    //     assertEq(bobOrder.trader, bob);
    //     assertEq(bobOrder.amountIn, 100e18);
    //     assertFalse(bobOrder.zeroForOne);
    //     assertTrue(bobOrder.isActive);

    //     // Both should have lost their input tokens (held by hook)
    //     assertEq(currency0.balanceOf(alice), 900e18); // Started with 1000, lost 100
    //     assertEq(currency1.balanceOf(bob), 900e18); // Started with 1000, lost 100

    //     console.log("Two opposite orders created successfully");
    //     console.log("Ready for AVS to find matches off-chain");
    // }

    // function test_cancelOrder() public {
    //     PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
    //         takeClaims: false,
    //         settleUsingBurn: false
    //     });

    //     // Alice creates an order
    //     vm.prank(alice);
    //     swapRouter.swap(
    //         key,
    //         SwapParams({
    //             zeroForOne: true,
    //             amountSpecified: -100e18,
    //             sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //         }),
    //         settings,
    //         ZERO_BYTES
    //     );

    //     // Check order is active
    //     PrivateCowHook.CowOrder memory orderBefore = hook.getOrder(1);
    //     assertTrue(orderBefore.isActive);

    //     // Alice cancels the order
    //     vm.prank(alice);
    //     hook.cancelOrder(1);

    //     // Check order is now inactive
    //     PrivateCowHook.CowOrder memory orderAfter = hook.getOrder(1);
    //     assertFalse(orderAfter.isActive);

    //     console.log("Order cancelled successfully");
    // }
}
