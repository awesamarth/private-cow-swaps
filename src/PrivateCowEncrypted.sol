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
import {console} from "forge-std/console.sol";
import "@fhenixprotocol/cofhe-contracts/FHE.sol";

/**
 * @title PrivateCowEncrypted
 * @notice Demo version of PrivateCow with FHE encryption for privacy
 * @dev This contract demonstrates how order amounts and trader addresses can be encrypted
 *      while maintaining compatibility with Uniswap V4. For hackathon demo purposes.
 */
contract PrivateCowEncrypted is BaseHook {
    using CurrencySettler for Currency;

    error AddLiquidityThroughHook();

    // Regular events for Uniswap compatibility (visible)
    event HookSwap(
        bytes32 indexed id,
        address indexed sender,
        int128 amountInput,
        address trader,
        bool zeroForOne,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    );

    // Encrypted events for privacy (amounts and addresses hidden)
    event EncryptedHookSwap( // Encrypted amount
        // Encrypted trader address
        bytes32 indexed id,
        address indexed sender,
        euint128 encryptedAmount,
        euint256 encryptedTrader,
        bool zeroForOne,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    );

    event HookModifyLiquidity(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1);
    event CowMatchSettled(bytes32 indexed matchHash, address indexed buyer, address indexed seller, uint256 amount);

    struct CallbackData {
        bool cowMatch;
        uint256 amountEach;
        Currency currency0;
        Currency currency1;
        address sender;
    }

    struct CowSettleData {
        bool cowMatch;
        Currency currency0;
        Currency currency1;
        address[] buyers;
        address[] sellers;
        uint256[] buyerAmounts;
        uint256[] sellerAmounts;
    }

    mapping(address => bool) public operators;
    mapping(address => uint256) public operatorStake;

    constructor(IPoolManager poolManager) BaseHook(poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // Disable adding liquidity through the PM
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert AddLiquidityThroughHook();
    }

    // Custom add liquidity function
    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
        poolManager.unlock(
            abi.encode(
                CallbackData({
                    cowMatch: false,
                    amountEach: amountEach,
                    currency0: key.currency0,
                    currency1: key.currency1,
                    sender: msg.sender
                })
            )
        );
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        console.log("unlockCallback called");

        // Decode first field (cowMatch bool) to determine which struct
        bool cowMatch;
        assembly {
            cowMatch := calldataload(add(data.offset, 0))
        }

        console.log("cowMatch decoded:", cowMatch);

        if (!cowMatch) {
            CallbackData memory callbackData = abi.decode(data, (CallbackData));

            callbackData.currency0.settle(poolManager, callbackData.sender, callbackData.amountEach, false);
            callbackData.currency1.settle(poolManager, callbackData.sender, callbackData.amountEach, false);

            callbackData.currency0.take(poolManager, address(this), callbackData.amountEach, true);
            callbackData.currency1.take(poolManager, address(this), callbackData.amountEach, true);
        } else {
            console.log("unlock type is settle cow matches");

            CowSettleData memory cowData = abi.decode(data, (CowSettleData));

            console.log("buyers length:", cowData.buyers.length);
            console.log("sellers length:", cowData.sellers.length);

            // Give token1 to buyers (who deposited token0)
            for (uint256 i = 0; i < cowData.buyers.length; i++) {
                console.log("settling buyer:", cowData.buyers[i]);
                console.log("buyer amount:", cowData.buyerAmounts[i]);

                uint256 hookToken1Claims = poolManager.balanceOf(address(this), cowData.currency1.toId());
                uint256 buyerToken1Claims = poolManager.balanceOf(cowData.buyers[i], cowData.currency1.toId());
                console.log("Hook token1 claims:", hookToken1Claims);
                console.log("Buyer token1 claims before settle:", buyerToken1Claims);

                // Hook burns its token1 claims
                cowData.currency1.settle(poolManager, address(this), cowData.buyerAmounts[i], true);
                // Buyer gets real token1 (not claims)
                cowData.currency1.take(poolManager, cowData.buyers[i], cowData.buyerAmounts[i], false);
            }

            // Give token0 to sellers (who deposited token1)
            for (uint256 i = 0; i < cowData.sellers.length; i++) {
                console.log("settling seller:", cowData.sellers[i]);
                console.log("seller amount:", cowData.sellerAmounts[i]);
                // Hook burns its token0 claims
                cowData.currency0.settle(poolManager, address(this), cowData.sellerAmounts[i], true);
                // Seller gets real token0 (not claims)
                cowData.currency0.take(poolManager, cowData.sellers[i], cowData.sellerAmounts[i], false);
            }
        }

        return "";
    }

    function _postBeforeSwap(
        address sender,
        PoolKey calldata key,
        int128 absInputAmount,
        bool zeroForOne,
        bytes calldata hookData
    ) internal {
        if (hookData.length > 0) {
            address addressOfSender = abi.decode(hookData, (address));
            console.log("address of trader", addressOfSender);

            // Emit regular event for Uniswap compatibility
            emit HookSwap(
                PoolId.unwrap(key.toId()),
                sender,
                -absInputAmount,
                addressOfSender,
                zeroForOne,
                Currency.unwrap(key.currency0),
                Currency.unwrap(key.currency1),
                key.fee,
                key.tickSpacing,
                address(key.hooks)
            );

            // Handle encryption in separate function to avoid stack too deep
            _handleEncryption(sender, key, absInputAmount, zeroForOne, addressOfSender);
        }
    }

    function _handleEncryption(
        address sender,
        PoolKey calldata key,
        int128 absInputAmount,
        bool zeroForOne,
        address addressOfSender
    ) internal {
        // DEMO: Encrypt sensitive data for privacy
        euint128 encryptedAmount = FHE.asEuint128(uint128(absInputAmount));
        euint256 encryptedTrader = FHE.asEuint256(uint256(uint160(addressOfSender)));

        // Set permissions for encrypted values
        FHE.allowThis(encryptedAmount);
        FHE.allowThis(encryptedTrader);
        FHE.allowSender(encryptedAmount);
        FHE.allowSender(encryptedTrader);

        console.log("Encrypted amount created for privacy demo");
        console.log("Original amount:", uint128(absInputAmount));
        console.log("Original trader:", addressOfSender);

        // Emit encrypted event for operator privacy
        emit EncryptedHookSwap(
            PoolId.unwrap(key.toId()),
            sender,
            encryptedAmount, // Amount is now encrypted
            encryptedTrader, // Trader address is now encrypted
            zeroForOne,
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            key.fee,
            key.tickSpacing,
            address(key.hooks)
        );
    }

    // Swapping - identical to original for Uniswap compatibility
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        int128 absInputAmount;
        BeforeSwapDelta beforeSwapDelta;
        if (params.amountSpecified < 0) {
            absInputAmount = int128(-params.amountSpecified);

            beforeSwapDelta = toBeforeSwapDelta(
                absInputAmount, // abs(params.amountSpecified) of input token owed from uniswap to hook
                0
            );
        }

        if (params.zeroForOne) {
            key.currency0.take(poolManager, address(this), uint256(uint128(absInputAmount)), true);
            _postBeforeSwap(sender, key, -absInputAmount, params.zeroForOne, hookData);
        } else {
            // Sell order: token1 -> token0
            key.currency1.take(poolManager, address(this), uint256(uint128(absInputAmount)), true);
            _postBeforeSwap(sender, key, -absInputAmount, params.zeroForOne, hookData);
        }

        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }

    // AVS Functions
    modifier onlyOperator() {
        require(msg.sender == 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, "Not a registered operator");
        _;
    }

    function registerOperator() external payable {
        require(msg.value >= 0.01 ether, "Minimum stake required");
        require(!operators[msg.sender], "Already registered");

        operators[msg.sender] = true;
        operatorStake[msg.sender] = msg.value;
    }

    function settleCowMatches(
        PoolKey calldata key,
        address[] calldata buyers,
        address[] calldata sellers,
        uint256[] calldata buyerAmounts,
        uint256[] calldata sellerAmounts
    ) external onlyOperator {
        require(buyers.length == buyerAmounts.length && sellers.length == sellerAmounts.length, "Array length mismatch");

        console.log("calling unlock on poolmanager via cow contract");

        console.log("currency0: ", Currency.unwrap(key.currency0));
        console.log("currency1: ", Currency.unwrap(key.currency1));
        console.log("buyers: ", buyers[0]);
        console.log("sellers: ", sellers[0]);
        console.log("buyer amounts: ", buyerAmounts[0]);
        console.log("seller amounts: ", sellerAmounts[0]);

        poolManager.unlock(
            abi.encode(
                CowSettleData({
                    cowMatch: true,
                    currency0: key.currency0,
                    currency1: key.currency1,
                    buyers: buyers,
                    sellers: sellers,
                    buyerAmounts: buyerAmounts,
                    sellerAmounts: sellerAmounts
                })
            )
        );
    }

    // DEMO: Function to decrypt values (for testing/demo purposes)
    function decryptAmountForDemo(euint128 encryptedAmount) external {
        FHE.decrypt(encryptedAmount);
    }

    function getDecryptedAmountForDemo(euint128 encryptedAmount) external view returns (uint256) {
        (uint256 value, bool decrypted) = FHE.getDecryptResultSafe(encryptedAmount);
        if (!decrypted) revert("Value is not ready");
        return value;
    }
}
