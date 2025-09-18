// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {console} from "forge-std/console.sol";

// A CSMM is a pricing curve that follows the invariant `x + y = k`
// instead of the invariant `x * y = k`
// This is a super simple CSMM PoC that hardcodes 1:1 swaps through a custom pricing curve hook

// This is theoretically the ideal curve for a stablecoin or pegged pairs (stETH/ETH)
// In practice, we don't usually see this in prod since depegs can happen and we dont want exact equal amounts
// But is a nice little NoOp hook example

contract PrivateCow is BaseHook {
    using CurrencySettler for Currency;

    error AddLiquidityThroughHook();

    // router of the swap
    event HookSwap(
        bytes32 indexed id,
        address indexed sender,
        int128 amountInput,
        address trader,
        bool zeroForOne
    );

    event HookModifyLiquidity(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1);
    
    event CowMatchSettled(bytes32 indexed matchHash, address indexed buyer, address indexed seller, uint256 amount);

    struct CallbackData {
        uint256 amountEach;
        Currency currency0;
        Currency currency1;
        address sender;
    }

    mapping(address => bool) public operators;
    mapping(address => uint256) public operatorStake;

    constructor(IPoolManager poolManager) BaseHook(poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true, 
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

    // Disable adding liquidity through the PM
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert AddLiquidityThroughHook();
    }

    // Custom add liquidity function
    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
        poolManager.unlock(abi.encode(CallbackData(amountEach, key.currency0, key.currency1, msg.sender)));

        emit HookModifyLiquidity(
            PoolId.unwrap(key.toId()), address(this), int128(uint128(amountEach)), int128(uint128(amountEach))
        );
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        // Settle `amountEach` of each currency from the sender
        // i.e. Create a debit of `amountEach` of each currency with the Pool Manager
        callbackData.currency0.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
        );
        callbackData.currency1.settle(poolManager, callbackData.sender, callbackData.amountEach, false);

        // We will store those claim tokens with the hook, so when swaps take place
        // liquidity from our CSMM can be used by minting/burning claim tokens the hook owns
        callbackData.currency0.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
        );
        callbackData.currency1.take(poolManager, callbackData.sender, callbackData.amountEach, true);

        return "";
    }

    function _postBeforeSwap(address sender, PoolKey calldata key, int128 absInputAmount, bool zeroForOne, bytes calldata hookData) internal {
    if (hookData.length > 0) {
        address addressOfSender = abi.decode(hookData, (address));
        console.log("address of trader", addressOfSender);


    emit HookSwap(PoolId.unwrap(key.toId()), sender, -absInputAmount, addressOfSender, zeroForOne);

    }

}

    // Swapping
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {

        int128 absInputAmount;
        BeforeSwapDelta beforeSwapDelta;
        if ( params.amountSpecified < 0) {
            absInputAmount = int128(-params.amountSpecified);

            beforeSwapDelta = toBeforeSwapDelta(
                absInputAmount, // abs(params.amountSpecified) of input token owed from uniswap to hook
                0 
            );
        }

        if (params.zeroForOne) {
            key.currency0.take(poolManager, address(this), uint256(uint128(absInputAmount)), false);

            // They will be receiving Token 1 from the PM, creating a credit of Token 1 in the PM
            // We will burn claim tokens for Token 1 from the hook so PM can pay the user
            // and create an equivalent debit for Token 1 since it is ours!

        _postBeforeSwap(sender, key, -absInputAmount, params.zeroForOne, hookData);
        } else {
            // Sell order: token1 -> token0
        key.currency1.take(poolManager, address(this), uint256(uint128(absInputAmount)), false);

        _postBeforeSwap(sender, key, -absInputAmount, params.zeroForOne, hookData);
        }

        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }

    // AVS Functions
    modifier onlyOperator() {
        require(operators[msg.sender], "Not a registered operator");
        _;
    }

    function registerOperator() external payable {
        require(msg.value >= 0.01 ether, "Minimum stake required");
        require(!operators[msg.sender], "Already registered");
        
        operators[msg.sender] = true;
        operatorStake[msg.sender] = msg.value;
    }

    function settleCowMatches(
        address[] calldata buyers,
        address[] calldata sellers,
        uint256[] calldata sellerAmounts,
        uint256 [] calldata buyerAmounts
    ) external onlyOperator {
        require(
            buyers.length == sellers.length &&
            sellers.length == sellerAmounts.length&&
            buyers.length == buyerAmounts.length,

            "Array length mismatch"
        );

        for (uint256 i = 0; i < matchHashes.length; i++) {
            // Transfer tokens between matched traders using pool manager's claim tokens
            // This is simplified - in production would need proper token accounting
            
            emit CowMatchSettled(
                matchHashes[i],
                buyers[i],
                sellers[i],
                amounts[i]
            );
        }
    }
}
