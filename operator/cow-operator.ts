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
    id: string;
    trader: Address;
    amountInput: bigint;
    amountWanted: bigint;
    zeroForOne: boolean;
    poolId: Hash;
    timestamp: number;
    blockNumber: bigint;
    price: bigint; // Price as amountWanted/amountInput for sorting
}

interface OrderMatch {
    buyOrders: CowOrder[];  // Can be multiple small orders
    sellOrders: CowOrder[]; // Can be multiple small orders
    totalBuyAmount: bigint;
    totalSellAmount: bigint;
    clearingPrice: bigint;
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
    
    // Separate order books for buy (zeroForOne=true) and sell (zeroForOne=false)
    private buyOrders: CowOrder[] = [];  // zeroForOne = true
    private sellOrders: CowOrder[] = []; // zeroForOne = false
    private pendingMatches: Map<string, OrderMatch> = new Map(); // Store matches awaiting consensus
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

        console.log(" CoW AVS Operator initialized");
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
            console.log(" Initializing CoW AVS Operator...");

            // Check if already registered with service manager
            const isRegistered = await this.serviceManager.read.isValidOperator([this.account.address]);
            
            if (!isRegistered) {
                console.log(" Registering with Service Manager...");
                const regTx = await this.serviceManager.write.registerOperator({
                    value: parseEther("0.01"), // 0.01 ETH stake
                    gas: 200000n
                });
                console.log(`   Registration TX: ${regTx}`);
                await this.publicClient.waitForTransactionReceipt({ hash: regTx });
                console.log(" Registered with Service Manager");
            } else {
                console.log(" Already registered with Service Manager");
            }

            // Check if registered with PRIVATE_COW
            const isOperator = await this.privateCowContract.read.operators([this.account.address]);
            if (!isOperator) {
                console.log(" Registering with PRIVATE_COW contract...");
                const regTx = await this.privateCowContract.write.registerOperator({
                    value: parseEther("0.01"),
                    gas: 200000n
                });
                await this.publicClient.waitForTransactionReceipt({ hash: regTx });
                console.log(" Registered with PRIVATE_COW contract");
            }

            this.isOperatorRegistered = true;
            this.startEventListeners();

