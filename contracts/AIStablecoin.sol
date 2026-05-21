// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title AIStablecoin
 * @notice ERC-20 stablecoin with mint/burn/rebase mechanics.
 *         Designed to be controlled by PriceController and AIController (Phases 3-4).
 *
 * Access roles:
 *  - ADMIN_ROLE        : contract owner — manages roles, emergency pause
 *  - MINTER_ROLE       : PriceController — mints new supply
 *  - BURNER_ROLE       : PriceController — burns circulating supply
 *  - REBASE_ROLE       : PriceController — executes proportional rebases
 *
 * Deployment target: Base Sepolia testnet
 * Faucet: https://www.alchemy.com/faucets/base-sepolia
 */

interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract AIStablecoin is IERC20 {

    // ── Token metadata ────────────────────────────────────────────────────────
    string public constant name     = unicode"A\u0336rithmic";
    string public constant symbol   = unicode"USDA\u0336";
    uint8  public constant decimals = 6;

    // ── Supply caps ───────────────────────────────────────────────────────────
    uint256 public constant MAX_SUPPLY          = 1_000_000_000 * 1e6;
    uint256 public constant MAX_REBASE_PERCENT  = 10;

    // ── Roles ─────────────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE  = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant REBASE_ROLE = keccak256("REBASE_ROLE");

    mapping(bytes32 => mapping(address => bool)) private _roles;

    // ── ERC-20 state ──────────────────────────────────────────────────────────
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ── Pause ─────────────────────────────────────────────────────────────────
    bool public paused;

    // ── Rebase tracking ───────────────────────────────────────────────────────
    uint256 public lastRebaseTimestamp;
    uint256 public rebaseCooldown = 1 hours;
    uint256 public totalRebasesExecuted;

    // ── Events ────────────────────────────────────────────────────────────────
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event Mint(address indexed to, uint256 amount);
    event Burn(address indexed from, uint256 amount);
    event Rebase(uint256 supplyBefore, uint256 supplyAfter, int256 adjustmentPercent, uint256 timestamp);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event RebaseCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);

    // ── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "AIStablecoin: caller lacks role");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "AIStablecoin: contract is paused");
        _;
    }

    modifier whenPaused() {
        require(paused, "AIStablecoin: contract is not paused");
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(address admin, uint256 initialSupply) {
        require(admin != address(0), "AIStablecoin: zero admin address");
        _grantRole(ADMIN_ROLE, admin);
        if (initialSupply > 0) {
            require(initialSupply <= MAX_SUPPLY, "AIStablecoin: exceeds max supply");
            _mint(admin, initialSupply);
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  ERC-20 CORE
    // ══════════════════════════════════════════════════════════════════════════

    function totalSupply() external view override returns (uint256) { return _totalSupply; }

    function balanceOf(address account) external view override returns (uint256) { return _balances[account]; }

    function transfer(address to, uint256 amount) external override whenNotPaused returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override whenNotPaused returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override whenNotPaused returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  MINT / BURN
    // ══════════════════════════════════════════════════════════════════════════

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) whenNotPaused {
        require(to != address(0), "AIStablecoin: mint to zero address");
        require(_totalSupply + amount <= MAX_SUPPLY, "AIStablecoin: exceeds max supply");
        _mint(to, amount);
        emit Mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) whenNotPaused {
        require(from != address(0), "AIStablecoin: burn from zero address");
        require(_balances[from] >= amount, "AIStablecoin: burn exceeds balance");
        _burn(from, amount);
        emit Burn(from, amount);
    }

    function burnOwn(uint256 amount) external whenNotPaused {
        require(_balances[msg.sender] >= amount, "AIStablecoin: burn exceeds balance");
        _burn(msg.sender, amount);
        emit Burn(msg.sender, amount);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  REBASE
    // ══════════════════════════════════════════════════════════════════════════

    function rebase(int256 adjustmentBps) external onlyRole(REBASE_ROLE) whenNotPaused {
        require(
            block.timestamp >= lastRebaseTimestamp + rebaseCooldown,
            "AIStablecoin: rebase cooldown active"
        );
        require(adjustmentBps != 0, "AIStablecoin: zero adjustment");

        int256 maxBps = int256(MAX_REBASE_PERCENT * 100);
        require(adjustmentBps >= -maxBps && adjustmentBps <= maxBps, "AIStablecoin: adjustment exceeds cap");

        uint256 supplyBefore = _totalSupply;
        uint256 newSupply;

        if (adjustmentBps > 0) {
            newSupply = (supplyBefore * (10_000 + uint256(adjustmentBps))) / 10_000;
            require(newSupply <= MAX_SUPPLY, "AIStablecoin: rebase exceeds max supply");
        } else {
            uint256 absBps = uint256(-adjustmentBps);
            newSupply = (supplyBefore * (10_000 - absBps)) / 10_000;
            require(newSupply > 0, "AIStablecoin: rebase would zero supply");
        }

        _totalSupply = newSupply;
        lastRebaseTimestamp = block.timestamp;
        totalRebasesExecuted++;

        emit Rebase(supplyBefore, newSupply, adjustmentBps, block.timestamp);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  EMERGENCY PAUSE
    // ══════════════════════════════════════════════════════════════════════════

    function pause() external onlyRole(ADMIN_ROLE) whenNotPaused { paused = true; emit Paused(msg.sender); }
    function unpause() external onlyRole(ADMIN_ROLE) whenPaused { paused = false; emit Unpaused(msg.sender); }

    // ══════════════════════════════════════════════════════════════════════════
    //  ROLE MANAGEMENT
    // ══════════════════════════════════════════════════════════════════════════

    function grantRole(bytes32 role, address account) external onlyRole(ADMIN_ROLE) { _grantRole(role, account); }

    function revokeRole(bytes32 role, address account) external onlyRole(ADMIN_ROLE) {
        require(!(role == ADMIN_ROLE && account == msg.sender), "AIStablecoin: cannot revoke own admin");
        _roles[role][account] = false;
        emit RoleRevoked(role, account, msg.sender);
    }

    function hasRole(bytes32 role, address account) external view returns (bool) { return _roles[role][account]; }

    function setRebaseCooldown(uint256 newCooldown) external onlyRole(ADMIN_ROLE) {
        emit RebaseCooldownUpdated(rebaseCooldown, newCooldown);
        rebaseCooldown = newCooldown;
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  VIEW HELPERS
    // ══════════════════════════════════════════════════════════════════════════

    function circulatingSupply() external view returns (uint256) { return _totalSupply; }
    function remainingMintableSupply() external view returns (uint256) { return MAX_SUPPLY - _totalSupply; }

    // ══════════════════════════════════════════════════════════════════════════
    //  INTERNAL
    // ══════════════════════════════════════════════════════════════════════════

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "AIStablecoin: transfer from zero");
        require(to != address(0), "AIStablecoin: transfer to zero");
        require(_balances[from] >= amount, "AIStablecoin: insufficient balance");
        unchecked { _balances[from] -= amount; _balances[to] += amount; }
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        _balances[from] -= amount;
        _totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "AIStablecoin: approve from zero");
        require(spender != address(0), "AIStablecoin: approve to zero");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 current = _allowances[owner][spender];
        if (current != type(uint256).max) {
            require(current >= amount, "AIStablecoin: insufficient allowance");
            unchecked { _allowances[owner][spender] = current - amount; }
        }
    }

    function _grantRole(bytes32 role, address account) internal {
        _roles[role][account] = true;
        emit RoleGranted(role, account, msg.sender);
    }
}
