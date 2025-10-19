# Payment Splitter Smart Contract

A Clarity smart contract that enables automatic payment splitting between multiple payees based on predefined shares. Supports both STX and SIP-010 tokens.

## Features

- 🔒 **Immutable Configuration**: Payee configuration is locked after first deposit
- 💰 **Multi-Token Support**: Handle both STX and SIP-010 tokens
- ⚖️ **Fair Distribution**: Automatic splitting based on predefined shares
- 🔍 **Transparent**: View functions for checking balances and shares
- 🛡️ **Secure**: Safe state updates before transfers
- 🚨 **Emergency Control**: Owner can withdraw funds in emergencies

## Usage

### Setting Up Payees

```clarity
(contract-call? .payment-splitter add-payee 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM u100)
```

### Depositing Funds

For STX:
```clarity
(contract-call? .payment-splitter deposit)
```

For SIP-010 tokens:
```clarity
(contract-call? .payment-splitter deposit-token token-contract amount)
```

### Claiming Funds

For STX:
```clarity
(contract-call? .payment-splitter release 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM)
```

For tokens:
```clarity
(contract-call? .payment-splitter release-token token-contract 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM)
```

## Technical Details

- Uses safe multiplication/division pattern
- Implements SIP-010 fungible token trait
- Comprehensive error handling
- Maintains separate accounting per token
- View functions for transparency

## Error Codes

| Code | Description |
|------|-------------|
| u100 | Unauthorized |
| u101 | Bad arguments |
| u102 | Not found |
| u103 | Already exists/locked |
| u104 | Insufficient funds |
| u105 | No funds to release |
| u106 | Contract paused |

## Installation

1. Clone this repository
2. Install Clarinet
3. Run tests:
```bash
clarinet test
```

## Security

- All state changes happen before transfers
- Integer overflow protection
- Locked configuration after first deposit
- Owner-only administrative functions


## Testing

```bash
clarinet test tests/payment-splitter_test.ts
```

## Deployment

Use Clarinet to deploy:
```bash
clarinet deploy
```


## Acknowledgments

- Based on OpenZeppelin's PaymentSplitter pattern
- Adapted for Clarity smart contracts
