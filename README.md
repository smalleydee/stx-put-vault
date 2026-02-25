# STX Put Vault

A Clarity smart contract implementing cash-settled PUT options on STX (Bitcoin L2 token). The vault allows users to buy protective put options with customizable strike prices and expiry dates.

## Overview

**STX Put Vault** enables:
- **Vault Owner** to fund an STX pool and create PUT option series
- **Buyers** to purchase PUT options by paying a premium
- **Settlement** at expiry using oracle price feeds
- **Payouts** calculated as `max(0, strike - settlement_price)`

## Key Features

### Option Series Management
- Owner creates series with configurable strike price, premium-per-unit, and expiry block height
- Series lifecycle: creation → buying → settlement → claim payouts
- Supports multiple concurrent series

### Buyer Flow
1. Purchase option quantity by paying `premium-per-unit × quantity`
2. Hold position until series expiry
3. Claim payout after oracle-based settlement: `max(0, strike - settlement_price) × quantity`

### Vault Operations
- Owner funds vault with STX to underwrite options
- Vault balance tracks available liquidity for payouts
- Owner can withdraw excess funds after obligations met

## Contract Functions

### Admin Functions
```clarity
(set-oracle who)                    ;; Set trusted price oracle
(fund-vault)                        ;; Owner deposits STX to vault
(owner-withdraw amount recipient)   ;; Owner withdraws STX
```

### Series Management
```clarity
(create-series strike premium expiry)  ;; Create new option series
(cancel-series id)                    ;; Cancel series before trading
```

### Trading & Settlement
```clarity
(buy series-id quantity)           ;; Buy options (pay premium)
(settle-series series-id)          ;; Settle at/after expiry using oracle
(claim series-id)                  ;; Claim payout after settlement
```

### Read-Only Views
```clarity
(get-series id)                    ;; Retrieve series details
(get-next-series-id)               ;; Next available series ID
(position-of series-id principal)  ;; Get buyer's position
(get-vault-balance)                ;; Current vault STX balance
```

## Units & Pricing

All values use **micro-STX** (1 STX = 1,000,000 micro-STX):
- **Strike**: micro-STX per STX
- **Premium**: micro-STX per unit (1 unit = 1 STX)
- **Settlement Price**: micro-STX per STX (from oracle)

## Error Codes

| Code | Error | Cause |
|------|-------|-------|
| 100 | `ERR-UNAUTHORIZED` | Only owner can execute |
| 101 | `ERR-BAD-ARGS` | Invalid strike, premium, or expiry |
| 102 | `ERR-NOT-FOUND` | Series ID does not exist |
| 103 | `ERR-INSUFFICIENT` | Insufficient vault or buyer balance |
| 104 | `ERR-ALREADY` | Series already settled or position claimed |
| 105 | `ERR-NOT-DUE` | Series not yet expired |
| 106 | `ERR-ALREADY-SETTLED` | Series already settled |

## Example Usage

```clarity
;; 1. Owner funds vault (example: 100 STX = 100,000,000 micro-STX)
(fund-vault)

;; 2. Owner creates PUT series: strike 50 micro-STX/STX, premium 1,000,000 micro-STX/unit, expires at block 10,000
(create-series u50000000 u1000000 u10000)

;; 3. Buyer purchases 1 unit, pays 1,000,000 micro-STX
(buy u0 u1)

;; 4. At block 10,001, oracle settles series with price 40 micro-STX/STX
(settle-series u0)

;; 5. Buyer claims payout: max(0, 50-40) × 1 = 10 micro-STX
(claim u0)
```

## Technical Details

- **Language**: Clarity v2
- **Network**: Bitcoin L2 / Stacks
- **Settlement**: Oracle-based (configurable principal)
- **Safety**: Pre-transfer balance checks prevent vault depletion
- **State**: Maps track series data and buyer positions

## Future Enhancements

- [ ] Integrate live price oracle (currently uses mock price: 100 micro-STX/STX)
- [ ] Add per-series position tracking for analytics
- [ ] Implement series total-quantity counter for efficient validation
- [ ] Support holder buyback before expiry
- [ ] Multi-currency settlement

## Testing

Deploy and test using Clarinet:

```bash
clarinet check          ;; Type check contract
clarinet test          ;; Run unit tests
clarinet console       ;; Interactive console for testing
```

## License

MIT
