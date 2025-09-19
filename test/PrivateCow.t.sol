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
import {PrivateCow} from "../src/PrivateCow.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

contract PrivateCowTest is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    PrivateCow hook;
    address alice = address(0x1);
    address bob = address(0x2);

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address hookAddress = address(
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
        );
        deployCodeTo("PrivateCow.sol", abi.encode(manager), hookAddress);
        hook = PrivateCow(hookAddress);
        console.log("hook address: ", hookAddress);
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

        hook.addLiquidity(key, 1000e18);
    }

    function test_cannotModifyLiquidity() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function test_claimTokenBalances() public view {
        uint256 token0ClaimID = CurrencyLibrary.toId(currency0);

        uint256 token0ClaimsBalance = manager.balanceOf(address(hook), token0ClaimID);

        assertEq(token0ClaimsBalance, 1000 ether);
    }

    function test_swap_exactInput_zeroForOne() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Swap exact input 100 Token A
        uint256 balanceOfTokenABefore = key.currency0.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings,
            abi.encode(alice)
        );
        uint256 balanceOfTokenAAfter = key.currency0.balanceOf(alice);

        assertEq(balanceOfTokenABefore - balanceOfTokenAAfter, 100e18);
    }

    function test_swap_exactInput_OneForZero() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 balanceOfTokenBBefore = key.currency1.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -100e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings,
            abi.encode(10342340)
        );
        uint256 balanceOfTokenBAfter = key.currency1.balanceOf(alice);

        assertEq(balanceOfTokenBBefore - balanceOfTokenBAfter, 100e18);
    }

    function test_settleCowMatches() public {
        // Check Alice's initial balances
        uint256 aliceToken1Before = key.currency1.balanceOf(alice);

        // Prepare settlement data - Alice and Bob both as buyer and seller (simplest test)
        address[] memory buyers = new address[](1);
        buyers[0] = alice;

        address[] memory sellers = new address[](1);
        sellers[0] = bob;

        uint256[] memory buyerAmounts = new uint256[](1);
        buyerAmounts[0] = 50 ether;

        uint256[] memory sellerAmounts = new uint256[](1);
        sellerAmounts[0] = 50 ether;

        // Call settleCowMatches as the hardcoded operator
        vm.prank(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
        hook.settleCowMatches(key, buyers, sellers, buyerAmounts, sellerAmounts);

        uint256 aliceToken1After = key.currency1.balanceOf(alice);

        // Alice should have received 50 token1
        assertEq(aliceToken1After, aliceToken1Before + 50 ether);
    }
}
