// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MockPriceController
 * @notice Test double for PriceController — used by AIController tests.
 *         Records stabilize() calls and supports fault injection.
 */
contract MockPriceController {
    bool    public stabilizeCalled;
    uint256 public stabilizeCallCount;
    bool    public shouldRevert;
    bool    public isPaused;
    uint256 public cooldown; // 0 means ready

    // Preview return values
    uint8   public previewAction       = 1; // MINT
    uint256 public previewMintBurnAmt  = 1000e18;
    int256  public previewRebaseBps    = 0;
    uint256 public previewPrice        = 5_100_000;
    int256  public previewDeviation    = 200;

    function setShouldRevert(bool v)  external { shouldRevert = v; }
    function setPaused(bool v)        external { isPaused = v; }
    function setCooldown(uint256 v)   external { cooldown = v; }
    function reset()                  external { stabilizeCalled = false; }

    function paused() external view returns (bool) { return isPaused; }
    function cooldownRemaining() external view returns (uint256) { return cooldown; }

    function stabilize() external {
        require(!shouldRevert, "MockPriceController: stabilize reverted");
        stabilizeCalled = true;
        stabilizeCallCount++;
    }

    function previewStabilization() external view returns (
        uint8, uint256, int256, uint256, int256
    ) {
        return (previewAction, previewMintBurnAmt, previewRebaseBps, previewPrice, previewDeviation);
    }
}
