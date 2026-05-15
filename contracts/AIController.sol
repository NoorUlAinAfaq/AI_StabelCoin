// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title AIController
 * @notice Phase 4 — AI decision gateway for the AI StableCoin ecosystem.
 *
 * Receives stabilization recommendations from an off-chain AI engine,
 * validates them on-chain (confidence threshold, cooldown, staleness),
 * forwards approved actions to PriceController, and maintains a full
 * auditable history of every AI decision for model analytics.
 *
 * Flow:
 *   Off-chain AI engine
 *       │
 *       │  submitRecommendation(action, confidenceScore, reasoning, ...)
 *       ▼
 *   AIController  ──[if approved]──▶  PriceController.stabilize()
 *       │
 *       └──▶  DecisionRecord stored on-chain (win/loss tracked later)
 *
 * Role model:
 *   ADMIN_ROLE      — config, pause, emergency override
 *   AI_AGENT_ROLE   — off-chain engine wallet(s) that submit recommendations
 *   ANALYST_ROLE    — read-only analytics access (for dashboards)
 *
 * Wiring required after deployment:
 *   PriceController.grantRole(KEEPER_ROLE, address(this))
 *   OracleReceiver.grantRole(CONSUMER_ROLE, address(this))
 *
 * Deployment target: Base Sepolia testnet
 */

// ─────────────────────────────────────────────────────────────────────────────
//  External interfaces
// ─────────────────────────────────────────────────────────────────────────────

interface IPriceController {
    function stabilize() external;
    function previewStabilization() external view returns (
        uint8  action,
        uint256 mintBurnAmount,
        int256  rebaseBps,
        uint256 currentPrice,
        int256  deviationBps
    );
    function cooldownRemaining() external view returns (uint256);
    function paused() external view returns (bool);
}

interface IOracle {
    function latestValidatedPrice() external view returns (uint256 price, uint256 timestamp);
    function deviationFromPeg()     external view returns (int256 bps);
    function priceHistory()         external view returns (uint256[24] memory prices, uint256[24] memory timestamps);
}

// ─────────────────────────────────────────────────────────────────────────────
//  AIController
// ─────────────────────────────────────────────────────────────────────────────

