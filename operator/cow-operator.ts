import {
    createPublicClient,
    createWalletClient,
    http,
    parseEther,
    formatEther,
    toHex,
    getContract,
    type Address,
    type Hash,
    type PublicClient,
    type WalletClient
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { sepolia, foundry } from 'viem/chains';
import dotenv from "dotenv";

dotenv.config();

interface CowOrder {
    trader: Address;
    amountInput: bigint;
    amountWanted: bigint;
    zeroForOne: boolean;
    poolId: Hash;
    timestamp: number;
    blockNumber: bigint;
}

interface CowMatch {
    buyOrder: CowOrder;
    sellOrder: CowOrder;
    matchId: string;  // Simple string ID instead of hash
    executionPrice: bigint;
    timestamp: number;
}

/**
 * CoW AVS Operator - Listens for orders and finds CoW matches
 */
class CowAVSOperator {
    private publicClient: PublicClient;
    private walletClient: WalletClient;
    private account: ReturnType<typeof privateKeyToAccount>;
    private privateCowContract: any;
    private serviceManager: any;
    private taskManager: any;
    
    private pendingOrders: Map<string, CowOrder> = new Map();
    private isOperatorRegistered: boolean = false;

    constructor(
        privateCowAddress: Address,
        serviceManagerAddress: Address,
        taskManagerAddress: Address,
        operatorPrivateKey: Hash,
        rpcUrl: string,
        chainId: number = 31337
    ) {
        const chain = chainId === 11155111 ? sepolia : foundry;
        
        this.publicClient = createPublicClient({
            chain,
            transport: http(rpcUrl)
        });

        this.account = privateKeyToAccount(operatorPrivateKey);
        
        this.walletClient = createWalletClient({
            account: this.account,
            chain,
            transport: http(rpcUrl)
        });

        // Contract ABIs for Viem
        const privateCowABI = [
            {
                type: 'event',
                name: 'HookSwap',
                inputs: [
                    { name: 'id', type: 'bytes32', indexed: true },
                    { name: 'sender', type: 'address', indexed: true },
                    { name: 'amountInput', type: 'int128' },
                    { name: 'amountWanted', type: 'uint256' },
                    { name: 'zeroForOne', type: 'bool' }
                ]
            },
            {
                type: 'function',
                name: 'settleCowMatches',
                inputs: [
                    { name: 'matchHashes', type: 'bytes32[]' },
                    { name: 'buyers', type: 'address[]' },
                    { name: 'sellers', type: 'address[]' },
                    { name: 'amounts', type: 'uint256[]' },
                    { name: 'currencies', type: 'address[]' }
                ],
                outputs: [],
                stateMutability: 'nonpayable'
            },
            {
                type: 'function',
                name: 'operators',
                inputs: [{ name: 'operator', type: 'address' }],
                outputs: [{ name: '', type: 'bool' }],
                stateMutability: 'view'
            },
            {
                type: 'function',
                name: 'registerOperator',
                inputs: [],
                outputs: [],
                stateMutability: 'payable'
            }
        ] as const;

        const serviceManagerABI = [
            {
                type: 'function',
                name: 'registerOperator',
                inputs: [],
                outputs: [],
                stateMutability: 'payable'
            },
            {
                type: 'function',
                name: 'isValidOperator',
                inputs: [{ name: 'operator', type: 'address' }],
                outputs: [{ name: '', type: 'bool' }],
                stateMutability: 'view'
            },
            {
                type: 'function',
                name: 'getOperatorStake',
                inputs: [{ name: 'operator', type: 'address' }],
                outputs: [{ name: '', type: 'uint256' }],
                stateMutability: 'view'
            },
            {
                type: 'function',
                name: 'claimRewards',
                inputs: [],
                outputs: [],
                stateMutability: 'nonpayable'
            }
        ] as const;

        const taskManagerABI = [
            {
                type: 'function',
                name: 'createNewTask',
                inputs: [
                    { name: 'matchHash', type: 'bytes32' },
                    { name: 'quorumThreshold', type: 'uint32' },
                    { name: 'quorumNumbers', type: 'bytes' }
                ],
                outputs: [],
                stateMutability: 'payable'
            },
            {
                type: 'function',
                name: 'respondToTask',
                inputs: [
                    { name: 'matchHash', type: 'bytes32' },
                    { name: 'response', type: 'bytes32' },
                    { name: 'signature', type: 'bytes' }
                ],
                outputs: [],
                stateMutability: 'nonpayable'
            },
            {
                type: 'function',
                name: 'hasConsensus',
                inputs: [{ name: 'taskIndex', type: 'uint32' }],
                outputs: [
                    { name: '', type: 'bool' },
                    { name: '', type: 'bytes32' }
                ],
                stateMutability: 'view'
            },
            {
                type: 'event',
                name: 'TaskCreated',
                inputs: [
                    { name: 'taskIndex', type: 'uint32', indexed: true },
                    { name: 'matchHash', type: 'bytes32', indexed: true },
                    { name: 'creator', type: 'address', indexed: true },
                    { name: 'reward', type: 'uint256' }
                ]
            },
            {
                type: 'event',
                name: 'ConsensusAchieved',
                inputs: [
                    { name: 'taskIndex', type: 'uint32', indexed: true },
                    { name: 'consensusResponse', type: 'bytes32' }
                ]
            }
        ] as const;

        this.privateCowContract = getContract({
            address: privateCowAddress,
            abi: privateCowABI,
            client: { public: this.publicClient, wallet: this.walletClient }
        });

        this.serviceManager = getContract({
            address: serviceManagerAddress,
            abi: serviceManagerABI,
            client: { public: this.publicClient, wallet: this.walletClient }
        });

        this.taskManager = getContract({
            address: taskManagerAddress,
            abi: taskManagerABI,
            client: { public: this.publicClient, wallet: this.walletClient }
        });

        console.log("🤖 CoW AVS Operator initialized");
        console.log(`   Operator Address: ${this.account.address}`);
        console.log(`   PRIVATE_COW Contract: ${privateCowAddress}`);
        console.log(`   Service Manager: ${serviceManagerAddress}`);
        console.log(`   Task Manager: ${taskManagerAddress}`);
    }

    /**
     * Initialize the operator by registering with the AVS
     */
    async initialize(): Promise<void> {
        try {
            console.log("🚀 Initializing CoW AVS Operator...");

            // Check if already registered with service manager
            const isRegistered = await this.serviceManager.read.isValidOperator([this.account.address]);
            
            if (!isRegistered) {
                console.log("📝 Registering with Service Manager...");
                const regTx = await this.serviceManager.write.registerOperator({
                    value: parseEther("0.01"), // 0.01 ETH stake
                    gas: 200000n
                });
                console.log(`   Registration TX: ${regTx}`);
                await this.publicClient.waitForTransactionReceipt({ hash: regTx });
                console.log("✅ Registered with Service Manager");
            } else {
                console.log("✅ Already registered with Service Manager");
            }

            // Check if registered with PRIVATE_COW
            const isOperator = await this.privateCowContract.read.operators([this.account.address]);
            if (!isOperator) {
                console.log("📝 Registering with PRIVATE_COW contract...");
                const regTx = await this.privateCowContract.write.registerOperator({
                    value: parseEther("0.01"),
                    gas: 200000n
                });
                await this.publicClient.waitForTransactionReceipt({ hash: regTx });
                console.log("✅ Registered with PRIVATE_COW contract");
            }

            this.isOperatorRegistered = true;
            this.startEventListeners();

            console.log("✅ CoW AVS Operator initialized successfully");
            console.log("🎯 Listening for CoW orders and creating matches...");

        } catch (error) {
            console.error("❌ Failed to initialize:", error);
            throw error;
        }
    }

    /**
     * Start listening for events
     */
    private startEventListeners(): void {
        console.log("👂 Starting event listeners...");

        // Listen for new orders from PRIVATE_COW hook
        this.publicClient.watchEvent({
            address: this.privateCowContract.address,
            event: {
                type: 'event',
                name: 'HookSwap',
                inputs: [
                    { name: 'id', type: 'bytes32', indexed: true },
                    { name: 'sender', type: 'address', indexed: true },
                    { name: 'amountInput', type: 'int128' },
                    { name: 'amountWanted', type: 'uint256' },
                    { name: 'zeroForOne', type: 'bool' }
                ]
            },
            onLogs: async (logs) => {
                for (const log of logs) {
                    const { id: poolId, sender, amountInput, amountWanted, zeroForOne } = log.args;
                    console.log(`📝 New order detected:`);
                    console.log(`   Trader: ${sender!.slice(0, 8)}...`);
                    console.log(`   Amount In: ${formatEther(BigInt(amountInput!))}`);
                    console.log(`   Amount Wanted: ${formatEther(amountWanted!)}`);
                    console.log(`   Direction: ${zeroForOne ? "0→1" : "1→0"}`);

                    await this.handleNewOrder(poolId!, sender!, BigInt(amountInput!), amountWanted!, zeroForOne!);
                }
            }
        });

        // Listen for task creation
        this.publicClient.watchEvent({
            address: this.taskManager.address,
            event: {
                type: 'event',
                name: 'TaskCreated',
                inputs: [
                    { name: 'taskIndex', type: 'uint32', indexed: true },
                    { name: 'matchHash', type: 'bytes32', indexed: true },
                    { name: 'creator', type: 'address', indexed: true },
                    { name: 'reward', type: 'uint256' }
                ]
            },
            onLogs: async (logs) => {
                for (const log of logs) {
                    const { taskIndex, matchHash, creator, reward } = log.args;
                    if (creator!.toLowerCase() !== this.account.address.toLowerCase()) {
                        console.log(`🎯 New task detected: ${taskIndex}`);
                        console.log(`   Match Hash: ${matchHash!.slice(0, 10)}...`);
                        console.log(`   Reward: ${formatEther(reward!)} ETH`);
                        
                        await this.handleNewTask(Number(taskIndex), matchHash!);
                    }
                }
            }
        });

        // Listen for consensus achieved
        this.publicClient.watchEvent({
            address: this.taskManager.address,
            event: {
                type: 'event',
                name: 'ConsensusAchieved',
                inputs: [
                    { name: 'taskIndex', type: 'uint32', indexed: true },
                    { name: 'consensusResponse', type: 'bytes32' }
                ]
            },
            onLogs: (logs:any) => {
                for (const log of logs) {
                    const { taskIndex, consensusResponse } = log.args;
                    console.log(`✅ Consensus achieved for task ${taskIndex}`);
                    console.log(`   Response: ${consensusResponse.slice(0, 10)}...`);
                }
            }
        });
    }

    /**
     * Handle new order by storing it and looking for matches
     */
    private async handleNewOrder(
        poolId: Hash,
        trader: Address,
        amountInput: bigint,
        amountWanted: bigint,
        zeroForOne: boolean
    ): Promise<void> {
        const orderKey = `${trader}-${poolId}-${Date.now()}`;
        
        const order: CowOrder = {
            trader,
            amountInput: BigInt(amountInput.toString()),
            amountWanted: BigInt(amountWanted.toString()),
            zeroForOne,
            poolId,
            timestamp: Date.now(),
            blockNumber: await this.publicClient.getBlockNumber()
        };

        this.pendingOrders.set(orderKey, order);
        console.log(`   📦 Stored order: ${this.pendingOrders.size} total pending`);

        // Look for matches
        const matches = this.findCowMatches();
        if (matches.length > 0) {
            await this.createMatchingTask(matches);
        }
    }

    /**
     * Find CoW matches among pending orders
     */
    private findCowMatches(): CowMatch[] {
        const matches: CowMatch[] = [];
        const orders = Array.from(this.pendingOrders.entries());

        for (let i = 0; i < orders.length; i++) {
            for (let j = i + 1; j < orders.length; j++) {
                const [key1, order1] = orders[i];
                const [key2, order2] = orders[j];

                if (this.canMatch(order1, order2)) {
                    const match: CowMatch = {
                        buyOrder: order1.zeroForOne ? order1 : order2,
                        sellOrder: order1.zeroForOne ? order2 : order1,
                        matchId: `${key1}-${key2}-${Date.now()}`, // Simple string ID
                        executionPrice: this.calculatePrice(order1, order2),
                        timestamp: Date.now()
                    };

                    matches.push(match);

                    // Remove matched orders
                    this.pendingOrders.delete(key1);
                    this.pendingOrders.delete(key2);

                    console.log(`🔄 Found CoW match: ${order1.trader.slice(0, 8)}... ↔ ${order2.trader.slice(0, 8)}...`);
                    console.log(`   Price: ${formatEther(match.executionPrice)}`);
                    break;
                }
            }
        }

        return matches;
    }

    /**
     * Check if two orders can be matched
     */
    private canMatch(order1: CowOrder, order2: CowOrder): boolean {
        return (
            order1.poolId === order2.poolId &&
            order1.zeroForOne !== order2.zeroForOne && // Opposite directions
            order1.trader !== order2.trader && // Different traders
            this.amountsCanMatch(order1, order2) // Compatible amounts
        );
    }

    /**
     * Check if order amounts are compatible for matching
     */
    private amountsCanMatch(order1: CowOrder, order2: CowOrder): boolean {
        // Simple matching: both orders should be within 10% of each other
        const ratio1 = (order1.amountInput * BigInt(100)) / order1.amountWanted;
        const ratio2 = (order2.amountWanted * BigInt(100)) / order2.amountInput;
        
        const diff = ratio1 > ratio2 ? ratio1 - ratio2 : ratio2 - ratio1;
        return diff <= BigInt(10); // 10% tolerance
    }

    /**
     * Calculate execution price for matched orders
     */
    private calculatePrice(order1: CowOrder, order2: CowOrder): bigint {
        // Use midpoint pricing
        const price1 = (order1.amountInput * parseEther("1")) / order1.amountWanted;
        const price2 = (order2.amountWanted * parseEther("1")) / order2.amountInput;
        return (price1 + price2) / BigInt(2);
    }

    /**
     * Create a task for match validation
     */
    private async createMatchingTask(matches: CowMatch[]): Promise<void> {
        try {
            console.log(`📦 Creating AVS task for ${matches.length} matches...`);

            const match = matches[0]; // Handle one match for simplicity
            
            // For now, skip task creation and settle directly
            console.log(`   📦 Found match ${match.matchId}, settling directly...`);

            // Directly settle the match for testing
            await this.settleCowMatch(match);


        } catch (error) {
            console.error("❌ Failed to create task:", error);
        }
    }

    /**
     * Handle validation of tasks created by other operators
     */
    // Task validation disabled for simple testing
    private async handleNewTask(taskIndex: number, matchId: string): Promise<void> {
        console.log(`🔍 Task validation disabled for simple testing: ${taskIndex}`);
    }

    /**
     * Settle a CoW match by calling PRIVATE_COW contract
     */
    private async settleCowMatch(match: CowMatch): Promise<void> {
        try {
            console.log(`⚖️  Settling CoW match...`);

            // For testing: just log the settlement instead of calling contract
            console.log(`   📊 Match Details:`);
            console.log(`      Buyer: ${match.buyOrder.trader.slice(0, 8)}...`);
            console.log(`      Seller: ${match.sellOrder.trader.slice(0, 8)}...`);
            console.log(`      Amount: ${formatEther(match.buyOrder.amountInput)} tokens`);
            console.log(`      Price: ${formatEther(match.executionPrice)} per token`);

            // TODO: When contracts are deployed, uncomment this:
            // const tx = await this.privateCowContract.write.settleCowMatches([...]);

            console.log(`   ✅ CoW match simulated: ${match.matchId}`);

        } catch (error) {
            console.error("❌ Failed to settle match:", error);
        }
    }


    /**
     * Get operator statistics
     */
    async getStats(): Promise<any> {
        try {
            const isValid = await this.serviceManager.read.isValidOperator([this.account.address]);
            const stake = await this.serviceManager.read.getOperatorStake([this.account.address]);

            return {
                address: this.account.address,
                isValidOperator: isValid,
                stake: formatEther(stake),
                pendingOrders: this.pendingOrders.size,
                isRegistered: this.isOperatorRegistered
            };
        } catch (error) {
            console.error("❌ Failed to get stats:", error);
            return null;
        }
    }

    /**
     * Graceful shutdown
     */
    async shutdown(): Promise<void> {
    }
}

// Main function to run the operator
async function main() {
    console.log("🌟 Starting CoW AVS Operator");
    console.log("=============================\\n");

    // Configuration from environment
    const PRIVATE_COW_ADDRESS = process.env.PRIVATE_COW_ADDRESS || "";
    const SERVICE_MANAGER_ADDRESS = process.env.SERVICE_MANAGER_ADDRESS || "";
    const TASK_MANAGER_ADDRESS = process.env.TASK_MANAGER_ADDRESS || "";
    const OPERATOR_PRIVATE_KEY = process.env.OPERATOR_PRIVATE_KEY || "";
    const RPC_URL = process.env.RPC_URL || "http://localhost:8545";

    if (!OPERATOR_PRIVATE_KEY) {
        console.error("❌ Missing PRIVATE_KEY in environment");
        process.exit(1);
    }

    const operator = new CowAVSOperator(
        PRIVATE_COW_ADDRESS as Address,
        SERVICE_MANAGER_ADDRESS as Address,
        TASK_MANAGER_ADDRESS as Address,
        OPERATOR_PRIVATE_KEY as Hash,
        RPC_URL,
        process.env.CHAIN_ID ? parseInt(process.env.CHAIN_ID) : 31337
    );

    try {
        await operator.initialize();

        // Print initial stats
        const stats = await operator.getStats();
        console.log("\\n📊 Operator Stats:", stats);

        // Keep the operator running
        console.log("\\n🔄 CoW AVS Operator is now running...");
        console.log("   Press Ctrl+C to stop\\n");

        // Graceful shutdown handling
        process.on("SIGINT", async () => {
            console.log("\\n🛑 Received shutdown signal...");
            await operator.shutdown();
            process.exit(0);
        });

        // Status updates every 30 seconds
        setInterval(async () => {
            const stats = await operator.getStats();
            console.log(
                `💡 Status: ${stats?.pendingOrders || 0} pending orders, Stake: ${stats?.stake || 0} ETH`
            );
        }, 30000);

        // Keep alive
        await new Promise(() => {});

    } catch (error) {
        console.error("❌ Fatal error:", error);
        process.exit(1);
    }
}

// Run if this file is executed directly
if (require.main === module) {
    main().catch((error) => {
        console.error("❌ Unhandled error:", error);
        process.exit(1);
    });
}

export { CowAVSOperator };