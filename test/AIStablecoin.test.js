const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

// ─────────────────────────────────────────────────────────────────────────────
//  Helpers
// ─────────────────────────────────────────────────────────────────────────────

const ADMIN_ROLE  = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));
const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"));
const REBASE_ROLE = ethers.keccak256(ethers.toUtf8Bytes("REBASE_ROLE"));

const ONE_HOUR = 3600; // seconds
const toWei = (n) => ethers.parseEther(String(n));

// ─────────────────────────────────────────────────────────────────────────────
//  Test Suite
// ─────────────────────────────────────────────────────────────────────────────

describe("AIStablecoin", function () {
  let token;
  let admin, minter, burner, rebaser, user1, user2, stranger;

  // Deploy a fresh instance before every test
  beforeEach(async function () {
    [admin, minter, burner, rebaser, user1, user2, stranger] =
      await ethers.getSigners();

    const AIStablecoin = await ethers.getContractFactory("AIStablecoin");
    // Deploy with 1,000,000 initial supply to admin
    token = await AIStablecoin.deploy(admin.address, toWei(1_000_000));
    await token.waitForDeployment();

    // Grant individual roles so each suite tests in isolation
    await token.connect(admin).grantRole(MINTER_ROLE, minter.address);
    await token.connect(admin).grantRole(BURNER_ROLE, burner.address);
    await token.connect(admin).grantRole(REBASE_ROLE, rebaser.address);
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  DEPLOYMENT
  // ══════════════════════════════════════════════════════════════════════════

  describe("Deployment", function () {
   

    it("mints initial supply to admin", async function () {
      expect(await token.balanceOf(admin.address)).to.equal(toWei(1_000_000));
      expect(await token.totalSupply()).to.equal(toWei(1_000_000));
    });

    it("grants ADMIN_ROLE to deployer", async function () {
      expect(await token.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
    });

    it("reverts if admin is zero address", async function () {
      const AIStablecoin = await ethers.getContractFactory("AIStablecoin");
      await expect(
        AIStablecoin.deploy(ethers.ZeroAddress, 0)
      ).to.be.revertedWith("AIStablecoin: zero admin address");
    });

    it("reverts if initial supply exceeds MAX_SUPPLY", async function () {
      const AIStablecoin = await ethers.getContractFactory("AIStablecoin");
      const overMax = (await token.MAX_SUPPLY()) + 1n;
      await expect(
        AIStablecoin.deploy(admin.address, overMax)
      ).to.be.revertedWith("AIStablecoin: exceeds max supply");
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  ERC-20 TRANSFERS
  // ══════════════════════════════════════════════════════════════════════════

  describe("ERC-20 transfers", function () {
    it("transfers tokens between accounts", async function () {
      await token.connect(admin).transfer(user1.address, toWei(500));
      expect(await token.balanceOf(user1.address)).to.equal(toWei(500));
    });

    it("emits Transfer event", async function () {
      await expect(token.connect(admin).transfer(user1.address, toWei(100)))
        .to.emit(token, "Transfer")
        .withArgs(admin.address, user1.address, toWei(100));
    });

    it("reverts on insufficient balance", async function () {
      await expect(
        token.connect(user1).transfer(user2.address, toWei(1))
      ).to.be.revertedWith("AIStablecoin: insufficient balance");
    });

    it("reverts transfer to zero address", async function () {
      await expect(
        token.connect(admin).transfer(ethers.ZeroAddress, toWei(1))
      ).to.be.revertedWith("AIStablecoin: transfer to zero");
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  APPROVE & TRANSFER FROM
  // ══════════════════════════════════════════════════════════════════════════

  describe("Approve & transferFrom", function () {
    it("sets and reads allowance", async function () {
      await token.connect(admin).approve(user1.address, toWei(200));
      expect(await token.allowance(admin.address, user1.address)).to.equal(
        toWei(200)
      );
    });

    it("transfers via approved spender and decrements allowance", async function () {
      await token.connect(admin).approve(user1.address, toWei(200));
      await token
        .connect(user1)
        .transferFrom(admin.address, user2.address, toWei(100));
      expect(await token.allowance(admin.address, user1.address)).to.equal(
        toWei(100)
      );
      expect(await token.balanceOf(user2.address)).to.equal(toWei(100));
    });

    it("reverts transferFrom when allowance is exceeded", async function () {
      await token.connect(admin).approve(user1.address, toWei(50));
      await expect(
        token
          .connect(user1)
          .transferFrom(admin.address, user2.address, toWei(100))
      ).to.be.revertedWith("AIStablecoin: insufficient allowance");
    });

    it("max allowance (uint256.max) is not decremented", async function () {
      await token.connect(admin).approve(user1.address, ethers.MaxUint256);
      await token
        .connect(user1)
        .transferFrom(admin.address, user2.address, toWei(500));
      expect(await token.allowance(admin.address, user1.address)).to.equal(
        ethers.MaxUint256
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  MINTING
  // ══════════════════════════════════════════════════════════════════════════

  describe("Minting", function () {
    it("minter can mint tokens", async function () {
      await token.connect(minter).mint(user1.address, toWei(5000));
      expect(await token.balanceOf(user1.address)).to.equal(toWei(5000));
    });

    it("emits Mint event", async function () {
      await expect(token.connect(minter).mint(user1.address, toWei(100)))
        .to.emit(token, "Mint")
        .withArgs(user1.address, toWei(100));
    });

    it("reverts if caller lacks MINTER_ROLE", async function () {
      await expect(
        token.connect(stranger).mint(user1.address, toWei(1))
      ).to.be.revertedWith("AIStablecoin: caller lacks role");
    });

    it("reverts if mint would exceed MAX_SUPPLY", async function () {
      const max = await token.MAX_SUPPLY();
      const current = await token.totalSupply();
      const overflow = max - current + 1n;
      await expect(
        token.connect(minter).mint(user1.address, overflow)
      ).to.be.revertedWith("AIStablecoin: exceeds max supply");
    });

    it("reverts mint to zero address", async function () {
      await expect(
        token.connect(minter).mint(ethers.ZeroAddress, toWei(1))
      ).to.be.revertedWith("AIStablecoin: mint to zero address");
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  BURNING
  // ══════════════════════════════════════════════════════════════════════════

  describe("Burning", function () {
    it("burner can burn tokens from a holder", async function () {
      await token.connect(burner).burn(admin.address, toWei(100));
      // Initial supply is 1_000_000 → burning 100 leaves 999_900
      expect(await token.balanceOf(admin.address)).to.equal(toWei(999_900));
    });

    it("emits Burn event", async function () {
      await expect(token.connect(burner).burn(admin.address, toWei(100)))
        .to.emit(token, "Burn")
        .withArgs(admin.address, toWei(100));
    });

    it("reverts burn from zero address", async function () {
      await expect(
        token.connect(burner).burn(ethers.ZeroAddress, toWei(1))
      ).to.be.revertedWith("AIStablecoin: burn from zero address");
    });

    it("reverts if caller lacks BURNER_ROLE", async function () {
      await expect(
        token.connect(stranger).burn(admin.address, toWei(1))
      ).to.be.revertedWith("AIStablecoin: caller lacks role");
    });

    it("reverts if burn exceeds balance", async function () {
      await expect(
        token.connect(burner).burn(user1.address, toWei(1))
      ).to.be.revertedWith("AIStablecoin: burn exceeds balance");
    });

    it("holder can self-burn via burnOwn", async function () {
      await token.connect(admin).transfer(user1.address, toWei(200));
      await token.connect(user1).burnOwn(toWei(100));
      expect(await token.balanceOf(user1.address)).to.equal(toWei(100));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  REBASE
  // ══════════════════════════════════════════════════════════════════════════

  describe("Rebase", function () {
    beforeEach(async function () {
      // Set cooldown to 0 for easier testing (admin can reset it)
      await token.connect(admin).setRebaseCooldown(0);
    });

    it("positive rebase expands totalSupply", async function () {
      const before = await token.totalSupply();
      await token.connect(rebaser).rebase(500); // +5%
      const after = await token.totalSupply();
      // after ≈ before * 10500 / 10000
      expect(after).to.equal((before * 10500n) / 10000n);
    });

    it("negative rebase contracts totalSupply", async function () {
      const before = await token.totalSupply();
      await token.connect(rebaser).rebase(-500); // -5%
      const after = await token.totalSupply();
      expect(after).to.equal((before * 9500n) / 10000n);
    });

    it("emits Rebase event with correct values", async function () {
      const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
      const before = await token.totalSupply();
      await expect(token.connect(rebaser).rebase(200))
        .to.emit(token, "Rebase")
        .withArgs(
          before,
          (before * 10200n) / 10000n,
          200n,
          anyValue // block.timestamp — varies by one second depending on mining
        );
    });

    it("increments totalRebasesExecuted", async function () {
      await token.connect(rebaser).rebase(100);
      expect(await token.totalRebasesExecuted()).to.equal(1);
    });

    it("reverts if caller lacks REBASE_ROLE", async function () {
      await expect(token.connect(stranger).rebase(100)).to.be.revertedWith(
        "AIStablecoin: caller lacks role"
      );
    });

    it("reverts if adjustment exceeds 10% cap (1000 bps)", async function () {
      await expect(token.connect(rebaser).rebase(1001)).to.be.revertedWith(
        "AIStablecoin: adjustment exceeds cap"
      );
      await expect(token.connect(rebaser).rebase(-1001)).to.be.revertedWith(
        "AIStablecoin: adjustment exceeds cap"
      );
    });

    it("reverts on zero adjustment", async function () {
      await expect(token.connect(rebaser).rebase(0)).to.be.revertedWith(
        "AIStablecoin: zero adjustment"
      );
    });

    it("enforces cooldown between rebases", async function () {
      // Restore cooldown to 1 hour
      await token.connect(admin).setRebaseCooldown(ONE_HOUR);

      await token.connect(rebaser).rebase(100);
      // Immediately try a second rebase — should fail
      await expect(token.connect(rebaser).rebase(100)).to.be.revertedWith(
        "AIStablecoin: rebase cooldown active"
      );

      // Fast-forward 1 hour
      await time.increase(ONE_HOUR);
      // Now it should succeed
      await expect(token.connect(rebaser).rebase(100)).to.not.be.reverted;
    });

    it("rebase respects MAX_SUPPLY cap on expansion", async function () {
      // Mint nearly to max so a +10% would overflow
      const max = await token.MAX_SUPPLY();
      const current = await token.totalSupply();
      const gap = max - current;
      // Mint gap tokens — now totalSupply == MAX_SUPPLY
      await token.connect(minter).mint(admin.address, gap);
      await expect(token.connect(rebaser).rebase(1)).to.be.revertedWith(
        "AIStablecoin: rebase exceeds max supply"
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  PAUSE
  // ══════════════════════════════════════════════════════════════════════════

  describe("Emergency pause", function () {
    it("admin can pause and unpause", async function () {
      await token.connect(admin).pause();
      expect(await token.paused()).to.be.true;
      await token.connect(admin).unpause();
      expect(await token.paused()).to.be.false;
    });

    it("reverts transfer when paused", async function () {
      await token.connect(admin).pause();
      await expect(
        token.connect(admin).transfer(user1.address, toWei(1))
      ).to.be.revertedWith("AIStablecoin: contract is paused");
    });

    it("reverts mint when paused", async function () {
      await token.connect(admin).pause();
      await expect(
        token.connect(minter).mint(user1.address, toWei(1))
      ).to.be.revertedWith("AIStablecoin: contract is paused");
    });

    it("reverts burn when paused", async function () {
      await token.connect(admin).pause();
      await expect(
        token.connect(burner).burn(admin.address, toWei(1))
      ).to.be.revertedWith("AIStablecoin: contract is paused");
    });

    it("reverts non-admin pause attempt", async function () {
      await expect(token.connect(stranger).pause()).to.be.revertedWith(
        "AIStablecoin: caller lacks role"
      );
    });

    it("emits Paused and Unpaused events", async function () {
      await expect(token.connect(admin).pause())
        .to.emit(token, "Paused")
        .withArgs(admin.address);
      await expect(token.connect(admin).unpause())
        .to.emit(token, "Unpaused")
        .withArgs(admin.address);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  ROLE MANAGEMENT
  // ══════════════════════════════════════════════════════════════════════════

  describe("Role management", function () {
    it("admin can grant and revoke roles", async function () {
      await token.connect(admin).grantRole(MINTER_ROLE, user2.address);
      expect(await token.hasRole(MINTER_ROLE, user2.address)).to.be.true;
      await token.connect(admin).revokeRole(MINTER_ROLE, user2.address);
      expect(await token.hasRole(MINTER_ROLE, user2.address)).to.be.false;
    });

    it("non-admin cannot grant roles", async function () {
      await expect(
        token.connect(stranger).grantRole(MINTER_ROLE, user2.address)
      ).to.be.revertedWith("AIStablecoin: caller lacks role");
    });

    it("admin cannot revoke their own admin role", async function () {
      await expect(
        token.connect(admin).revokeRole(ADMIN_ROLE, admin.address)
      ).to.be.revertedWith("AIStablecoin: cannot revoke own admin");
    });

    it("emits RoleGranted event", async function () {
      await expect(
        token.connect(admin).grantRole(BURNER_ROLE, user2.address)
      ).to.emit(token, "RoleGranted");
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  //  VIEW HELPERS
  // ══════════════════════════════════════════════════════════════════════════

  describe("View helpers", function () {
    it("circulatingSupply equals totalSupply", async function () {
      expect(await token.circulatingSupply()).to.equal(
        await token.totalSupply()
      );
    });

    it("remainingMintableSupply decreases after minting", async function () {
      const before = await token.remainingMintableSupply();
      await token.connect(minter).mint(user1.address, toWei(1000));
      expect(await token.remainingMintableSupply()).to.equal(
        before - toWei(1000)
      );
    });
  });
});
