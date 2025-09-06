// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

/**
 * @title PrivateCoWHook
 * @notice A Uniswap V4 Hook for Coincidence of Wants (CoW) matching
 * @dev Intercepts swaps to find opposite orders and execute CoW trades
 */
contract PrivateCoWHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    // Events
    event CoWOrderPlaced(
        address indexed trader,
        PoolId indexed poolId,
        uint256 indexed orderId,
        uint256 amountIn,
        uint256 minAmountOut,
        bool zeroForOne
    );

    event CoWTradeExecuted(
        address indexed buyer,
        address indexed seller,
        PoolId indexed poolId,
        uint256 amountIn,
        uint256 amountOut,
        uint256 executionPrice
    );

    event CoWMatchSettled(
        bytes32 indexed matchHash,
        address indexed buyer,
        address indexed seller,
        uint256 amount
    );

    // Order struct
    struct CoWOrder {
        address trader;
        uint256 amountIn;
        uint256 minAmountOut;
        bool zeroForOne;
        uint256 deadline;
        bool isActive;
    }

    // State variables
    uint256 public nextOrderId = 1;
    mapping(uint256 => CoWOrder) public orders;
    mapping(PoolId => uint256[]) public activeBuyOrders;  // zeroForOne = true
    mapping(PoolId => uint256[]) public activeSellOrders; // zeroForOne = false
    mapping(address => uint256[]) public traderOrders;
    mapping(bytes32 => bool) public settledMatches;


    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @dev Get hook permissions
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * @dev Main hook function - intercepts all swaps
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        uint256 amountSpecified = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);
        

        // Try to find immediate CoW match
       // gonna emit an event here
    }


    /**
     * @dev Execute immediate CoW trade when match found
     */
    function _executeCoWTrade(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        uint256 matchedOrderId
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        CoWOrder storage matchedOrder = orders[matchedOrderId];
        PoolId poolId = key.toId();

        uint256 amountSpecified = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        // Calculate trade amounts (1:1 for simplicity)
        uint256 amountIn = amountSpecified;
        uint256 amountOut = matchedOrder.amountIn;

        // Update order state
        matchedOrder.isActive = false;
        _removeFromActiveOrders(poolId, matchedOrderId, !params.zeroForOne);

        // Create delta for swap execution - this tells Pool Manager how to move tokens
        int128 specifiedDelta;
        int128 unspecifiedDelta;

        if (params.zeroForOne) {
            // token0 -> token1: sender loses token0, gains token1
            specifiedDelta = -int128(int256(amountIn));
            unspecifiedDelta = int128(int256(amountOut));
        } else {
            // token1 -> token0: sender loses token1, gains token0  
            specifiedDelta = -int128(int256(amountIn));
            unspecifiedDelta = int128(int256(amountOut));
        }

        // This delta completely replaces the AMM swap
        BeforeSwapDelta cowDelta = toBeforeSwapDelta(specifiedDelta, unspecifiedDelta);

        // Emit successful CoW execution
        emit CoWTradeExecuted(
            params.zeroForOne ? sender : matchedOrder.trader, // buyer
            params.zeroForOne ? matchedOrder.trader : sender, // seller
            poolId,
            amountIn,
            amountOut,
            (amountOut * 1e18) / amountIn // execution price
        );

        return (this.beforeSwap.selector, cowDelta, 0);
    }

    /**
     * @dev Create pending order when no immediate match found
     */
    function _createPendingOrder(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        uint256 amountSpecified = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        // Create the order
        uint256 orderId = nextOrderId++;
        orders[orderId] = CoWOrder({
            trader: sender,
            amountIn: amountSpecified,
            minAmountOut: (amountSpecified * 95) / 100, // 5% slippage tolerance
            zeroForOne: params.zeroForOne,
            deadline: block.timestamp + 1 hours, // 1 hour expiry
            isActive: true
        });

        // Track the order
        traderOrders[sender].push(orderId);
        if (params.zeroForOne) {
            activeBuyOrders[poolId].push(orderId);
        } else {
            activeSellOrders[poolId].push(orderId);
        }

        // Emit order creation event (AVS will listen to this)
        emit CoWOrderPlaced(
            sender,
            poolId,
            orderId,
            amountSpecified,
            (amountSpecified * 95) / 100,
            params.zeroForOne
        );

        // Create delta that takes user's tokens but stops the AMM swap
        int128 specifiedDelta = -int128(int256(amountSpecified)); // Take their input tokens
        int128 unspecifiedDelta = int128(int256(amountSpecified)); // Give back same amount (1:1 hold)

        BeforeSwapDelta holdDelta = toBeforeSwapDelta(specifiedDelta, unspecifiedDelta);

        return (this.beforeSwap.selector, holdDelta, 0);
    }

    /**
     * @dev Remove order from active lists
     */
    function _removeFromActiveOrders(
        PoolId poolId,
        uint256 orderId,
        bool isBuyOrder
    ) internal {
        uint256[] storage ordersList = isBuyOrder
            ? activeBuyOrders[poolId]
            : activeSellOrders[poolId];

        for (uint256 i = 0; i < ordersList.length; i++) {
            if (ordersList[i] == orderId) {
                ordersList[i] = ordersList[ordersList.length - 1];
                ordersList.pop();
                break;
            }
        }
    }

    /**
     * @dev AVS function to settle complex CoW matches found off-chain
     * Note: In production, operator validation would be done by DarkPoolServiceManager
     */
    function settleCoWMatches(
        bytes32[] calldata matchHashes,
        address[] calldata buyers,
        address[] calldata sellers,
        uint256[] calldata amounts
    ) external {
        // TODO: Add operator validation via DarkPoolServiceManager
        // require(serviceManager.isValidOperator(msg.sender), "Not a valid operator");
        
        require(
            matchHashes.length == buyers.length &&
            buyers.length == sellers.length &&
            sellers.length == amounts.length,
            "Array length mismatch"
        );

        for (uint256 i = 0; i < matchHashes.length; i++) {
            // Mark as settled (no token transfers needed - Pool Manager handles it)
            settledMatches[matchHashes[i]] = true;

            emit CoWMatchSettled(matchHashes[i], buyers[i], sellers[i], amounts[i]);
        }
    }

    /**
     * @dev Cancel an order
     */
    function cancelOrder(uint256 orderId) external {
        CoWOrder storage order = orders[orderId];
        require(order.trader == msg.sender, "Not your order");
        require(order.isActive, "Order not active");

        order.isActive = false;
        // Note: In full implementation, would need to return held tokens to user
    }

    // View functions
    function getOrder(uint256 orderId) external view returns (CoWOrder memory) {
        return orders[orderId];
    }

    function getActiveBuyOrders(PoolId poolId) external view returns (uint256[] memory) {
        return activeBuyOrders[poolId];
    }

    function getActiveSellOrders(PoolId poolId) external view returns (uint256[] memory) {
        return activeSellOrders[poolId];
    }

    function getTraderOrders(address trader) external view returns (uint256[] memory) {
        return traderOrders[trader];
    }
}