import { createPublicClient, createWalletClient, http, parseEther, getContract, Address } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { foundry } from 'viem/chains';

// Contract addresses from your deployment
const HOOK_ADDRESS = "0xce932F8B0C471Cf12a62257b26223Feff2aBC888" as Address;
const POOL_MANAGER = "0x5FbDB2315678afecb367f032d93F642f64180aa3" as Address;
const RPC_URL = "http://localhost:8545";

// Test private key (anvil default)
const PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

interface MockERC20 {
    address: Address;
    name: string;
}

async function main() {
    console.log("🧪 Testing Batch CoW Matching");
    console.log("==============================\n");

    // Setup clients
    const account = privateKeyToAccount(PRIVATE_KEY);
    const publicClient = createPublicClient({
        chain: foundry,
        transport: http(RPC_URL)
    });

    const walletClient = createWalletClient({
        account,
        chain: foundry,
        transport: http(RPC_URL)
    });

    // ERC20 ABI
    const erc20ABI = [
        {
            type: 'constructor',
            inputs: [
                { name: '_name', type: 'string' },
                { name: '_symbol', type: 'string' }
            ]
        },
        {
            type: 'function',
            name: 'mint',
            inputs: [
                { name: 'to', type: 'address' },
                { name: 'amount', type: 'uint256' }
            ],
            outputs: [],
            stateMutability: 'nonpayable'
        },
        {
            type: 'function',
            name: 'approve',
            inputs: [
                { name: 'spender', type: 'address' },
                { name: 'amount', type: 'uint256' }
            ],
            outputs: [{ name: '', type: 'bool' }],
            stateMutability: 'nonpayable'
        },
        {
            type: 'function',
            name: 'balanceOf',
            inputs: [{ name: 'account', type: 'address' }],
            outputs: [{ name: '', type: 'uint256' }],
            stateMutability: 'view'
        }
    ] as const;

    // PoolSwapTest ABI
    const poolSwapTestABI = [
        {
            type: 'constructor',
            inputs: [{ name: '_poolManager', type: 'address' }]
        },
        {
            type: 'function',
            name: 'swap',
            inputs: [
                { name: 'key', type: 'tuple', components: [
                    { name: 'currency0', type: 'address' },
                    { name: 'currency1', type: 'address' },
                    { name: 'fee', type: 'uint24' },
                    { name: 'tickSpacing', type: 'int24' },
                    { name: 'hooks', type: 'address' }
                ]},
                { name: 'params', type: 'tuple', components: [
                    { name: 'zeroForOne', type: 'bool' },
                    { name: 'amountSpecified', type: 'int256' },
                    { name: 'sqrtPriceLimitX96', type: 'uint160' }
                ]},
                { name: 'testSettings', type: 'tuple', components: [
                    { name: 'takeClaims', type: 'bool' },
                    { name: 'settleUsingBurn', type: 'bool' }
                ]},
                { name: 'hookData', type: 'bytes' }
            ],
            outputs: [],
            stateMutability: 'payable'
        }
    ] as const;

    // PrivateCow ABI
    const privateCowABI = [
        {
            type: 'function',
            name: 'addLiquidity',
            inputs: [
                { name: 'key', type: 'tuple', components: [
                    { name: 'currency0', type: 'address' },
                    { name: 'currency1', type: 'address' },
                    { name: 'fee', type: 'uint24' },
                    { name: 'tickSpacing', type: 'int24' },
                    { name: 'hooks', type: 'address' }
                ]},
                { name: 'amountEach', type: 'uint256' }
            ],
            outputs: [],
            stateMutability: 'nonpayable'
        }
    ] as const;

    // PoolManager ABI
    const poolManagerABI = [
        {
            type: 'function',
            name: 'initialize',
            inputs: [
                { name: 'key', type: 'tuple', components: [
                    { name: 'currency0', type: 'address' },
                    { name: 'currency1', type: 'address' },
                    { name: 'fee', type: 'uint24' },
                    { name: 'tickSpacing', type: 'int24' },
                    { name: 'hooks', type: 'address' }
                ]},
                { name: 'sqrtPriceX96', type: 'uint160' }
            ],
            outputs: [],
            stateMutability: 'nonpayable'
        }
    ] as const;

    try {
        console.log("1. Deploying test tokens...");

        // Deploy MockERC20 bytecode (simplified)
        const mockERC20Bytecode = "0x608060405234801561001057600080fd5b50604051610a18380380610a188339818101604052810190610032919061015c565b8160009081610041919061035e565b50806001908161005191906103e5565b505050610471565b6000604051905090565b600080fd5b600080fd5b600080fd5b600080fd5b6000601f19601f8301169050919050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b6100c082610077565b810181811067ffffffffffffffff821117156100df576100de610088565b5b80604052505050565b60006100f261005e565b90506100fe82826100b7565b919050565b600067ffffffffffffffff82111561011e5761011d610088565b5b61012782610077565b9050602081019050919050565b60005b8381101561015257808201518184015260208101905061013b565b50505050565b600061016b61016684610103565b6100e8565b90508281526020810184848401111561018757610186610072565b5b610192848285610138565b509392505050565b600082601f8301126101af576101ae61006d565b5b81516101bf848260208601610158565b91505092915050565b600080604083850312156101df576101de610068565b5b600083015167ffffffffffffffff8111156101fd576101fc6100b4565b5b6102098582860161019a565b925050602083015167ffffffffffffffff81111561022a576102296100b4565b5b6102368582860161019a565b9150509250929050565b600081519050919050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052602260045260246000fd5b6000600282049050600182168061029057607f821691505b6020821081036102a3576102a2610249565b5b50919050565b60006102b482610240565b6102be8185610278565b93506102ce818560208601610289565b6102d781610077565b840191505092915050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052601160045260246000fd5b600081905092915050565b60008190508160005260206000209050919050565b60006020601f8301049050919050565b600082821b905092915050565b60006008830261036f7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff82610332565b6103798683610332565b95508019841693508086168417925050509392505050565b6000819050919050565b6000819050919050565b60006103c06103bb6103b684610391565b61039b565b610391565b9050919050565b6000819050919050565b6103da836103a5565b6103ee6103e6826103c7565b84845461033f565b825550505050565b600090565b6103f66103f6565b6104018184846103d1565b505050565b5b818110156104255761041a6000826103ee565b600181019050610407565b5050565b601f82111561046a5761043b8161031e565b61044484610333565b81016020851015610453578190505b61046761045f85610333565b830182610406565b50505b505050565b600082821c905092915050565b600061048d6000198460080261046f565b1980831691505092915050565b60006104a6838361047c565b9150826002028217905092915050565b6104bf82610240565b67ffffffffffffffff8111156104d8576104d7610088565b5b6104e28254610278565b6104ed828285610429565b600060209050601f83116001811461052057600084156105065782870151905090565b5b60008460000361051757600160028602915050505b505050919050565b61053d9050600160008361052b565b50919050565b00"; // This would be the actual bytecode

        // For now, use pre-deployed token addresses or deploy via contract call
        console.log("   Deploying Token0...");
        const token0Hash = await walletClient.deployContract({
            abi: erc20ABI,
            bytecode: mockERC20Bytecode,
            args: ["Token0", "TK0"],
            gas: 1000000n
        });

        console.log("   Deploying Token1...");
        const token1Hash = await walletClient.deployContract({
            abi: erc20ABI,
            bytecode: mockERC20Bytecode,
            args: ["Token1", "TK1"],
            gas: 1000000n
        });

        // Wait for deployment and get addresses
        const token0Receipt = await publicClient.waitForTransactionReceipt({ hash: token0Hash });
        const token1Receipt = await publicClient.waitForTransactionReceipt({ hash: token1Hash });

        const token0Address = token0Receipt.contractAddress!;
        const token1Address = token1Receipt.contractAddress!;

        console.log(`   Token0: ${token0Address}`);
        console.log(`   Token1: ${token1Address}`);

        // Get contract instances
        const token0 = getContract({
            address: token0Address,
            abi: erc20ABI,
            client: { public: publicClient, wallet: walletClient }
        });

        const token1 = getContract({
            address: token1Address,
            abi: erc20ABI,
            client: { public: publicClient, wallet: walletClient }
        });

        const poolManager = getContract({
            address: POOL_MANAGER,
            abi: poolManagerABI,
            client: { public: publicClient, wallet: walletClient }
        });

        const privateCow = getContract({
            address: HOOK_ADDRESS,
            abi: privateCowABI,
            client: { public: publicClient, wallet: walletClient }
        });

        console.log("\n2. Minting tokens...");
        await token0.write.mint([account.address, parseEther("1000")]);
        await token1.write.mint([account.address, parseEther("1000")]);

        console.log("3. Setting up pool...");
        const poolKey = {
            currency0: token0Address,
            currency1: token1Address,
            fee: 3000,
            tickSpacing: 60,
            hooks: HOOK_ADDRESS
        };

        // Initialize pool (1:1 price)
        const SQRT_PRICE_1_1 = 79228162514264337593543950336n; // sqrt(1) * 2^96
        await poolManager.write.initialize([poolKey, SQRT_PRICE_1_1]);

        // Add liquidity through hook
        await token0.write.approve([HOOK_ADDRESS, parseEther("500")]);
        await token1.write.approve([HOOK_ADDRESS, parseEther("500")]);
        await privateCow.write.addLiquidity([poolKey, parseEther("500")]);

        console.log("4. Deploying PoolSwapTest router...");
        const swapRouterHash = await walletClient.deployContract({
            abi: poolSwapTestABI,
            bytecode: "0x608060405234801561001057600080fd5b50604051610400380380610400833981810160405281019061003291906100b0565b80600081905550506100dd565b600080fd5b600073ffffffffffffffffffffffffffffffffffffffff82169050919050565b600061007382610048565b9050919050565b61008381610068565b811461008e57600080fd5b50565b6000815190506100a08161007a565b92915050565b6000602082840312156100bc576100bb610043565b5b60006100ca84828501610091565b91505092915050565b610314806100ec6000396000f3fe608060405234801561001057600080fd5b50600436106100295760003560e01c8063128acb081461002e575b600080fd5b610048600480360381019061004391906101b8565b61004a565b005b50565b600080fd5b600080fd5b600080fd5b600080fd5b600080fd5b600080fd5b60008115159050919050565b61007e81610069565b811461008957600080fd5b50565b60008135905061009b81610075565b92915050565b600080fd5b6000819050919050565b6100b9816100a6565b81146100c457600080fd5b50565b6000813590506100d6816100b0565b92915050565b60006100f76100f2846100a6565b6100a6565b90508281526020810184848401111561011357610112610060565b5b61011e8482856101a9565b509392505050565b600082601f83011261013b5761013a61005b565b5b813561014b8482602086016100e4565b91505092915050565b6000806040838503121561016b5761016a61004d565b5b600083013567ffffffffffffffff8111156101895761018861004c565b5b61019585828601610126565b92505060206101a68582860161008c565b9150509250929050565b82818337600083830152505050565b6000602082840312156101d5576101d4610048565b5b600082013567ffffffffffffffff8111156101f3576101f2610051565b5b6101ff84828501610154565b9150509291505056fea26469706673582212201a2b3c4d5e6f7081928374657687392847565748291039485765473829109384756400640033", // This would be the actual bytecode
            args: [POOL_MANAGER],
            gas: 1000000n
        });

        const swapRouterReceipt = await publicClient.waitForTransactionReceipt({ hash: swapRouterHash });
        const swapRouterAddress = swapRouterReceipt.contractAddress!;

        const swapRouter = getContract({
            address: swapRouterAddress,
            abi: poolSwapTestABI,
            client: { public: publicClient, wallet: walletClient }
        });

        // Approve router
        await token0.write.approve([swapRouterAddress, parseEther("1000")]);
        await token1.write.approve([swapRouterAddress, parseEther("1000")]);

        console.log("\n🎯 Creating batch matching scenario...");
        console.log("==========================================");

        const testSettings = {
            takeClaims: false,
            settleUsingBurn: false
        };

        const MIN_SQRT_PRICE = "4295128739";
        const MAX_SQRT_PRICE = "1461446703485210103287273052203988822378723970341";

        // 1. Large buy order: 100 token0 → wanting 60 token1
        console.log("\n1. 🔵 Large BUY order: 100 token0 → 60 token1");
        await swapRouter.write.swap([
            poolKey,
            {
                zeroForOne: true,
                amountSpecified: parseEther("-100"), // Input 100 token0
                sqrtPriceLimitX96: MIN_SQRT_PRICE
            },
            testSettings,
            "0x" + (60).toString(16).padStart(64, '0') // Want 60 token1
        ]);

        console.log("   ✅ Large buy order submitted");
        await new Promise(resolve => setTimeout(resolve, 2000)); // Wait 2 seconds

        // 2. First sell order: 15 token1 → token0
        console.log("\n2. 🔴 Small SELL order: 15 token1 → token0");
        await swapRouter.write.swap([
            poolKey,
            {
                zeroForOne: false,
                amountSpecified: parseEther("-15"), // Input 15 token1
                sqrtPriceLimitX96: MAX_SQRT_PRICE
            },
            testSettings,
            "0x" + (15).toString(16).padStart(64, '0')
        ]);

        console.log("   ✅ First sell order submitted");
        await new Promise(resolve => setTimeout(resolve, 2000));

        // 3. Second sell order: 15 token1 → token0
        console.log("\n3. 🔴 Small SELL order: 15 token1 → token0");
        await swapRouter.write.swap([
            poolKey,
            {
                zeroForOne: false,
                amountSpecified: parseEther("-15"), // Input 15 token1
                sqrtPriceLimitX96: MAX_SQRT_PRICE
            },
            testSettings,
            "0x" + (15).toString(16).padStart(64, '0')
        ]);

        console.log("   ✅ Second sell order submitted");
        await new Promise(resolve => setTimeout(resolve, 2000));

        // 4. Third sell order: 20 token1 → token0
        console.log("\n4. 🔴 Small SELL order: 20 token1 → token0");
        await swapRouter.write.swap([
            poolKey,
            {
                zeroForOne: false,
                amountSpecified: parseEther("-20"), // Input 20 token1
                sqrtPriceLimitX96: MAX_SQRT_PRICE
            },
            testSettings,
            "0x" + (20).toString(16).padStart(64, '0')
        ]);

        console.log("   ✅ Third sell order submitted");

        console.log("\n🎉 BATCH MATCHING TEST COMPLETE!");
        console.log("=====================================");
        console.log("Expected behavior:");
        console.log("  🔵 1x Large buy order: 100 token0 → 60 token1");
        console.log("  🔴 3x Small sell orders: 15+15+20=50 token1 → token0");
        console.log("  🎯 Should trigger batch clearing in AVS operator");
        console.log("  ⚡ Check your operator logs for matching results!");

    } catch (error) {
        console.error("❌ Test failed:", error);
        process.exit(1);
    }
}

// Run the test
if (require.main === module) {
    main().catch((error) => {
        console.error("Unhandled error:", error);
        process.exit(1);
    });
}