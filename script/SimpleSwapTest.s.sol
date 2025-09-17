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

contract SimpleSwapTest is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Use deployed addresses
    address constant HOOK_ADDRESS = 0xce932F8B0C471Cf12a62257b26223Feff2aBC888;
    address constant POOL_MANAGER = 0x5FbDB2315678afecb367f032d93F642f64180aa3;

    function run() external {
        vm.startBroadcast();

        console.log("Simple Order Creation Test");

        // Deploy test tokens
        MockERC20 token0 = new MockERC20("Token0", "TK0");
        MockERC20 token1 = new MockERC20("Token1", "TK1");

        console.log("Tokens deployed:");
        console.log("  Token0:", address(token0));
        console.log("  Token1:", address(token1));

        // Mint tokens to deployer
        token0.mint(msg.sender, 1000 ether);
        token1.mint(msg.sender, 1000 ether);

        // Create pool key with proper ordering
        (Currency curr0, Currency curr1) = address(token0) < address(token1)
            ? (Currency.wrap(address(token0)), Currency.wrap(address(token1)))
            : (Currency.wrap(address(token1)), Currency.wrap(address(token0)));

        PoolKey memory key = PoolKey({
            currency0: curr0,
            currency1: curr1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDRESS)
        });

        // Initialize pool
        IPoolManager(POOL_MANAGER).initialize(key, TickMath.getSqrtPriceAtTick(0));
        console.log("Pool initialized with 1:1 price");

        // Add liquidity through hook
        token0.approve(HOOK_ADDRESS, 1000 ether);
        token1.approve(HOOK_ADDRESS, 1000 ether);
        PrivateCow(HOOK_ADDRESS).addLiquidity(key, 100 ether);
        console.log("Added 100 tokens liquidity");

        // Deploy swap router
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));

        // Approve tokens for swapping (need all three: swapRouter, poolManager, hook)
        token0.approve(address(swapRouter), 100 ether);
        token1.approve(address(swapRouter), 100 ether);
        token0.approve(POOL_MANAGER, 100 ether);
        token1.approve(POOL_MANAGER, 100 ether);

        console.log(" Creating single test order...");
        console.log("  Order: Buy 20 tokens (zeroForOne=true)");
        console.log("  This should emit HookSwap event that your operator catches");

        // Make ONE simple swap - this will emit HookSwap event
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,        // Buy order (token0 -> token1)
                amountSpecified: -20e18, // Input exactly 20 tokens
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            abi.encode(uint256(12345)) // hookData
        );

        console.log(" Single order created!");
        console.log(" HookSwap event should be emitted now");
        console.log(" Check your AVS operator logs!");

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