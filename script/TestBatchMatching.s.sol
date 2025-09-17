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

contract TestBatchMatching is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Use deployed addresses
    address constant HOOK_ADDRESS = 0xce932F8B0C471Cf12a62257b26223Feff2aBC888;
    address constant POOL_MANAGER = 0x5FbDB2315678afecb367f032d93F642f64180aa3;

    function run() external {
        // Use first private key for setup and buy order
        uint256 buyerKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        // Use second private key for sell orders
        uint256 sellerKey = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

        address buyer = vm.addr(buyerKey);
        address seller = vm.addr(sellerKey);

        console.log("Testing Batch CoW Matching");
        console.log("==============================");
        console.log("Buyer:", buyer);
        console.log("Seller:", seller);

        vm.startBroadcast(buyerKey);

        // Deploy test tokens
        MockERC20 token0 = new MockERC20("Token0", "TK0");
        MockERC20 token1 = new MockERC20("Token1", "TK1");

        console.log("Tokens deployed:");
        console.log("  Token0:", address(token0));
        console.log("  Token1:", address(token1));

        // Mint tokens to both buyer and seller
        token0.mint(buyer, 10000 ether);
        token1.mint(buyer, 10000 ether);
        token0.mint(seller, 10000 ether);
        token1.mint(seller, 10000 ether);

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

        // Initialize pool (1:1 price)
        IPoolManager(POOL_MANAGER).initialize(key, TickMath.getSqrtPriceAtTick(0));
        console.log("Pool initialized with 1:1 price");

        // Add liquidity through hook (using buyer account)
        token0.approve(HOOK_ADDRESS, 1000 ether);
        token1.approve(HOOK_ADDRESS, 1000 ether);
        PrivateCow(HOOK_ADDRESS).addLiquidity(key, 1000 ether);
        console.log("Added 1000 tokens liquidity");

        // Deploy swap router
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));

        // Buyer approvals
        token0.approve(address(swapRouter), 1000 ether);
        token1.approve(address(swapRouter), 1000 ether);
        token0.approve(POOL_MANAGER, 1000 ether);
        token1.approve(POOL_MANAGER, 1000 ether);

        console.log("");
        console.log(" Creating batch matching scenario...");
        console.log("==========================================");

        // 1. Large buy order from BUYER: 100 token0 → wants 60 token1
        console.log("1. Large BUY order from BUYER: 100 token0 -> 60 token1");
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,        // Buy order (token0 → token1)
                amountSpecified: -100e18, // Input exactly 100 tokens
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            abi.encode(uint256(60 ether)) // Want 60 token1
        );

        console.log("    Large buy order submitted by BUYER");
        vm.stopBroadcast();

        // Switch to SELLER account for sell orders
        vm.startBroadcast(sellerKey);

        // Seller approvals
        token0.approve(address(swapRouter), 1000 ether);
        token1.approve(address(swapRouter), 1000 ether);
        token0.approve(POOL_MANAGER, 1000 ether);
        token1.approve(POOL_MANAGER, 1000 ether);

        // Wait 2 seconds (simulate real ordering)
        vm.sleep(2000);

        // 2. First sell order from SELLER: 15 token1 → token0
        console.log("2. Small SELL order from SELLER: 15 token1 -> token0");
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,       // Sell order (token1 → token0)
                amountSpecified: -15e18, // Input exactly 15 tokens
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            abi.encode(uint256(15 ether))
        );

        console.log("    First sell order submitted by SELLER");
        vm.sleep(2000);

        // 3. Second sell order from SELLER: 15 token1 → token0
        console.log("3. Small SELL order from SELLER: 15 token1 -> token0");
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -15e18,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            abi.encode(uint256(15 ether))
        );

        console.log("    Second sell order submitted by SELLER");
        vm.sleep(2000);

        // 4. Third sell order from SELLER: 20 token1 → token0
        console.log("4. Small SELL order from SELLER: 20 token1 -> token0");
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -20e18,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            abi.encode(uint256(20 ether))
        );

        console.log("    Third sell order submitted by SELLER");

        console.log("");
        console.log("BATCH MATCHING TEST COMPLETE!");
        console.log("=====================================");
        console.log("Expected behavior:");
        console.log("  1x Large buy order: 100 token0 -> 60 token1");
        console.log("  3x Small sell orders: 15+15+20=50 token1 -> token0");
        console.log("  Should trigger batch clearing in AVS operator");
        console.log("  Check your operator logs for matching results!");

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