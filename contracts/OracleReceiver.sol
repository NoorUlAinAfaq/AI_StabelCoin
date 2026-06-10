// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title OracleReceiver
 * @notice Receives price submissions from authorized off-chain oracle nodes,
 *         aggregates them via median, validates staleness and outliers,
 *         and exposes the final price for PriceController (Phase 3).
 *
 * Target peg: $5.00  (stored as 5_000_000 with PRICE_DECIMALS = 6)
 *
 */

contract OracleReceiver {
    // ── Price representation ───────────────────────────────────────────────────
    uint8 public constant PRICE_DECIMALS = 6;
    uint256 public constant PEG_PRICE = 5_000_000; // $5.00

    // ── Validation thresholds ─────────────────────────────────────────────────
    uint256 public maxDeviationBps = 3000;
    uint256 public stalenessThreshold = 1 hours;
    uint256 public minQuorum = 2;
    uint256 public maxPriceAge = 2 hours;

    // ── Roles ─────────────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant CONSUMER_ROLE = keccak256("CONSUMER_ROLE");

    mapping(bytes32 => mapping(address => bool)) private _roles;
    address[] private _oracleNodes;

    // ── Round state ───────────────────────────────────────────────────────────

    struct Submission {
        uint256 price;
        uint256 timestamp;
        bool submitted;
    }

    struct Round {
        uint256 roundId;
        uint256 startedAt;
        uint256 finalizedAt;
        uint256 medianPrice;
        uint256 submissionCount;
        bool finalized;
        address[] submitters;
    }

    uint256 public currentRoundId;
    mapping(uint256 => Round) private _rounds;
    mapping(uint256 => mapping(address => Submission)) private _submissions;

    // ── Latest validated price ────────────────────────────────────────────────
    uint256 public latestPrice;
    uint256 public latestPriceTimestamp;
    uint256 public latestRoundId;

    // ── Historical ring buffer (last 24 rounds) ───────────────────────────────
    uint256 public constant HISTORY_SIZE = 24;
    uint256[HISTORY_SIZE] private _priceHistory;
    uint256[HISTORY_SIZE] private _priceHistoryTimestamps;
    uint256 private _historyIndex;

    // ── Pause ─────────────────────────────────────────────────────────────────
    bool public paused;

    // ── Events ────────────────────────────────────────────────────────────────
    event RoleGranted(bytes32 indexed role, address indexed account);
    event RoleRevoked(bytes32 indexed role, address indexed account);
    event OracleNodeAdded(address indexed node);
    event OracleNodeRemoved(address indexed node);
    event RoundStarted(uint256 indexed roundId, uint256 timestamp);
    event PriceSubmitted(
        uint256 indexed roundId,
        address indexed oracle,
        uint256 price,
        uint256 timestamp
    );
    event SubmissionRejected(
        uint256 indexed roundId,
        address indexed oracle,
        uint256 price,
        string reason
    );
    event RoundFinalized(
        uint256 indexed roundId,
        uint256 medianPrice,
        uint256 submissionCount,
        uint256 timestamp
    );
    event PriceUpdated(uint256 oldPrice, uint256 newPrice, uint256 timestamp);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event ConfigUpdated(string param, uint256 oldValue, uint256 newValue);

    // ── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "OracleReceiver: caller lacks role");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "OracleReceiver: contract is paused");
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(
        address admin,
        address[] memory initialOracles,
        uint256 quorum
    ) {
        require(admin != address(0), "OracleReceiver: zero admin");
        require(quorum > 0, "OracleReceiver: zero quorum");
        require(
            initialOracles.length >= quorum,
            "OracleReceiver: fewer oracles than quorum"
        );

        _grantRole(ADMIN_ROLE, admin);
        for (uint256 i = 0; i < initialOracles.length; i++) {
            _addOracleNode(initialOracles[i]);
        }
        minQuorum = quorum;
        _startNewRound();
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  ORACLE SUBMISSION
    // ══════════════════════════════════════════════════════════════════════════

    function submitPrice(
        uint256 price
    ) external onlyRole(ORACLE_ROLE) whenNotPaused {
        require(price > 0, "OracleReceiver: zero price");

        uint256 roundId = currentRoundId;
        Round storage round = _rounds[roundId];

        if (_submissions[roundId][msg.sender].submitted) {
            emit SubmissionRejected(
                roundId,
                msg.sender,
                price,
                "already submitted"
            );
            return;
        }

        _submissions[roundId][msg.sender] = Submission({
            price: price,
            timestamp: block.timestamp,
            submitted: true
        });
        round.submitters.push(msg.sender);
        round.submissionCount++;

        emit PriceSubmitted(roundId, msg.sender, price, block.timestamp);

        if (round.submissionCount >= minQuorum) {
            _finalizeRound(roundId);
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  CONSUMER READ INTERFACE
    // ══════════════════════════════════════════════════════════════════════════

    function latestValidatedPrice()
        external
        view
        returns (uint256 price, uint256 timestamp)
    {
        require(latestPriceTimestamp > 0, "OracleReceiver: no price yet");
        require(
            block.timestamp - latestPriceTimestamp <= maxPriceAge,
            "OracleReceiver: price is stale"
        );
        return (latestPrice, latestPriceTimestamp);
    }

    function latestPriceUnchecked()
        external
        view
        returns (uint256 price, uint256 timestamp, uint256 roundId)
    {
        return (latestPrice, latestPriceTimestamp, latestRoundId);
    }

    function deviationFromPeg() external view returns (int256 bps) {
        require(latestPriceTimestamp > 0, "OracleReceiver: no price yet");
        int256 diff = int256(latestPrice) - int256(PEG_PRICE);
        bps = (diff * 10_000) / int256(PEG_PRICE);
    }

    function priceHistory()
        external
        view
        returns (
            uint256[HISTORY_SIZE] memory prices,
            uint256[HISTORY_SIZE] memory timestamps
        )
    {
        return (_priceHistory, _priceHistoryTimestamps);
    }

    function getRound(
        uint256 roundId
    )
        external
        view
        returns (
            uint256 startedAt,
            uint256 finalizedAt,
            uint256 medianPrice,
            uint256 submissionCount,
            bool finalized
        )
    {
        Round storage r = _rounds[roundId];
        return (
            r.startedAt,
            r.finalizedAt,
            r.medianPrice,
            r.submissionCount,
            r.finalized
        );
    }

    function getSubmission(
        uint256 roundId,
        address oracle
    ) external view returns (uint256 price, uint256 timestamp, bool submitted) {
        Submission storage s = _submissions[roundId][oracle];
        return (s.price, s.timestamp, s.submitted);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  ADMIN
    // ══════════════════════════════════════════════════════════════════════════

    function addOracleNode(address node) external onlyRole(ADMIN_ROLE) {
        _addOracleNode(node);
    }

    function removeOracleNode(address node) external onlyRole(ADMIN_ROLE) {
        require(_roles[ORACLE_ROLE][node], "OracleReceiver: not an oracle");
        require(
            _oracleNodes.length - 1 >= minQuorum,
            "OracleReceiver: would fall below quorum"
        );
        _roles[ORACLE_ROLE][node] = false;
        for (uint256 i = 0; i < _oracleNodes.length; i++) {
            if (_oracleNodes[i] == node) {
                _oracleNodes[i] = _oracleNodes[_oracleNodes.length - 1];
                _oracleNodes.pop();
                break;
            }
        }
        emit OracleNodeRemoved(node);
        emit RoleRevoked(ORACLE_ROLE, node);
    }

    function oracleNodes() external view returns (address[] memory) {
        return _oracleNodes;
    }

    function setMinQuorum(uint256 quorum) external onlyRole(ADMIN_ROLE) {
        require(
            quorum > 0 && quorum <= _oracleNodes.length,
            "OracleReceiver: invalid quorum"
        );
        emit ConfigUpdated("minQuorum", minQuorum, quorum);
        minQuorum = quorum;
    }

    function setMaxDeviationBps(uint256 bps) external onlyRole(ADMIN_ROLE) {
        require(bps > 0 && bps <= 10_000, "OracleReceiver: invalid bps");
        emit ConfigUpdated("maxDeviationBps", maxDeviationBps, bps);
        maxDeviationBps = bps;
    }

    function setStalenessThreshold(
        uint256 threshold
    ) external onlyRole(ADMIN_ROLE) {
        emit ConfigUpdated("stalenessThreshold", stalenessThreshold, threshold);
        stalenessThreshold = threshold;
    }

    function setMaxPriceAge(uint256 age) external onlyRole(ADMIN_ROLE) {
        emit ConfigUpdated("maxPriceAge", maxPriceAge, age);
        maxPriceAge = age;
    }

    function forceNewRound() external onlyRole(ADMIN_ROLE) {
        Round storage r = _rounds[currentRoundId];
        require(
            !r.finalized || block.timestamp > r.startedAt + stalenessThreshold,
            "OracleReceiver: current round still active"
        );
        _startNewRound();
    }

    function grantRole(
        bytes32 role,
        address account
    ) external onlyRole(ADMIN_ROLE) {
        _grantRole(role, account);
    }

    function revokeRole(
        bytes32 role,
        address account
    ) external onlyRole(ADMIN_ROLE) {
        require(
            !(role == ADMIN_ROLE && account == msg.sender),
            "OracleReceiver: cannot revoke own admin"
        );
        _roles[role][account] = false;
        emit RoleRevoked(role, account);
    }

    function hasRole(
        bytes32 role,
        address account
    ) external view returns (bool) {
        return _roles[role][account];
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        require(!paused);
        paused = true;
        emit Paused(msg.sender);
    }
    function unpause() external onlyRole(ADMIN_ROLE) {
        require(paused);
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  INTERNAL
    // ══════════════════════════════════════════════════════════════════════════

    function _startNewRound() internal {
        currentRoundId++;
        Round storage r = _rounds[currentRoundId];
        r.roundId = currentRoundId;
        r.startedAt = block.timestamp;
        r.finalized = false;
        emit RoundStarted(currentRoundId, block.timestamp);
    }

    function _finalizeRound(uint256 roundId) internal {
        Round storage round = _rounds[roundId];
        address[] memory submitters = round.submitters;
        uint256[] memory prices = new uint256[](submitters.length);
        for (uint256 i = 0; i < submitters.length; i++) {
            prices[i] = _submissions[roundId][submitters[i]].price;
        }

        uint256 median = _median(prices);

        uint256 validCount = 0;
        uint256[] memory validPrices = new uint256[](prices.length);
        for (uint256 i = 0; i < prices.length; i++) {
            uint256 deviation = prices[i] > median
                ? ((prices[i] - median) * 10_000) / median
                : ((median - prices[i]) * 10_000) / median;

            if (deviation <= maxDeviationBps) {
                validPrices[validCount] = prices[i];
                validCount++;
            } else {
                emit SubmissionRejected(
                    roundId,
                    submitters[i],
                    prices[i],
                    "outlier"
                );
            }
        }

        if (validCount < minQuorum) {
            emit SubmissionRejected(
                roundId,
                address(0),
                0,
                "insufficient valid submissions after outlier filter"
            );
            _startNewRound();
            return;
        }

        uint256[] memory cleanPrices = new uint256[](validCount);
        for (uint256 i = 0; i < validCount; i++) {
            cleanPrices[i] = validPrices[i];
        }
        uint256 finalMedian = _median(cleanPrices);

        round.medianPrice = finalMedian;
        round.finalizedAt = block.timestamp;
        round.finalized = true;

        uint256 oldPrice = latestPrice;
        latestPrice = finalMedian;
        latestPriceTimestamp = block.timestamp;
        latestRoundId = roundId;

        _priceHistory[_historyIndex] = finalMedian;
        _priceHistoryTimestamps[_historyIndex] = block.timestamp;
        _historyIndex = (_historyIndex + 1) % HISTORY_SIZE;

        emit RoundFinalized(roundId, finalMedian, validCount, block.timestamp);
        emit PriceUpdated(oldPrice, finalMedian, block.timestamp);

        _startNewRound();
    }

    function _median(uint256[] memory arr) internal pure returns (uint256) {
        uint256 n = arr.length;
        require(n > 0, "OracleReceiver: empty array");
        for (uint256 i = 1; i < n; i++) {
            uint256 key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > key) {
                arr[j] = arr[j - 1];
                j--;
            }
            arr[j] = key;
        }
        return n % 2 == 1 ? arr[n / 2] : (arr[n / 2 - 1] + arr[n / 2]) / 2;
    }

    function _addOracleNode(address node) internal {
        require(node != address(0), "OracleReceiver: zero oracle address");
        //require(!_roles[ORACLE_ROLE][node], "OracleReceiver: already an oracle");
        _roles[ORACLE_ROLE][node] = true;
        _oracleNodes.push(node);
        emit OracleNodeAdded(node);
        emit RoleGranted(ORACLE_ROLE, node);
    }

    function _grantRole(bytes32 role, address account) internal {
        _roles[role][account] = true;
        emit RoleGranted(role, account);
    }
}
