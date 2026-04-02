# SimpleLending

A minimal overcollateralized lending protocol written in Solidity. Users deposit WETH as collateral and borrow USDC against it. Prices are sourced from Chainlink and positions are protected by a health factor system.

---

## Overview

| Parameter | Value |
|---|---|
| Solidity version | `0.8.30` |
| Collateral token | WETH (18 decimals) |
| Borrow token | USDC (6 decimals) |
| Price feed | Chainlink ETH/USD (8 decimals) |
| Max LTV | 80% (8,000 BPS) |
| Liquidation threshold | 85% (8,500 BPS) |
| Liquidation bonus | 5% (500 BPS) |
| Price feed max staleness | 1 hour |

---

## How It Works

### Depositing Collateral
Users approve and deposit WETH into the contract. Their balance is tracked internally.

### Borrowing
Users can borrow USDC up to 80% of their collateral value (LTV). The contract checks the health factor after updating the debt — if it falls below `1e18`, the transaction reverts.

### Repaying
Users repay USDC debt. If the repay amount exceeds their outstanding debt, it is automatically capped at the actual debt balance.

### Liquidation
If a borrower's health factor drops below `1e18` (i.e. their collateral value relative to debt crosses the 85% liquidation threshold), any address can liquidate them by repaying part or all of their debt in exchange for the equivalent collateral value plus a **5% bonus**.

---

## Health Factor

```
healthFactor = (collateralValueInUSD × liquidationThreshold) / borrowedValueInUSD
```

- Scaled by `1e18`
- `healthFactor >= 1e18` → position is safe
- `healthFactor < 1e18` → position is liquidatable
- If a user has no debt, health factor returns `type(uint256).max`

---

## Contract Interface

### `depositCollateral(uint256 amount)`
Transfers `amount` of collateral token from the caller into the contract.

### `withdrawCollateral(uint256 amount)`
> ⚠️ Not yet implemented.

### `borrow(uint256 amount)`
Borrows `amount` of the borrow token. Reverts if the resulting health factor would fall below `1e18`.

### `repay(uint256 amount)`
Repays `amount` of borrow token debt. Capped at the caller's outstanding debt.

### `liquidate(address borrower, uint256 debtAmount)`
Liquidates an undercollateralized position. The caller repays `debtAmount` of the borrower's debt and receives the equivalent collateral plus a 5% bonus.

### `getHealthFactor(address borrower) → uint256`
Returns the borrower's current health factor scaled by `1e18`.

### `getCollateralPriceInUsd() → uint256`
Returns the latest Chainlink price for the collateral token in USD (8 decimals). Reverts if the price is stale or non-positive.

---

## Events

| Event | Description |
|---|---|
| `CollateralDeposited(user, collateralToken, amount)` | Emitted on collateral deposit |
| `Borrow(user, amount)` | Emitted when a user borrows |
| `Repaid(user, amount)` | Emitted when a user repays debt |
| `Liquidated(user, userDebt, amountRepaid)` | Emitted when a position is liquidated |

---

## Errors

| Error | Description |
|---|---|
| `SimpleLending__ZeroAddress()` | Thrown in constructor if any address argument is zero |

---

## Dependencies

- [OpenZeppelin](https://github.com/OpenZeppelin/openzeppelin-contracts) — `IERC20`, `SafeERC20`
- [Chainlink](https://github.com/smartcontractkit/chainlink) — `AggregatorV3Interface`

---

## Known Limitations

- `withdrawCollateral` is not implemented
- Single collateral / single borrow asset only — no multi-asset support
- No interest rate model — debt does not accrue interest over time
- No partial liquidation cap — a liquidator can repay the full outstanding debt in one call
- No access control or admin functions

---

## License

MIT