// SPDX-License-Identifier: MIT
pragma solidity >=0.8.30 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {SimpleLending} from "src/SimpleLending.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
}

contract ForkSimpleLending is Test {
    // Sepolia addresses
    address internal constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    address internal constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address internal constant ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    uint256 internal constant FORK_BLOCK = 9_817_118;

    SimpleLending internal lending;
    IWETH internal weth;
    IERC20 internal usdc;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("sepolia"), FORK_BLOCK);
        vm.txGasPrice(0);

        lending = new SimpleLending(WETH, USDC, ETH_USD_FEED);
        weth = IWETH(WETH);
        usdc = IERC20(USDC);

        // Seed protocol + user USDC balances on fork for deterministic tests.
        deal(USDC, address(lending), 1_000_000e6, true);
        deal(USDC, bob, 100_000e6, true);

        // Give Alice ETH so she can wrap to real WETH on fork.
        vm.deal(alice, 10 ether);
    }

    function testFork_DepositBorrowRepayFlow() public {
        vm.startPrank(alice);
        weth.deposit{value: 1 ether}();
        weth.approve(address(lending), type(uint256).max);
        usdc.approve(address(lending), type(uint256).max);

        lending.depositCollateral(1 ether);
        lending.borrow(1_000e6);
        uint256 hfAfterBorrow = lending.getHealthFactor(alice);

        lending.repay(300e6);
        uint256 hfAfterRepay = lending.getHealthFactor(alice);
        vm.stopPrank();

        assertGe(hfAfterBorrow, 1e18);
        assertGt(hfAfterRepay, hfAfterBorrow);
    }

    function testFork_RevertWhenPriceBecomesStale() public {
        // Contract max staleness is 1 hour.
        vm.warp(block.timestamp + 1 hours + 1);

        vm.expectRevert("Price too old");
        lending.getCollateralPriceInUsd();
    }

    function testFork_RevertLiquidationWhenUserHealthy() public {
        vm.startPrank(alice);
        weth.deposit{value: 1 ether}();
        weth.approve(address(lending), type(uint256).max);
        lending.depositCollateral(1 ether);
        lending.borrow(1_000e6);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(lending), type(uint256).max);
        vm.expectRevert("User not liquidatable");
        lending.liquidate(alice, 100e6);
        vm.stopPrank();
    }
}
