// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PrivateCow} from "../src/PrivateCow.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

contract TestSwaps is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Use deployed addresses from previous scripts
    address constant HOOK_ADDRESS = 0x487e08EF68dB8b274C92702861dbb9b086670888;
    address constant POOL_MANAGER = 0x5FbDB2315678afecb367f032d93F642f64180aa3;

    function run() external {
        vm.startBroadcast();

        console.log(" Creating test swaps to trigger HookSwap events...");

        // Deploy test tokens
        MockERC20 token0 = new MockERC20("Token0", "TK0");
        MockERC20 token1 = new MockERC20("Token1", "TK1");

        console.log("Token0 deployed at:", address(token0));
        console.log("Token1 deployed at:", address(token1));

        // Mint tokens
        token0.mint(msg.sender, 10000 ether);
        token1.mint(msg.sender, 10000 ether);

        // Create pool key
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDRESS)
        });

        // Initialize pool
        IPoolManager(POOL_MANAGER).initialize(key, TickMath.getSqrtPriceAtTick(0));
        console.log("Pool initialized");

        // Add liquidity through hook
        token0.approve(HOOK_ADDRESS, 1000 ether);
        token1.approve(HOOK_ADDRESS, 1000 ether);
        PrivateCow(HOOK_ADDRESS).addLiquidity(key, 1000 ether);
        console.log("Liquidity added");

        // Deploy swap router
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));

        // Approve tokens for swapping
        token0.approve(address(swapRouter), 1000 ether);
        token1.approve(address(swapRouter), 1000 ether);

        console.log("Making test swaps to trigger events...");

        // Test Swap 1: Large buy order (should trigger matching)
        console.log("1. Large buy order: 50 tokens (zeroForOne=true)");
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -50e18, // 50 tokens
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            abi.encode(uint256(1)) // Large order
        );

        // Test Swap 2: Small sell order
        console.log("2. Small sell order: 5 tokens (zeroForOne=false)");
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -5e18, // 5 tokens
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            abi.encode(uint256(2)) // Small order
        );

        // Test Swap 3: Another small sell order
        console.log("3. Another small sell order: 8 tokens (zeroForOne=false)");
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -8e18, // 8 tokens
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            abi.encode(uint256(3)) // Small order
        );

        // Test Swap 4: Medium buy order
        console.log("4. Medium buy order: 15 tokens (zeroForOne=true)");
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -15e18, // 15 tokens
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            abi.encode(uint256(4)) // Medium order
        );

        // Test Swap 5: Another large sell order
        console.log("5. Large sell order: 30 tokens (zeroForOne=false)");
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -30e18, // 30 tokens
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            abi.encode(uint256(5)) // Large order
        );

        console.log(" Test swaps completed!");
        console.log(" Summary:");
        console.log("   - Created 5 test orders of varying sizes");
        console.log("   - Mix of buy (zeroForOne=true) and sell (zeroForOne=false) orders");
        console.log("   - Should trigger batch matching in AVS operator");
        console.log(" Check your AVS operator logs for matching results!");

        vm.stopBroadcast();
    }
}

// Simple ERC20 for testing
contract MockERC20 is IERC20Minimal {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}