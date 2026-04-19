// scripts/deploy.js
// Run: npx hardhat run scripts/deploy.js --network baseSepolia

const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("\n=== AI StableCoin Deployment ===");
  console.log("Deployer:", deployer.address);
  console.log(
    "Balance:",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "ETH\n"
  );

  // ── 1. Deploy AIStablecoin ──────────────────────────────────────────────
  const initialSupply = ethers.parseEther("1000000"); // 1,000,000 AISC
  const AIStablecoin = await ethers.getContractFactory("AIStablecoin");
  const token = await AIStablecoin.deploy(deployer.address, initialSupply);
  await token.waitForDeployment();
  console.log("✅ AIStablecoin deployed:", await token.getAddress());

  // ── 2. Deploy OracleReceiver ───────────────────────────────────────────
  // Replace these with your actual oracle node addresses before deploying to testnet
  const oracleNodes = [
    deployer.address, // placeholder — replace with real oracle wallet
    deployer.address, // placeholder
    deployer.address, // placeholder
  ];
  const quorum = 2;

  const OracleReceiver = await ethers.getContractFactory("OracleReceiver");
  const oracle = await OracleReceiver.deploy(
    deployer.address,
    oracleNodes,
    quorum
  );
  await oracle.waitForDeployment();
  console.log("✅ OracleReceiver deployed:", await oracle.getAddress());

  // ── 3. Wire up roles ───────────────────────────────────────────────────
  // In production, PriceController address goes here.
  // For now just log the role bytes so you can grant them later.
  const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));
  const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"));
  const REBASE_ROLE = ethers.keccak256(ethers.toUtf8Bytes("REBASE_ROLE"));
  console.log("\n── Role bytes (use these when wiring PriceController) ──");
  console.log("MINTER_ROLE:", MINTER_ROLE);
  console.log("BURNER_ROLE:", BURNER_ROLE);
  console.log("REBASE_ROLE:", REBASE_ROLE);

  console.log("\n── Summary ──────────────────────────────────────────────");
  console.log("AIStablecoin :", await token.getAddress());
  console.log("OracleReceiver:", await oracle.getAddress());
  console.log("\nNext steps:");
  console.log(
    "1. Verify on Basescan: npx hardhat verify --network baseSepolia <address> <args>"
  );
  console.log(
    "2. Grant MINTER_ROLE + BURNER_ROLE + REBASE_ROLE to PriceController (Phase 3)"
  );
  console.log(
    "3. Grant CONSUMER_ROLE on OracleReceiver to PriceController and AIController"
  );
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
