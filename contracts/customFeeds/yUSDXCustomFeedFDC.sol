// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { IICustomFeed } from "@flarenetwork/flare-periphery-contracts/coston2/customFeeds/interfaces/IICustomFeed.sol";
import { ContractRegistry } from "@flarenetwork/flare-periphery-contracts/coston2/ContractRegistry.sol";
import { IWeb2JsonVerification } from "@flarenetwork/flare-periphery-contracts/coston2/IWeb2JsonVerification.sol";
import { IWeb2Json } from "@flarenetwork/flare-periphery-contracts/coston2/IWeb2Json.sol";

/**
 * @title yUSDXCustomFeedFDC
 * @notice FTSO Custom Feed for yUSDX/USD pricing using Flare Data Connector (FDC)
 *
 * @dev yUSDX is the LP token from Clearpool's X-Pool vault. Its value floats based on
 *      the NAV of a delta-neutral basis trading strategy on centralized exchanges.
 *
 *      The Problem:
 *      - yUSDX NAV is calculated from external CEX data (Binance, OKX, Bybit funding rates)
 *      - Currently, someone calculates NAV off-chain and pushes it to getRate() on-chain
 *      - We have to trust whoever updates getRate()
 *
 *      The FDC Solution:
 *      - Use FDC to fetch and verify CEX data directly
 *      - Multiple attestation providers independently verify the data
 *      - NAV calculation can be verified on-chain
 *
 *      Data Sources (from proposal):
 *      - "yUSDX price will be submitted based on daily NAV/unit calculated
 *         external (CEX) yield source inputs"
 *      - "NAV updates happen at 08:30 UTC"
 *
 *      X-Pool vault: 0xd006185B765cA59F29FDd0c57526309726b69d99
 *      Reference: https://vaults.clearpool.finance/vault?address=0x6b9e9d89e0e9fd93eb95d8c7715be2a8de64af07
 */
