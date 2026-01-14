// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title MockClearpoolVault
 * @notice Mock contract for testing yUSDX custom feed on testnets
 * @dev Simulates the Clearpool X-Pool vault's getRate() function
 */
contract MockClearpoolVault {
    uint256 public rate;
    address public owner;

    event RateSet(uint256 newRate);

    constructor(uint256 _initialRate) {
        owner = msg.sender;
        rate = _initialRate;
    }

    /**
     * @notice Returns the current exchange rate (NAV per share)
     * @dev Rate is in 18 decimals (1e18 = $1.00)
     * @return The current rate
     */
    function getRate() external view returns (uint256) {
        return rate;
    }

    /**
     * @notice Sets a new rate (for testing purposes)
     * @param _newRate The new rate to set (18 decimals)
     */
    function setRate(uint256 _newRate) external {
        require(msg.sender == owner, "Only owner");
        rate = _newRate;
        emit RateSet(_newRate);
    }
}
