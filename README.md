# AI StableCoin — Hardhat Project (Phases 1, 2 & 3)

## Project Structure

```
ai-stablecoin/
├── contracts/
│   ├── AIStablecoin.sol         ← Phase 1: ERC-20 stablecoin (mint/burn/rebase)
│   ├── OracleReceiver.sol       ← Phase 2: Multi-source price oracle
│   ├── PriceController.sol      ← Phase 3: Stabilization engine
│   └── mocks/
│       ├── MockOracle.sol       ← Test double for OracleReceiver
│       └── MockToken.sol        ← Test double for AIStablecoin
├── test/
│   ├── AIStablecoin.test.js     ← 30+ test cases
│   ├── OracleReceiver.test.js   ← 30+ test cases
│   └── PriceController.test.js  ← 30+ test cases
├── scripts/
│   └── deploy.js                ← Deploys all 3 contracts and wires roles
├── hardhat.config.js
├── package.json
├── .env.example
└── .gitignore
```

---

## Architecture Overview

```
  Off-chain oracle nodes
         │
         │ submitPrice()
         ▼
  ┌─────────────────┐       latestValidatedPrice()      ┌──────────────────────┐
  │ OracleReceiver  │ ─────────────────────────────────▶ │  PriceController     │
  │   (Phase 2)     │       deviationFromPeg()           │    (Phase 3)         │
  └─────────────────┘                                    └──────────┬───────────┘
                                                                    │
                                              mint() / burn() / rebase()
                                                                    │
                                                                    ▼
                                                         ┌─────────────────────┐
                                                         │   AIStablecoin      │
                                                         │     (Phase 1)       │
                                                         └─────────────────────┘
```

### How stabilization works

| Oracle Price | Deviation | Action taken by PriceController |
|---|---|---|
| = $5.00 | < 100 bps | **Skip** — within dead-band |
| > $5.00 | 100–499 bps | **Mint** tokens to treasury (expands supply) |
| < $5.00 | -100 to -499 bps | **Burn** tokens from treasury (contracts supply) |
| > $5.00 | ≥ 500 bps | **Positive rebase** (proportional expansion, capped 5%) |
| < $5.00 | ≤ -500 bps | **Negative rebase** (proportional contraction, capped 5%) |

---

## Step 1 — Prerequisites

Make sure you have **Node.js v18+** installed.

```bash
node --version   # should be v18 or higher
```

---

## Step 2 — Install Dependencies

```bash
cd ai-stablecoin
npm install
```

---

## Step 3 — Compile Contracts

```bash
npx hardhat compile
```

Expected output:

```
Compiled 5 Solidity files successfully
```

Artifacts go into `/artifacts/`. You don't need to touch them manually.

---

## Step 4 — Run Tests (Local)

```bash
npx hardhat test
```

To run a single contract's tests:

```bash
npx hardhat test test/AIStablecoin.test.js
npx hardhat test test/OracleReceiver.test.js
npx hardhat test test/PriceController.test.js
```

To print gas usage per function:

```bash
REPORT_GAS=true npx hardhat test
```

To generate a coverage report:

```bash
npx hardhat coverage
```

---

## Step 5 — Run a Local Hardhat Node (Optional)

```bash
# Terminal 1 — start local blockchain
npx hardhat node

# Terminal 2 — deploy to it
npx hardhat run scripts/deploy.js --network localhost
```

---

## Step 6 — Deploy to Base Sepolia Testnet

### 6a. Get testnet ETH

