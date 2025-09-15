import {
    createPublicClient,
    createWalletClient,
    http,
    parseEther,
    formatEther,
    parseAbiItem,
    type Address,
    type Hash
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { foundry } from 'viem/chains';

async function main() {
    console.log("Simple CoW Event Test\n");

    // Setup clients
    const account = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");

    const publicClient = createPublicClient({
        chain: foundry,
        transport: http("http://localhost:8545")
    });

    const walletClient = createWalletClient({
        chain: foundry,
        transport: http("http://localhost:8545"),
        account
    });

    console.log(" Using wallet:", account.address);
    const balance = await publicClient.getBalance({ address: account.address });
    console.log(" Balance:", formatEther(balance), "ETH\n");

    // Deployed contract addresses
    const HOOK_ADDRESS: Address = "0x487e08EF68dB8b274C92702861dbb9b086670888" as Address;
    const POOL_MANAGER: Address = "0x5FbDB2315678afecb367f032d93F642f64180aa3" as Address;

    console.log(" Connecting to deployed contracts...");

    // Check if contracts exist
    const hookCode = await publicClient.getCode({ address: HOOK_ADDRESS });
    const pmCode = await publicClient.getCode({ address: POOL_MANAGER });

    if (!hookCode || hookCode === "0x") {
        console.error("Hook contract not found at", HOOK_ADDRESS);
        return;
    }
    if (!pmCode || pmCode === "0x") {
        console.error(" PoolManager not found at", POOL_MANAGER);
        return;
    }

    console.log(" Hook contract found");
    console.log(" PoolManager found\n");

    console.log(" Setting up event listener for HookSwap events...");

    // Watch for HookSwap events
    const unwatch = publicClient.watchContractEvent({
        address: HOOK_ADDRESS,
        abi: [
            parseAbiItem('event HookSwap(bytes32 indexed id, address indexed sender, int128 amountInput, uint256 amountWanted, bool zeroForOne)')
        ],
        eventName: 'HookSwap',
        onLogs: (logs) => {
            logs.forEach((log) => {
                console.log(" HookSwap Event Detected!");
                console.log("   Pool ID:", log.args.id);
                console.log("   Sender:", log.args.sender);
                console.log("   Amount Input:", log.args.amountInput?.toString());
                console.log("   Amount Wanted:", log.args.amountWanted?.toString());
                console.log("   Zero for One:", log.args.zeroForOne);
                console.log("   Transaction:", log.transactionHash);
                console.log("   Block:", log.blockNumber?.toString());
                console.log("   ==========================================\n");
            });
        }
    });

    console.log(" Event listener setup complete!");
    console.log("\n Instructions:");
    console.log("   1. Make sure your AVS operator is running");
    console.log("   2. Use forge test or manual transactions to trigger swaps");
    console.log("   3. Both this script and your AVS should catch the events");
    console.log("\nListening for events... (Press Ctrl+C to stop)");

    // Keep running
    process.stdin.resume();
    process.on('SIGINT', () => {
        console.log("\n Stopping event listener...");
        unwatch();
        process.exit(0);
    });
}

main().catch(console.error);