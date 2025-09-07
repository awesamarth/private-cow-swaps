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
 * @title PrivateCowHook
 * @notice A Uniswap V4 Hook for Coincidence of Wants (Cow) matching
 * @dev Intercepts swaps to find opposite orders and execute Cow trades
 */
contract PrivateCowHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    // Events
    event CowOrderPlaced(
        address indexed trader,
        PoolId indexed poolId,
        uint256 indexed orderId,
        uint256 amountIn,
        uint256 minAmountOut,
        bool zeroForOne
    );

    event CowTradeExecuted(
        address indexed buyer,
        address indexed seller,
        PoolId indexed poolId,
        uint256 amountIn,
        uint256 amountOut,
        uint256 executionPrice
    );

    event CowMatchSettled(bytes32 indexed matchHash, address indexed buyer, address indexed seller, uint256 amount);

    // Order struct
    struct CowOrder {
        address trader;
        uint256 amountIn;
        uint256 minAmountOut;
        bool zeroForOne;
        uint256 deadline;
        bool isActive;
    }

    // State variables
    uint256 public nextOrderId = 1;
    mapping(uint256 => CowOrder) public orders;
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
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        
        // CSMM jaise absolute value nikaal
        uint256 amountSpecified = params.amountSpecified < 0 
            ? uint256(-params.amountSpecified) 
            : uint256(params.amountSpecified);
        
        // Order create kar
        uint256 orderId = nextOrderId++;
        orders[orderId] = CowOrder({
            trader: tx.origin,
            amountIn: amountSpecified,
            minAmountOut: (amountSpecified * 95) / 100,
            zeroForOne: params.zeroForOne,
            deadline: block.timestamp + 1 hours,
            isActive: true
        });
        
        traderOrders[tx.origin].push(orderId);
        emit CowOrderPlaced(sender, poolId, orderId, amountSpecified, (amountSpecified * 95) / 100, params.zeroForOne);
        
        // CSMM pattern - proper int128 conversion
        int128 absAmount = int128(int256(amountSpecified));
        
        // Take tokens like CSMM does
        if (params.zeroForOne) {
            key.currency0.take(poolManager, address(this), amountSpecified, true);
        } else {
            key.currency1.take(poolManager, address(this), amountSpecified, true);
        }
        
        // Delta - CSMM style with proper signs
        BeforeSwapDelta holdDelta = toBeforeSwapDelta(
            params.amountSpecified < 0 ? absAmount : -absAmount,  // Input delta
            0  // No output yet
        );
        
        return (this.beforeSwap.selector, holdDelta, 0);
    }






    /**
     * @dev AVS function to settle complex Cow matches found off-chain
     * Note: In production, operator validation would be done by DarkPoolServiceManager
     */
    function settleCowMatches(
        bytes32[] calldata matchHashes,
        address[] calldata buyers,
        address[] calldata sellers,
        uint256[] calldata amounts
    ) external {
        // TODO: Add operator validation via DarkPoolServiceManager
        // require(serviceManager.isValidOperator(msg.sender), "Not a valid operator");

        require(
            matchHashes.length == buyers.length && buyers.length == sellers.length && sellers.length == amounts.length,
            "Array length mismatch"
        );

        for (uint256 i = 0; i < matchHashes.length; i++) {
            // Mark as settled (no token transfers needed - Pool Manager handles it)
            settledMatches[matchHashes[i]] = true;

            emit CowMatchSettled(matchHashes[i], buyers[i], sellers[i], amounts[i]);
        }
    }

    /**
     * @dev Cancel an order
     */
    function cancelOrder(uint256 orderId) external {
        CowOrder storage order = orders[orderId];
        require(order.trader == msg.sender, "Not your order");
        require(order.isActive, "Order not active");

        order.isActive = false;
        // Note: In full implementation, would need to return held tokens to user
    }

    // View functions
    function getOrder(uint256 orderId) external view returns (CowOrder memory) {
        return orders[orderId];
    }


    function getTraderOrders(address trader) external view returns (uint256[] memory) {
        return traderOrders[trader];
    }
}
