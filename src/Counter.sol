// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IPool} from "aave-v3-core/contracts/interfaces/IPool.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Counter is BaseHook {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    mapping(PoolId => uint256 count) public beforeSwapCount;
    mapping(PoolId => uint256 count) public afterSwapCount;

    address public immutable developer;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // USDT Token Address
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC Token Address
    IPool public immutable aavePool = IPool(0x794a6135B16114791212725b7E55E372DF2e5Fb8);

    struct TraderInfo {
        uint256 volume;
        uint256 rewardDebt;
    }

    mapping(address => TraderInfo) public traders;
    uint256 public totalVolume;
    uint256 public accRewardPerShare;
    uint256 public devRewards;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        developer = msg.sender;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata swapParams, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(key.currency0 == Currency.wrap(USDC) && key.currency1 == Currency.wrap(USDT));
        uint256 swapAmount =
            swapParams.amountSpecified < 0 ? uint256(-swapParams.amountSpecified) : uint256(swapParams.amountSpecified);
        uint256 fee = swapAmount / 1000; // 0.1% fee
        uint256 traderReward = fee / 2; // 50% of fee goes to traders
        uint256 devReward = fee - traderReward; // Remaining 50% to dev
        Currency feeCurrency = swapParams.zeroForOne ? key.currency0 : key.currency1;
        poolManager.take(feeCurrency, address(this), devReward);
       
        BeforeSwapDelta returnDelta = toBeforeSwapDelta(
            int128(int256(devReward)), // Specified delta (fee amount)
            0 // Unspecified delta (no change)
        );
        devRewards += devReward;
        // beforeSwapCount[poolId]++;
        return (BaseHook.beforeSwap.selector, returnDelta, 0);
    }

    function _afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        afterSwapCount[key.toId()]++;
        return (BaseHook.afterSwap.selector, 0);
    }

    function depositToAave(address token, uint256 amount) internal {
        IERC20(token).approve(address(aavePool), amount);
        aavePool.deposit(token, amount, address(this), 0);
    }

    function withdrawFromAave(address user, uint256 amount) internal {
        if (traders[user].volume > 0) {
            aavePool.withdraw(USDT, amount, user);
        } else {
            aavePool.withdraw(USDC, amount, user);
        }
    }
}
