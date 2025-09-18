# Private CoW Swaps - Uniswap V4 Hook

A Uniswap V4 hook enabling private Coincidence of Wants (CoW) swaps with encrypted order matching through EigenLayer AVS operators.

## Overview

This project implements a privacy-preserving order matching system for Uniswap V4 pools that prevents MEV extraction by:

1. **Private Order Submission**: Orders are encrypted (via Fhenix integration - WIP) to hide amounts and trader identities
2. **Offchain Batch Matching**: EigenLayer AVS operators process encrypted orders to find optimal CoW matches
3. **Batch Settlement**: Matched orders are settled in batches onchain for gas efficiency and MEV protection

## Architecture

### Core Components

- **PrivateCow Hook**: Uniswap V4 hook that captures swap intentions and enables batch settlement
- **CoW AVS Operator**: EigenLayer operator that matches orders offchain using encrypted computation
- **Settlement Engine**: Batches matched orders for optimal onchain execution

### Privacy Layer (WIP)

- **Fhenix Integration**: FHE encryption for order amounts and trader addresses
- **CofheJS**: Client-side encryption/decryption for operator order matching

## Features

- **MEV Protection**: Orders matched privately 
- **Gas Efficiency**: Batch settlement reduces individual transaction costs
- **Partial Fills**: Large orders can be matched against multiple smaller orders
- **AVS Consensus**: Multiple operators validate matches for security

## Smart Contracts

### PrivateCow.sol
Main hook contract implementing:
- Order capture via `beforeSwap`
- Liquidity management with claim tokens
- Batch settlement via `settleCowMatches`
- Operator registration and management

### AVS Contracts
- **ServiceManager**: Operator registration and staking
- **TaskManager**: Consensus mechanism for match validation

## Installation & Setup

### Prerequisites
- Node.js v18+
- Foundry
- pnpm

### Environment Setup
```bash
# Required environment variables
OPERATOR_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
HOOK_ADDRESS=0x0427F86546fE98aF98Fc540a5e32eAd7D0814888  # Updated after each deployment
RPC_URL=http://localhost:8545
```

### Installation
```bash
# Install dependencies
forge install
cd operator && pnpm install
```

## How to Run

### 1. Start Local Network
```bash
anvil
```

### 2. Deploy Contracts
```bash
# Deploy hook
forge script script/DeployCowHook.s.sol --rpc-url http://localhost:8545 --broadcast --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Deploy AVS contracts
forge script script/DeployCowAVS.s.sol --rpc-url http://localhost:8545 --broadcast --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

### 3. Verify Deployment
```bash
cast code $HOOK_ADDRESS --rpc-url http://localhost:8545
```

### 4. Start Operator
```bash
cd operator
pnpm start
```

### 5. Run Tests & Demos

#### Unit Tests (All Passing)
```bash
# Core hook functionality
forge test --match-path test/PrivateCow.t.sol -vv

# Specific test functions:
# - test_claimTokenBalances: Verifies hook token claim management
# - test_swap_exactInput_zeroForOne: Tests token0 -> token1 swaps
# - test_swap_exactInput_OneForZero: Tests token1 -> token0 swaps
# - test_settleCowMatches: Validates settlement mechanism
```

#### Demo Scripts

**Simple 1:1 Matching (Working)**
```bash
forge script script/SimpleSwapTest.s.sol --rpc-url http://localhost:8545 --broadcast --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```
- Creates one 100-token buy order and one 100-token sell order
- Demonstrates perfect CoW matching
- Shows successful settlement

**Batch Matching Demo (Partial Issues)**
```bash
forge script script/TestBatchMatching.s.sol --rpc-url http://localhost:8545 --broadcast --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```
- Creates one large buy order (100 tokens) and multiple smaller sell orders (15+15+20 tokens)
- Successfully matches first partial fill (100 vs 15)
- **Known Issue**: Remaining orders (85 tokens) are removed instead of staying for additional matches
- **Status**: Partial fill logic needs refinement for production use

## Technical Details

### Order Flow
1. User submits swap through Uniswap router
2. Hook intercepts swap in `beforeSwap` and captures order details
3. Order is added to operator's order book
4. Operator continuously scans for matching opportunities
5. When matches found, operator calls `settleCowMatches` for batch execution
6. Settlement transfers tokens directly to users via claim system

### Matching Algorithm
- Implements 50% fill threshold for batch aggregation
- Prioritizes larger orders for matching efficiency
- Supports multiple small orders filling one large order
- Cross-validation ensures different traders and opposite directions

### Settlement Mechanism
```solidity
function settleCowMatches(
    PoolKey calldata key,
    address[] calldata buyers,
    address[] calldata sellers,
    uint256[] calldata buyerAmounts,
    uint256[] calldata sellerAmounts
) external onlyOperator
```

## Current Status

### Working Features
- Basic CoW order matching and settlement
- 1:1 perfect matches with full order completion
- Hook integration with Uniswap V4 pools
- Operator order book management
- Mock AVS infrastructure (registration, consensus framework)

### In Development
- **Fhenix FHE Integration**: Private order encryption
- **Partial Fill Handling**: Proper order book management for incomplete matches
- **Production Security**: Enhanced operator validation and slashing conditions

### Future Enhancements
- Actual AVS consensus integration
- Frontend interface for user interaction
- Support for variable pricing curves beyond 1:1


## Architecture Decisions


### Why EigenLayer AVS?
- Decentralized operator network prevents single points of failure
- Slashing mechanisms ensure honest behavior
- Enables complex offchain computation with onchain verification

### Why Fhenix FHE?
- Enables truly private order matching without revealing details, even to operators
- Allows operators to process encrypted orders while maintaining confidentiality
- Provides computational privacy that traditional zero-knowledge proofs cannot achieve for dynamic matching
- Reduces gas costs for users
- Minimizes MEV opportunities
- Enables partial fill aggregation

## Testing

Run the complete test suite:
```bash
# All unit tests
forge test -vv

# Specific test patterns
forge test --match-test settleCow -vv
forge test --match-test swap -vv
```

## Contributing

This project is actively developed for hackathon participation. Focus areas:
1. Fhenix FHE integration for order privacy
2. Partial fill order book management
3. Gas optimization for batch settlements
4. Frontend integration for user experience

## License

MIT License - see LICENSE file for details.