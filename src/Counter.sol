// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IPool} from "aave-v3-core/contracts/interfaces/IPool.sol";
import "forge-std/console2.sol";


import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract Counter is BaseHook {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // USDT Token Address
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC Token Address
    IPool public immutable aavePool = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

    struct TraderInfo {
        uint256 volume;
        uint256 rewardDebt;
    }

    mapping(Currency => IERC20) public shareTokens;
    mapping(Currency => uint256) public totalShareTokenShares;
    mapping(Currency => mapping(address => TraderInfo)) public traderInfos;

    mapping(Currency => uint256) public devFee;
    mapping(Currency => uint256) public totalFee;
    mapping(Currency => uint256) public rewardPerShare;
    mapping(Currency => uint256) public totalVolume;

    error UnsupportedCurrency();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        IERC20(USDT).forceApprove(address(aavePool), type(uint256).max);
        IERC20(USDC).forceApprove(address(aavePool), type(uint256).max);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
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

    function pendingReward(address user, Currency currency) public view returns (uint256) {
        return (traderInfos[currency][user].volume * rewardPerShare[currency]) / 1e18
            - traderInfos[currency][user].rewardDebt;
    }

    function realPendingReward(address user, Currency currency) external view returns (uint256) {
        uint256 share = pendingReward(user, currency);
        uint256 reward =
            (share * ((shareTokens[currency].balanceOf(address(this)) * 1e18) / totalShareTokenShares[currency])) / 1e18;
        return reward;
    }

    function depositToAave(address token, uint256 amount) internal {
        totalShareTokenShares[Currency.wrap(token)] += amount;
        aavePool.supply(token, amount, address(this), 0);
    }

    function withdrawFromAave(address user, uint256 amount, Currency currency) internal returns (uint256) {
        uint256 amount =
            (amount * ((shareTokens[currency].balanceOf(address(this)) * 1e18) / totalShareTokenShares[currency])) / 1e18;
        totalShareTokenShares[currency] -= amount;
        return aavePool.withdraw(Currency.unwrap(currency), amount, user);
    }

    function setShareTokens(address shareToken, Currency currency) external {
        shareTokens[currency] = IERC20(shareToken);
    }

    function _claimFee(address user, Currency currency) internal returns (uint256) {
        uint256 pendingReward = pendingReward(user, currency);
        console2.log("pendingReward:", pendingReward);
        TraderInfo storage traderInfo = traderInfos[currency][user];
        if (pendingReward > 0) {
            traderInfo.rewardDebt = (traderInfo.volume * rewardPerShare[currency]) / 1e18;
        }
        return pendingReward;
    }

    function claimFee(Currency currency) external {
        uint256 rewards = _claimFee(msg.sender, currency);
        withdrawFromAave(msg.sender, rewards, currency);
    }

    function claimHookFee(Currency currency) external {
        withdrawFromAave(msg.sender, devFee[currency], currency);
        devFee[currency] = 0;
    }
    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (equals(key.currency0, Currency.wrap(USDC)) && equals(key.currency1, Currency.wrap(USDT))) {
            return BaseHook.beforeInitialize.selector;
        }

        revert UnsupportedCurrency();
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 swapAmount =
            swapParams.amountSpecified < 0 ? uint256(-swapParams.amountSpecified) : uint256(swapParams.amountSpecified);
        uint256 fee = swapAmount / 1000; // 0.1% fee
        Currency feeCurrency = swapParams.zeroForOne ? Currency.wrap(USDC) : Currency.wrap(USDT);
        poolManager.take(feeCurrency, address(this), fee);

        depositToAave(Currency.unwrap(feeCurrency), fee);


        totalFee[feeCurrency] += fee;
        devFee[feeCurrency] += fee / 2;
        address caller = abi.decode(hookData, (address));

        TraderInfo storage traderInfo = traderInfos[feeCurrency][caller];
        traderInfo.rewardDebt += (swapAmount * rewardPerShare[feeCurrency]) / 1e18;
        traderInfo.volume += swapAmount;
        totalVolume[feeCurrency] += swapAmount;

        rewardPerShare[feeCurrency] += ((fee - fee / 2) * 1e18) / totalVolume[feeCurrency];

        BeforeSwapDelta returnDelta = toBeforeSwapDelta(
            int128(int256(fee)), // Specified delta (fee amount)
            0 // Unspecified delta (no change)
        );
        return (BaseHook.beforeSwap.selector, returnDelta, 0);
    }

    // function _afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
    //     internal
    //     override
    //     returns (bytes4, int128)
    // {
    //     return (BaseHook.afterSwap.selector, 0);
    // }
}
