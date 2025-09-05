// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";


contract PrivateHook is BaseHook, ERC1155 {
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;


    event HookSwap(
        bytes32 indexed id, // v4 pool id
        address indexed sender, // router of the swap
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    );

    event CowTradeSettled(uint256 indexed buyOrderId, uint256 indexed sellOrderId, uint256 amount);
    event CowOrderCreated(uint256 indexed orderId, address indexed trader, uint256 amount, bool isZeroForOne);

    // Errors
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();

    // Constructor
    constructor(
        IPoolManager _manager,
        string memory _uri
    ) BaseHook(_manager) ERC1155(_uri) {
        owner = msg.sender;
    }

    struct CowOrder {
        address trader;
        uint256 amountIn;
        uint256 minAmountOut; 
        bool isZeroForOne;
        uint256 deadline;
        bool isActive;
        PoolId poolId;
        Currency currency0;
        Currency currency1;
    }

    mapping(uint256 => CowOrder) public CowOrders;
    mapping(PoolId => uint256[]) public activeBuyOrders;
    mapping(PoolId => uint256[]) public activeSellOrders;
    mapping(address => uint256[]) public traderOrders;
    uint256 public nextOrderId = 1;

    mapping(address => bool) public authorizedOperators;
    address public owner;

    modifier onlyAuthorizedOperator() {
        require(authorizedOperators[msg.sender], "Not authorized operator");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyPoolManager() override {
        require(msg.sender == address(poolManager), "Not pool manager");
        _;
    }

    // BaseHook Functions
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
        
        // Try to find opposite order for Cow matching
        uint256 matchingOrderId = _findCowMatch(poolId, amountSpecified, params.zeroForOne);
        
        if (matchingOrderId != 0) {
            return _executeCowTrade(sender, key, params, matchingOrderId);
        }
        
        // No match found, create pending order
        return _createPendingOrder(sender, key, params);
    }

    function _findCowMatch(PoolId poolId, uint256 amount, bool isZeroForOne) internal view returns (uint256) {
        uint256[] memory oppositeOrders = isZeroForOne ? activeSellOrders[poolId] : activeBuyOrders[poolId];
        
        for (uint256 i = 0; i < oppositeOrders.length; i++) {
            uint256 orderId = oppositeOrders[i];
            CowOrder memory order = CowOrders[orderId];
            
            if (order.isActive && 
                order.deadline > block.timestamp &&
                order.amountIn == amount) {
                return orderId;
            }
        }
        return 0;
    }

    function _executeCowTrade(address /*sender*/, PoolKey calldata key, SwapParams calldata params, uint256 matchingOrderId) internal returns (bytes4, BeforeSwapDelta, uint24) {
        CowOrder storage matchedOrder = CowOrders[matchingOrderId];
        uint256 amountIn = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        
        // Deactivate matched order
        matchedOrder.isActive = false;
        _removeFromActiveOrders(key.toId(), matchingOrderId, !params.zeroForOne);
        
        // Create 1:1 swap delta
        BeforeSwapDelta swapDelta = toBeforeSwapDelta(
            int128(-int256(amountIn)),
            int128(int256(amountIn))
        );
        
        return (this.beforeSwap.selector, swapDelta, 0);
    }

    function _createPendingOrder(address sender, PoolKey calldata key, SwapParams calldata params) internal returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 amountSpecified = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 orderId = nextOrderId++;
        
        CowOrders[orderId] = CowOrder({
            trader: sender,
            amountIn: amountSpecified,
            minAmountOut: amountSpecified,
            isZeroForOne: params.zeroForOne,
            deadline: block.timestamp + 1 hours,
            isActive: true,
            poolId: key.toId(),
            currency0: key.currency0,
            currency1: key.currency1
        });
        
        // Track order
        if (params.zeroForOne) {
            activeBuyOrders[key.toId()].push(orderId);
        } else {
            activeSellOrders[key.toId()].push(orderId);
        }
        traderOrders[sender].push(orderId);
        
        emit CowOrderCreated(orderId, sender, amountSpecified, params.zeroForOne);
        
        // Hold their tokens
        BeforeSwapDelta holdDelta = toBeforeSwapDelta(
            int128(-int256(amountSpecified)),
            0
        );
        
        return (this.beforeSwap.selector, holdDelta, 0);
    }

    function _removeFromActiveOrders(PoolId poolId, uint256 orderId, bool isBuyOrder) internal {
        uint256[] storage orders = isBuyOrder ? activeBuyOrders[poolId] : activeSellOrders[poolId];
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i] == orderId) {
                orders[i] = orders[orders.length - 1];
                orders.pop();
                break;
            }
        }
    }

    function addOperator(address operator) external onlyOwner {
        authorizedOperators[operator] = true;
    }

    function settleCowMatches(uint256[] calldata orderIds) external onlyAuthorizedOperator {
        poolManager.unlock(abi.encode(orderIds));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256[] memory orderIds = abi.decode(data, (uint256[]));
        
        for (uint256 i = 0; i < orderIds.length; i += 2) {
            uint256 buyOrderId = orderIds[i];
            uint256 sellOrderId = orderIds[i + 1];
            
            CowOrder storage buyOrder = CowOrders[buyOrderId];
            CowOrder storage sellOrder = CowOrders[sellOrderId];
            
            require(buyOrder.isActive && sellOrder.isActive, "Orders not active");
            require(buyOrder.isZeroForOne != sellOrder.isZeroForOne, "Same direction");
            require(buyOrder.amountIn == sellOrder.amountIn, "Amount mismatch");
            
            // Proper settlement using CSMM pattern
            if (buyOrder.isZeroForOne) {
                buyOrder.currency0.take(poolManager, address(this), buyOrder.amountIn, true);
                buyOrder.currency1.settle(poolManager, address(this), sellOrder.amountIn, true);
            } else {
                buyOrder.currency1.take(poolManager, address(this), buyOrder.amountIn, true);
                buyOrder.currency0.settle(poolManager, address(this), sellOrder.amountIn, true);
            }
            
            buyOrder.isActive = false;
            sellOrder.isActive = false;
            
            emit CowTradeSettled(buyOrderId, sellOrderId, buyOrder.amountIn);
        }
        return "";
    }

    function getActiveOrders(PoolId poolId) external view returns (uint256[] memory buyOrders, uint256[] memory sellOrders) {
        return (activeBuyOrders[poolId], activeSellOrders[poolId]);
    }

    function getOrderDetails(uint256 orderId) external view returns (CowOrder memory) {
        return CowOrders[orderId];
    }

    function getOrdersByTrader(address trader) external view returns (uint256[] memory) {
        return traderOrders[trader];
    }


}
