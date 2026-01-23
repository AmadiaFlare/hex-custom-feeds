// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { IICustomFeed } from "@flarenetwork/flare-periphery-contracts/coston2/customFeeds/interfaces/IICustomFeed.sol";
import { ContractRegistry } from "@flarenetwork/flare-periphery-contracts/coston2/ContractRegistry.sol";
import { IWeb2Json } from "@flarenetwork/flare-periphery-contracts/coston2/IWeb2Json.sol";

/**
 * @notice Struct to decode the FDC response body
 * @dev Must match the abiSignature used in the FDC request:
 *      {"components": [{"internalType": "uint256", "name": "navScaled", "type": "uint256"}],
 *       "internalType": "struct NavData", "name": "data", "type": "tuple"}
 */
struct NavData {
    uint256 navScaled;
}

/**
 * @title yUSDXCustomFeedFDC
 * @notice FTSO Custom Feed for yUSDX/USD pricing using Flare Data Connector (FDC)
 *
 * @dev yUSDX is the LP token from Clearpool's X-Pool vault. Its value floats based on
 *      the NAV of a delta-neutral basis trading strategy on centralized exchanges.
 *
 *      Why FDC?
 *      Traditional oracle solutions require trusting whoever pushes data on-chain.
 *      FDC provides cryptographic proof that data came from a specific URL, verified
 *      by multiple independent attestation providers. This contract validates that
 *      the proof URL matches expected patterns before accepting the data.
 *
 *      Security Model:
 *      1. FDC attestation providers independently fetch and verify the API response
 *      2. This contract enforces HTTPS-only to prevent MitM attacks
 *      3. Host validation ensures data comes from allowed sources only
 *      4. Path validation (startsWith) prevents prefix injection attacks
 *      5. NAV bounds checking prevents extreme values from manipulation
 *
 *      Allowed API Sources:
 *      - GitHub Pages: amadiaflare.github.io/hex-custom-feeds/api/v1/xpool/nav
 *      - Production: api.htmarkets.com/api/v1/xpool/nav
 *
 *      X-Pool vault: 0xd006185B765cA59F29FDd0c57526309726b69d99
 */
