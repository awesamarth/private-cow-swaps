// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Foundry libraries
import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {PrivateCow} from "../src/PrivateCow.sol";

contract PrivateCowTest is Test, Deployers, ERC1155Holder {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // The two currencies (tokens) from the pool
    Currency token0;
    Currency token1;

    PrivateCow hook;
    PoolId poolId;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address operator = makeAddr("operator");

    function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();

        // Deploy two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();

        // Deploy our hook with correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(flags);
        deployCodeTo(
            "PrivateCow.sol",
            abi.encode(manager, ""),
            hookAddress
        );
        hook = PrivateCow(hookAddress);

        // Initialize a pool with these two tokens
        (key, poolId) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);

        // Add liquidity like CSMM does
        IERC20Minimal(Currency.unwrap(key.currency0)).approve(address(hook), 1000 ether);
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(address(hook), 1000 ether);
        
        hook.addLiquidity(key, 1000e18);

        // Add initial liquidity to the pool for price discovery
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // Set up test accounts
        _dealTokensToUser(alice, 1000 ether);
        _dealTokensToUser(bob, 1000 ether);
        
        // Add operator
        hook.addOperator(operator);
    }

    function _dealTokensToUser(address user, uint256 amount) internal {
        deal(Currency.unwrap(token0), user, amount);
        deal(Currency.unwrap(token1), user, amount);
        
        vm.startPrank(user);
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function test_deploymentState() public {
        // Check hook permissions
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.beforeSwapReturnDelta);
        assertFalse(permissions.afterSwap);

        // Check operator status
        assertTrue(hook.authorizedOperators(operator));
        assertFalse(hook.authorizedOperators(alice));

        // Check initial order ID
        assertEq(hook.nextOrderId(), 1);
    }

    function test_singleOrderCreation() public {
        uint256 swapAmount = 10 ether;
        
        // Record initial balances
        uint256 aliceToken0Before = token0.balanceOf(alice);
        
        // Alice places a zeroForOne order (sell token0 for token1)
        vm.prank(alice);
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Check that an order was created
        assertEq(hook.nextOrderId(), 2); // Should increment to 2

        // Check order details
        PrivateCow.CowOrder memory order = hook.getOrderDetails(1);
        assertEq(order.trader, alice);
        assertEq(order.amountIn, swapAmount);
        assertTrue(order.isZeroForOne);
        assertTrue(order.isActive);
        assertEq(PoolId.unwrap(order.poolId), PoolId.unwrap(poolId));

        // Check active orders tracking
        (uint256[] memory buyOrders, uint256[] memory sellOrders) = hook.getActiveOrders(poolId);
        assertEq(buyOrders.length, 1);
        assertEq(sellOrders.length, 0);
        assertEq(buyOrders[0], 1);

        // Check trader orders tracking
        uint256[] memory aliceOrders = hook.getOrdersByTrader(alice);
        assertEq(aliceOrders.length, 1);
        assertEq(aliceOrders[0], 1);

        // Alice should have spent token0 (tokens are held by hook)
        uint256 aliceToken0After = token0.balanceOf(alice);
        assertEq(aliceToken0Before - aliceToken0After, swapAmount);
    }

    // function test_immediateCoWMatch() public {
    //     uint256 swapAmount = 10 ether;

    //     // Record initial balances
    //     uint256 aliceToken0Before = token0.balanceOf(alice);
    //     uint256 aliceToken1Before = token1.balanceOf(alice);
    //     uint256 bobToken0Before = token0.balanceOf(bob);
    //     uint256 bobToken1Before = token1.balanceOf(bob);

    //     // Alice places a zeroForOne order (sell token0 for token1)
    //     vm.prank(alice);
    //     SwapParams memory aliceParams = SwapParams({
    //         zeroForOne: true,
    //         amountSpecified: -int256(swapAmount),
    //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //     });

    //     PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
    //         takeClaims: false,
    //         settleUsingBurn: false
    //     });

    //     swapRouter.swap(key, aliceParams, testSettings, ZERO_BYTES);

    //     // Verify Alice's order was created
    //     assertEq(hook.nextOrderId(), 2);
    //     PrivateCow.CowOrder memory aliceOrder = hook.getOrderDetails(1);
    //     assertTrue(aliceOrder.isActive);

    //     // Bob places opposite order (oneForZero - buy token0 with token1) with same amount
    //     vm.prank(bob);
    //     SwapParams memory bobParams = SwapParams({
    //         zeroForOne: false,
    //         amountSpecified: -int256(swapAmount),
    //         sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
    //     });

    //     swapRouter.swap(key, bobParams, testSettings, ZERO_BYTES);

    //     // Check that immediate CoW matching occurred
    //     // Alice's order should be deactivated
    //     PrivateCow.CowOrder memory aliceOrderAfter = hook.getOrderDetails(1);
    //     assertFalse(aliceOrderAfter.isActive);

    //     // No new order should be created for Bob since it was immediately matched
    //     assertEq(hook.nextOrderId(), 2);

    //     // Check that no active orders remain
    //     (uint256[] memory buyOrders, uint256[] memory sellOrders) = hook.getActiveOrders(poolId);
    //     assertEq(buyOrders.length, 0);
    //     assertEq(sellOrders.length, 0);

    //     // Check final balances - both should have received the opposite token
    //     uint256 aliceToken0After = token0.balanceOf(alice);
    //     uint256 aliceToken1After = token1.balanceOf(alice);
    //     uint256 bobToken0After = token0.balanceOf(bob);
    //     uint256 bobToken1After = token1.balanceOf(bob);

    //     // Alice should have less token0 and more token1
    //     assertEq(aliceToken0Before - aliceToken0After, swapAmount);
    //     assertEq(aliceToken1After - aliceToken1Before, swapAmount);

    //     // Bob should have more token0 and less token1
    //     assertEq(bobToken0After - bobToken0Before, swapAmount);
    //     assertEq(bobToken1Before - bobToken1After, swapAmount);
    // }

    // function test_operatorSettlement() public {
    //     uint256 swapAmount = 15 ether;

    //     // Alice places zeroForOne order
    //     vm.prank(alice);
    //     SwapParams memory aliceParams = SwapParams({
    //         zeroForOne: true,
    //         amountSpecified: -int256(swapAmount),
    //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //     });

    //     PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
    //         takeClaims: false,
    //         settleUsingBurn: false
    //     });

    //     swapRouter.swap(key, aliceParams, testSettings, ZERO_BYTES);

    //     // Bob places oneForZero order with same amount
    //     vm.prank(bob);
    //     SwapParams memory bobParams = SwapParams({
    //         zeroForOne: false,
    //         amountSpecified: -int256(swapAmount),
    //         sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
    //     });

    //     swapRouter.swap(key, bobParams, testSettings, ZERO_BYTES);

    //     // Both orders should be active
    //     assertEq(hook.nextOrderId(), 3);
    //     assertTrue(hook.getOrderDetails(1).isActive);
    //     assertTrue(hook.getOrderDetails(2).isActive);

    //     // Operator settles the matching orders
    //     uint256[] memory orderIds = new uint256[](2);
    //     orderIds[0] = 1; // Alice's buy order (zeroForOne)
    //     orderIds[1] = 2; // Bob's sell order (oneForZero)

    //     vm.prank(operator);
    //     hook.settleCowMatches(orderIds);

    //     // Check that both orders are now inactive
    //     assertFalse(hook.getOrderDetails(1).isActive);
    //     assertFalse(hook.getOrderDetails(2).isActive);

    //     // Check that active orders arrays are empty
    //     (uint256[] memory buyOrders, uint256[] memory sellOrders) = hook.getActiveOrders(poolId);
    //     assertEq(buyOrders.length, 0);
    //     assertEq(sellOrders.length, 0);
    // }

    // function test_unauthorizedOperatorFails() public {
    //     uint256 swapAmount = 10 ether;

    //     // Create an order first
    //     vm.prank(alice);
    //     SwapParams memory params = SwapParams({
    //         zeroForOne: true,
    //         amountSpecified: -int256(swapAmount),
    //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //     });

    //     PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
    //         takeClaims: false,
    //         settleUsingBurn: false
    //     });

    //     swapRouter.swap(key, params, testSettings, ZERO_BYTES);

    //     // Try to settle with unauthorized user
    //     uint256[] memory orderIds = new uint256[](2);
    //     orderIds[0] = 1;
    //     orderIds[1] = 1;

    //     vm.prank(alice); // Alice is not an authorized operator
    //     vm.expectRevert("Not authorized operator");
    //     hook.settleCowMatches(orderIds);
    // }

    function test_invalidOrderSettlement() public {
        uint256 swapAmount = 10 ether;

        // Create two orders in same direction (both zeroForOne)
        vm.prank(alice);
        SwapParams memory aliceParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(key, aliceParams, testSettings, ZERO_BYTES);

        vm.prank(bob);
        SwapParams memory bobParams = SwapParams({
            zeroForOne: true, // Same direction as Alice
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap(key, bobParams, testSettings, ZERO_BYTES);

        // Try to settle same-direction orders
        uint256[] memory orderIds = new uint256[](2);
        orderIds[0] = 1;
        orderIds[1] = 2;

        vm.prank(operator);
        vm.expectRevert("Same direction");
        hook.settleCowMatches(orderIds);
    }

    function test_sameDirectionOrdersNoMatch() public {
        uint256 swapAmount = 10 ether;

        // Alice places zeroForOne order
        vm.prank(alice);
        SwapParams memory aliceParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(key, aliceParams, testSettings, ZERO_BYTES);

        // Bob places another zeroForOne order (same direction)
        vm.prank(bob);
        SwapParams memory bobParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap(key, bobParams, testSettings, ZERO_BYTES);

        // Both orders should be created since no immediate match
        assertEq(hook.nextOrderId(), 3);
        assertTrue(hook.getOrderDetails(1).isActive);
        assertTrue(hook.getOrderDetails(2).isActive);

        // Check that both orders are in the same direction list
        (uint256[] memory buyOrders, uint256[] memory sellOrders) = hook.getActiveOrders(poolId);
        assertEq(buyOrders.length, 2); // Both are zeroForOne (buy orders)
        assertEq(sellOrders.length, 0);
    }

    function test_orderExpiration() public {
        uint256 swapAmount = 10 ether;

        // Alice places an order
        vm.prank(alice);
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Fast forward time beyond expiration (1 hour + 1 second)
        vm.warp(block.timestamp + 3601);

        // Bob tries to place opposite order
        vm.prank(bob);
        SwapParams memory bobParams = SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(key, bobParams, testSettings, ZERO_BYTES);

        // Should not match expired order - both orders should exist
        assertEq(hook.nextOrderId(), 3);
        assertTrue(hook.getOrderDetails(1).isActive); // Alice's order (expired but still marked active)
        assertTrue(hook.getOrderDetails(2).isActive); // Bob's order

        // Verify no immediate settlement occurred
        (uint256[] memory buyOrders, uint256[] memory sellOrders) = hook.getActiveOrders(poolId);
        assertEq(buyOrders.length, 1); // Alice's zeroForOne
        assertEq(sellOrders.length, 1); // Bob's oneForZero
    }

    function test_multipleOrdersTracking() public {
        uint256 swapAmount = 5 ether;

        // Create multiple orders from different users
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = makeAddr("charlie");
        
        _dealTokensToUser(users[2], 1000 ether);

        // Each user places a zeroForOne order
        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            SwapParams memory params = SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });

            PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            });

            swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        }

        // Check that all orders are tracked
        assertEq(hook.nextOrderId(), 4); // Should be 4 (1, 2, 3 created)
        
        (uint256[] memory buyOrders, uint256[] memory sellOrders) = hook.getActiveOrders(poolId);
        assertEq(buyOrders.length, 3);
        assertEq(sellOrders.length, 0);

        // Check individual trader tracking
        for (uint256 i = 0; i < users.length; i++) {
            uint256[] memory userOrders = hook.getOrdersByTrader(users[i]);
            assertEq(userOrders.length, 1);
            assertEq(userOrders[0], i + 1); // Order IDs 1, 2, 3
        }
    }

    function test_hookEvents() public {
        uint256 swapAmount = 10 ether;

        // Test CowOrderCreated event
        vm.prank(alice);
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        vm.expectEmit(true, true, false, true);
        emit PrivateCow.CowOrderCreated(1, alice, swapAmount, true);
        
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Create second order and test settlement event
        vm.prank(bob);
        SwapParams memory bobParams = SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(key, bobParams, testSettings, ZERO_BYTES);

        // Test CowTradeSettled event during operator settlement
        uint256[] memory orderIds = new uint256[](2);
        orderIds[0] = 1;
        orderIds[1] = 2;

        vm.expectEmit(true, true, false, true);
        emit PrivateCow.CowTradeSettled(1, 2, swapAmount);

        vm.prank(operator);
        hook.settleCowMatches(orderIds);
    }
}