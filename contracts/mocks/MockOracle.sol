// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MockOracle
 * @notice Test double for OracleReceiver.
 *         Lets tests set any price and deviation freely.
 */
contract MockOracle {
    uint256 public price      = 5_000_000;
    int256  public deviation  = 0;
    uint256 public constant PEG_PRICE = 5_000_000;
    bool    public shouldRevert;

    function setPrice(uint256 _price, int256 _deviation) external {
        price     = _price;
        deviation = _deviation;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function latestValidatedPrice() external view returns (uint256, uint256) {
        require(!shouldRevert, "OracleReceiver: price is stale");
        return (price, block.timestamp);
    }

    function deviationFromPeg() external view returns (int256) {
        return deviation;
    }
}
