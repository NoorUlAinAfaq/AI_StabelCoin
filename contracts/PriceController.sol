// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title PriceController
 * @notice Phase 3 — Stabilization engine for the AI StableCoin ecosystem.
 *
 * Reads the validated price from OracleReceiver, compares it against the
 * $5.00 peg, and drives supply adjustments on AIStablecoin to push the
 * price back toward peg:
 *
 *   price > $5.00  →  mint new tokens  (increases supply, reduces price)
 *   price < $5.00  →  burn tokens      (decreases supply, raises price)
 *   deviation ≥ threshold → rebase     (proportional supply adjustment)
 *
 * Safety limits (all configurable by admin):
 *   - MAX_MINT_PERCENT   : 5%  max single-cycle mint
 *   - MAX_BURN_PERCENT   : 5%  max single-cycle burn
 *   - MAX_REBASE_BPS     : 500 bps (5%) max single-cycle rebase
 *   - STABILIZATION_COOLDOWN : 1 hour between cycles
 *   - MIN_DEVIATION_BPS  : 100 bps (1%) minimum deviation to act
 *
 * Role model:
 *   ADMIN_ROLE    — manages config, pause, and the stabilization treasury
 *   KEEPER_ROLE   — EOA/bot allowed to call stabilize() (e.g. Gelato keeper)
 *
 * Wiring required after deployment:
 *   AIStablecoin.grantRole(MINTER_ROLE, address(this))
 *   AIStablecoin.grantRole(BURNER_ROLE, address(this))
 *   AIStablecoin.grantRole(REBASE_ROLE, address(this))
 *
 * Deployment target: Base Sepolia testnet
 */

// ─────────────────────────────────────────────────────────────────────────────
//  Minimal external interfaces (avoids import overhead on testnet)
// ─────────────────────────────────────────────────────────────────────────────

interface IOracle {
    function latestValidatedPrice() external view returns (uint256 price, uint256 timestamp);
    function deviationFromPeg()     external view returns (int256 bps);
    function PEG_PRICE()            external view returns (uint256);
}

