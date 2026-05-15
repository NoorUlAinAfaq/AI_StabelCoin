const { ethers } = require("hardhat");

async function main() {
 const [admin, aiAgent] = await ethers.getSigners();

 // ── Deploy mocks ───────────────────────────────────────────────────────
 const mockPC = await (await ethers.getContractFactory("MockPriceController")).deploy();
 const mockOracle = await (await ethers.getContractFactory("MockOracle")).deploy();
 await mockPC.waitForDeployment();
 await mockOracle.waitForDeployment();

 // ── Deploy AIController ────────────────────────────────────────────────
 const controller = await (await ethers.getContractFactory("AIController")).deploy(
  admin.address,
  await mockPC.getAddress(),
  await mockOracle.getAddress()
 );
 await controller.waitForDeployment();
 console.log("AIController deployed:", await controller.getAddress());

 // ── Setup ──────────────────────────────────────────────────────────────
 const AI_AGENT_ROLE = ethers.keccak256(ethers.toUtf8Bytes("AI_AGENT_ROLE"));
 await controller.grantRole(AI_AGENT_ROLE, aiAgent.address);
 await controller.setSubmissionCooldown(0);

 // ── Submit a recommendation ────────────────────────────────────────────
 await controller.connect(aiAgent).submitRecommendation(1, 85, "Price above peg, expand supply");
 console.log("Decision 1:", await controller.getDecision(1));

 // ── Manual override ────────────────────────────────────────────────────
 await controller.manualOverride("Testing emergency override");

 // ── Analytics ──────────────────────────────────────────────────────────
 const a = await controller.analytics();
 console.log("Total decisions :", a.decisions.toString());
 console.log("Total approved  :", a.approved.toString());
 console.log("Approval rate   :", a.approvalRateBps.toString(), "bps");
 console.log("Success rate    :", a.successRateBps.toString(), "bps");
}

main().catch(console.error);