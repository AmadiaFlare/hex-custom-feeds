// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { IICustomFeed } from "@flarenetwork/flare-periphery-contracts/coston2/customFeeds/interfaces/IICustomFeed.sol";
import { FtsoV2Interface } from "@flarenetwork/flare-periphery-contracts/coston2/FtsoV2Interface.sol";
import { ContractRegistry } from "@flarenetwork/flare-periphery-contracts/coston2/ContractRegistry.sol";

// Custom feed for cUSDX/USD pricing based on USDX/USD FTSO feed (1:1 peg)

/**
 * @title IERC20Metadata
 * @notice Minimal interface for ERC20 metadata
 */
interface IERC20Metadata {
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
}

/**
 * @title cUSDXCustomFeed
 * @notice FTSO Custom Feed for cUSDX/USD pricing based on USDX/USD FTSO feed
 * @dev cUSDX is the LP token from Clearpool's T-Pool vault. It maintains a 1:1 peg with USDX
 *      as funds are invested in short-term US Treasuries. Users earn Treasury yield while
 *      holding cUSDX.
 *
 *      Since cUSDX is 1:1 with USDX, this feed derives its price from the USDX/USD FTSO feed.
 *
 *      T-Pool (cUSDX token): 0xfe2907dfa8db6e320cdbf45f0aa888f6135ec4f8
 *      Reference: https://clearpool.finance/lending/tpool
 *      Strategy: https://medium.com/clearpool-finance/usdx-t-pool-is-now-live-on-flare-c2f714c42efd
 */
contract cUSDXCustomFeed is IICustomFeed {
    // --- State Variables ---

    bytes21 public immutable feedIdentifier;
    int8 public constant DECIMALS = 6; // USD price with 6 decimal places

    /// @notice The cUSDX token address (T-Pool LP token)
    address public immutable cUSDXToken;

    /// @notice The USDX/USD feed ID for FTSO lookup
    /// @dev USDX/USD feed ID: 0x01555344582f55534400000000000000000000000000
    bytes21 public immutable usdxFeedId;

    /// @notice The last cached price
    uint256 public cachedPrice;

    /// @notice Timestamp of the last price update
    uint64 public lastUpdateTimestamp;

    // --- Events ---
    event PriceUpdated(uint256 price, uint64 timestamp);

    // --- Errors ---
    error InvalidFeedId();
    error InvalidTokenAddress();

    // --- Constructor ---

    /**
     * @param _feedId The unique feed identifier for cUSDX/USD (bytes21, starting with 0x21)
     * @param _cUSDXToken The address of the cUSDX token (T-Pool)
     * @param _usdxFeedId The FTSO feed ID for USDX/USD
     */
    constructor(bytes21 _feedId, address _cUSDXToken, bytes21 _usdxFeedId) {
        if (_feedId == bytes21(0)) revert InvalidFeedId();
        if (_cUSDXToken == address(0)) revert InvalidTokenAddress();

        feedIdentifier = _feedId;
        cUSDXToken = _cUSDXToken;
        usdxFeedId = _usdxFeedId;
    }

    // --- Internal Helpers ---

    /**
     * @notice Gets the current USDX/USD price from the FTSO
     * @dev This function calls the FTSO which may require a fee for some feeds
     * @return price The USDX price in 6 decimals
     * @return timestamp The timestamp of the price
     */
    function _getUSDXPrice() internal returns (uint256 price, uint64 timestamp) {
        FtsoV2Interface ftsoV2 = ContractRegistry.getFtsoV2();

        (uint256 value, int8 srcDecimals, uint64 updateTimestamp) = ftsoV2.getFeedById(usdxFeedId);

        // Convert to 6 decimals if needed
        if (srcDecimals == DECIMALS) {
            price = value;
        } else if (srcDecimals > DECIMALS) {
            price = value / (10 ** uint8(srcDecimals - DECIMALS));
        } else {
            price = value * (10 ** uint8(DECIMALS - srcDecimals));
        }

        timestamp = updateTimestamp;
    }

    // --- Rate Update Logic ---

    /**
     * @notice Fetches and caches the current USDX price from FTSO
     * @dev Anyone can call this to update the cached price
     * @return price The current USDX/USD price (= cUSDX/USD price due to 1:1 peg)
     */
    function updateRate() external returns (uint256 price) {
        uint64 timestamp;
        (price, timestamp) = _getUSDXPrice();
        cachedPrice = price;
        lastUpdateTimestamp = timestamp;
        emit PriceUpdated(price, timestamp);
    }

    /**
     * @notice Gets the current price directly from FTSO (no caching)
     * @return price The live USDX/USD price
     */
    function getLiveRate() external returns (uint256 price) {
        (price, ) = _getUSDXPrice();
    }

    /**
     * @notice Gets the total supply of cUSDX tokens (market cap reference)
     * @return supply The total supply of cUSDX
     */
    function getTotalSupply() external view returns (uint256 supply) {
        supply = IERC20Metadata(cUSDXToken).totalSupply();
    }

    // --- Custom Feed Interface (IICustomFeed) Implementation ---

    /**
     * @notice Returns the current cUSDX/USD price based on USDX/USD FTSO feed
     * @dev Since cUSDX is 1:1 with USDX, we simply return the USDX/USD price
     * @return _value The price value scaled by 10^DECIMALS
     * @return _decimals The number of decimals (6)
     * @return _timestamp The timestamp of the price
     */
    function getCurrentFeed() external payable override returns (uint256 _value, int8 _decimals, uint64 _timestamp) {
        (_value, _timestamp) = _getUSDXPrice();
        _decimals = DECIMALS;
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
     * @return _value The cached price value
     * @return _decimals The number of decimals
     * @return _timestamp The timestamp of the cached value
     */
    function getFeedDataView() external view returns (uint256 _value, int8 _decimals, uint64 _timestamp) {
        _value = cachedPrice;
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
    function read() public returns (uint256 value) {
        (value, ) = _getUSDXPrice();
    }

    /**
     * @notice Returns the number of decimals for the feed value
     * @return The decimal count (6)
     */
    function decimals() external pure returns (int8) {
        return DECIMALS;
    }
}