[https://www.alchemy.com/faucets/base-sepolia](https://www.alchemy.com/faucets/base-sepolia)

### 6b. Set up your .env file

```bash
cp .env.example .env
```

Fill in:

```
PRIVATE_KEY=your_wallet_private_key_without_0x
BASE_SEPOLIA_RPC_URL=https://base-sepolia.g.alchemy.com/v2/YOUR_KEY
BASESCAN_API_KEY=your_basescan_api_key
```

> ⚠️ Never commit `.env` to git. It is already in `.gitignore`.

### 6c. Get an Alchemy RPC URL

1. Create a free account at [https://www.alchemy.com](https://www.alchemy.com)
2. Create a new app → choose **Base Sepolia**
3. Copy the HTTPS URL into `.env`

### 6d. Deploy all three contracts

```bash
npx hardhat run scripts/deploy.js --network baseSepolia
```

The script deploys all three contracts in order, wires the roles automatically, and prints all addresses. Save them.

**Before deploying to production**, edit `deploy.js` and replace:
- The oracle node placeholder addresses with real oracle wallets
- The treasury address (currently deployer) with a multisig

---

## Step 7 — Verify Contracts on Basescan

```bash
# AIStablecoin
npx hardhat verify --network baseSepolia \
  <AIStablecoin_address> \
  "0xYourAdminAddress" \
  "1000000000000000000000000"

# OracleReceiver
npx hardhat verify --network baseSepolia \
  <OracleReceiver_address> \
  "0xYourAdminAddress" \
  '["0xOracle1","0xOracle2","0xOracle3"]' \
  "2"

# PriceController
npx hardhat verify --network baseSepolia \
  <PriceController_address> \
  "0xYourAdminAddress" \
  "<OracleReceiver_address>" \
  "<AIStablecoin_address>" \
  "0xYourTreasuryAddress"
```

Then open [https://sepolia.basescan.org](https://sepolia.basescan.org) and use the **Read/Write Contract** tab to interact.

---

## Roles Quick Reference

### AIStablecoin

| Role | Held by | Allows |
|---|---|---|
| ADMIN_ROLE | Deployer / multisig | Pause, manage roles |
| MINTER_ROLE | PriceController | Call `mint()` |
| BURNER_ROLE | PriceController | Call `burn()` |
| REBASE_ROLE | PriceController | Call `rebase()` |

### OracleReceiver

| Role | Held by | Allows |
|---|---|---|
| ADMIN_ROLE | Deployer / multisig | Manage nodes, config |
| ORACLE_ROLE | Off-chain oracle wallets | Call `submitPrice()` |
| CONSUMER_ROLE | PriceController, AIController | Read price data |

### PriceController

| Role | Held by | Allows |
|---|---|---|
| ADMIN_ROLE | Deployer / multisig | Config, pause, role management |
| KEEPER_ROLE | Bot / deployer / AIController | Call `stabilize()` |

Grant a role manually via the Hardhat console:

```javascript
// npx hardhat console --network baseSepolia
const controller = await ethers.getContractAt("PriceController", "<address>");
const KEEPER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("KEEPER_ROLE"));
await controller.grantRole(KEEPER_ROLE, "<keeper_bot_address>");
```

---

## PriceController Key Functions

| Function | Who calls it | Description |
|---|---|---|
| `stabilize()` | Keeper bot (hourly) | Reads oracle, decides action, executes |
| `previewStabilization()` | Anyone (view) | Preview action without executing — use in keeper bots |
| `status()` | Anyone (view) | Live snapshot: price, deviation, supply, cycle count |
| `recentLog(n)` | Anyone (view) | Last N stabilization records, newest first |
| `cooldownRemaining()` | Anyone (view) | Seconds until next `stabilize()` is allowed |

---

## Phase 4 — AIController (coming next)

When AIController is deployed it will:

1. Read `OracleReceiver.priceHistory()` for trend data
2. Use confidence scoring to approve or block stabilization actions
3. Call `PriceController.stabilize()` via KEEPER_ROLE

Wiring needed after AIController deployment:

```bash
controller.grantRole(KEEPER_ROLE, aiControllerAddress)
oracle.grantRole(CONSUMER_ROLE, aiControllerAddress)
```

---

## Common Commands

```bash
npm test                                        # run all tests
npx hardhat test test/PriceController.test.js  # run one file
npx hardhat coverage                            # coverage report
npx hardhat compile                             # recompile after edits
npx hardhat node                                # local blockchain
npx hardhat console --network baseSepolia       # interactive console
```