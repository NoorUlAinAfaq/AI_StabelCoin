// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MockToken
 * @notice Test double for AIStablecoin.
 *         Records every mint/burn/rebase call for assertion in tests.
 */
contract MockToken {
    uint256 public supply = 1_000_000 * 1e18;
    mapping(address => uint256) public balances;

    // Call tracking
    bool    public mintCalled;
    bool    public burnCalled;
    bool    public rebaseCalled;
    uint256 public lastMintAmount;
    uint256 public lastBurnAmount;
    int256  public lastRebaseBps;
    address public lastMintTo;

    // Fault injection
    bool public shouldRevertBurn;

    constructor() {
        balances[address(this)] = supply;
    }

    // ── Test helpers ──────────────────────────────────────────────────────────

    function setTreasuryBalance(address _treasury, uint256 amount) external {
        balances[_treasury] = amount;
    }

    function setShouldRevertBurn(bool v) external {
        shouldRevertBurn = v;
    }

    function reset() external {
        mintCalled    = false;
        burnCalled    = false;
        rebaseCalled  = false;
        lastMintAmount = 0;
        lastBurnAmount = 0;
        lastRebaseBps  = 0;
        lastMintTo     = address(0);
    }

    // ── IStablecoin interface ─────────────────────────────────────────────────

    function totalSupply() external view returns (uint256) {
        return supply;
    }

    function balanceOf(address a) external view returns (uint256) {
        return balances[a];
    }

    function mint(address to, uint256 amount) external {
        mintCalled     = true;
        lastMintAmount = amount;
        lastMintTo     = to;
        supply         += amount;
        balances[to]   += amount;
    }

    function burn(address from, uint256 amount) external {
        require(!shouldRevertBurn, "MockToken: burn reverted");
        burnCalled      = true;
        lastBurnAmount  = amount;
        supply          -= amount;
        balances[from]  -= amount;
    }

    function rebase(int256 bps) external {
        rebaseCalled  = true;
        lastRebaseBps = bps;
        if (bps > 0) {
            supply = (supply * (10_000 + uint256(bps))) / 10_000;
        } else {
            supply = (supply * (10_000 - uint256(-bps))) / 10_000;
        }
    }
}
