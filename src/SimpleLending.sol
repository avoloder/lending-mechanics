//SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title SimpleLending
/// @notice Minimal overcollateralized lending contract with a single collateral and borrow asset
/// @dev Uses Chainlink price feeds and basis points (BPS) risk parameters
contract SimpleLending {
    using SafeERC20 for IERC20;
    
    /// @notice Thrown when a provided address argument is the zero address
    error SimpleLending__ZeroAddress();

    /// @notice Emitted when a user deposits collateral into the protocol
    /// @param user The address of the user depositing collateral
    /// @param collateralToken The collateral ERC20 token address
    /// @param amount The amount of collateral tokens deposited
    event CollateralDeposited(address indexed user, address collateralToken, uint256 amount);

    /// @notice Emitted when a user borrows against their collateral
    /// @param user The address of the borrower
    /// @param amount The amount of borrow tokens sent to the user
    event Borrow(address indexed user, uint256 amount);

    /// @notice Emitted when a user repays their outstanding debt
    /// @param user The address of the borrower repaying
    /// @param amount The amount of borrow tokens repaid
    event Repaid(address indexed user, uint256 amount);

    /// @notice Emitted when a borrower is liquidated
    /// @param user The address of the liquidated borrower
    /// @param userDebt The remaining user debt after liquidation
    /// @param amountRepaid The amount of debt repaid by the liquidator
    event Liquidated(address indexed user, uint256 userDebt, uint256 amountRepaid);


    /// @notice ERC20 token accepted as collateral
    IERC20 private immutable COLLATERAL_TOKEN;

    /// @notice ERC20 token that users can borrow
    IERC20 private immutable BORROW_TOKEN;

    /// @notice Decimals used by the Chainlink price feed
    uint8 private immutable FEED_DECIMALS;

    /// @notice Chainlink price feed for collateral priced in USD
    AggregatorV3Interface private immutable WETH_USD_PRICE_FEED;

    /// @notice Denominator for expressing percentages in basis points (BPS)
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Maximum allowed loan-to-value (LTV) in BPS (80%)
    uint256 private constant LTV = 8_000;  /* (=80 %) */

    /// @notice Liquidation threshold in BPS (85%) above which positions become liquidatable
    uint256 private constant LIQUIDATION_THRESHOLD = 8_500; /* (= 85%) */

    /// @notice Liquidation bonus in BPS (5%) paid to liquidators
    uint256 private constant LIQUIDATION_BONUS = 500; /* (= 5%) */

    /// @notice Maximum allowed staleness for price feed data
    uint256 private constant MAX_STALENESS = 1 hours;

    /// @notice Tracks each borrower's outstanding debt in borrow tokens
    mapping(address borrower => uint256 amount) private userDebt;

    /// @notice Tracks each user's deposited collateral balance
    mapping(address user => uint256 collateral) private userCollateral;

    /// @notice Total outstanding system-wide debt in borrow tokens
    uint256 private totalDebt;

    /// @notice Sets immutable protocol configuration
    /// @param _collateralToken Address of the collateral ERC20 token
    /// @param _borrowToken Address of the borrow ERC20 token
    /// @param _priceFeed Address of the Chainlink price feed used for collateral valuation
    constructor(address _collateralToken, address _borrowToken, address _priceFeed) {
        if (_collateralToken == address(0) || _borrowToken == address(0) || _priceFeed == address(0)) revert SimpleLending__ZeroAddress();
        BORROW_TOKEN = IERC20(_borrowToken);
        COLLATERAL_TOKEN = IERC20(_collateralToken);
        WETH_USD_PRICE_FEED = AggregatorV3Interface(_priceFeed);
        FEED_DECIMALS = WETH_USD_PRICE_FEED.decimals();
    }

    /// @notice Deposit collateral into the protocol on behalf of the caller
    /// @param amount The amount of collateral tokens to deposit
    function depositCollateral(uint256 amount) external {
        require(amount > 0, "Cannot deposit zero amount");
        
        userCollateral[msg.sender] += amount;

        COLLATERAL_TOKEN.safeTransferFrom(msg.sender, address(this), amount);

        emit CollateralDeposited(msg.sender, address(COLLATERAL_TOKEN), amount);
    }

    /// @notice Withdraw previously deposited collateral for the caller
    /// @dev Not yet implemented
    /// @param amount The amount of collateral tokens to withdraw
    function withdrawCollateral(uint256 amount) external {}

    /// @notice Borrow against the caller's deposited collateral
    /// @dev Reverts if the resulting health factor would fall below 1
    /// @param amount The amount of borrow tokens to receive
    function borrow(uint256 amount) external {
        require(amount > 0, "Cannot borrow zero amount");
        require (BORROW_TOKEN.balanceOf(address(this)) >= amount, "Insufficient balance");
        totalDebt += amount;
        userDebt[msg.sender] += amount;
        uint256 healthFactor = getHealthFactor(msg.sender);
        require (healthFactor >= 1e18, "Healthfactor too low");

        BORROW_TOKEN.safeTransfer(msg.sender, amount);
        emit Borrow(msg.sender, amount);
    }

    /// @notice Repay outstanding debt on behalf of the caller
    /// @param amount The amount of borrow tokens to repay (capped at current debt)
    function repay(uint256 amount) external {
        require(amount > 0, "Cannot repay zero amount");
        uint256 debt = userDebt[msg.sender];
        uint256 repayAmount = amount > debt ? debt : amount;
        totalDebt -= repayAmount;
        userDebt[msg.sender] -= repayAmount;
        BORROW_TOKEN.safeTransferFrom(msg.sender, address(this), repayAmount);
        emit Repaid(msg.sender, repayAmount);
    }
    
    /// @notice Liquidate an undercollateralized position
    /// @dev Caller must transfer `debtAmount` of borrow tokens and receives collateral plus bonus
    /// @param borrower The address of the undercollateralized borrower
    /// @param debtAmount The amount of the borrower's debt to cover
    function liquidate(address borrower, uint256 debtAmount) external {
        // 1. First we need to make sure that the user is liquidatable
        uint256 healthFactor = getHealthFactor(borrower);
        require(healthFactor < 1e18, "User not liquidatable");

        // 2. Need to make sure that the user is covering the whole debt amount
        uint256 outstandingDebt = userDebt[borrower];
        require (debtAmount <= outstandingDebt, "Exceeds outstanding debt");

        // 3. We need to calculate the value of user's collateral in USD 
        uint256 collateralPrice = getCollateralPriceInUsd();

        // 4. User gets the paid amount in collateral unit + 5% bonus 
        uint256 collateralToSeize = (debtAmount * (10 ** (18 - 6)) * 1e18 * (BPS_DENOMINATOR + LIQUIDATION_BONUS) / BPS_DENOMINATOR) / (collateralPrice * 10 ** (18 - 8));

        totalDebt -= debtAmount;
        userDebt[borrower] -= debtAmount;
        userCollateral[borrower] -= collateralToSeize;

        BORROW_TOKEN.safeTransferFrom(msg.sender, address(this), debtAmount);
        COLLATERAL_TOKEN.safeTransfer(msg.sender, collateralToSeize);

        emit Liquidated(borrower, userDebt[borrower], debtAmount);
    }

    /// @notice Compute the health factor of a given borrower
    /// @dev Health factor is scaled by 1e18; values below 1e18 are liquidatable
    /// @param borrower The borrower whose health factor is queried
    /// @return healthFactor The borrower's current health factor scaled by 1e18
    function getHealthFactor(address borrower) public view returns(uint256 healthFactor) {

        // Formula for calculating a health factor is: (collateralValue * liquidationThreshold) / borrowedAmount;
        uint256 collateralAmount = userCollateral[borrower];
        uint256 borrowedAmount = userDebt[borrower];

        if (borrowedAmount == 0) return type(uint256).max;

        // This returns price in 8 decimals in USD
        uint256 priceOfCollateral = getCollateralPriceInUsd();

        uint256 collateralValueInUsd = collateralAmount * priceOfCollateral * (10 ** (18 - FEED_DECIMALS)) / 1e18;
        healthFactor = (collateralValueInUsd * LIQUIDATION_THRESHOLD / BPS_DENOMINATOR) * 1e18 / (borrowedAmount * (10 ** (18 - 6)));
        
    }

    /// @notice Fetch the latest collateral price in USD from the Chainlink feed
    /// @dev Reverts if the price is non-positive or exceeds `MAX_STALENESS`
    /// @return The latest collateral price in USD with feed decimals
    function getCollateralPriceInUsd() public view returns(uint256) {
        (,int256 price,,uint256 updatedAt,) = WETH_USD_PRICE_FEED.latestRoundData();
        require(price > 0, "Invalid price");
        require(block.timestamp - updatedAt < MAX_STALENESS, "Price too old");
        return uint256(price);       
    }



}