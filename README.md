# AI StableCoin — Hardhat Project (Phases 1 & 2)

## Project Structure

```
ai-stablecoin/
├── contracts/
│   ├── AIStablecoin.sol       ← Phase 1: ERC-20 token
│   └── OracleReceiver.sol     ← Phase 2: Price oracle
├── test/
│   ├── AIStablecoin.test.js   ← 30+ test cases for token
│   └── OracleReceiver.test.js ← 30+ test cases for oracle
├── scripts/
│   └── deploy.js              ← Deployment script
├── hardhat.config.js
├── package.json
├── .env.example
└── .gitignore
```

---

## Step 1 — Prerequisites

Make sure you have **Node.js v18+** installed.

```bash
node --version   # should be v18 or higher
```

---

## Step 2 — Install Dependencies

Navigate into the project folder and install:

```bash
cd ai-stablecoin
npm install
```

This installs Hardhat and all testing tools (`chai`, `ethers`, network helpers).

---

## Step 3 — Compile Contracts

```bash
npx hardhat compile
```

You will see:

```
Compiled 2 Solidity files successfully
```

Compiled artifacts go into `/artifacts/`. You don't need to touch them manually.

---

## Step 4 — Run Tests (Local)

```bash
npx hardhat test
```

To run only one contract's tests:

```bash
npx hardhat test test/AIStablecoin.test.js
npx hardhat test test/OracleReceiver.test.js
```

To see gas usage per function:

```bash
REPORT_GAS=true npx hardhat test
```

To see test coverage:

```bash
npx hardhat coverage
```

---

## Step 5 — Run a Local Hardhat Node (Optional)

If you want a live local blockchain to interact with manually:

```bash
npx hardhat node
```

Leave this terminal open. Open a second terminal and deploy to it:

```bash
npx hardhat run scripts/deploy.js --network localhost
```

---

## Step 6 — Deploy to Base Sepolia Testnet

### 6a. Get testnet ETH

Visit the faucet from your project plan:
[https://www.alchemy.com/faucets/base-sepolia](https://www.alchemy.com/faucets/base-sepolia)

Paste your wallet address and receive free testnet ETH.

### 6b. Set up your .env file

```bash
cp .env.example .env
```

Open `.env` and fill in:

```
PRIVATE_KEY=your_wallet_private_key_without_0x
BASE_SEPOLIA_RPC_URL=https://base-sepolia.g.alchemy.com/v2/YOUR_KEY
BASESCAN_API_KEY=your_basescan_api_key
```

> ⚠️ Never commit `.env` to git. It's already in `.gitignore`.

### 6c. Get an Alchemy RPC URL

1. Go to [https://www.alchemy.com](https://www.alchemy.com) and create a free account
2. Create a new app → choose **Base Sepolia**
3. Copy the HTTPS URL into your `.env`

### 6d. Deploy

```bash
npx hardhat run scripts/deploy.js --network baseSepolia
```

You will see the deployed addresses printed in the terminal. Save them.

---

## Step 7 — Verify Contracts on Basescan (Optional but Recommended)

After deployment, verify so you can interact via the Basescan UI:

```bash
# AIStablecoin — args: admin_address  initial_supply_in_wei
npx hardhat verify --network baseSepolia \
  <AIStablecoin_address> \
  "0xYourAdminAddress" \
  "1000000000000000000000000"

# OracleReceiver — args: admin  [oracle1,oracle2,oracle3]  quorum
npx hardhat verify --network baseSepolia \
  <OracleReceiver_address> \
  "0xYourAdminAddress" \
  '["0xOracle1","0xOracle2","0xOracle3"]' \
  "2"
```

Then open [https://sepolia.basescan.org](https://sepolia.basescan.org), search your address,
and use the **Read/Write Contract** tab.

---

## Roles Quick Reference

### AIStablecoin roles

| Role         | Who holds it (planned)   | What it allows           |
|--------------|--------------------------|--------------------------|
| ADMIN_ROLE   | Your deployer / multisig | Pause, manage roles      |
| MINTER_ROLE  | PriceController (Phase 3)| Call `mint()`            |
| BURNER_ROLE  | PriceController (Phase 3)| Call `burn()`            |
| REBASE_ROLE  | PriceController (Phase 3)| Call `rebase()`          |

Grant a role after deployment:

```javascript
// In Hardhat console: npx hardhat console --network baseSepolia
const token = await ethers.getContractAt("AIStablecoin", "<address>");
const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));
await token.grantRole(MINTER_ROLE, "<PriceController_address>");
```

### OracleReceiver roles

| Role          | Who holds it (planned)    | What it allows           |
|---------------|---------------------------|--------------------------|
| ADMIN_ROLE    | Your deployer / multisig  | Manage oracles, config   |
| ORACLE_ROLE   | Off-chain oracle nodes    | Call `submitPrice()`     |
| CONSUMER_ROLE | PriceController, AIController | Read price data      |

---

## Wiring to Phase 3 (PriceController)

When you build `PriceController.sol`, it will:

1. Call `OracleReceiver.latestValidatedPrice()` to get the current price
2. Compare against the $5.00 peg (`OracleReceiver.PEG_PRICE()`)
3. Call `AIStablecoin.mint()` if price > peg, or `AIStablecoin.burn()` if price < peg

You will then:

```bash
# Grant PriceController the roles it needs on AIStablecoin
grantRole(MINTER_ROLE, priceControllerAddress)
grantRole(BURNER_ROLE, priceControllerAddress)
grantRole(REBASE_ROLE, priceControllerAddress)

# Grant PriceController read access on OracleReceiver
grantRole(CONSUMER_ROLE, priceControllerAddress)
```

---

## Common Commands

```bash
npm test                          # run all tests
npx hardhat test test/X.test.js   # run one file
npx hardhat coverage              # coverage report
npx hardhat compile               # recompile after edits
npx hardhat node                  # local blockchain
npx hardhat console --network baseSepolia  # interactive console
```
