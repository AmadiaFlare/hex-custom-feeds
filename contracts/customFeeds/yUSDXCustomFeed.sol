// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { IICustomFeed } from "@flarenetwork/flare-periphery-contracts/coston2/customFeeds/interfaces/IICustomFeed.sol";

/**
 * @title IClearpoolVault
 * @notice Interface for Clearpool vault's getRate function
 */
interface IClearpoolVault {
    /**
     * @notice Returns the current exchange rate of the vault's LP token
     * @dev Rate is scaled by 1e18 (18 decimals)
     * @return The exchange rate representing NAV per share
     */
    function getRate() external view returns (uint256);
}

/**
 * @title yUSDXCustomFeed
 * @notice FTSO Custom Feed for yUSDX/USD pricing based on Clearpool X-Pool vault NAV
 * @dev yUSDX is the LP token from Clearpool's X-Pool vault. Its value floats based on
 *      the NAV of the delta-neutral basis trading strategy. The rate is updated daily at 08:30 UTC.
 *
 *      X-Pool vault address: 0xd006185B765cA59F29FDd0c57526309726b69d99
 *      Reference: https://vaults.clearpool.finance/vault?address=0x6b9e9d89e0e9fd93eb95d8c7715be2a8de64af07
 */
contract yUSDXCustomFeed is IICustomFeed {
    // --- State Variables ---

    bytes21 public immutable feedIdentifier;
    int8 public constant DECIMALS = 6; // USD price with 6 decimal places

    /// @notice The Clearpool X-Pool vault contract address
    address public immutable clearpoolVault;

    /// @notice The last cached rate from the vault (for gas optimization)
    uint256 public cachedRate;

    /// @notice Timestamp of the last rate update
    uint64 public lastUpdateTimestamp;

    // --- Events ---
    event RateUpdated(uint256 rate, uint64 timestamp);

    // --- Errors ---
    error InvalidFeedId();
    error InvalidVaultAddress();
    error VaultCallFailed();

    // --- Constructor ---

    /**
     * @param _feedId The unique feed identifier (bytes21, starting with 0x21)
     * @param _clearpoolVault The address of the Clearpool X-Pool vault
     */
    constructor(bytes21 _feedId, address _clearpoolVault) {
        if (_feedId == bytes21(0)) revert InvalidFeedId();
        if (_clearpoolVault == address(0)) revert InvalidVaultAddress();

        feedIdentifier = _feedId;
        clearpoolVault = _clearpoolVault;
    }

    // --- Rate Update Logic ---

    /**
     * @notice Fetches and caches the current rate from the Clearpool vault
     * @dev Anyone can call this to update the cached rate
     * @return rate The current rate from the vault
     */
    function updateRate() external returns (uint256 rate) {
        rate = IClearpoolVault(clearpoolVault).getRate();
        cachedRate = rate;
        lastUpdateTimestamp = uint64(block.timestamp);
        emit RateUpdated(rate, lastUpdateTimestamp);
    }

    /**
     * @notice Gets the current rate directly from the Clearpool vault (no caching)
     * @return rate The live rate from the vault
     */
    function getLiveRate() external view returns (uint256 rate) {
        rate = IClearpoolVault(clearpoolVault).getRate();
    }

    // --- Custom Feed Interface (IICustomFeed) Implementation ---

    /**
     * @notice Returns the current yUSDX/USD price based on the vault's NAV rate
     * @dev The rate from Clearpool is in 18 decimals (1e18 = $1.00)
     *      We convert to 6 decimals for the feed (1e6 = $1.00)
     * @return _value The price value scaled by 10^DECIMALS
     * @return _decimals The number of decimals (6)
     * @return _timestamp The timestamp of the last rate update
     */
    function getCurrentFeed() external payable override returns (uint256 _value, int8 _decimals, uint64 _timestamp) {
        // Get live rate from vault (18 decimals)
        uint256 rate = IClearpoolVault(clearpoolVault).getRate();

        // Convert from 18 decimals to 6 decimals
        // rate is in 1e18, we want 1e6, so divide by 1e12
        _value = rate / 1e12;
        _decimals = DECIMALS;
        _timestamp = uint64(block.timestamp);
    }

    /**
     * @notice Returns the feed identifier
     * @return _feedId The bytes21 feed identifier
     */
    function feedId() external view override returns (bytes21 _feedId) {
        _feedId = feedIdentifier;
    }

    /**
     * @notice Returns the cached feed data (gas-efficient view)
     * @dev Uses cached rate instead of making external call
     * @return _value The cached price value
     * @return _decimals The number of decimals
     * @return _timestamp The timestamp of the cached value
     */
    function getFeedDataView() external view returns (uint256 _value, int8 _decimals, uint64 _timestamp) {
        // Use cached rate (18 decimals) and convert to 6 decimals
        _value = cachedRate / 1e12;
        _decimals = DECIMALS;
        _timestamp = lastUpdateTimestamp;
    }

    /**
     * @notice Returns the fee for calling getCurrentFeed (always 0)
     * @return _fee The fee amount (0)
     */
    function calculateFee() external pure override returns (uint256 _fee) {
        return 0;
    }

    /**
     * @notice Reads the current price value
     * @return value The price scaled by 10^DECIMALS
     */
    function read() public view returns (uint256 value) {
        uint256 rate = IClearpoolVault(clearpoolVault).getRate();
        value = rate / 1e12; // Convert 18 decimals to 6 decimals
    }

    /**
     * @notice Returns the number of decimals for the feed value
     * @return The decimal count (6)
     */
    function decimals() external pure returns (int8) {
        return DECIMALS;
    }
}
