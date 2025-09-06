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


// A CSMM is a pricing curve that follows the invariant `x + y = k`
// instead of the invariant `x * y = k`

// This is theoretically the ideal curve for a stablecoin or pegged pairs (stETH/ETH)
// In practice, we don't usually see this in prod since depegs can happen and we dont want exact equal amounts
// But is a nice little custom curve hook example

contract CSMM is BaseHook {
    using CurrencySettler for Currency;

    error AddLiquidityThroughHook(); // error to throw when someone tries adding liquidity directly to the PoolManager

    event HookSwap(
        bytes32 indexed id, // v4 pool id
        address indexed sender, // router of the swap
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    );

    event HookModifyLiquidity(
        bytes32 indexed id, // v4 pool id
        address indexed sender, // router address
        int128 amount0,
        int128 amount1
    );

    constructor(IPoolManager poolManager) BaseHook(poolManager) {}

    struct CallbackData {
        uint256 amountEach; // Amount of each token to add as liquidity
        Currency currency0;
        Currency currency1;
        address sender;
    }

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
                beforeAddLiquidity: true, // Don't allow adding liquidity normally
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true, // Override how swaps are done
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true, // Allow beforeSwap to return a custom delta
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // Disable adding liquidity through the PM
    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        revert AddLiquidityThroughHook();
    }

    function unlockCallback(
        bytes calldata data
    ) external onlyPoolManager returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        // Settle `amountEach` of each currency from the sender
        // i.e. Create a debit of `amountEach` of each currency with the Pool Manager
        callbackData.currency0.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
        );
        callbackData.currency1.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false
        );

        // Since we didn't go through the regular "modify liquidity" flow,
        // the PM just has a debit of `amountEach` of each currency from us
        // We can, in exchange, get back ERC-6909 claim tokens for `amountEach` of each currency
        // to create a credit of `amountEach` of each currency to us
        // that balances out the debit

        // We will store those claim tokens with the hook, so when swaps take place
        // liquidity from our CSMM can be used by minting/burning claim tokens the hook owns
        callbackData.currency0.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
        );
        callbackData.currency1.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true
        );

        return "";
    }

    // Custom add liquidity function
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

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 amountInOutPositive = params.amountSpecified > 0
            ? uint256(params.amountSpecified)
            : uint256(-params.amountSpecified);

        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(
            int128(-params.amountSpecified), // So `specifiedAmount` = +100
            int128(params.amountSpecified) // Unspecified amount (output delta) = -100
        );

        if (params.zeroForOne) {
            // If user is selling Token 0 and buying Token 1

            // They will be sending Token 0 to the PM, creating a debit of Token 0 in the PM
            // We will take claim tokens for that Token 0 from the PM and keep it in the hook to create an equivalent credit for ourselves
            key.currency0.take(
                poolManager,
                address(this),
                amountInOutPositive,
                true
            );

            // They will be receiving Token 1 from the PM, creating a credit of Token 1 in the PM
            // We will burn claim tokens for Token 1 from the hook so PM can pay the user
            key.currency1.settle(
                poolManager,
                address(this),
                amountInOutPositive,
                true
            );

            emit HookSwap(
                PoolId.unwrap(key.toId()),
                sender,
                -int128(uint128(amountInOutPositive)),
                int128(uint128(amountInOutPositive)),
                0,
                0
            );
        } else {
            key.currency0.settle(
                poolManager,
                address(this),
                amountInOutPositive,
                true
            );
            key.currency1.take(
                poolManager,
                address(this),
                amountInOutPositive,
                true
            );

            emit HookSwap(
                PoolId.unwrap(key.toId()),
                sender,
                int128(uint128(amountInOutPositive)),
                -int128(uint128(amountInOutPositive)),
                0,
                0
            );
        }

        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }
}