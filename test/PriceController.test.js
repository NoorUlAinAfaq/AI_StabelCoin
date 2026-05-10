const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

// ─────────────────────────────────────────────────────────────────────────────
//  Mock contracts are in contracts/mocks/MockOracle.sol and MockToken.sol
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
//  Helpers
// ─────────────────────────────────────────────────────────────────────────────

const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
const KEEPER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("KEEPER_ROLE"));
const ONE_HOUR = 3600;
const PEG = 5_000_000n;




// ─────────────────────────────────────────────────────────────────────────────
//  Test Suite
// ─────────────────────────────────────────────────────────────────────────────

describe("PriceController", function () {
  let controller, mockOracle, mockToken;
  let admin, keeper, treasury, stranger;

  // Deploy fresh mock + controller before every test
  beforeEach(async function () {
    [admin, keeper, treasury, stranger] = await ethers.getSigners();

    // Deploy real AIStablecoin and OracleReceiver as mocks via their actual
    // factories so we get proper ABI — then override behaviour using the
    // PriceController's interface calls.
    // For clean unit tests we deploy tiny inline mock contracts.

    const MockOracleFactory = await ethers.getContractFactory("MockOracle");
    mockOracle = await MockOracleFactory.deploy();
    await mockOracle.waitForDeployment();

    const MockTokenFactory = await ethers.getContractFactory("MockToken");
    mockToken = await MockTokenFactory.deploy();
    await mockToken.waitForDeployment();

    // Give treasury some tokens for burn tests
    await mockToken.setTreasuryBalance(treasury.address, ethers.parseEther("100000"));

    const PriceController = await ethers.getContractFactory("PriceController");
    controller = await PriceController.deploy(
      admin.address,
      await mockOracle.getAddress(),
      await mockToken.getAddress(),
      treasury.address
    );
    await controller.waitForDeployment();

    // Grant keeper role
    await controller.connect(admin).grantRole(KEEPER_ROLE, keeper.address);

    // Zero the cooldown so tests can call stabilize() freely
    await controller.connect(admin).setStabilizationCooldown(0);
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  DEPLOYMENT
  // ══════════════════════════════════════════════════════════════════════════

  describe("Deployment", function () {
    it("sets admin, oracle, token, treasury correctly", async function () {
      expect(await controller.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
      expect(await controller.oracle()).to.equal(await mockOracle.getAddress());
      expect(await controller.token()).to.equal(await mockToken.getAddress());
      expect(await controller.treasury()).to.equal(treasury.address);
    });

    it("reverts if any constructor arg is zero address", async function () {
      const PriceController = await ethers.getContractFactory("PriceController");
      await expect(
        PriceController.deploy(ethers.ZeroAddress, await mockOracle.getAddress(), await mockToken.getAddress(), treasury.address)
      ).to.be.revertedWith("PriceController: zero admin");
      await expect(
        PriceController.deploy(admin.address, ethers.ZeroAddress, await mockToken.getAddress(), treasury.address)
      ).to.be.revertedWith("PriceController: zero oracle");
      await expect(
        PriceController.deploy(admin.address, await mockOracle.getAddress(), ethers.ZeroAddress, treasury.address)
      ).to.be.revertedWith("PriceController: zero token");
      await expect(
        PriceController.deploy(admin.address, await mockOracle.getAddress(), await mockToken.getAddress(), ethers.ZeroAddress)
      ).to.be.revertedWith("PriceController: zero treasury");
    });

    it("initializes default safety parameters", async function () {
      expect(await controller.maxMintPercent()).to.equal(5);
      expect(await controller.maxBurnPercent()).to.equal(5);
      expect(await controller.maxRebaseBps()).to.equal(500);
      expect(await controller.minDeviationBps()).to.equal(100);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  ACCESS CONTROL
  // ══════════════════════════════════════════════════════════════════════════

  describe("Access control", function () {
    it("non-keeper cannot call stabilize()", async function () {
      await expect(controller.connect(stranger).stabilize())
        .to.be.revertedWith("PriceController: caller lacks role");
    });

    it("non-admin cannot update config", async function () {
      await expect(controller.connect(stranger).setMaxMintPercent(10))
        .to.be.revertedWith("PriceController: caller lacks role");
    });

    it("non-admin cannot pause", async function () {
      await expect(controller.connect(stranger).pause())
        .to.be.revertedWith("PriceController: caller lacks role");
    });

    it("admin cannot revoke their own admin role", async function () {
      await expect(controller.connect(admin).revokeRole(ADMIN_ROLE, admin.address))
        .to.be.revertedWith("PriceController: cannot revoke own admin");
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  STABILIZE — DEAD BAND (skip)
  // ══════════════════════════════════════════════════════════════════════════

  describe("Dead-band: deviation below minimum", function () {
    it("emits StabilizationSkipped and does not mint/burn when price is at peg", async function () {
      // deviation = 0, minDeviationBps = 100 → skip
      await mockOracle.setPrice(PEG, 0);
      const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
      await expect(controller.connect(keeper).stabilize())
        .to.emit(controller, "StabilizationSkipped")
        .withArgs(PEG, 0n, "deviation below minimum threshold", anyValue);

      expect(await mockToken.mintCalled()).to.be.false;
      expect(await mockToken.burnCalled()).to.be.false;
    });

    it("skips when deviation is exactly minDeviationBps - 1", async function () {
      // minDeviationBps = 100; set deviation to 99 bps
      const price = PEG + (PEG * 99n) / 10000n; // ~$5.00495
      await mockOracle.setPrice(price, 99);
      await expect(controller.connect(keeper).stabilize())
        .to.emit(controller, "StabilizationSkipped");
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  STABILIZE — MINTING (price above peg, small deviation)
  // ══════════════════════════════════════════════════════════════════════════

  describe("Minting path: price above peg", function () {
    beforeEach(async function () {
      // +200 bps = 2% above peg — small, triggers MINT not REBASE
      // (threshold for REBASE is 5 × minDeviationBps = 500 bps)
      await mockOracle.setPrice(5_100_000n, 200);
    });

    it("calls mint on the token contract", async function () {
      await controller.connect(keeper).stabilize();
      expect(await mockToken.mintCalled()).to.be.true;
    });

    it("mints to the treasury address", async function () {
      await controller.connect(keeper).stabilize();
      expect(await mockToken.lastMintTo()).to.equal(treasury.address);
    });

    it("mints a proportional amount (half the deviation bps of supply)", async function () {
      const supply = await mockToken.totalSupply();
      // rawMintBps = 200 / 2 = 100; mintAmount = supply * 100 / 10000
      const expected = (supply * 100n) / 10000n;
      await controller.connect(keeper).stabilize();
      expect(await mockToken.lastMintAmount()).to.equal(expected);
    });

    it("emits StabilizationExecuted with action MINT (1)", async function () {
      await expect(controller.connect(keeper).stabilize())
        .to.emit(controller, "StabilizationExecuted");
    });

    it("increments totalStabilizationCycles", async function () {
      await controller.connect(keeper).stabilize();
      expect(await controller.totalStabilizationCycles()).to.equal(1);
    });

    it("caps mint at maxMintPercent of supply", async function () {
      // Set deviation to 2000 bps — rawMintBps = 1000, but cap is 500 (5%)
      await mockOracle.setPrice(6_000_000n, 2000);
      // But 2000 bps >= 5×100 = 500 threshold, so it would REBASE instead.
      // Use 900 bps (below 500? no — 900 > 500 → REBASE). Let's use 400 bps.
      await mockOracle.setPrice(5_200_000n, 400);
      const supply = await mockToken.totalSupply();
      const expected = (supply * 200n) / 10000n; // 400/2 = 200 bps, under cap
      await controller.connect(keeper).stabilize();
      expect(await mockToken.lastMintAmount()).to.equal(expected);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  STABILIZE — BURNING (price below peg, small deviation)
  // ══════════════════════════════════════════════════════════════════════════

  describe("Burning path: price below peg", function () {
    beforeEach(async function () {
      // -200 bps = 2% below peg — small, triggers BURN
      await mockOracle.setPrice(4_900_000n, -200);
    });

    it("calls burn on the token contract", async function () {
      await controller.connect(keeper).stabilize();
      expect(await mockToken.burnCalled()).to.be.true;
    });

    it("burns a proportional amount from treasury", async function () {
      const supply = await mockToken.totalSupply();
      const expected = (supply * 100n) / 10000n; // 200/2 = 100 bps
      await controller.connect(keeper).stabilize();
      expect(await mockToken.lastBurnAmount()).to.equal(expected);
    });

    it("clamps burn to treasury balance if treasury has insufficient tokens", async function () {
      // Set treasury balance very small
      const tinyBalance = ethers.parseEther("1");
      await mockToken.setTreasuryBalance(treasury.address, tinyBalance);
      await controller.connect(keeper).stabilize();
      // Should burn only what treasury has
      expect(await mockToken.lastBurnAmount()).to.equal(tinyBalance);
    });

    it("reverts if treasury is empty", async function () {
      await mockToken.setTreasuryBalance(treasury.address, 0);
      await expect(controller.connect(keeper).stabilize())
        .to.be.revertedWith("PriceController: treasury empty, cannot burn");
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  STABILIZE — REBASE (large deviation)
  // ══════════════════════════════════════════════════════════════════════════

  describe("Rebase path: large deviation", function () {
    it("triggers positive rebase when price is far above peg", async function () {
      // 600 bps >= 5 × 100 = 500 threshold → REBASE
      await mockOracle.setPrice(5_300_000n, 600);
      await controller.connect(keeper).stabilize();
      expect(await mockToken.rebaseCalled()).to.be.true;
      // rebaseBps = 600 / 2 = 300, under maxRebaseBps (500) → 300
      expect(await mockToken.lastRebaseBps()).to.equal(300n);
    });

    it("triggers negative rebase when price is far below peg", async function () {
      // -600 bps → negative rebase
      await mockOracle.setPrice(4_700_000n, -600);
      await controller.connect(keeper).stabilize();
      expect(await mockToken.rebaseCalled()).to.be.true;
      expect(await mockToken.lastRebaseBps()).to.equal(-300n);
    });

    it("caps rebase at maxRebaseBps", async function () {
      // 1200 bps deviation / 2 = 600, but maxRebaseBps = 500 → capped at 500
      await mockOracle.setPrice(5_600_000n, 1200);
      await controller.connect(keeper).stabilize();
      expect(await mockToken.lastRebaseBps()).to.equal(500n);
    });

    it("does not call mint or burn during rebase", async function () {
      await mockOracle.setPrice(5_300_000n, 600);
      await controller.connect(keeper).stabilize();
      expect(await mockToken.mintCalled()).to.be.false;
      expect(await mockToken.burnCalled()).to.be.false;
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  COOLDOWN
  // ══════════════════════════════════════════════════════════════════════════

  describe("Cooldown", function () {
    it("reverts if cooldown has not elapsed", async function () {
      await controller.connect(admin).setStabilizationCooldown(ONE_HOUR);
      await mockOracle.setPrice(5_100_000n, 200);
      await controller.connect(keeper).stabilize();
      // Second call immediately — should revert
      await expect(controller.connect(keeper).stabilize())
        .to.be.revertedWith("PriceController: cooldown active");
    });

    it("succeeds after cooldown elapses", async function () {
      await controller.connect(admin).setStabilizationCooldown(ONE_HOUR);
      await mockOracle.setPrice(5_100_000n, 200);
      await controller.connect(keeper).stabilize();
      await time.increase(ONE_HOUR);
      await mockToken.reset();
      await expect(controller.connect(keeper).stabilize()).to.not.be.reverted;
    });

    it("cooldownRemaining() returns correct value", async function () {
      await controller.connect(admin).setStabilizationCooldown(ONE_HOUR);
      await mockOracle.setPrice(5_100_000n, 200);
      await controller.connect(keeper).stabilize();
      const remaining = await controller.cooldownRemaining();
      expect(remaining).to.be.gt(0);
      expect(remaining).to.be.lte(ONE_HOUR);
    });

    it("cooldownRemaining() returns 0 before any stabilization", async function () {
      expect(await controller.cooldownRemaining()).to.equal(0);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  PAUSE
  // ══════════════════════════════════════════════════════════════════════════

  describe("Emergency pause", function () {
    it("paused controller blocks stabilize()", async function () {
      await controller.connect(admin).pause();
      await expect(controller.connect(keeper).stabilize())
        .to.be.revertedWith("PriceController: contract is paused");
    });

    it("can unpause and resume stabilization", async function () {
      await controller.connect(admin).pause();
      await controller.connect(admin).unpause();
      await mockOracle.setPrice(5_100_000n, 200);
      await expect(controller.connect(keeper).stabilize()).to.not.be.reverted;
    });

    it("emits Paused and Unpaused events", async function () {
      await expect(controller.connect(admin).pause())
        .to.emit(controller, "Paused").withArgs(admin.address);
      await expect(controller.connect(admin).unpause())
        .to.emit(controller, "Unpaused").withArgs(admin.address);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  STALE ORACLE
  // ══════════════════════════════════════════════════════════════════════════

  describe("Stale oracle handling", function () {
    it("reverts stabilize() if oracle reverts (stale price)", async function () {
      await mockOracle.setShouldRevert(true);
      await expect(controller.connect(keeper).stabilize())
        .to.be.revertedWith("OracleReceiver: price is stale");
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  PREVIEW
  // ══════════════════════════════════════════════════════════════════════════

  describe("previewStabilization()", function () {
    it("returns NONE when deviation is below threshold", async function () {
      await mockOracle.setPrice(PEG, 0);
      const [action] = await controller.previewStabilization();
      expect(action).to.equal(0); // Action.NONE
    });

    it("returns MINT (1) for small upward deviation", async function () {
      await mockOracle.setPrice(5_100_000n, 200);
      const [action] = await controller.previewStabilization();
      expect(action).to.equal(1); // Action.MINT
    });

    it("returns BURN (2) for small downward deviation", async function () {
      await mockOracle.setPrice(4_900_000n, -200);
      const [action] = await controller.previewStabilization();
      expect(action).to.equal(2); // Action.BURN
    });

    it("returns REBASE (3) for large deviation", async function () {
      await mockOracle.setPrice(5_300_000n, 600);
      const [action] = await controller.previewStabilization();
      expect(action).to.equal(3); // Action.REBASE
    });

    it("preview matches what stabilize() actually does", async function () {
      await mockOracle.setPrice(5_100_000n, 200);
      const [, previewAmount] = await controller.previewStabilization();
      await controller.connect(keeper).stabilize();
      expect(await mockToken.lastMintAmount()).to.equal(previewAmount);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  STATUS
  // ══════════════════════════════════════════════════════════════════════════

  describe("status()", function () {
    it("returns correct values after a stabilization cycle", async function () {
      await mockOracle.setPrice(5_100_000n, 200);
      await controller.connect(keeper).stabilize();
      const s = await controller.status();
      expect(s.currentPrice).to.equal(5_100_000n);
      expect(s.deviationBps).to.equal(200n);
      expect(s.cyclesExecuted).to.equal(1n);
      expect(s.isPaused).to.be.false;
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  LOGGING (ring buffer)
  // ══════════════════════════════════════════════════════════════════════════

  describe("Stabilization log", function () {
    it("stores record after each cycle", async function () {
      await mockOracle.setPrice(5_100_000n, 200);
      await controller.connect(keeper).stabilize();
      const logs = await controller.recentLog(1);
      expect(logs[0].oraclePrice).to.equal(5_100_000n);
      expect(logs[0].cycleId).to.equal(1n);
      expect(logs[0].action).to.equal(1); // MINT
    });

    it("recentLog returns records newest first", async function () {
      await mockOracle.setPrice(5_100_000n, 200);
      await controller.connect(keeper).stabilize();
      await mockToken.reset();
      await mockOracle.setPrice(4_900_000n, -200);
      await controller.connect(keeper).stabilize();

      const logs = await controller.recentLog(2);
      // logs[0] = most recent = cycle 2 (burn)
      expect(logs[0].cycleId).to.equal(2n);
      expect(logs[0].action).to.equal(2); // BURN
      // logs[1] = cycle 1 (mint)
      expect(logs[1].cycleId).to.equal(1n);
      expect(logs[1].action).to.equal(1); // MINT
    });

    it("skipped cycles do not create a log entry", async function () {
      await mockOracle.setPrice(PEG, 0); // below threshold → skip
      await controller.connect(keeper).stabilize();
      const logs = await controller.recentLog(1);
      expect(logs[0].cycleId).to.equal(0n); // empty slot
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  ADMIN CONFIGURATION
  // ══════════════════════════════════════════════════════════════════════════

  describe("Admin configuration", function () {
    it("admin can update oracle address", async function () {
      const newOracle = stranger.address; // dummy address for test
      await expect(controller.connect(admin).setOracle(newOracle))
        .to.emit(controller, "OracleUpdated");
      expect(await controller.oracle()).to.equal(newOracle);
    });

    it("admin can update treasury", async function () {
      await controller.connect(admin).setTreasury(stranger.address);
      expect(await controller.treasury()).to.equal(stranger.address);
    });

    it("admin can update maxMintPercent", async function () {
      await controller.connect(admin).setMaxMintPercent(10);
      expect(await controller.maxMintPercent()).to.equal(10);
    });

    it("reverts maxMintPercent > 20", async function () {
      await expect(controller.connect(admin).setMaxMintPercent(21))
        .to.be.revertedWith("PriceController: out of range");
    });

    it("admin can update maxRebaseBps", async function () {
      await controller.connect(admin).setMaxRebaseBps(300);
      expect(await controller.maxRebaseBps()).to.equal(300);
    });

    it("admin can update minDeviationBps", async function () {
      await controller.connect(admin).setMinDeviationBps(200);
      expect(await controller.minDeviationBps()).to.equal(200);
    });

    it("emits ConfigUpdated event", async function () {
      await expect(controller.connect(admin).setMaxBurnPercent(8))
        .to.emit(controller, "ConfigUpdated")
        .withArgs("maxBurnPercent", 5, 8);
    });

    it("non-admin cannot update oracle", async function () {
      await expect(
        controller.connect(stranger).setOracle(stranger.address)
      ).to.be.revertedWith("PriceController: caller lacks role");
    });
  });
});