contract AIController {

    // ── Roles ─────────────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE   = keccak256("ADMIN_ROLE");
    bytes32 public constant AI_AGENT_ROLE = keccak256("AI_AGENT_ROLE");
    bytes32 public constant ANALYST_ROLE = keccak256("ANALYST_ROLE");

    mapping(bytes32 => mapping(address => bool)) private _roles;

    // ── Connected contracts ───────────────────────────────────────────────────
    IPriceController public priceController;
    IOracle          public oracle;

    // ── Confidence & validation config ───────────────────────────────────────
    uint256 public minConfidenceScore   = 70;   // 0–100; submissions below this are rejected
    uint256 public maxReasoningLength   = 500;  // bytes, prevents bloated calldata
    uint256 public submissionCooldown   = 30 minutes; // min gap between AI submissions
    uint256 public recommendationTTL    = 15 minutes; // recommendation expires if not executed within this window

    // ── Action enum (mirrors PriceController.Action) ─────────────────────────
    enum Action { NONE, MINT, BURN, REBASE }

    // ── Decision status ───────────────────────────────────────────────────────
    enum DecisionStatus {
        PENDING,    // submitted, awaiting execution
        APPROVED,   // passed threshold — forwarded to PriceController
        REJECTED,   // below confidence threshold or validation failed
        OVERRIDDEN, // admin manually overrode the decision
        EXPIRED     // TTL elapsed before execution
    }

    // ── Decision record ───────────────────────────────────────────────────────
    struct DecisionRecord {
        uint256    decisionId;
        address    aiAgent;           // which AI agent wallet submitted this
        Action     recommendedAction;
        uint256    confidenceScore;   // 0–100
        string     reasoning;         // free-text from the AI model
        uint256    oraclePriceAtTime; // snapshot of oracle price when submitted
        int256     deviationAtTime;   // snapshot of deviation bps when submitted
        uint256    submittedAt;
        uint256    executedAt;        // 0 if not executed
        DecisionStatus status;
        bool       executionSuccess;  // did PriceController.stabilize() succeed?
        string     rejectionReason;   // populated on REJECTED / EXPIRED
    }

    // ── Storage ───────────────────────────────────────────────────────────────
    uint256 public totalDecisions;
    mapping(uint256 => DecisionRecord) private _decisions;

    // Ring buffer for fast recent-history reads (last 100 decisions)
    uint256 public constant HISTORY_SIZE = 100;
    uint256[HISTORY_SIZE] private _recentDecisionIds;
    uint256 private _historyIndex;

    // ── Analytics counters ────────────────────────────────────────────────────
    uint256 public totalApproved;
    uint256 public totalRejected;
    uint256 public totalOverridden;
    uint256 public totalExpired;
    uint256 public totalExecutionSuccesses;
    uint256 public totalExecutionFailures;

    // Confidence-bucket histogram (0–9, 10–19, … 90–100)
    uint256[10] private _confidenceHistogram;

    // Per-agent performance
    struct AgentStats {
        uint256 submitted;
        uint256 approved;
        uint256 rejected;
        uint256 successes;
        uint256 failures;
    }
    mapping(address => AgentStats) private _agentStats;

    // ── Submission cooldown tracking ──────────────────────────────────────────
    mapping(address => uint256) public lastSubmissionTimestamp;

    // ── Pending decision (only one at a time) ─────────────────────────────────
    uint256 public pendingDecisionId; // 0 = none pending

    // ── Emergency manual override ─────────────────────────────────────────────
    bool    public aiEnabled = true;   // admin can disable AI routing entirely
    bool    public paused;

    // ── Events ───────────────────────────────────────────────────────────────
    event RoleGranted(bytes32 indexed role, address indexed account);
    event RoleRevoked(bytes32 indexed role, address indexed account);

    event RecommendationSubmitted(
        uint256 indexed decisionId,
        address indexed aiAgent,
        Action  action,
        uint256 confidenceScore,
        uint256 oraclePrice,
        int256  deviationBps,
        uint256 timestamp
    );

    event DecisionApproved(
        uint256 indexed decisionId,
        Action  action,
        uint256 confidenceScore,
        uint256 timestamp
    );

    event DecisionRejected(
        uint256 indexed decisionId,
        Action  action,
        uint256 confidenceScore,
        string  reason,
        uint256 timestamp
    );

    event DecisionExecuted(
        uint256 indexed decisionId,
        bool    success,
        uint256 timestamp
    );

    event DecisionExpired(
        uint256 indexed decisionId,
        uint256 timestamp
    );

    event ManualOverride(
        uint256 indexed decisionId,
        address indexed admin,
        string  reason,
        uint256 timestamp
    );

    event AIEnabledChanged(bool enabled, address indexed by);
    event ConfigUpdated(string param, uint256 oldValue, uint256 newValue);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event ContractUpdated(string name, address oldAddr, address newAddr);

    // ── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "AIController: caller lacks role");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "AIController: contract is paused");
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param admin            Initial admin address.
     * @param _priceController Deployed PriceController address.
     * @param _oracle          Deployed OracleReceiver address.
     */
    constructor(address admin, address _priceController, address _oracle) {
        require(admin            != address(0), "AIController: zero admin");
        require(_priceController != address(0), "AIController: zero priceController");
        require(_oracle          != address(0), "AIController: zero oracle");

        _grantRole(ADMIN_ROLE, admin);
        priceController = IPriceController(_priceController);
        oracle          = IOracle(_oracle);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  CORE — RECOMMENDATION SUBMISSION
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Off-chain AI engine submits a stabilization recommendation.
     *         Validated on-chain; if approved, forwarded to PriceController.
     *
     * @param action          Recommended action (0=NONE,1=MINT,2=BURN,3=REBASE).
     * @param confidenceScore 0–100 confidence level from the AI model.
     * @param reasoning       Human-readable explanation from the model.
     */
    function submitRecommendation(
        Action  action,
        uint256 confidenceScore,
        string calldata reasoning
    )
        external
        onlyRole(AI_AGENT_ROLE)
        whenNotPaused
    {
        // ── Validate inputs ───────────────────────────────────────────────────
        require(confidenceScore <= 100, "AIController: confidence > 100");
        require(bytes(reasoning).length <= maxReasoningLength, "AIController: reasoning too long");
        require(action != Action.NONE, "AIController: NONE action not submittable");

        // ── Cooldown check per agent ──────────────────────────────────────────
        require(
            block.timestamp >= lastSubmissionTimestamp[msg.sender] + submissionCooldown,
            "AIController: submission cooldown active"
        );

        // ── Expire any stale pending decision ─────────────────────────────────
        _expireStaleDecision();

        // ── Snapshot oracle state ─────────────────────────────────────────────
        (uint256 currentPrice, ) = oracle.latestValidatedPrice();
        int256  currentDeviation = oracle.deviationFromPeg();

        // ── Create decision record ────────────────────────────────────────────
        totalDecisions++;
        uint256 decisionId = totalDecisions;

        _decisions[decisionId] = DecisionRecord({
            decisionId:        decisionId,
            aiAgent:           msg.sender,
            recommendedAction: action,
            confidenceScore:   confidenceScore,
            reasoning:         reasoning,
            oraclePriceAtTime: currentPrice,
            deviationAtTime:   currentDeviation,
            submittedAt:       block.timestamp,
            executedAt:        0,
            status:            DecisionStatus.PENDING,
            executionSuccess:  false,
            rejectionReason:   ""
        });

        // Update ring buffer and cooldown
        _recentDecisionIds[_historyIndex] = decisionId;
        _historyIndex = (_historyIndex + 1) % HISTORY_SIZE;
        lastSubmissionTimestamp[msg.sender] = block.timestamp;

        // Update agent stats
        _agentStats[msg.sender].submitted++;

        // Update confidence histogram
        uint256 bucket = confidenceScore / 10;
        if (bucket > 9) bucket = 9;
        _confidenceHistogram[bucket]++;

        emit RecommendationSubmitted(
            decisionId,
            msg.sender,
            action,
            confidenceScore,
            currentPrice,
            currentDeviation,
            block.timestamp
        );

        // ── Validate confidence threshold ─────────────────────────────────────
        if (confidenceScore < minConfidenceScore) {
            _rejectDecision(decisionId, "confidence below threshold");
            return;
        }

        // ── Check AI routing is enabled ───────────────────────────────────────
        if (!aiEnabled) {
            _rejectDecision(decisionId, "AI routing disabled by admin");
            return;
        }

        // ── Check PriceController is ready ────────────────────────────────────
        if (priceController.paused()) {
            _rejectDecision(decisionId, "PriceController is paused");
            return;
        }

        if (priceController.cooldownRemaining() > 0) {
            _rejectDecision(decisionId, "PriceController cooldown active");
            return;
        }

        // ── All checks passed — approve and execute ───────────────────────────
        _decisions[decisionId].status = DecisionStatus.APPROVED;
        pendingDecisionId = decisionId;
        totalApproved++;
        _agentStats[msg.sender].approved++;

        emit DecisionApproved(decisionId, action, confidenceScore, block.timestamp);

        _executeDecision(decisionId);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  CORE — EXECUTION
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Execute the current pending approved decision.
     *         Can be called by any keeper if the decision is still pending
     *         (e.g. if submitRecommendation ran out of gas mid-execution).
     */
    function executePending() external onlyRole(AI_AGENT_ROLE) whenNotPaused {
        require(pendingDecisionId != 0, "AIController: no pending decision");
        DecisionRecord storage rec = _decisions[pendingDecisionId];
        require(rec.status == DecisionStatus.APPROVED, "AIController: decision not approved");
        _expireStaleDecision();
        if (rec.status == DecisionStatus.EXPIRED) return;
        _executeDecision(pendingDecisionId);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  EMERGENCY MANUAL OVERRIDE
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Admin can force-execute stabilize() bypassing AI validation.
     *         Logged as OVERRIDDEN for analytics transparency.
     * @param reason Free-text reason for the override (audit trail).
     */
    function manualOverride(string calldata reason) external onlyRole(ADMIN_ROLE) whenNotPaused {
        require(bytes(reason).length > 0, "AIController: reason required");

        // Cancel any pending AI decision
        if (pendingDecisionId != 0) {
            DecisionRecord storage pending = _decisions[pendingDecisionId];
            if (pending.status == DecisionStatus.APPROVED || pending.status == DecisionStatus.PENDING) {
                pending.status = DecisionStatus.OVERRIDDEN;
                totalOverridden++;
                emit ManualOverride(pendingDecisionId, msg.sender, reason, block.timestamp);
            }
            pendingDecisionId = 0;
        }

        // Create a synthetic override record
        totalDecisions++;
        uint256 decisionId = totalDecisions;
        (uint256 currentPrice, ) = oracle.latestValidatedPrice();
        int256 currentDeviation   = oracle.deviationFromPeg();

        _decisions[decisionId] = DecisionRecord({
            decisionId:        decisionId,
            aiAgent:           msg.sender,
            recommendedAction: Action.NONE, // admin doesn't specify — PriceController decides
            confidenceScore:   100,         // admin override = max confidence
            reasoning:         reason,
            oraclePriceAtTime: currentPrice,
            deviationAtTime:   currentDeviation,
            submittedAt:       block.timestamp,
            executedAt:        0,
            status:            DecisionStatus.OVERRIDDEN,
            executionSuccess:  false,
            rejectionReason:   ""
        });

        _recentDecisionIds[_historyIndex] = decisionId;
        _historyIndex = (_historyIndex + 1) % HISTORY_SIZE;
        totalOverridden++;

        emit ManualOverride(decisionId, msg.sender, reason, block.timestamp);

        // Execute
        bool success = _callStabilize();
        _decisions[decisionId].executedAt       = block.timestamp;
        _decisions[decisionId].executionSuccess = success;

        if (success) {
            totalExecutionSuccesses++;
        } else {
            totalExecutionFailures++;
        }

        emit DecisionExecuted(decisionId, success, block.timestamp);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  VIEW — DECISION QUERIES
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Full record for a specific decision.
     */
    function getDecision(uint256 decisionId)
        external
        view
        returns (DecisionRecord memory)
    {
        require(decisionId > 0 && decisionId <= totalDecisions, "AIController: invalid id");
        return _decisions[decisionId];
    }

    /**
     * @notice Returns the last `count` decision IDs (newest first).
     *         Use getDecision() to fetch individual records.
     */
    function recentDecisionIds(uint256 count)
        external
        view
        returns (uint256[] memory ids)
    {
        if (count > HISTORY_SIZE) count = HISTORY_SIZE;
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 idx = (_historyIndex + HISTORY_SIZE - 1 - i) % HISTORY_SIZE;
            ids[i] = _recentDecisionIds[idx];
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  VIEW — ANALYTICS
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Overall AI performance summary.
     */
    function analytics() external view returns (
        uint256 decisions,
        uint256 approved,
        uint256 rejected,
        uint256 overridden,
        uint256 expired,
        uint256 successes,
        uint256 failures,
        uint256 approvalRateBps,   // approved / decisions * 10000
        uint256 successRateBps     // successes / approved * 10000
    ) {
        decisions  = totalDecisions;
        approved   = totalApproved;
        rejected   = totalRejected;
        overridden = totalOverridden;
        expired    = totalExpired;
        successes  = totalExecutionSuccesses;
        failures   = totalExecutionFailures;
        approvalRateBps = totalDecisions > 0
            ? (totalApproved * 10_000) / totalDecisions
            : 0;
        successRateBps = totalApproved > 0
            ? (totalExecutionSuccesses * 10_000) / totalApproved
            : 0;
    }

    /**
     * @notice Confidence score distribution histogram.
     *         Returns counts for each 10-point bucket: [0-9, 10-19, ..., 90-100].
     */
    function confidenceHistogram() external view returns (uint256[10] memory) {
        return _confidenceHistogram;
    }

    /**
     * @notice Per-agent performance stats.
     */
    function agentStats(address agent) external view returns (
        uint256 submitted,
        uint256 approved,
        uint256 rejected,
        uint256 successes,
        uint256 failures,
        uint256 successRateBps
    ) {
        AgentStats storage s = _agentStats[agent];
        submitted  = s.submitted;
        approved   = s.approved;
        rejected   = s.rejected;
        successes  = s.successes;
        failures   = s.failures;
        successRateBps = s.approved > 0
            ? (s.successes * 10_000) / s.approved
            : 0;
    }

    /**
     * @notice Average confidence score of all approved decisions.
     *         Useful for model drift detection.
     */
    function averageApprovedConfidence() external view returns (uint256 avg) {
        if (totalApproved == 0) return 0;
        uint256 total = 0;
        uint256 counted = 0;
        // Walk recent history buffer for approved decisions
        for (uint256 i = 0; i < HISTORY_SIZE; i++) {
            uint256 id = _recentDecisionIds[i];
            if (id == 0) continue;
            DecisionRecord storage r = _decisions[id];
            if (r.status == DecisionStatus.APPROVED) {
                total += r.confidenceScore;
                counted++;
            }
        }
        avg = counted > 0 ? total / counted : 0;
    }

    /**
     * @notice Seconds until `msg.sender` (AI agent) can submit again.
     */
    function agentCooldownRemaining(address agent) external view returns (uint256) {
        uint256 next = lastSubmissionTimestamp[agent] + submissionCooldown;
        return block.timestamp >= next ? 0 : next - block.timestamp;
    }

    /**
     * @notice Full status snapshot for dashboards.
     */
    function systemStatus() external view returns (
        bool   _paused,
        bool   _aiEnabled,
        uint256 _pendingDecisionId,
        uint256 _totalDecisions,
        uint256 _minConfidenceScore,
        uint256 _submissionCooldown,
        address _priceController,
        address _oracle
    ) {
        _paused             = paused;
        _aiEnabled          = aiEnabled;
        _pendingDecisionId  = pendingDecisionId;
        _totalDecisions     = totalDecisions;
        _minConfidenceScore = minConfidenceScore;
        _submissionCooldown = submissionCooldown;
        _priceController    = address(priceController);
        _oracle             = address(oracle);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  ADMIN — CONFIGURATION
    // ══════════════════════════════════════════════════════════════════════════

    function setMinConfidenceScore(uint256 score) external onlyRole(ADMIN_ROLE) {
        require(score <= 100, "AIController: score > 100");
        emit ConfigUpdated("minConfidenceScore", minConfidenceScore, score);
        minConfidenceScore = score;
    }

    function setSubmissionCooldown(uint256 cooldown) external onlyRole(ADMIN_ROLE) {
        emit ConfigUpdated("submissionCooldown", submissionCooldown, cooldown);
        submissionCooldown = cooldown;
    }

    function setRecommendationTTL(uint256 ttl) external onlyRole(ADMIN_ROLE) {
        require(ttl > 0, "AIController: zero TTL");
        emit ConfigUpdated("recommendationTTL", recommendationTTL, ttl);
        recommendationTTL = ttl;
    }

    function setMaxReasoningLength(uint256 length) external onlyRole(ADMIN_ROLE) {
        emit ConfigUpdated("maxReasoningLength", maxReasoningLength, length);
        maxReasoningLength = length;
    }

    function setPriceController(address addr) external onlyRole(ADMIN_ROLE) {
        require(addr != address(0), "AIController: zero address");
        emit ContractUpdated("priceController", address(priceController), addr);
        priceController = IPriceController(addr);
    }

    function setOracle(address addr) external onlyRole(ADMIN_ROLE) {
        require(addr != address(0), "AIController: zero address");
        emit ContractUpdated("oracle", address(oracle), addr);
        oracle = IOracle(addr);
    }

    function setAIEnabled(bool enabled) external onlyRole(ADMIN_ROLE) {
        aiEnabled = enabled;
        emit AIEnabledChanged(enabled, msg.sender);
    }

    // ── Role management ───────────────────────────────────────────────────────

    function grantRole(bytes32 role, address account) external onlyRole(ADMIN_ROLE) {
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(ADMIN_ROLE) {
        require(
            !(role == ADMIN_ROLE && account == msg.sender),
            "AIController: cannot revoke own admin"
        );
        _roles[role][account] = false;
        emit RoleRevoked(role, account);
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    // ── Emergency pause ───────────────────────────────────────────────────────

    function pause() external onlyRole(ADMIN_ROLE) {
        require(!paused, "AIController: already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        require(paused, "AIController: not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  INTERNAL
    // ══════════════════════════════════════════════════════════════════════════

    function _executeDecision(uint256 decisionId) internal {
        DecisionRecord storage rec = _decisions[decisionId];

        bool success = _callStabilize();

        rec.executedAt      = block.timestamp;
        rec.executionSuccess = success;

        if (success) {
            rec.status = DecisionStatus.APPROVED; // remains APPROVED
            totalExecutionSuccesses++;
            _agentStats[rec.aiAgent].successes++;
        } else {
            totalExecutionFailures++;
            _agentStats[rec.aiAgent].failures++;
        }

        pendingDecisionId = 0;
        emit DecisionExecuted(decisionId, success, block.timestamp);
    }

    /**
     * @dev Calls priceController.stabilize() and catches reverts gracefully.
     *      Returns true on success, false on revert.
     */
    function _callStabilize() internal returns (bool success) {
        try priceController.stabilize() {
            success = true;
        } catch {
            success = false;
        }
    }

    function _rejectDecision(uint256 decisionId, string memory reason) internal {
        DecisionRecord storage rec = _decisions[decisionId];
        rec.status          = DecisionStatus.REJECTED;
        rec.rejectionReason = reason;
        totalRejected++;
        _agentStats[rec.aiAgent].rejected++;

        emit DecisionRejected(
            decisionId,
            rec.recommendedAction,
            rec.confidenceScore,
            reason,
            block.timestamp
        );
    }

    function _expireStaleDecision() internal {
        if (pendingDecisionId == 0) return;
        DecisionRecord storage rec = _decisions[pendingDecisionId];
        if (
            rec.status == DecisionStatus.APPROVED &&
            block.timestamp > rec.submittedAt + recommendationTTL
        ) {
            rec.status          = DecisionStatus.EXPIRED;
            rec.rejectionReason = "TTL elapsed";
            totalExpired++;
            emit DecisionExpired(pendingDecisionId, block.timestamp);
            pendingDecisionId = 0;
        }
    }

    function _grantRole(bytes32 role, address account) internal {
        _roles[role][account] = true;
        emit RoleGranted(role, account);
    }
}
