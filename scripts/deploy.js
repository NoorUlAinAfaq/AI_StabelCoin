// scripts/deploy.js
// Run: .exit --network baseSepolia

const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("\n=== AI StableCoin Deployment ===");
  console.log("Deployer:", deployer.address);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

  // ── 1. AIStablecoin ────────────────────────────────────────────────────
  const AIStablecoin = await ethers.getContractFactory("AIStablecoin");
  const token = await AIStablecoin.deploy(deployer.address, ethers.parseEther("1000000"));
  await token.waitForDeployment();
  console.log("✅ AIStablecoin deployed:   ", await token.getAddress());

  // ── 2. OracleReceiver ──────────────────────────────────────────────────
  // Replace placeholder addresses with real oracle node wallets
  const oracleNodes = [deployer.address, deployer.address, deployer.address];
  const OracleReceiver = await ethers.getContractFactory("OracleReceiver");
  const oracle = await OracleReceiver.deploy(deployer.address, oracleNodes, 2);
  await oracle.waitForDeployment();
  console.log("✅ OracleReceiver deployed: ", await oracle.getAddress());

  // ── 3. PriceController ─────────────────────────────────────────────────
  // Treasury = deployer for testnet. Use a multisig in production.
  const PriceController = await ethers.getContractFactory("PriceController");
  const controller = await PriceController.deploy(
    deployer.address,
    await oracle.getAddress(),
    await token.getAddress(),
    deployer.address
  );
  await controller.waitForDeployment();
  console.log("✅ PriceController deployed:", await controller.getAddress());

  // ── 4. AIController ─────────────────────────────────────────────────
  // Treasury = deployer for testnet. Use a multisig in production.
  const AIController = await ethers.getContractFactory("AIController");
  const aicontroller = await AIController.deploy(
    deployer.address,
    await oracle.getAddress(),
    await controller.getAddress()
  );
  await aicontroller.waitForDeployment();
  console.log("✅ AIController deployed:", await aicontroller.getAddress());

  // ── 4. Wire roles ──────────────────────────────────────────────────────
  const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));
  const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"));
  const REBASE_ROLE = ethers.keccak256(ethers.toUtf8Bytes("REBASE_ROLE"));
  const KEEPER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("KEEPER_ROLE"));

  await token.grantRole(MINTER_ROLE, await controller.getAddress());
  await token.grantRole(BURNER_ROLE, await controller.getAddress());
  await token.grantRole(REBASE_ROLE, await controller.getAddress());
  await controller.grantRole(KEEPER_ROLE, deployer.address);
  console.log("\n✅ All roles wired");
  console.log("\n MINTER ROLE:", await MINTER_ROLE)

  // ── 5. Summary ─────────────────────────────────────────────────────────
  console.log("\n── Deployed Addresses ────────────────────────────────────");
  console.log("AIStablecoin   :", await token.getAddress());
  console.log("OracleReceiver :", await oracle.getAddress());
  console.log("PriceController:", await controller.getAddress());
  console.log("AIController:", await aicontroller.getAddress());
  console.log("\n MINTER ROLE:", await MINTER_ROLE)
  console.log("\n BURNER ROLE:", await BURNER_ROLE)
  console.log("\n REBASE_ ROLE:", await REBASE_ROLE)
  console.log("\n KEEPER ROLE:", await KEEPER_ROLE)
  /*console.log("\n── Next Steps ────────────────────────────────────────────");
  console.log("1. npx hardhat verify --network baseSepolia <address> <args>");
  console.log("2. Replace oracle node placeholders with real wallet addresses");
  console.log("3. Replace treasury (deployer) with a multisig in production");
  console.log("4. Set up a keeper bot to call PriceController.stabilize() hourly");
  console.log("5. Phase 4: deploy AIController, grant it KEEPER_ROLE on PriceController");*/
}

main().catch((err) => { console.error(err); process.exitCode = 1; });
