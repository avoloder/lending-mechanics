// SPDX-License-Identifier: MIT
pragma solidity >=0.8.30 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {SimpleLending} from "src/SimpleLending.sol";
import {MockERC20, MockAggregatorV3} from "test/mocks/MockTokensAndFeed.sol";

contract IntegrationSimpleLending is Test {
    SimpleLending internal _lending;
    MockERC20 internal _weth;
    MockERC20 internal _usdc;
    MockAggregatorV3 internal _priceFeed;

    address internal _alice = makeAddr("alice");
    address internal _bob = makeAddr("bob");

    uint256 internal constant COLLATERAL_AMOUNT = 1 ether;
    uint256 internal constant STARTING_PRICE = 2_000e8; // 8 decimals

    function setUp() public {
        vm.txGasPrice(0);

        _weth = new MockERC20("Wrapped Ether", "WETH", 18);
        _usdc = new MockERC20("USD Coin", "USDC", 6);
        _priceFeed = new MockAggregatorV3(8, int256(STARTING_PRICE));

        _lending = new SimpleLending(address(_weth), address(_usdc), address(_priceFeed));

        // Seed protocol liquidity for borrowing.
        _usdc.mint(address(_lending), 1_000_000e6);

        // Seed users.
        _weth.mint(_alice, 10 ether);
        _weth.mint(_bob, 10 ether);
        _usdc.mint(_alice, 200_000e6);
        _usdc.mint(_bob, 200_000e6);
    }

    function testDepositCollateralAndBorrow() public {
        vm.startPrank(_alice);
        _weth.approve(address(_lending), type(uint256).max);
        _lending.depositCollateral(COLLATERAL_AMOUNT);

        // 1 WETH @ $2000, threshold=85% => max safe borrow is 1700 USDC.
        uint256 borrowAmount = 1_000e6;
        _lending.borrow(borrowAmount);
        vm.stopPrank();

        assertEq(_usdc.balanceOf(_alice), 201_000e6);
        assertGe(_lending.getHealthFactor(_alice), 1e18);
    }

    function testRepayRestoresHealthFactorAndDebt() public {
        vm.startPrank(_alice);
        _weth.approve(address(_lending), type(uint256).max);
        _usdc.approve(address(_lending), type(uint256).max);

        _lending.depositCollateral(COLLATERAL_AMOUNT);
        _lending.borrow(1_000e6);

        uint256 hfBefore = _lending.getHealthFactor(_alice);
        _lending.repay(400e6);
        uint256 hfAfter = _lending.getHealthFactor(_alice);
        vm.stopPrank();

        assertGt(hfAfter, hfBefore);
        assertEq(_usdc.balanceOf(_alice), 200_600e6);
    }

    function testRevertBorrowWhenHealthFactorWouldDropBelowOne() public {
        vm.startPrank(_alice);
        _weth.approve(address(_lending), type(uint256).max);
        _lending.depositCollateral(COLLATERAL_AMOUNT);

        // Above safe amount (1700 USDC), should revert.
        vm.expectRevert("Healthfactor too low");
        _lending.borrow(1_800e6);
        vm.stopPrank();
    }

    function testLiquidateUnhealthyBorrower() public {
        // Alice opens a position right at healthy boundary.
        vm.startPrank(_alice);
        _weth.approve(address(_lending), type(uint256).max);
        _lending.depositCollateral(COLLATERAL_AMOUNT);
        _lending.borrow(1_600e6);
        vm.stopPrank();

        // Price drops from $2000 to $1500, making position unsafe.
        _priceFeed.setPrice(1_500e8);
        assertLt(_lending.getHealthFactor(_alice), 1e18);

        uint256 bobWethBefore = _weth.balanceOf(_bob);

        vm.startPrank(_bob);
        _usdc.approve(address(_lending), type(uint256).max);
        _lending.liquidate(_alice, 800e6);
        vm.stopPrank();

        assertGt(_weth.balanceOf(_bob), bobWethBefore);
        assertGt(_lending.getHealthFactor(_alice), 0);
    }

    function testRevertLiquidationWhenUserHealthy() public {
        vm.startPrank(_alice);
        _weth.approve(address(_lending), type(uint256).max);
        _lending.depositCollateral(COLLATERAL_AMOUNT);
        _lending.borrow(1_000e6);
        vm.stopPrank();

        vm.startPrank(_bob);
        _usdc.approve(address(_lending), type(uint256).max);
        vm.expectRevert("User not liquidatable");
        _lending.liquidate(_alice, 500e6);
        vm.stopPrank();
    }

    function testRevertOnZeroDeposit() public {
        vm.prank(_alice);
        vm.expectRevert("Cannot deposit zero amount");
        _lending.depositCollateral(0);
    }

    function testRevertOnZeroBorrow() public {
        vm.prank(_alice);
        vm.expectRevert("Cannot borrow zero amount");
        _lending.borrow(0);
    }

    function testRevertOnZeroRepay() public {
        vm.prank(_alice);
        vm.expectRevert("Cannot repay zero amount");
        _lending.repay(0);
    }

    function testRevertOnStalePrice() public {
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert("Price too old");
        _lending.getCollateralPriceInUsd();
    }

    function testRevertLiquidationAmountExceedsDebt() public {
        vm.startPrank(_alice);
        _weth.approve(address(_lending), type(uint256).max);
        _lending.depositCollateral(COLLATERAL_AMOUNT);
        _lending.borrow(1_600e6);
        vm.stopPrank();

        _priceFeed.setPrice(1_400e8);
        assertLt(_lending.getHealthFactor(_alice), 1e18);

        vm.startPrank(_bob);
        _usdc.approve(address(_lending), type(uint256).max);
        vm.expectRevert("Exceeds outstanding debt");
        _lending.liquidate(_alice, 1_700e6);
        vm.stopPrank();
    }

    function testRepayMoreThanDebtCapsAtOutstanding() public {
        vm.startPrank(_alice);
        _weth.approve(address(_lending), type(uint256).max);
        _usdc.approve(address(_lending), type(uint256).max);
        _lending.depositCollateral(COLLATERAL_AMOUNT);
        _lending.borrow(600e6);

        uint256 usdcBeforeRepay = _usdc.balanceOf(_alice);
        _lending.repay(1_000e6);
        vm.stopPrank();

        assertEq(_usdc.balanceOf(_alice), usdcBeforeRepay - 600e6);
        assertEq(_lending.getHealthFactor(_alice), type(uint256).max);
    }

    function testFuzzBorrowWithinSafeRangeKeepsHealthy(uint256 borrowAmount) public {
        // Safe max = collateralUsd * liquidationThreshold = 2000 * 85% = 1700 USDC.
        borrowAmount = bound(borrowAmount, 1, 1_700e6);

        vm.startPrank(_alice);
        _weth.approve(address(_lending), type(uint256).max);
        _lending.depositCollateral(COLLATERAL_AMOUNT);
        _lending.borrow(borrowAmount);
        vm.stopPrank();

        assertGe(_lending.getHealthFactor(_alice), 1e18);
    }

    function testFuzzRepayAmountAlwaysImprovesOrClearsPosition(uint256 repayAmount) public {
        vm.startPrank(_alice);
        _weth.approve(address(_lending), type(uint256).max);
        _usdc.approve(address(_lending), type(uint256).max);
        _lending.depositCollateral(COLLATERAL_AMOUNT);
        _lending.borrow(1_000e6);

        uint256 hfBefore = _lending.getHealthFactor(_alice);
        repayAmount = bound(repayAmount, 1, 5_000e6);
        _lending.repay(repayAmount);
        uint256 hfAfter = _lending.getHealthFactor(_alice);
        vm.stopPrank();

        assertGe(hfAfter, hfBefore);
    }
}
