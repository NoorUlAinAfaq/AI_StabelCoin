const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

// ─────────────────────────────────────────────────────────────────────────────
//  Helpers
// ─────────────────────────────────────────────────────────────────────────────

const ADMIN_ROLE    = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
const ORACLE_ROLE   = ethers.keccak256(ethers.toUtf8Bytes("ORACLE_ROLE"));
const CONSUMER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("CONSUMER_ROLE"));

const TWO_HOURS = 7200;

// Prices use 6 decimals: $5.00 == 5_000_000
const PEG    = 5_000_000n;
const ABOVE  = 5_500_000n; // $5.50 — +10% above peg
const BELOW  = 4_500_000n; // $4.50 — -10% below peg

// ─────────────────────────────────────────────────────────────────────────────
//  Test Suite
// ─────────────────────────────────────────────────────────────────────────────

describe("OracleReceiver", function () {
  let oracle;
  let admin, oracle1, oracle2, oracle3, consumer, stranger;

  async function deployOracle(quorum = 2) {
    [admin, oracle1, oracle2, oracle3, consumer, stranger] =
      await ethers.getSigners();

    const OracleReceiver = await ethers.getContractFactory("OracleReceiver");
    oracle = await OracleReceiver.deploy(
      admin.address,
      [oracle1.address, oracle2.address, oracle3.address],
      quorum
    );
    await oracle.waitForDeployment();
    return oracle;
  }

  beforeEach(async function () {
    await deployOracle(2); // quorum = 2 of 3 oracles
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  DEPLOYMENT
  // ══════════════════════════════════════════════════════════════════════════

  describe("Deployment", function () {
    it("grants ADMIN_ROLE to deployer", async function () {
      expect(await oracle.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
    });

    it("registers all initial oracle nodes with ORACLE_ROLE", async function () {
      expect(await oracle.hasRole(ORACLE_ROLE, oracle1.address)).to.be.true;
      expect(await oracle.hasRole(ORACLE_ROLE, oracle2.address)).to.be.true;
      expect(await oracle.hasRole(ORACLE_ROLE, oracle3.address)).to.be.true;
    });

    it("starts at round 1", async function () {
      expect(await oracle.currentRoundId()).to.equal(1);
    });

    it("stores correct PEG_PRICE constant", async function () {
      expect(await oracle.PEG_PRICE()).to.equal(PEG);
    });

    it("reverts if admin is zero address", async function () {
      const OracleReceiver = await ethers.getContractFactory("OracleReceiver");
      await expect(
        OracleReceiver.deploy(ethers.ZeroAddress, [oracle1.address, oracle2.address], 2)
      ).to.be.revertedWith("OracleReceiver: zero admin");
    });

    it("reverts if fewer oracles than quorum", async function () {
      const OracleReceiver = await ethers.getContractFactory("OracleReceiver");
      await expect(
        OracleReceiver.deploy(admin.address, [oracle1.address], 2)
      ).to.be.revertedWith("OracleReceiver: fewer oracles than quorum");
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  PRICE SUBMISSION
  // ══════════════════════════════════════════════════════════════════════════

  describe("Price submission", function () {
    it("oracle node can submit a price", async function () {
      await expect(oracle.connect(oracle1).submitPrice(PEG))
        .to.emit(oracle, "PriceSubmitted")
        .withArgs(1n, oracle1.address, PEG, await time.latest().then((t) => t + 1));
    });

    it("non-oracle cannot submit a price", async function () {
      await expect(
        oracle.connect(stranger).submitPrice(PEG)
      ).to.be.revertedWith("OracleReceiver: caller lacks role");
    });

    it("reverts on zero price", async function () {
      await expect(
        oracle.connect(oracle1).submitPrice(0)
      ).to.be.revertedWith("OracleReceiver: zero price");
    });

    it("double submission in same round is silently rejected (event emitted)", async function () {
      await oracle.connect(oracle1).submitPrice(PEG);
      // Second submission should emit SubmissionRejected, not revert
      await expect(oracle.connect(oracle1).submitPrice(PEG))
        .to.emit(oracle, "SubmissionRejected")
        .withArgs(1n, oracle1.address, PEG, "already submitted");
    });

    it("records submission data correctly", async function () {
      await oracle.connect(oracle1).submitPrice(ABOVE);
      const [price, , submitted] = await oracle.getSubmission(1, oracle1.address);
      expect(price).to.equal(ABOVE);
      expect(submitted).to.be.true;
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  ROUND FINALIZATION
  // ══════════════════════════════════════════════════════════════════════════

  describe("Round finalization", function () {
    it("finalizes when quorum is reached and advances to next round", async function () {
      // quorum = 2; submit from oracle1 and oracle2
      await oracle.connect(oracle1).submitPrice(PEG);
      await expect(oracle.connect(oracle2).submitPrice(PEG))
        .to.emit(oracle, "RoundFinalized");

      // Should now be on round 2
      expect(await oracle.currentRoundId()).to.equal(2);
    });

    it("sets latestPrice to median after finalization", async function () {
      // quorum = 2, so the round finalizes as soon as oracle1 + oracle2 submit.
      // oracle3's submission lands in the NEXT round, not this one.
      // Submissions in round 1: $4.80 (oracle1) and $5.00 (oracle2)
      // median of [$4.80, $5.00] = ($4.80 + $5.00) / 2 = $4.90
      await oracle.connect(oracle1).submitPrice(4_800_000n);
      await oracle.connect(oracle2).submitPrice(PEG);
      // oracle3 submits but goes into round 2 — doesn't affect round 1 median
      await oracle.connect(oracle3).submitPrice(5_200_000n);

      expect(await oracle.latestPrice()).to.equal(4_900_000n); // $4.90
    });

    it("computes correct median for even count", async function () {
      // Two submissions: $4.80 and $5.20 → median = ($4.80 + $5.20) / 2 = $5.00
      await oracle.connect(oracle1).submitPrice(4_800_000n);
      await oracle.connect(oracle2).submitPrice(5_200_000n);

      expect(await oracle.latestPrice()).to.equal(PEG);
    });

    it("stores round data correctly", async function () {
      await oracle.connect(oracle1).submitPrice(PEG);
      await oracle.connect(oracle2).submitPrice(PEG);

      const [, , medianPrice, submissionCount, finalized] = await oracle.getRound(1);
      expect(medianPrice).to.equal(PEG);
      expect(submissionCount).to.equal(2);
      expect(finalized).to.be.true;
    });

    it("does not finalize before quorum is reached", async function () {
      await oracle.connect(oracle1).submitPrice(PEG);
      // Only 1 of 2 required submissions — round stays open
      expect(await oracle.currentRoundId()).to.equal(1);
      const [, , , , finalized] = await oracle.getRound(1);
      expect(finalized).to.be.false;
    });

    it("updates latestRoundId after finalization", async function () {
      await oracle.connect(oracle1).submitPrice(PEG);
      await oracle.connect(oracle2).submitPrice(PEG);
      expect(await oracle.latestRoundId()).to.equal(1);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  OUTLIER FILTERING
  // ══════════════════════════════════════════════════════════════════════════

  describe("Outlier filtering", function () {
    it("rejects submissions deviating more than maxDeviationBps from median", async function () {
      // Default maxDeviationBps = 3000 (30%)
      // oracle1: $5.00, oracle2: $5.10 → median ≈ $5.05
      // oracle3: $10.00 → deviation ≈ 98% → should be rejected
      // But we need a round to finalize — set quorum to 2 so oracle1+oracle2 finalize
      // Then test outlier logging in a fresh round

      // Submit outlier alongside two normal prices
      // Outlier: $1 (80% below peg)
      await oracle.connect(oracle1).submitPrice(PEG);
      await oracle.connect(oracle2).submitPrice(PEG);
      // Round already finalized with median $5.00

      // Next round: submit one normal and one extreme outlier
      await oracle.connect(oracle1).submitPrice(PEG);
      // oracle3 submits $20 (300% above peg — massive outlier)
      await expect(oracle.connect(oracle3).submitPrice(20_000_000n))
        .to.emit(oracle, "SubmissionRejected")
        .withArgs(2n, oracle3.address, 20_000_000n, "outlier");
    });

    it("proceeds with median if enough valid submissions survive filter", async function () {
      // All three within range
      await oracle.connect(oracle1).submitPrice(4_900_000n); // $4.90
      await oracle.connect(oracle2).submitPrice(5_000_000n); // $5.00
      // quorum met — round finalizes
      expect(await oracle.latestPrice()).to.equal(4_950_000n); // median of 4.90 and 5.00
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  VALIDATED PRICE READ
  // ══════════════════════════════════════════════════════════════════════════

  describe("latestValidatedPrice", function () {
    beforeEach(async function () {
      // Finalize one round so we have a price
      await oracle.connect(oracle1).submitPrice(PEG);
      await oracle.connect(oracle2).submitPrice(PEG);
    });

    it("returns correct price and timestamp", async function () {
      const [price] = await oracle.latestValidatedPrice();
      expect(price).to.equal(PEG);
    });

    it("reverts if price is older than maxPriceAge", async function () {
      await time.increase(TWO_HOURS + 1);
      await expect(oracle.latestValidatedPrice()).to.be.revertedWith(
        "OracleReceiver: price is stale"
      );
    });

    it("reverts if no price has been finalized yet", async function () {
      // Deploy a fresh oracle with no submissions
      const OracleReceiver = await ethers.getContractFactory("OracleReceiver");
      const fresh = await OracleReceiver.deploy(
        admin.address,
        [oracle1.address, oracle2.address],
        2
      );
      await expect(fresh.latestValidatedPrice()).to.be.revertedWith(
        "OracleReceiver: no price yet"
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  DEVIATION FROM PEG
  // ══════════════════════════════════════════════════════════════════════════

  describe("deviationFromPeg", function () {
    it("returns 0 bps when price equals peg", async function () {
      await oracle.connect(oracle1).submitPrice(PEG);
      await oracle.connect(oracle2).submitPrice(PEG);
      expect(await oracle.deviationFromPeg()).to.equal(0);
    });

    it("returns positive bps when price is above peg", async function () {
      // $5.50 = +10% = +1000 bps
      await oracle.connect(oracle1).submitPrice(ABOVE);
      await oracle.connect(oracle2).submitPrice(ABOVE);
      expect(await oracle.deviationFromPeg()).to.equal(1000);
    });

    it("returns negative bps when price is below peg", async function () {
      // $4.50 = -10% = -1000 bps
      await oracle.connect(oracle1).submitPrice(BELOW);
      await oracle.connect(oracle2).submitPrice(BELOW);
      expect(await oracle.deviationFromPeg()).to.equal(-1000);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  PRICE HISTORY
  // ══════════════════════════════════════════════════════════════════════════

  describe("Price history", function () {
    it("records prices in the ring buffer after finalization", async function () {
      await oracle.connect(oracle1).submitPrice(PEG);
      await oracle.connect(oracle2).submitPrice(PEG);

      const [prices] = await oracle.priceHistory();
      expect(prices[0]).to.equal(PEG);
    });

    it("ring buffer wraps after 24 rounds", async function () {
      // Submit 25 rounds worth of prices
      for (let i = 0; i < 25; i++) {
        const roundPrice = PEG + BigInt(i * 1000);
        await oracle.connect(oracle1).submitPrice(roundPrice);
        await oracle.connect(oracle2).submitPrice(roundPrice);
      }
      const [prices] = await oracle.priceHistory();
      // The ring has 24 slots; round 25 overwrites slot 0
      // slot 0 should hold the price from round 25 (index 24)
      const expectedPrice = PEG + BigInt(24 * 1000);
      expect(prices[0]).to.equal(expectedPrice);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  ADMIN — ORACLE NODE MANAGEMENT
  // ══════════════════════════════════════════════════════════════════════════

  describe("Oracle node management", function () {
    it("admin can add a new oracle node", async function () {
      await oracle.connect(admin).addOracleNode(stranger.address);
      expect(await oracle.hasRole(ORACLE_ROLE, stranger.address)).to.be.true;
    });

    it("admin can remove an oracle node", async function () {
      // 3 nodes, quorum 2 — removing one leaves 2 = quorum ✓
      await oracle.connect(admin).removeOracleNode(oracle3.address);
      expect(await oracle.hasRole(ORACLE_ROLE, oracle3.address)).to.be.false;
    });

    it("cannot remove oracle if it would drop below quorum", async function () {
      // Remove oracle3 first (3→2, still ok)
      await oracle.connect(admin).removeOracleNode(oracle3.address);
      // Now 2 nodes, quorum 2 — removing any would leave 1 < 2
      await expect(
        oracle.connect(admin).removeOracleNode(oracle2.address)
      ).to.be.revertedWith("OracleReceiver: would fall below quorum");
    });

    it("reverts if non-admin tries to add oracle", async function () {
      await expect(
        oracle.connect(stranger).addOracleNode(stranger.address)
      ).to.be.revertedWith("OracleReceiver: caller lacks role");
    });

    it("reverts adding a duplicate oracle", async function () {
      await expect(
        oracle.connect(admin).addOracleNode(oracle1.address)
      ).to.be.revertedWith("OracleReceiver: already an oracle");
    });

    it("oracleNodes() returns all active nodes", async function () {
      const nodes = await oracle.oracleNodes();
      expect(nodes).to.include(oracle1.address);
      expect(nodes).to.include(oracle2.address);
      expect(nodes).to.include(oracle3.address);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  ADMIN — CONFIG
  // ══════════════════════════════════════════════════════════════════════════

  describe("Admin configuration", function () {
    it("admin can update minQuorum", async function () {
      await oracle.connect(admin).setMinQuorum(3);
      expect(await oracle.minQuorum()).to.equal(3);
    });

    it("admin can update maxDeviationBps", async function () {
      await oracle.connect(admin).setMaxDeviationBps(2000);
      expect(await oracle.maxDeviationBps()).to.equal(2000);
    });

    it("admin can update maxPriceAge", async function () {
      await oracle.connect(admin).setMaxPriceAge(3600);
      expect(await oracle.maxPriceAge()).to.equal(3600);
    });

    it("emits ConfigUpdated event", async function () {
      await expect(oracle.connect(admin).setMinQuorum(3))
        .to.emit(oracle, "ConfigUpdated")
        .withArgs("minQuorum", 2, 3);
    });

    it("non-admin cannot update config", async function () {
      await expect(
        oracle.connect(stranger).setMinQuorum(1)
      ).to.be.revertedWith("OracleReceiver: caller lacks role");
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  FORCE NEW ROUND
  // ══════════════════════════════════════════════════════════════════════════

  describe("forceNewRound", function () {
    it("admin can force a new round after staleness threshold", async function () {
      // Submit one price but don't hit quorum — round stays open
      await oracle.connect(oracle1).submitPrice(PEG);
      // Advance past stalenessThreshold (1 hour default)
      await time.increase(3601);
      await oracle.connect(admin).forceNewRound();
      expect(await oracle.currentRoundId()).to.equal(2);
    });

    it("non-admin cannot force a new round", async function () {
      await time.increase(3601);
      await expect(
        oracle.connect(stranger).forceNewRound()
      ).to.be.revertedWith("OracleReceiver: caller lacks role");
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  PAUSE
  // ══════════════════════════════════════════════════════════════════════════

  describe("Emergency pause", function () {
    it("admin can pause and unpause", async function () {
      await oracle.connect(admin).pause();
      expect(await oracle.paused()).to.be.true;
      await oracle.connect(admin).unpause();
      expect(await oracle.paused()).to.be.false;
    });

    it("reverts price submission when paused", async function () {
      await oracle.connect(admin).pause();
      await expect(
        oracle.connect(oracle1).submitPrice(PEG)
      ).to.be.revertedWith("OracleReceiver: contract is paused");
    });

    it("non-admin cannot pause", async function () {
      await expect(oracle.connect(stranger).pause()).to.be.revertedWith(
        "OracleReceiver: caller lacks role"
      );
    });

    it("emits Paused and Unpaused events", async function () {
      await expect(oracle.connect(admin).pause())
        .to.emit(oracle, "Paused")
        .withArgs(admin.address);
      await expect(oracle.connect(admin).unpause())
        .to.emit(oracle, "Unpaused")
        .withArgs(admin.address);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  ROLE MANAGEMENT
  // ══════════════════════════════════════════════════════════════════════════

  describe("Role management", function () {
    it("admin can grant CONSUMER_ROLE", async function () {
      await oracle.connect(admin).grantRole(CONSUMER_ROLE, consumer.address);
      expect(await oracle.hasRole(CONSUMER_ROLE, consumer.address)).to.be.true;
    });

    it("admin cannot revoke their own admin role", async function () {
      await expect(
        oracle.connect(admin).revokeRole(ADMIN_ROLE, admin.address)
      ).to.be.revertedWith("OracleReceiver: cannot revoke own admin");
    });

    it("non-admin cannot grant roles", async function () {
      await expect(
        oracle.connect(stranger).grantRole(ORACLE_ROLE, stranger.address)
      ).to.be.revertedWith("OracleReceiver: caller lacks role");
    });
  });
});