interface IStablecoin {
    function totalSupply()           external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function rebase(int256 adjustmentBps) external;
    function balanceOf(address account) external view returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
//  PriceController
// ─────────────────────────────────────────────────────────────────────────────

contract PriceController {

    // ── Role constants ────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE  = keccak256("ADMIN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    mapping(bytes32 => mapping(address => bool)) private _roles;

    // ── Connected contracts ───────────────────────────────────────────────────
    IOracle     public oracle;
    IStablecoin public token;

    // ── Peg ───────────────────────────────────────────────────────────────────
    // Mirrors OracleReceiver.PEG_PRICE — 6 decimal representation of $5.00
    uint256 public constant PEG = 5_000_000;

    // ── Safety limits (configurable) ──────────────────────────────────────────
    uint256 public maxMintPercent       = 5;    // % of totalSupply per cycle
    uint256 public maxBurnPercent       = 5;    // % of totalSupply per cycle
    uint256 public maxRebaseBps         = 500;  // basis points per cycle
    uint256 public stabilizationCooldown = 1 hours;
    uint256 public minDeviationBps      = 100;  // 1% — ignore tiny fluctuations

    // ── Stabilization treasury ────────────────────────────────────────────────
    // Minted tokens go here; burned tokens come from here.
    // Admin sets this to a reserve wallet / multisig.
    address public treasury;

    // ── State ─────────────────────────────────────────────────────────────────
    bool    public paused;
    uint256 public lastStabilizationTimestamp;
    uint256 public totalStabilizationCycles;

    // ── Action enum ───────────────────────────────────────────────────────────
    enum Action { NONE, MINT, BURN, REBASE }

    // ── Historical log (last 50 cycles) ──────────────────────────────────────
    uint256 public constant LOG_SIZE = 50;

    struct StabilizationRecord {
        uint256 cycleId;
        uint256 oraclePrice;
        int256  deviationBps;
        Action  action;
        uint256 amount;       // tokens minted/burned (0 for NONE)
        int256  rebaseBps;    // bps passed to rebase() (0 if not REBASE)
        uint256 supplyBefore;
        uint256 supplyAfter;
        uint256 timestamp;
    }

    StabilizationRecord[LOG_SIZE] private _log;
    uint256 private _logIndex;

    // ── Events ────────────────────────────────────────────────────────────────
    event RoleGranted(bytes32 indexed role, address indexed account);
    event RoleRevoked(bytes32 indexed role, address indexed account);

    event StabilizationExecuted(
        uint256 indexed cycleId,
        uint256 oraclePrice,
        int256  deviationBps,
        Action  action,
        uint256 mintBurnAmount,
        int256  rebaseBps,
        uint256 supplyBefore,
        uint256 supplyAfter,
        uint256 timestamp
    );

    event StabilizationSkipped(
        uint256 oraclePrice,
        int256  deviationBps,
        string  reason,
        uint256 timestamp
    );

    event OracleUpdated(address oldOracle, address newOracle);
    event TokenUpdated(address oldToken, address newToken);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event ConfigUpdated(string param, uint256 oldValue, uint256 newValue);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    // ── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "PriceController: caller lacks role");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "PriceController: contract is paused");
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param admin      Initial admin (your deployer / multisig).
     * @param _oracle    Deployed OracleReceiver address.
     * @param _token     Deployed AIStablecoin address.
     * @param _treasury  Address that receives minted tokens / holds tokens to burn.
     */
    constructor(
        address admin,
        address _oracle,
        address _token,
        address _treasury
    ) {
        require(admin     != address(0), "PriceController: zero admin");
        require(_oracle   != address(0), "PriceController: zero oracle");
        require(_token    != address(0), "PriceController: zero token");
        require(_treasury != address(0), "PriceController: zero treasury");

        _grantRole(ADMIN_ROLE, admin);

        oracle   = IOracle(_oracle);
        token    = IStablecoin(_token);
        treasury = _treasury;
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  CORE STABILIZATION
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Main entry point. Called by a keeper bot every cycle.
     *         Anyone with KEEPER_ROLE (or admin) can call this.
     *         Reads oracle price, decides action, executes, logs.
     */
    function stabilize() external onlyRole(KEEPER_ROLE) whenNotPaused {
        // ── 1. Cooldown check ─────────────────────────────────────────────────
        require(
            block.timestamp >= lastStabilizationTimestamp + stabilizationCooldown,
            "PriceController: cooldown active"
        );

        // ── 2. Read oracle ────────────────────────────────────────────────────
        (uint256 currentPrice, ) = oracle.latestValidatedPrice();
        int256 deviationBps      = oracle.deviationFromPeg();

        // ── 3. Dead-band check — skip tiny deviations ─────────────────────────
        uint256 absDeviation = deviationBps >= 0
            ? uint256(deviationBps)
            : uint256(-deviationBps);

        if (absDeviation < minDeviationBps) {
            emit StabilizationSkipped(
                currentPrice,
                deviationBps,
                "deviation below minimum threshold",
                block.timestamp
            );
            lastStabilizationTimestamp = block.timestamp;
            return;
        }

        // ── 4. Determine action and magnitude ─────────────────────────────────
        uint256 supplyBefore = token.totalSupply();
        Action  action;
        uint256 mintBurnAmount;
        int256  rebaseBps;

        if (currentPrice > PEG) {
            // Price above peg: expand supply to push price down
            (action, mintBurnAmount, rebaseBps) = _calcExpansion(
                currentPrice,
                deviationBps,
                supplyBefore
            );
        } else {
            // Price below peg: contract supply to push price up
            (action, mintBurnAmount, rebaseBps) = _calcContraction(
                currentPrice,
                deviationBps,
                supplyBefore
            );
        }

        // ── 5. Execute ────────────────────────────────────────────────────────
        if (action == Action.MINT) {
            token.mint(treasury, mintBurnAmount);
        } else if (action == Action.BURN) {
            uint256 treasuryBalance = token.balanceOf(treasury);
            uint256 actualBurn = mintBurnAmount > treasuryBalance
                ? treasuryBalance
                : mintBurnAmount;
            require(actualBurn > 0, "PriceController: treasury empty, cannot burn");
            token.burn(treasury, actualBurn);
            mintBurnAmount = actualBurn; // log actual amount
        } else if (action == Action.REBASE) {
            token.rebase(rebaseBps);
        }
        // Action.NONE falls through (should not happen given dead-band check above)

        uint256 supplyAfter = token.totalSupply();

        // ── 6. Update state ───────────────────────────────────────────────────
        lastStabilizationTimestamp = block.timestamp;
        totalStabilizationCycles++;
        uint256 cycleId = totalStabilizationCycles;

        // ── 7. Log ────────────────────────────────────────────────────────────
        _log[_logIndex] = StabilizationRecord({
            cycleId:      cycleId,
            oraclePrice:  currentPrice,
            deviationBps: deviationBps,
            action:       action,
            amount:       mintBurnAmount,
            rebaseBps:    rebaseBps,
            supplyBefore: supplyBefore,
            supplyAfter:  supplyAfter,
            timestamp:    block.timestamp
        });
        _logIndex = (_logIndex + 1) % LOG_SIZE;

        emit StabilizationExecuted(
            cycleId,
            currentPrice,
            deviationBps,
            action,
            mintBurnAmount,
            rebaseBps,
            supplyBefore,
            supplyAfter,
            block.timestamp
        );
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  VIEW — PRICE & SUPPLY STATUS
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Live status snapshot — useful for dashboards and AIController.
     */
    function status() external view returns (
        uint256 currentPrice,
        int256  deviationBps,
        uint256 totalSupply,
        uint256 lastCycleTimestamp,
        uint256 cyclesExecuted,
        bool    isPaused
    ) {
        (currentPrice, ) = oracle.latestValidatedPrice();
        deviationBps     = oracle.deviationFromPeg();
        totalSupply      = token.totalSupply();
        lastCycleTimestamp = lastStabilizationTimestamp;
        cyclesExecuted   = totalStabilizationCycles;
        isPaused         = paused;
    }

    /**
     * @notice Preview what action stabilize() would take right now, without
     *         executing it. Useful for keeper bots and monitoring.
     */
    function previewStabilization() external view returns (
        Action  action,
        uint256 mintBurnAmount,
        int256  rebaseBps,
        uint256 currentPrice,
        int256  deviationBps
    ) {
        (currentPrice, ) = oracle.latestValidatedPrice();
        deviationBps     = oracle.deviationFromPeg();

        uint256 absDeviation = deviationBps >= 0
            ? uint256(deviationBps)
            : uint256(-deviationBps);

        if (absDeviation < minDeviationBps) {
            return (Action.NONE, 0, 0, currentPrice, deviationBps);
        }

        uint256 supply = token.totalSupply();

        if (currentPrice > PEG) {
            (action, mintBurnAmount, rebaseBps) = _calcExpansion(currentPrice, deviationBps, supply);
        } else {
            (action, mintBurnAmount, rebaseBps) = _calcContraction(currentPrice, deviationBps, supply);
        }
    }

    /**
     * @notice Returns the last `count` stabilization records (newest first).
     */
    function recentLog(uint256 count)
        external
        view
        returns (StabilizationRecord[] memory records)
    {
        if (count > LOG_SIZE) count = LOG_SIZE;
        records = new StabilizationRecord[](count);
        for (uint256 i = 0; i < count; i++) {
            // Walk backwards from latest entry
            uint256 idx = (_logIndex + LOG_SIZE - 1 - i) % LOG_SIZE;
            records[i]  = _log[idx];
        }
    }

    /**
     * @notice Seconds remaining until stabilize() can be called again.
     */
    function cooldownRemaining() external view returns (uint256) {
        if (block.timestamp >= lastStabilizationTimestamp + stabilizationCooldown) {
            return 0;
        }
        return (lastStabilizationTimestamp + stabilizationCooldown) - block.timestamp;
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  INTERNAL — EXPANSION & CONTRACTION CALCULATORS
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Price above peg — decide between MINT and REBASE.
     *      Small deviation (< 5×minDeviationBps)  → MINT proportional amount.
     *      Large deviation (≥ 5×minDeviationBps)  → REBASE for broader effect.
     */
    function _calcExpansion(
        uint256 /* price */,
        int256  deviationBps,
        uint256 supply
    )
        internal
        view
        returns (Action action, uint256 mintAmount, int256 _rebaseBps)
    {
        uint256 absBps = uint256(deviationBps); // deviationBps > 0 here

        if (absBps >= uint256(minDeviationBps) * 5) {
            // Large deviation — rebase
            uint256 rawRebaseBps = absBps / 2; // soften: half the deviation
            _rebaseBps = int256(_min(rawRebaseBps, maxRebaseBps));
            return (Action.REBASE, 0, _rebaseBps);
        }

        // Small deviation — targeted mint
        // mintAmount = supply * deviationBps / 10000, capped at maxMintPercent
        uint256 rawMintBps = absBps / 2;
        uint256 maxMintBps = maxMintPercent * 100;
        uint256 finalBps   = _min(rawMintBps, maxMintBps);
        mintAmount = (supply * finalBps) / 10_000;
        return (Action.MINT, mintAmount, 0);
    }

    /**
     * @dev Price below peg — decide between BURN and REBASE.
     *      Small deviation  → BURN proportional amount from treasury.
     *      Large deviation  → REBASE (negative) for broader effect.
     */
    function _calcContraction(
        uint256 /* price */,
        int256  deviationBps,
        uint256 supply
    )
        internal
        view
        returns (Action action, uint256 burnAmount, int256 _rebaseBps)
    {
        uint256 absBps = uint256(-deviationBps); // deviationBps < 0 here

        if (absBps >= uint256(minDeviationBps) * 5) {
            // Large deviation — negative rebase
            uint256 rawRebaseBps = absBps / 2;
            _rebaseBps = -int256(_min(rawRebaseBps, maxRebaseBps));
            return (Action.REBASE, 0, _rebaseBps);
        }

        // Small deviation — targeted burn
        uint256 rawBurnBps = absBps / 2;
        uint256 maxBurnBps = maxBurnPercent * 100;
        uint256 finalBps   = _min(rawBurnBps, maxBurnBps);
        burnAmount = (supply * finalBps) / 10_000;
        return (Action.BURN, burnAmount, 0);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  ADMIN — CONFIGURATION
    // ══════════════════════════════════════════════════════════════════════════

    function setOracle(address newOracle) external onlyRole(ADMIN_ROLE) {
        require(newOracle != address(0), "PriceController: zero oracle");
        emit OracleUpdated(address(oracle), newOracle);
        oracle = IOracle(newOracle);
    }

    function setToken(address newToken) external onlyRole(ADMIN_ROLE) {
        require(newToken != address(0), "PriceController: zero token");
        emit TokenUpdated(address(token), newToken);
        token = IStablecoin(newToken);
    }

    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        require(newTreasury != address(0), "PriceController: zero treasury");
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function setMaxMintPercent(uint256 pct) external onlyRole(ADMIN_ROLE) {
        require(pct > 0 && pct <= 20, "PriceController: out of range");
        emit ConfigUpdated("maxMintPercent", maxMintPercent, pct);
        maxMintPercent = pct;
    }

    function setMaxBurnPercent(uint256 pct) external onlyRole(ADMIN_ROLE) {
        require(pct > 0 && pct <= 20, "PriceController: out of range");
        emit ConfigUpdated("maxBurnPercent", maxBurnPercent, pct);
        maxBurnPercent = pct;
    }

    function setMaxRebaseBps(uint256 bps) external onlyRole(ADMIN_ROLE) {
        require(bps > 0 && bps <= 1000, "PriceController: out of range");
        emit ConfigUpdated("maxRebaseBps", maxRebaseBps, bps);
        maxRebaseBps = bps;
    }

    function setStabilizationCooldown(uint256 cooldown) external onlyRole(ADMIN_ROLE) {
        emit ConfigUpdated("stabilizationCooldown", stabilizationCooldown, cooldown);
        stabilizationCooldown = cooldown;
    }

    function setMinDeviationBps(uint256 bps) external onlyRole(ADMIN_ROLE) {
        require(bps > 0, "PriceController: zero deviation");
        emit ConfigUpdated("minDeviationBps", minDeviationBps, bps);
        minDeviationBps = bps;
    }

    // ── Role management ───────────────────────────────────────────────────────

    function grantRole(bytes32 role, address account) external onlyRole(ADMIN_ROLE) {
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(ADMIN_ROLE) {
        require(
            !(role == ADMIN_ROLE && account == msg.sender),
            "PriceController: cannot revoke own admin"
        );
        _roles[role][account] = false;
        emit RoleRevoked(role, account);
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    // ── Emergency pause ───────────────────────────────────────────────────────

    function pause() external onlyRole(ADMIN_ROLE) {
        require(!paused, "PriceController: already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        require(paused, "PriceController: not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _grantRole(bytes32 role, address account) internal {
        _roles[role][account] = true;
        emit RoleGranted(role, account);
    }
}
