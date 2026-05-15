# AI StableCoin — Hardhat Project (Phases 1–4)

## Project Structure

```
ai-stablecoin/
├── contracts/
│   ├── AIStablecoin.sol          ← Phase 1: ERC-20 stablecoin (mint/burn/rebase)
│   ├── OracleReceiver.sol        ← Phase 2: Multi-source price oracle
│   ├── PriceController.sol       ← Phase 3: Supply stabilization engine
│   ├── AIController.sol          ← Phase 4: AI decision gateway & analytics
│   └── mocks/
│       ├── MockOracle.sol
│       ├── MockToken.sol
│       └── MockPriceController.sol
├── test/
│   ├── AIStablecoin.test.js
│   ├── OracleReceiver.test.js
│   ├── PriceController.test.js
│   └── AIController.test.js
├── scripts/
│   └── deploy.js                 ← Deploys all 4 contracts and wires all roles
├── hardhat.config.js
├── package.json
├── .env.example
└── .gitignore
```

---

## Full System Architecture

```
  Off-chain AI Engine
        │
        │ submitRecommendation(action, confidence, reasoning)
        ▼
  ┌─────────────────────┐
  │   AIController      │  ← Phase 4
  │  (AI Gateway)       │
  └────────┬────────────┘
           │ stabilize()  [if confidence ≥ threshold]
           ▼
  ┌─────────────────────┐     latestValidatedPrice()    ┌──────────────────────┐
  │  PriceController    │ ◀──────────────────────────── │  OracleReceiver      │
  │  (Phase 3)          │     deviationFromPeg()        │  (Phase 2)           │
  └────────┬────────────┘                               └──────────────────────┘
           │                                                      ▲
           │  mint() / burn() / rebase()             submitPrice()│
           ▼                                          (oracle nodes)
  ┌─────────────────────┐
  │   AIStablecoin      │
  │   (Phase 1)         │
  └─────────────────────┘
```

---

## Contract Roles Reference

### AIStablecoin
| Role | Held by | Allows |
|---|---|---|
| ADMIN_ROLE | Deployer / multisig | Pause, manage roles |
| MINTER_ROLE | PriceController | `mint()` |
| BURNER_ROLE | PriceController | `burn()` |
| REBASE_ROLE | PriceController | `rebase()` |

### OracleReceiver
| Role | Held by | Allows |
|---|---|---|
| ADMIN_ROLE | Deployer / multisig | Manage nodes, config |
| ORACLE_ROLE | Off-chain oracle wallets | `submitPrice()` |
| CONSUMER_ROLE | PriceController, AIController | Read price data |

### PriceController
| Role | Held by | Allows |
|---|---|---|
| ADMIN_ROLE | Deployer / multisig | Config, pause |
| KEEPER_ROLE | AIController, deployer | `stabilize()` |

### AIController
| Role | Held by | Allows |
|---|---|---|
| ADMIN_ROLE | Deployer / multisig | Config, pause, manual override |
| AI_AGENT_ROLE | Off-chain AI engine wallet | `submitRecommendation()` |
| ANALYST_ROLE | Dashboard / read-only services | Analytics views |

---

## Stabilization Decision Flow

| Oracle Price | Deviation | Action |
|---|---|---|
| = $5.00 | < 100 bps | Skip — within dead-band |
| > $5.00 | 100–499 bps | **Mint** to treasury |
| < $5.00 | -100 to -499 bps | **Burn** from treasury |
| > $5.00 | ≥ 500 bps | **Positive rebase** (capped 5%) |
| < $5.00 | ≤ -500 bps | **Negative rebase** (capped 5%) |

AI recommendations are additionally validated by:
- Minimum confidence score (default 70/100)
- Per-agent submission cooldown (default 30 min)
- Recommendation TTL (default 15 min)
- PriceController availability check

---

## Step 1 — Prerequisites

```bash
node --version   # v18 or higher required
```

---

## Step 2 — Install Dependencies

```bash
cd ai-stablecoin
npm install
```

---

## Step 3 — Compile

```bash
npx hardhat compile
# Expected: Compiled 7 Solidity files successfully
```

---

## Step 4 — Run Tests

```bash
npx hardhat test
```

Run a single suite:

```bash
npx hardhat test test/AIController.test.js
```

Gas report:

```bash
REPORT_GAS=true npx hardhat test
```

Coverage:

```bash
npx hardhat coverage
```

---

## Step 5 — Local Node (Optional)

```bash
# Terminal 1
npx hardhat node

# Terminal 2
npx hardhat run scripts/deploy.js --network localhost
```

---

## Step 6 — Deploy to Base Sepolia

### 6a. Get testnet ETH
[https://www.alchemy.com/faucets/base-sepolia](https://www.alchemy.com/faucets/base-sepolia)

### 6b. Configure .env

```bash
cp .env.example .env
```

```
PRIVATE_KEY=your_wallet_private_key_without_0x
BASE_SEPOLIA_RPC_URL=https://base-sepolia.g.alchemy.com/v2/YOUR_KEY
BASESCAN_API_KEY=your_basescan_api_key
```

### 6c. Deploy all 4 contracts

```bash
npx hardhat run scripts/deploy.js --network baseSepolia
```

The script deploys all four contracts, wires all roles, and prints every address. Before production, edit `deploy.js` to replace:
- Oracle node placeholder addresses → real oracle wallets
- Treasury (deployer) → multisig
- AI_AGENT_ROLE holder (deployer) → real AI engine wallet

---

## Step 7 — Verify on Basescan

```bash
# AIStablecoin
npx hardhat verify --network baseSepolia <address> "0xAdmin" "1000000000000000000000000"

# OracleReceiver
npx hardhat verify --network baseSepolia <address> "0xAdmin" '["0xO1","0xO2","0xO3"]' "2"

# PriceController
npx hardhat verify --network baseSepolia <address> "0xAdmin" "<oracle>" "<token>" "0xTreasury"

# AIController
npx hardhat verify --network baseSepolia <address> "0xAdmin" "<priceController>" "<oracle>"
```

---

## AIController Key Functions

| Function | Caller | Description |
|---|---|---|
| `submitRecommendation(action, confidence, reasoning)` | AI engine | Submit and auto-execute if approved |
| `manualOverride(reason)` | Admin | Force stabilize(), bypasses AI |
| `getDecision(id)` | Anyone | Full record for a specific decision |
| `recentDecisionIds(n)` | Anyone | Last N decision IDs, newest first |
| `analytics()` | Anyone | Approval rate, success rate, totals |
| `agentStats(addr)` | Anyone | Per-agent performance breakdown |
| `confidenceHistogram()` | Anyone | Score distribution across 10 buckets |
| `averageApprovedConfidence()` | Anyone | Drift detection metric |
| `systemStatus()` | Anyone | Full live snapshot for dashboards |
| `agentCooldownRemaining(addr)` | Anyone | Seconds until agent can resubmit |

---

## Common Commands

```bash
npm test                                        # all tests
npx hardhat test test/AIController.test.js      # one file
npx hardhat coverage                            # coverage report
npx hardhat compile                             # recompile
npx hardhat node                                # local chain
npx hardhat console --network baseSepolia       # interactive console
```
