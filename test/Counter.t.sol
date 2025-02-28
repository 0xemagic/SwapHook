// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Counter} from "../src/Counter.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Commands} from "universal-router/contracts/libraries/Commands.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";

import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IUniversalRouter} from "universal-router/contracts/interfaces/IUniversalRouter.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "forge-std/console2.sol";

contract CounterTest is Test, IERC721Receiver {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    Counter hook;
    PoolId poolId;
    PoolKey poolKey;
    uint160 initSqrtPriceX96;

    IPositionManager constant positionManager = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IPoolManager constant poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPermit2 constant permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IUniversalRouter constant universalRouter = IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant aUSDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address constant aUSDT = 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a;

    address constant Trader1 = address(0xe2fF3c4a7b87df9a6Acabf3a848083198080a763);
    address constant Trader2 = address(0xee0d9c760b28ADb71aE0deFBD5236Cc806B38118);

    function initPool() public {
        (, bytes32 salt) = HookMiner.find(
            address(this),
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG),
            type(Counter).creationCode,
            abi.encode(address(poolManager))
        );
        hook = new Counter{salt: salt}(poolManager);

        poolKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(USDT),
            fee: 10000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });

        hook.setShareTokens(aUSDC, Currency.wrap(USDC));
        hook.setShareTokens(aUSDT, Currency.wrap(USDT));

        initSqrtPriceX96 = uint160(TickMath.getSqrtPriceAtTick(0));
        poolManager.initialize(poolKey, initSqrtPriceX96);
        deal(USDC, address(this), 1_000_000e6);
        deal(USDT, address(this), 1_000_000e6);
        IERC20(USDC).forceApprove(address(permit2), type(uint256).max);
        IERC20(USDT).forceApprove(address(permit2), type(uint256).max);
        permit2.approve(USDC, address(positionManager), type(uint160).max, uint48(block.timestamp + 100));
        permit2.approve(USDT, address(positionManager), type(uint160).max, uint48(block.timestamp + 100));

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey, -200, 200, 1_000_000e6, type(uint256).max, type(uint256).max, address(this), "");
        params[1] = abi.encode(Currency.wrap(address(USDC)), Currency.wrap(address(USDT)));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 100);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function swapExactInputSingle(PoolKey memory key, uint128 amountIn, uint128 minAmountOut, address user)
        public
        returns (uint256 amountOut)
    {
        // Encode the Universal Router command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        // Encode V4Router actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        // Prepare parameters for each action
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: abi.encode(user)
            })
        );
        params[1] = abi.encode(key.currency0, amountIn);
        params[2] = abi.encode(key.currency1, minAmountOut);

        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, params);

        // Execute the swap
        universalRouter.execute(commands, inputs, block.timestamp + 60);

        // Verify and return the output amount
        amountOut = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        require(amountOut >= minAmountOut, "Insufficient output amount");
        return amountOut;
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        deal(address(USDC), Trader1, 1_000_000e6);
        deal(address(USDT), Trader1, 1_000_000e6);
        deal(address(USDC), Trader2, 1_000_000e6);
        deal(address(USDT), Trader2, 1_000_000e6);

        vm.startPrank(Trader1);
        IERC20(USDC).forceApprove(address(permit2), type(uint256).max);
        IERC20(USDT).forceApprove(address(permit2), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(Trader2);
        IERC20(USDC).forceApprove(address(permit2), type(uint256).max);
        IERC20(USDT).forceApprove(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    function test_PoolCreationTest() public {
        initPool();
    }

    function test_HookDeployTest() public {
        initPool();
        PoolKey memory invalidKey = PoolKey({
            currency0: Currency.wrap(address(USDC)),
            currency1: Currency.wrap(address(aUSDT)),
            fee: 10000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        poolManager.initialize(invalidKey, initSqrtPriceX96);
    }

    function test_SwapFeeTest() public {
        initPool();
        permit2.approve(USDC, address(universalRouter), type(uint160).max, uint48(block.timestamp + 100));
        uint128 swapAmount = 5_000e6;
        uint256 fee = swapAmount / 1000;
        uint256 shareAmount = IERC20(USDC).balanceOf(address(aUSDC));
        swapExactInputSingle(poolKey, swapAmount, 0, address(this));
        assertEq(IERC20(USDC).balanceOf(aUSDC) - shareAmount, fee);
    }

    function test_WithdrawTest() public {
        initPool();
        vm.startPrank(Trader1);
        permit2.approve(address(USDC), address(universalRouter), type(uint160).max, uint48(block.timestamp + 100));
        uint128 swapAmount = 5_000e6;
        uint256 fee = swapAmount / 1000;
        swapExactInputSingle(poolKey, swapAmount, 0, Trader1);
        vm.stopPrank();

        assertEq(hook.devFee(Currency.wrap(address(USDT))), 0);
        assertEq(hook.devFee(Currency.wrap(address(USDC))), fee / 2);
        assertEq(hook.pendingReward(Trader1, Currency.wrap(address(USDC))), fee / 2);

        vm.startPrank(address(this));
        hook.claimHookFee(Currency.wrap(USDC));
        assertEq(hook.devFee(Currency.wrap(USDC)), 0);
        vm.stopPrank();
    }

    function test_RewardTest() public {
        initPool();
        vm.startPrank(Trader1);
        uint128 swapAmount = 5_000e6;
        uint256 rewards = swapAmount / 2000;
        permit2.approve(address(USDC), address(universalRouter), type(uint160).max, uint48(block.timestamp + 60));
        swapExactInputSingle(poolKey, swapAmount, 0, Trader1);
        vm.stopPrank();
        assertEq(hook.pendingReward(Trader1, Currency.wrap(address(USDC))), rewards);

        vm.startPrank(Trader2);
        uint128 swapAmount2 = 5_000e6;
        uint256 rewards2 = swapAmount2 / 2000;
        permit2.approve(address(USDC), address(universalRouter), type(uint160).max, uint48(block.timestamp + 60));
        swapExactInputSingle(poolKey, swapAmount2, 0, Trader2);
        vm.stopPrank();
        assertEq(hook.pendingReward(Trader1, Currency.wrap(address(USDC))), rewards + rewards2 * 1 / 2);
        assertEq(hook.pendingReward(Trader2, Currency.wrap(address(USDC))), rewards2 * 1/2);
    }
}