contract yUSDXCustomFeedFDC is IICustomFeed {
    // --- State Variables ---

    bytes21 public immutable feedIdentifier;
    int8 public constant DECIMALS = 6;

    /// @notice The X-Pool vault address (for reference)
    address public immutable xPoolVault;

    /// @notice The verified NAV price (6 decimals, 1000000 = $1.00)
    uint256 public verifiedNav;

    /// @notice Timestamp of the last verified update
    uint64 public lastVerifiedTimestamp;

    /// @notice Number of successful FDC updates
    uint256 public updateCount;

    // --- Events ---
    event NavUpdatedViaFDC(uint256 nav, uint64 timestamp, bytes32 proofHash);

    // --- Errors ---
    error InvalidFeedId();
    error InvalidVaultAddress();
    error InvalidProof();
    error NavOutOfBounds();
    error InvalidUrlHost(string url, string extractedHost);
    error InvalidUrlPath(string url, string extractedPath);
    error InvalidUrlProtocol();
    error SliceOutOfBounds();
    error EthRefundFailed();

    // --- Constants ---

    /// @notice Maximum allowed NAV deviation from $1.00 (20% for yield-bearing token)
    uint256 public constant MAX_NAV_DEVIATION = 200000; // 20%

    /// @notice Expected API path for NAV endpoint
    string public constant EXPECTED_API_PATH = "/api/v1/xpool/nav";

    // --- Constructor ---

    /**
     * @param _feedId The unique feed identifier for yUSDX/USD
     * @param _xPoolVault The address of the X-Pool vault
     */
    constructor(bytes21 _feedId, address _xPoolVault) {
        if (_feedId == bytes21(0)) revert InvalidFeedId();
        if (_xPoolVault == address(0)) revert InvalidVaultAddress();

        feedIdentifier = _feedId;
        xPoolVault = _xPoolVault;

        // Initialize with $1.00 NAV and timestamp 0 to allow first update
        verifiedNav = 1000000;
        lastVerifiedTimestamp = 0;
    }

    // --- FDC Integration ---

    /**
     * @notice Updates the NAV using FDC-verified off-chain data
     *
     * @dev FDC provides cryptographic proof that data came from a specific URL.
     *      This function validates:
     *      1. The URL in the proof uses HTTPS (prevents MitM)
     *      2. The URL host is one of the allowed sources
     *      3. The URL path starts with the expected API endpoint
     *      4. The FDC proof is cryptographically valid
     *      5. The NAV value is within acceptable bounds ($0.80 - $1.20)
     *
     * @param _proof The Web2Json proof structure from FDC
     */
    function updateNavWithFDC(IWeb2Json.Proof calldata _proof) external {
        // 1. Validate the URL from the proof matches allowed patterns
        _validateUrl(_proof.data.requestBody.url);

        // 2. Verify the FDC proof (cryptographic verification by attestation providers)
        if (!ContractRegistry.getFdcVerification().verifyWeb2Json(_proof)) revert InvalidProof();

        // 3. Decode the NAV value from the response body
        uint256 newNav = _decodeNavFromResponse(_proof.data.responseBody);

        // 4. Validate the NAV is within bounds
        _validateNav(newNav);

        // 5. Update state
        verifiedNav = newNav;
        lastVerifiedTimestamp = uint64(block.timestamp);
        unchecked {
            ++updateCount;
        }

        emit NavUpdatedViaFDC(newNav, uint64(block.timestamp), keccak256(abi.encode(_proof)));
    }

    /**
     * @notice Decodes the NAV value from the FDC response body
     * @dev The abiEncodedData is ABI-encoded as a struct matching the abiSignature in the FDC request
     */
    function _decodeNavFromResponse(IWeb2Json.ResponseBody memory _responseBody) internal pure returns (uint256) {
        // Decode the struct from the ABI-encoded data
        NavData memory data = abi.decode(_responseBody.abiEncodedData, (NavData));
        return data.navScaled;
    }

    /**
     * @notice Validates that NAV is within acceptable bounds
     * @dev yUSDX can appreciate due to trading profits, but extreme values indicate manipulation
     */
    function _validateNav(uint256 _nav) internal pure {
        // NAV should be between $0.80 and $1.20 for a yield-bearing token
        uint256 minNav = 1000000 - MAX_NAV_DEVIATION; // 800000 ($0.80)
        uint256 maxNav = 1000000 + MAX_NAV_DEVIATION; // 1200000 ($1.20)

        if (_nav < minNav || _nav > maxNav) {
            revert NavOutOfBounds();
        }
    }

    // --- URL Validation ---

    /**
     * @notice Validates that the URL from the FDC proof matches allowed patterns
     * @dev This is a critical security check. We only accept data from known sources:
     *      - GitHub Pages: amadiaflare.github.io/hex-custom-feeds/api/v1/xpool/nav
     *      - Production API: api.htmarkets.com/api/v1/xpool/nav
     *
     *      Security measures:
     *      1. HTTPS only (HTTP rejected)
     *      2. Exact host matching (case-insensitive)
     *      3. Path must START with expected pattern (no prefix injection)
     *
     * @param _url The URL from the FDC proof
     */
    function _validateUrl(string memory _url) internal pure {
        // 1. Enforce HTTPS only
        bytes memory urlBytes = bytes(_url);
        bytes memory httpsPrefix = bytes("https://");
        if (!_startsWith(urlBytes, httpsPrefix)) {
            revert InvalidUrlProtocol();
        }

        string memory host = _extractHost(_url);
        string memory path = _extractPath(_url);

        // 2. Validate host is one of the allowed sources (case-insensitive)
        string memory lowerHost = _toLowerCase(host);
        bool validHost = _stringsEqual(lowerHost, "amadiaflare.github.io") ||
            _stringsEqual(lowerHost, "api.htmarkets.com");

        if (!validHost) {
            revert InvalidUrlHost(_url, host);
        }

        // 3. Validate path STARTS with the expected API endpoint (prevents prefix injection)
        // For GitHub Pages: /hex-custom-feeds/api/v1/xpool/nav[.json]
        // For Production: /api/v1/xpool/nav
        bool validPath;
        if (_stringsEqual(lowerHost, "amadiaflare.github.io")) {
            // GitHub Pages path: /hex-custom-feeds/api/v1/xpool/nav.json
            validPath = _startsWith(bytes(path), bytes("/hex-custom-feeds/api/v1/xpool/nav"));
        } else {
            // Production path: /api/v1/xpool/nav
            validPath = _startsWith(bytes(path), bytes("/api/v1/xpool/nav"));
        }

        if (!validPath) {
            revert InvalidUrlPath(_url, path);
        }
    }

    /**
     * @notice Extracts the host from a URL
     * @dev Handles URLs like "https://example.com/path" -> "example.com"
     * @param _url The full URL string
     * @return The extracted host
     */
    function _extractHost(string memory _url) internal pure returns (string memory) {
        bytes memory urlBytes = bytes(_url);
        bytes memory httpsPrefix = bytes("https://");
        bytes memory httpPrefix = bytes("http://");

        uint256 startIndex = 0;

        // Find start after protocol
        if (_startsWith(urlBytes, httpsPrefix)) {
            startIndex = httpsPrefix.length;
        } else if (_startsWith(urlBytes, httpPrefix)) {
            startIndex = httpPrefix.length;
        }

        // Find end at first "/" after host
        uint256 urlLen = urlBytes.length;
        uint256 endIndex = urlLen;
        for (uint256 i = startIndex; i < urlLen; ) {
            if (urlBytes[i] == "/") {
                endIndex = i;
                break;
            }
            unchecked {
                ++i;
            }
        }

        return string(_slice(urlBytes, startIndex, endIndex));
    }

    /**
     * @notice Extracts the path from a URL
     * @dev Handles URLs like "https://example.com/path/to/resource" -> "/path/to/resource"
     * @param _url The full URL string
     * @return The extracted path
     */
    function _extractPath(string memory _url) internal pure returns (string memory) {
        bytes memory urlBytes = bytes(_url);
        bytes memory httpsPrefix = bytes("https://");
        bytes memory httpPrefix = bytes("http://");

        uint256 startIndex = 0;

        // Find start after protocol
        if (_startsWith(urlBytes, httpsPrefix)) {
            startIndex = httpsPrefix.length;
        } else if (_startsWith(urlBytes, httpPrefix)) {
            startIndex = httpPrefix.length;
        }

        // Find path start (first "/" after host)
        uint256 urlLen = urlBytes.length;
        for (uint256 i = startIndex; i < urlLen; ) {
            if (urlBytes[i] == "/") {
                return string(_slice(urlBytes, i, urlLen));
            }
            unchecked {
                ++i;
            }
        }

        return "";
    }

    // --- String Helper Functions ---

    /**
     * @notice Extracts a slice of bytes
     * @param data The original bytes array
     * @param start The starting index (inclusive)
     * @param end The ending index (exclusive)
     * @return The sliced bytes
     */
    function _slice(bytes memory data, uint256 start, uint256 end) internal pure returns (bytes memory) {
        if (end < start || data.length < end) revert SliceOutOfBounds();
        bytes memory result = new bytes(end - start);
        for (uint256 i = start; i < end; ) {
            result[i - start] = data[i];
            unchecked {
                ++i;
            }
        }
        return result;
    }

    /**
     * @notice Checks if bytes start with a prefix
     */
    function _startsWith(bytes memory data, bytes memory prefix) internal pure returns (bool) {
        uint256 prefixLen = prefix.length;
        if (data.length < prefixLen) return false;
        for (uint256 i = 0; i < prefixLen; ) {
            if (data[i] != prefix[i]) return false;
            unchecked {
                ++i;
            }
        }
        return true;
    }

    /**
     * @notice Compares two strings for equality
     */
    function _stringsEqual(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }

    /**
     * @notice Converts a string to lowercase
     * @dev Only handles ASCII characters (a-z, A-Z)
     * @param str The string to convert
     * @return The lowercase string
     */
    function _toLowerCase(string memory str) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        uint256 len = strBytes.length;
        bytes memory result = new bytes(len);
        for (uint256 i = 0; i < len; ) {
            bytes1 char = strBytes[i];
            // If uppercase A-Z (65-90), convert to lowercase (97-122)
            if (char >= 0x41) {
                if (char <= 0x5A) {
                    result[i] = bytes1(uint8(char) + 32);
                } else {
                    result[i] = char;
                }
            } else {
                result[i] = char;
            }
            unchecked {
                ++i;
            }
        }
        return string(result);
    }

    // --- View Functions ---

    function timeSinceLastUpdate() external view returns (uint256) {
        return block.timestamp - lastVerifiedTimestamp;
    }

    // --- IICustomFeed Implementation ---

    function getCurrentFeed() external payable override returns (uint256 _value, int8 _decimals, uint64 _timestamp) {
        // Refund any ETH sent (interface requires payable but this feed is free)
        if (msg.value > 0) {
            (bool success, ) = msg.sender.call{ value: msg.value }("");
            if (!success) revert EthRefundFailed();
        }

        _value = verifiedNav;
        _decimals = DECIMALS;
        _timestamp = lastVerifiedTimestamp;
    }

    function feedId() external view override returns (bytes21) {
        return feedIdentifier;
    }

    function getFeedDataView() external view returns (uint256 _value, int8 _decimals, uint64 _timestamp) {
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
