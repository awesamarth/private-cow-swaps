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
import {console} from "forge-std/console.sol";

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
        int256 amountIn,
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

    event CowMatchSettled(
        bytes32 indexed matchHash,
        address indexed buyer,
        address indexed seller,
        uint256 amount
    );
    event HookModifyLiquidity(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1
    );
    // Order struct

    struct CowOrder {
        address trader;
        int256 amountIn;
        bool zeroForOne;
        uint256 deadline;
        bool isActive;
    }

    struct CallbackData {
        uint256 amountEach;
        Currency currency0;
        Currency currency1;
        address sender;
    }

    // State variables
    uint256 public nextOrderId = 1;
    mapping(uint256 => CowOrder) public orders;
    mapping(address => uint256[]) public traderOrders;
    mapping(bytes32 => bool) public settledMatches;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
        poolManager.unlock(
            abi.encode(
                CallbackData(
                    amountEach,
                    key.currency0,
                    key.currency1,
                    msg.sender
                )
            )
        );

        emit HookModifyLiquidity(
            PoolId.unwrap(key.toId()),
            address(this),
            int128(uint128(amountEach)),
            int128(uint128(amountEach))
        );
    }

    /**
     * @dev Get hook permissions
     */
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
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

        if (params.zeroForOne == false) {
            revert();
        }

        uint256 orderId = nextOrderId++;
        orders[orderId] = CowOrder({
            trader: sender,
            amountIn: params.amountSpecified,
            zeroForOne: params.zeroForOne,
            deadline: block.timestamp + 1 hours,
            isActive: true
        });


        // Create the delta
        BeforeSwapDelta holdDelta = toBeforeSwapDelta(
            int128(-params.amountSpecified),
            0
        );

        // Log what delta values we're returning
        console.log("Returning specified delta:", int128(-params.amountSpecified));

        traderOrders[sender].push(orderId);
        emit CowOrderPlaced(
            sender,
            poolId,
            orderId,
            params.amountSpecified,
            params.zeroForOne
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
            matchHashes.length == buyers.length &&
                buyers.length == sellers.length &&
                sellers.length == amounts.length,
            "Array length mismatch"
        );

        for (uint256 i = 0; i < matchHashes.length; i++) {
            // Mark as settled (no token transfers needed - Pool Manager handles it)
            settledMatches[matchHashes[i]] = true;

            emit CowMatchSettled(
                matchHashes[i],
                buyers[i],
                sellers[i],
                amounts[i]
            );
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

    function getTraderOrders(
        address trader
    ) external view returns (uint256[] memory) {
        return traderOrders[trader];
    }
}