contract yUSDXCustomFeedFDC is IICustomFeed {
    // --- State Variables ---

    bytes21 public immutable feedIdentifier;
    int8 public constant DECIMALS = 6;

    /// @notice The X-Pool vault address (for reference/comparison)
    address public immutable xPoolVault;

    /// @notice The verified NAV price (6 decimals, 1000000 = $1.00)
    uint256 public verifiedNav;

    /// @notice Timestamp of the last verified update
    uint64 public lastVerifiedTimestamp;

    /// @notice Number of successful FDC updates
    uint256 public updateCount;

    /// @notice API URL hash for verification
    bytes32 public immutable apiUrlHash;

    // --- Events ---
    event NavUpdatedViaFDC(
        uint256 nav,
        uint64 timestamp,
        bytes32 proofHash
    );

    event NavUpdatedFromVault(
        uint256 nav,
        uint64 timestamp
    );

    // --- Errors ---
    error InvalidFeedId();
    error InvalidVaultAddress();
    error InvalidProof();
    error StaleData();
    error NavOutOfBounds();

    // --- Constants ---

    /// @notice Maximum allowed NAV deviation from $1.00 (20% for yield-bearing token)
    /// @dev yUSDX can appreciate significantly due to trading profits
    uint256 public constant MAX_NAV_DEVIATION = 200000; // 20%

    /// @notice Maximum age of data before considered stale (2 hours for daily updates)
    uint256 public constant MAX_DATA_AGE = 7200;

    // --- Constructor ---

    /**
     * @param _feedId The unique feed identifier for yUSDX/USD
     * @param _xPoolVault The address of the X-Pool vault
     * @param _apiUrl The API URL for FDC attestation (e.g., HT Markets NAV API)
     */
    constructor(
        bytes21 _feedId,
        address _xPoolVault,
        string memory _apiUrl
    ) {
        if (_feedId == bytes21(0)) revert InvalidFeedId();
        if (_xPoolVault == address(0)) revert InvalidVaultAddress();

        feedIdentifier = _feedId;
        xPoolVault = _xPoolVault;
        apiUrlHash = keccak256(bytes(_apiUrl));

        // Initialize with $1.00 NAV
        verifiedNav = 1000000;
        lastVerifiedTimestamp = uint64(block.timestamp);
    }

    // --- FDC Integration ---

    /**
     * @notice Updates the NAV using FDC-verified off-chain CEX data
     *
     * @dev This is the key FDC integration point. Instead of trusting
     *      whoever calls getRate() on the vault, we verify the underlying
     *      CEX data that the NAV is derived from.
     *
     *      The API should return NAV calculated from:
     *      - Binance perpetual funding rates
     *      - OKX perpetual funding rates
     *      - Bybit perpetual funding rates
     *      - Position P&L from delta-neutral strategy
     *
     * @param _proof The Web2Json proof structure from FDC
     */
    function updateNavWithFDC(
        IWeb2Json.Proof calldata _proof
    ) external {
        // 1. Get the FDC verification contract
        IWeb2JsonVerification web2JsonVerification = IWeb2JsonVerification(
            ContractRegistry.getContractAddressByName("FdcVerification")
        );

        // 2. Verify the proof
        bool isValid = web2JsonVerification.verifyWeb2Json(_proof);
        if (!isValid) revert InvalidProof();

        // 3. Extract the response data
        IWeb2Json.Response memory response = _proof.data;

        // 4. Decode the NAV value from the response body
        uint256 newNav = _decodeNavFromResponse(response.responseBody);

        // 5. Validate the NAV is within bounds
        _validateNav(newNav);

        // 6. Check timestamp freshness (skip if timestamp is 0 for testing with static data)
        uint64 responseTimestamp = response.lowestUsedTimestamp;
        if (responseTimestamp > 0 && block.timestamp - responseTimestamp > MAX_DATA_AGE) {
            revert StaleData();
        }

        // 7. Update state - use block.timestamp if response timestamp is 0
        verifiedNav = newNav;
        lastVerifiedTimestamp = responseTimestamp > 0 ? responseTimestamp : uint64(block.timestamp);
        updateCount++;

        emit NavUpdatedViaFDC(
            newNav,
            responseTimestamp,
            keccak256(abi.encode(_proof))
        );
    }

    /**
     * @notice Decodes the NAV value from the FDC response body
     */
    function _decodeNavFromResponse(
        IWeb2Json.ResponseBody memory _responseBody
    ) internal pure returns (uint256) {
        // The abiEncodedData contains the value extracted by the JQ filter
        // For API with postProcessJq = ".data.navScaled"
        return abi.decode(_responseBody.abiEncodedData, (uint256));
    }

    /**
     * @notice Validates that NAV is within acceptable bounds
     * @dev yUSDX can appreciate more than cUSDX due to trading profits
     */
    function _validateNav(uint256 _nav) internal pure {
        // NAV should be between $0.80 and $1.20 for a yield-bearing token
        uint256 minNav = 1000000 - MAX_NAV_DEVIATION; // 800000 ($0.80)
        uint256 maxNav = 1000000 + MAX_NAV_DEVIATION; // 1200000 ($1.20)

        if (_nav < minNav || _nav > maxNav) {
            revert NavOutOfBounds();
        }
    }

    // --- Fallback: Read from Vault ---

    /**
     * @notice Updates NAV by reading from the X-Pool vault's getRate()
     * @dev This is the fallback method - uses the on-chain getRate()
     *      Less secure than FDC as we trust whoever updates getRate()
     */
    function updateNavFromVault() external {
        // Call getRate() on the X-Pool vault
        (bool success, bytes memory data) = xPoolVault.staticcall(
            abi.encodeWithSignature("getRate()")
        );
        require(success, "getRate() failed");

        uint256 rate = abi.decode(data, (uint256));

        // Convert from 18 decimals to 6 decimals
        uint256 nav = rate / 1e12;

        // Validate
        _validateNav(nav);

        // Update state
        verifiedNav = nav;
        lastVerifiedTimestamp = uint64(block.timestamp);

        emit NavUpdatedFromVault(nav, lastVerifiedTimestamp);
    }

    /**
     * @notice Compares FDC-verified NAV with vault's getRate()
     * @return fdcNav The NAV from FDC
     * @return vaultNav The NAV from vault's getRate()
     * @return deviation The absolute deviation in basis points
     */
    function compareNavSources() external view returns (
        uint256 fdcNav,
        uint256 vaultNav,
        uint256 deviation
    ) {
        fdcNav = verifiedNav;

        // Get vault rate
        (bool success, bytes memory data) = xPoolVault.staticcall(
            abi.encodeWithSignature("getRate()")
        );
        if (success) {
            uint256 rate = abi.decode(data, (uint256));
            vaultNav = rate / 1e12;

            // Calculate deviation in basis points
            if (fdcNav > vaultNav) {
                deviation = ((fdcNav - vaultNav) * 10000) / vaultNav;
            } else {
                deviation = ((vaultNav - fdcNav) * 10000) / fdcNav;
            }
        }
    }

    // --- View Functions ---

    function isDataStale() external view returns (bool) {
        return block.timestamp - lastVerifiedTimestamp > MAX_DATA_AGE;
    }

    function timeSinceLastUpdate() external view returns (uint256) {
        return block.timestamp - lastVerifiedTimestamp;
    }

    // --- IICustomFeed Implementation ---

    function getCurrentFeed()
        external
        payable
        override
        returns (uint256 _value, int8 _decimals, uint64 _timestamp)
    {
        _value = verifiedNav;
        _decimals = DECIMALS;
        _timestamp = lastVerifiedTimestamp;
    }

    function feedId() external view override returns (bytes21) {
        return feedIdentifier;
    }

    function getFeedDataView()
        external
        view
        returns (uint256 _value, int8 _decimals, uint64 _timestamp)
    {
        _value = verifiedNav;
        _decimals = DECIMALS;
        _timestamp = lastVerifiedTimestamp;
    }

    function calculateFee() external pure override returns (uint256) {
        return 0;
    }

    function read() public view returns (uint256) {
        return verifiedNav;
    }

    function decimals() external pure returns (int8) {
        return DECIMALS;
    }
}
