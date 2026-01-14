// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title MockERC4626Vault
 * @notice Mock ERC4626 vault for testing cUSDX custom feed on testnets
 * @dev Simulates the Clearpool T-Pool vault's ERC4626 interface
 */
contract MockERC4626Vault {
    uint256 public rate;
    uint256 public supply;
    address public owner;
    uint8 public constant decimals = 18;

    event RateSet(uint256 newRate);

    constructor(uint256 _initialRate) {
        owner = msg.sender;
        rate = _initialRate;
        supply = 1000000 * 1e18; // 1M tokens initial supply
    }

    /**
     * @notice Returns the amount of assets that would be obtained for a given amount of shares
     * @dev ERC4626 standard function
     * @param shares The amount of shares to convert
     * @return assets The equivalent amount of underlying assets
     */
    function convertToAssets(uint256 shares) external view returns (uint256 assets) {
        // rate is stored as assets per 1e18 shares
        // For 1:1 peg, rate = 1e18 means 1 share = 1 asset
        assets = (shares * rate) / 1e18;
    }

    /**
     * @notice Returns the total supply of vault shares
     * @return The total supply
     */
    function totalSupply() external view returns (uint256) {
        return supply;
    }

    /**
     * @notice Sets a new rate (for testing purposes)
     * @param _newRate The new rate to set (18 decimals, 1e18 = 1:1)
     */
    function setRate(uint256 _newRate) external {
        require(msg.sender == owner, "Only owner");
        rate = _newRate;
        emit RateSet(_newRate);
    }

    /**
     * @notice Sets the total supply (for testing purposes)
     * @param _newSupply The new supply to set
     */
    function setTotalSupply(uint256 _newSupply) external {
        require(msg.sender == owner, "Only owner");
        supply = _newSupply;
    }
}