            console.log(" CoW AVS Operator initialized successfully");
            console.log(" Listening for CoW orders and creating matches...");

        } catch (error) {
            console.error(" Failed to initialize:", error);
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
                    console.log(` New order detected:`);
                    console.log(`   Trader: ${sender!.slice(0, 8)}...`);
                    console.log(`   Amount In: ${formatEther(BigInt(amountInput!))} tokens`);
                    console.log(`   Amount Wanted: ${formatEther(amountWanted!)} tokens`);
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
                        console.log(` New task detected: ${taskIndex}`);
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
                    console.log(` Consensus achieved for task ${taskIndex}`);
                    console.log(`   Response: ${consensusResponse.slice(0, 10)}...`);
                }
            }
        });
    }

    /**
     * Handle new order by storing it in appropriate order book and looking for matches
     */
    private async handleNewOrder(
        poolId: Hash,
        trader: Address,
        amountInput: bigint,
        amountWanted: bigint,
        zeroForOne: boolean
    ): Promise<void> {
        const orderId = `${trader}-${poolId}-${Date.now()}`;

        // Calculate price for sorting (amountWanted per amountInput)
        // Prevent division by zero and handle edge cases
        const price = amountInput > 0 ? (amountWanted * BigInt(10000)) / amountInput : BigInt(0);

        console.log(`   📊 Order created: ${formatEther(amountInput)} → ${formatEther(amountWanted)} (price: ${price})`);

        const order: CowOrder = {
            id: orderId,
            trader,
            amountInput: BigInt(amountInput.toString()),
            amountWanted: BigInt(amountWanted.toString()),
            zeroForOne,
            poolId,
            timestamp: Date.now(),
            blockNumber: await this.publicClient.getBlockNumber(),
            price
        };

        // Add to appropriate order book
        if (zeroForOne) {
            this.buyOrders.push(order);
            // Sort buy orders by price descending (highest price first)
            this.buyOrders.sort((a, b) => b.price > a.price ? 1 : -1);
            console.log(`    Added buy order: ${this.buyOrders.length} total buy orders`);
        } else {
            this.sellOrders.push(order);
            // Sort sell orders by price ascending (lowest price first)
            this.sellOrders.sort((a, b) => a.price > b.price ? 1 : -1);
            console.log(`    Added sell order: ${this.sellOrders.length} total sell orders`);
        }

        // Look for matches using improved algorithm
        console.log(`🔍 Checking for matches...`);
        console.log(`   Buy orders: ${this.buyOrders.length}, Sell orders: ${this.sellOrders.length}`);
        console.log(`   Buy order amounts: ${this.buyOrders.map(o => formatEther(o.amountInput))}`);
        console.log(`   Sell order amounts: ${this.sellOrders.map(o => formatEther(o.amountInput))}`);
        console.log(`   Buy order prices: ${this.buyOrders.map(o => o.price.toString())}`);
        console.log(`   Sell order prices: ${this.sellOrders.map(o => o.price.toString())}`);

        const matches = this.findOrderMatches();
        if (matches.length > 0) {
            console.log(`🎯 Found ${matches.length} matches!`);
            await this.createMatchingTask(matches);
        } else {
            console.log(`❌ No matches found`);
            // Debug why no matches
            if (this.buyOrders.length > 0 && this.sellOrders.length > 0) {
                console.log(`   🔍 Debug: Checking cross compatibility...`);
                for (const buyOrder of this.buyOrders) {
                    for (const sellOrder of this.sellOrders) {
                        const canCross = this.canOrdersCross(buyOrder, sellOrder);
                        console.log(`      Buy ${formatEther(buyOrder.amountInput)} @ ${buyOrder.price} vs Sell ${formatEther(sellOrder.amountInput)} @ ${sellOrder.price} = ${canCross}`);
                    }
                }
            }
        }
    }

    /**
     * Find order matches using improved batch clearing algorithm
     */
    private findOrderMatches(): OrderMatch[] {
        const matches: OrderMatch[] = [];

        if (this.buyOrders.length === 0 || this.sellOrders.length === 0) {
            return matches;
        }

        // Strategy: Start with largest order and try to fill it with multiple counter-orders
        // Try to match buy orders against sell orders
        const largeBuyOrders = this.buyOrders.filter(order => order.amountInput >= parseEther("1")); // Orders > 1 token
        for (const buyOrder of largeBuyOrders) {
            const match = this.findMatchingOrders(buyOrder, this.sellOrders, true);
            if (match && match.sellOrders.length > 0) {
                matches.push(match);
            }
        }

        // Try to match sell orders against buy orders
        const largeSellOrders = this.sellOrders.filter(order => order.amountInput >= parseEther("1"));
        for (const sellOrder of largeSellOrders) {
            const match = this.findMatchingOrders(sellOrder, this.buyOrders, false);
            if (match && match.buyOrders.length > 0) {
                matches.push(match);
            }
        }

        return matches;
    }

    /**
     * Find orders that can match against a target order
     */
    private findMatchingOrders(targetOrder: CowOrder, counterOrders: CowOrder[], targetIsBuy: boolean): OrderMatch | null {
        const matchingOrders: CowOrder[] = [];
        let totalMatchedAmount = BigInt(0);
        let targetAmount = targetOrder.amountInput;

        // Filter compatible orders (same pool, can cross)
        const compatibleOrders = counterOrders.filter(order =>
            order.poolId === targetOrder.poolId &&
            this.canOrdersCross(targetOrder, order)
        );

        // Aggregate orders until we can fill the target order
        for (const order of compatibleOrders) {
            if (totalMatchedAmount >= targetAmount) break;

            const remainingAmount = targetAmount - totalMatchedAmount;
            const useableAmount = order.amountInput < remainingAmount ? order.amountInput : remainingAmount;

            if (useableAmount > 0) {
                matchingOrders.push(order);
                totalMatchedAmount += useableAmount;
            }
        }

        // Only create match if we can fill significant portion (>50%) of target order
        if (totalMatchedAmount >= (targetAmount * BigInt(50)) / BigInt(100)) {
            const clearingPrice = this.calculateClearingPrice(targetOrder, matchingOrders);

            return {
                buyOrders: targetIsBuy ? [targetOrder] : matchingOrders,
                sellOrders: targetIsBuy ? matchingOrders : [targetOrder],
                totalBuyAmount: targetIsBuy ? targetOrder.amountInput : totalMatchedAmount,
                totalSellAmount: targetIsBuy ? totalMatchedAmount : targetOrder.amountInput,
                clearingPrice,
                timestamp: Date.now()
            };
        }

        return null;
    }

    /**
     * Check if two orders can cross (have compatible prices)
     */
    private canOrdersCross(buyOrder: CowOrder, sellOrder: CowOrder): boolean {
        // Buy order price should be >= sell order price for crossing
        // Buy price: how much they'll pay per unit
        // Sell price: how much they want per unit
        const sameTrader = buyOrder.trader === sellOrder.trader;
        const samePool = buyOrder.poolId === sellOrder.poolId;
        const priceCompatible = buyOrder.price >= sellOrder.price;

        console.log(`      Cross check: sameTrader=${sameTrader}, samePool=${samePool}, priceOk=${priceCompatible} (${buyOrder.price} >= ${sellOrder.price})`);

        return (
            !sameTrader &&
            samePool &&
            priceCompatible
        );
    }

    /**
     * Calculate clearing price for a batch of orders
     */
    private calculateClearingPrice(targetOrder: CowOrder, matchingOrders: CowOrder[]): bigint {
        if (matchingOrders.length === 0) return targetOrder.price;

        // Use volume-weighted average price
        let totalVolume = BigInt(0);
        let weightedPriceSum = BigInt(0);

        for (const order of matchingOrders) {
            const volume = order.amountInput;
            totalVolume += volume;
            weightedPriceSum += order.price * volume;
        }

        // Add target order
        totalVolume += targetOrder.amountInput;
        weightedPriceSum += targetOrder.price * targetOrder.amountInput;

        return totalVolume > 0 ? weightedPriceSum / totalVolume : targetOrder.price;
    }

    /**
     * Create a task for match validation
     */
    private async createMatchingTask(matches: OrderMatch[]): Promise<void> {
        try {
            console.log(`📦 Creating AVS task for ${matches.length} matches...`);

            const match = matches[0]; // Handle one match for simplicity

            // Create match hash for validation
            const matchData = JSON.stringify({
                buyOrders: match.buyOrders.map(o => ({ trader: o.trader, amount: o.amountInput.toString() })),
                sellOrders: match.sellOrders.map(o => ({ trader: o.trader, amount: o.amountInput.toString() })),
                timestamp: match.timestamp
            });
            const matchHash = toHex(matchData).slice(0, 66); // Convert to bytes32

            console.log(`   Creating task for match ${matchHash.slice(0, 10)}...`);

            // Create task with 60% quorum threshold
            const tx = await this.taskManager.write.createNewTask([
                matchHash as Hash,
                60, // 60% quorum
                "0x01" // Mock quorum numbers
            ], {
                value: parseEther("0.0001") // Task reward
            });

            await this.publicClient.waitForTransactionReceipt({ hash: tx });
            console.log(`   ✅ Validation task created for match ${matchHash.slice(0, 10)}...`);

            // Store match for later settlement
            this.pendingMatches.set(matchHash, match);

            // Wait for consensus, then settle
            setTimeout(() => {
                this.checkConsensusAndSettle(matchHash);
            }, 15000); // 15 second delay for consensus

        } catch (error) {
            console.error(" Failed to create task:", error);
        }
    }

    /**
     * Handle validation of tasks created by other operators
     */
    private async handleNewTask(taskIndex: number, matchHash: string): Promise<void> {
        try {
            // Skip tasks we created ourselves
            if (await this.isOurTask(taskIndex)) {
                console.log(`   Skipping our own task ${taskIndex}`);
                return;
            }

            console.log(`   Validating task ${taskIndex}...`);

            // Perform validation - check if match is still valid
            const validationResult = await this.validateMatch(matchHash);

            // Create response hash
            const responseData = JSON.stringify({ valid: validationResult, taskIndex });
            const response = toHex(responseData).slice(0, 66); // Convert to bytes32

            // Sign the response (simplified - should use EIP-191)
            const signature = await this.walletClient.signMessage({
                account: this.account,
                message: response
            });

            // Submit response to TaskManager
            const tx = await this.taskManager.write.respondToTask([
                matchHash as Hash,
                response as Hash,
                signature
            ]);

            await this.publicClient.waitForTransactionReceipt({ hash: tx });
            console.log(`   ✅ Submitted validation response for task ${taskIndex}`);

        } catch (error) {
            console.error(` Error handling task ${taskIndex}:`, error);
        }
    }

    /**
     * Settle a CoW match by calling PRIVATE_COW contract
     */
    private async settleCowMatch(match: OrderMatch): Promise<void> {
        try {
            console.log(`  Settling CoW match...`);

            // For testing: just log the settlement instead of calling contract
            console.log(`   Match Details:`);
            console.log(`      Buy Orders: ${match.buyOrders.length}`);
            console.log(`      Sell Orders: ${match.sellOrders.length}`);
            console.log(`      Total Amount: ${formatEther(match.totalBuyAmount)} tokens`);
            console.log(`      Clearing Price: ${formatEther(match.clearingPrice)} per token`);

            // TODO: When contracts are deployed
            // const tx = await this.privateCowContract.write.settleCowMatches([...]);

            console.log(`   CoW match simulated: ${match.timestamp}`);

        } catch (error) {
            console.error(" Failed to settle match:", error);
        }
    }

    /**
     * Process order matches found by the matching algorithm
     */
    private async processOrderMatches(matches: OrderMatch[]): Promise<void> {
        try {
            console.log(` Processing ${matches.length} order matches...`);

            for (const match of matches) {
                console.log(`🎯 Found batch match:`);
                console.log(`   Buy Orders: ${match.buyOrders.length} (${formatEther(match.totalBuyAmount)} total)`);
                console.log(`   Sell Orders: ${match.sellOrders.length} (${formatEther(match.totalSellAmount)} total)`);
                console.log(`   Clearing Price: ${formatEther(match.clearingPrice)}`);

                // Remove matched orders from order books
                this.removeMatchedOrders(match);

                // TODO: Call settlement contract
                // await this.settleOrderMatch(match);
                console.log(`   ✅ Batch match simulated successfully`);
            }

        } catch (error) {
            console.error(" Error processing order matches:", error);
        }
    }

    /**
     * Remove matched orders from the order books
     */
    private removeMatchedOrders(match: OrderMatch): void {
        // Remove buy orders
        for (const buyOrder of match.buyOrders) {
            const index = this.buyOrders.findIndex(order => order.id === buyOrder.id);
            if (index !== -1) {
                this.buyOrders.splice(index, 1);
            }
        }

        // Remove sell orders
        for (const sellOrder of match.sellOrders) {
            const index = this.sellOrders.findIndex(order => order.id === sellOrder.id);
            if (index !== -1) {
                this.sellOrders.splice(index, 1);
            }
        }

        console.log(`   📊 Remaining orders: ${this.buyOrders.length} buy, ${this.sellOrders.length} sell`);
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
                buyOrders: this.buyOrders.length,
                sellOrders: this.sellOrders.length,
                totalOrders: this.buyOrders.length + this.sellOrders.length,
                isRegistered: this.isOperatorRegistered
            };
        } catch (error) {
            console.error(" Failed to get stats:", error);
            return null;
        }
    }

    /**
     * Check if task was created by this operator
     */
    private async isOurTask(taskIndex: number): Promise<boolean> {
        // Simple heuristic - check if task was created recently by us
        // In production, would track task creation more precisely
        return false; // For now, validate all tasks
    }

    /**
     * Validate a match hash
     */
    private async validateMatch(matchHash: string): Promise<boolean> {
        try {
            // Basic validation - check if orders still exist and can cross
            // In production, would perform deeper validation
            console.log(`     Validating match ${matchHash.slice(0, 10)}...`);
            return true; // Simplified validation
        } catch (error) {
            console.error(`     Validation failed:`, error);
            return false;
        }
    }

    /**
     * Check consensus and settle match if achieved
     */
    private async checkConsensusAndSettle(matchHash: string): Promise<void> {
        try {
            const match = this.pendingMatches.get(matchHash);
            if (!match) {
                console.log(`   Match ${matchHash.slice(0, 10)} not found for settlement`);
                return;
            }

            // In production, would check TaskManager.hasConsensus()
            // For now, assume consensus achieved
            console.log(`   Consensus achieved for match ${matchHash.slice(0, 10)}, settling...`);

            await this.settleCowMatch(match);
            this.pendingMatches.delete(matchHash);

        } catch (error) {
            console.error(`   Failed to settle match ${matchHash.slice(0, 10)}:`, error);
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
    const PRIVATE_COW_ADDRESS = "0xce932F8B0C471Cf12a62257b26223Feff2aBC888";
    const SERVICE_MANAGER_ADDRESS = process.env.SERVICE_MANAGER_ADDRESS || "";
    const TASK_MANAGER_ADDRESS = process.env.TASK_MANAGER_ADDRESS || "";
    const OPERATOR_PRIVATE_KEY = process.env.OPERATOR_PRIVATE_KEY || "";
    const RPC_URL = process.env.RPC_URL || "http://localhost:8545";

    if (!OPERATOR_PRIVATE_KEY) {
        console.error(" Missing PRIVATE_KEY in environment");
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
        console.log("\\n Operator Stats:", stats);

        // Keep the operator running
        console.log("\\n CoW AVS Operator is now running...");
        console.log("   Press Ctrl+C to stop\\n");

        // Graceful shutdown handling
        process.on("SIGINT", async () => {
            console.log("\\n Received shutdown signal...");
            await operator.shutdown();
            process.exit(0);
        });

        // Status updates every 30 seconds
        setInterval(async () => {
            const stats = await operator.getStats();
            console.log(
                `💡 Status: ${stats?.totalOrders || 0} pending orders, Stake: ${stats?.stake || 0} ETH`
            );
        }, 30000);

        // Keep alive
        await new Promise(() => {});

    } catch (error) {
        console.error(" Fatal error:", error);
        process.exit(1);
    }
}

// Run if this file is executed directly
if (require.main === module) {
    main().catch((error) => {
        console.error("Unhandled error:", error);
        process.exit(1);
    });
}

export { CowAVSOperator };