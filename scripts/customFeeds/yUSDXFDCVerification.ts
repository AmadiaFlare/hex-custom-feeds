import { run, web3, network } from "hardhat";
import {
    prepareAttestationRequestBase,
    submitAttestationRequest,
    retrieveDataAndProofBaseWithRetry,
} from "../utils/fdc";

const yUSDXCustomFeedFDC = artifacts.require("yUSDXCustomFeedFDC");
const MockClearpoolVault = artifacts.require("MockClearpoolVault");

const { WEB2JSON_VERIFIER_URL_TESTNET, VERIFIER_API_KEY_TESTNET, COSTON2_DA_LAYER_URL } = process.env;

// yarn hardhat run scripts/customFeeds/yUSDXFDCVerification.ts --network coston2

// --- Configuration Constants ---
const FEED_SYMBOL = "yUSDX";

// Clearpool X-Pool vault address on Flare mainnet
const MAINNET_VAULT_ADDRESS = "0xd006185B765cA59F29FDd0c57526309726b69d99";

// GitHub Pages static API for testnet, HT Markets API for production
const TESTNET_API_URL = "https://amadiaflare.github.io/hex-custom-feeds/api/v1/xpool/nav.json";
const PRODUCTION_API_URL = "https://api.htmarkets.com/api/v1/xpool/nav";

// Initial mock rate for testnet (e.g., $1.05 = 1.05e18)
const MOCK_INITIAL_RATE = web3.utils.toWei("1.05", "ether");

// FDC Web2Json configuration
const attestationTypeBase = "Web2Json";
const sourceIdBase = "PublicWeb2";
const verifierUrlBase = WEB2JSON_VERIFIER_URL_TESTNET;

// Request parameters for X-Pool NAV API
const httpMethod = "GET";
const headers = "{}";
const queryParams = "{}";
const body = "{}";

// JQ filter to extract navScaled from the API response as an object
// Response format: { "success": true, "data": { "navScaled": 1004187, ... } }
const postProcessJq = `{navScaled: .data.navScaled}`;

// ABI signature for the response - tuple containing uint256 navScaled
const abiSignature = `{"components": [{"internalType": "uint256", "name": "navScaled", "type": "uint256"}], "internalType": "struct NavData", "name": "data", "type": "tuple"}`;

/**
 * Prepares the FDC attestation request for the X-Pool NAV API
 */
async function prepareAttestationRequest(apiUrl: string) {
    const requestBody = {
        url: apiUrl,
        httpMethod: httpMethod,
        headers: headers,
        queryParams: queryParams,
        body: body,
        postProcessJq: postProcessJq,
        abiSignature: abiSignature,
    };

    const url = `${verifierUrlBase}/Web2Json/prepareRequest`;
    const apiKey = VERIFIER_API_KEY_TESTNET;

    return await prepareAttestationRequestBase(url, apiKey!, attestationTypeBase, sourceIdBase, requestBody);
}

/**
 * Retrieves the proof from the DA layer after the round is finalized
 */
async function retrieveDataAndProof(abiEncodedRequest: string, roundId: number) {
    const url = `${COSTON2_DA_LAYER_URL}/api/v1/fdc/proof-by-request-round-raw`;
    console.log("DA Layer URL:", url, "\n");
    return await retrieveDataAndProofBaseWithRetry(url, abiEncodedRequest, roundId);
}

/**
 * Determines the vault address based on the network
 */
async function getVaultAddress(): Promise<string> {
    const chainId = await web3.eth.getChainId();

    if (chainId === 14) {
        console.log(`Using Clearpool X-Pool vault on Flare mainnet: ${MAINNET_VAULT_ADDRESS}`);
        return MAINNET_VAULT_ADDRESS;
    }

    console.log(`Testnet detected (chainId: ${chainId}). Deploying MockClearpoolVault...`);
    const mockVault = await MockClearpoolVault.new(MOCK_INITIAL_RATE);
    console.log(`MockClearpoolVault deployed to: ${mockVault.address}`);

    try {
        await run("verify:verify", {
            address: mockVault.address,
            constructorArguments: [MOCK_INITIAL_RATE],
            contract: "contracts/customFeeds/mocks/MockClearpoolVault.sol:MockClearpoolVault",
        });
    } catch (e: any) {
        if (!e.message?.toLowerCase().includes("already verified")) {
            console.log("MockClearpoolVault verification failed:", e.message);
        }
    }

    return mockVault.address;
}

/**
 * Deploys and verifies the yUSDXCustomFeedFDC contract
 */
async function deployAndVerifyContract(vaultAddress: string, apiUrl: string) {
    const feedIdString = `${FEED_SYMBOL}/USD`;
    const feedNameHash = web3.utils.keccak256(feedIdString);
    const finalFeedIdHex = `0x21${feedNameHash.substring(2, 42)}`;

    console.log(`\nDeploying yUSDXCustomFeedFDC...`);
    console.log(`Feed ID: ${finalFeedIdHex}`);
    console.log(`Vault address: ${vaultAddress}`);
    console.log(`API URL: ${apiUrl}`);

    const customFeedArgs: any[] = [finalFeedIdHex, vaultAddress, apiUrl];
    const customFeed = await yUSDXCustomFeedFDC.new(...customFeedArgs);
    console.log(`yUSDXCustomFeedFDC deployed to: ${customFeed.address}\n`);

    try {
        await run("verify:verify", {
            address: customFeed.address,
            constructorArguments: customFeedArgs,
            contract: "contracts/customFeeds/yUSDXCustomFeedFDC.sol:yUSDXCustomFeedFDC",
        });
        console.log("Contract verification successful.\n");
    } catch (e: any) {
        if (e.message?.toLowerCase().includes("already verified")) {
            console.log("Contract is already verified.\n");
        } else {
            console.log("Contract verification failed:", e.message, "\n");
        }
    }

    return customFeed;
}

/**
 * Updates the contract with FDC-verified NAV data
 */
async function updateWithFDCProof(customFeed: any, proof: any) {
    console.log("Proof hex:", proof.response_hex, "\n");

    // Decode the response type from the IWeb2JsonVerification artifact
    const IWeb2JsonVerification = await artifacts.require("IWeb2JsonVerification");
    const responseType = IWeb2JsonVerification._json.abi[0].inputs[0].components[1];
    console.log("Response type:", responseType, "\n");

    const decodedResponse = web3.eth.abi.decodeParameter(responseType, proof.response_hex);
    console.log("Decoded proof:", decodedResponse, "\n");

    // Call updateNavWithFDC with the proof
    const transaction = await customFeed.updateNavWithFDC({
        merkleProof: proof.proof,
        data: decodedResponse,
    });
    console.log("updateNavWithFDC Transaction:", transaction.tx, "\n");

    // Read the updated values
    const { _value, _decimals, _timestamp } = await customFeed.getFeedDataView();
    const price = Number(_value) / 10 ** Number(_decimals);
    const updateTime = new Date(Number(_timestamp) * 1000).toISOString();

    console.log(`Updated NAV: ${price.toFixed(6)} USD`);
    console.log(`Last update: ${updateTime}`);
    console.log(`Update count: ${await customFeed.updateCount()}\n`);
}

/**
 * Tests the fallback vault update method
 */
async function testVaultFallback(customFeed: any) {
    console.log("=== Testing Vault Fallback ===\n");

    try {
        console.log("Calling updateNavFromVault()...");
        const tx = await customFeed.updateNavFromVault();
        console.log(`Transaction: ${tx.tx}`);

        const { _value, _decimals, _timestamp } = await customFeed.getFeedDataView();
        const price = Number(_value) / 10 ** Number(_decimals);
        const updateTime = new Date(Number(_timestamp) * 1000).toISOString();

        console.log(`Updated NAV: ${price.toFixed(6)} USD`);
        console.log(`Last update: ${updateTime}\n`);
    } catch (error: any) {
        console.log(`Vault fallback failed: ${error.message}\n`);
    }
}

/**
 * Tests basic contract functionality
 */
async function testBasicFunctionality(customFeed: any) {
    console.log("=== Testing Basic Functionality ===\n");

    const price = await customFeed.read();
    const decimals = await customFeed.decimals();
    const formattedPrice = Number(price) / 10 ** Number(decimals);
    console.log(`read() -> ${price.toString()} (${formattedPrice.toFixed(6)} USD)`);

    const feedIdResult = await customFeed.feedId();
    console.log(`feedId() -> ${feedIdResult}`);

    const isStale = await customFeed.isDataStale();
    console.log(`isDataStale() -> ${isStale}`);

    const updateCount = await customFeed.updateCount();
    console.log(`updateCount() -> ${updateCount.toString()}\n`);
}

async function main() {
    console.log(`=== yUSDX/USD Custom Feed FDC Verification ===`);
    console.log(`Network: ${network.name}\n`);

    // Check required environment variables
    if (!WEB2JSON_VERIFIER_URL_TESTNET || !VERIFIER_API_KEY_TESTNET || !COSTON2_DA_LAYER_URL) {
        console.error("Missing required environment variables:");
        console.error("  WEB2JSON_VERIFIER_URL_TESTNET");
        console.error("  VERIFIER_API_KEY_TESTNET");
        console.error("  COSTON2_DA_LAYER_URL");
        process.exit(1);
    }

    // Determine API URL based on network
    const chainId = await web3.eth.getChainId();
    const apiUrl = chainId === 14 ? PRODUCTION_API_URL : TESTNET_API_URL;

    // Step 1: Get or deploy vault
    console.log("Step 1: Getting vault address...\n");
    const vaultAddress = await getVaultAddress();

    // Step 2: Deploy FDC custom feed
    console.log("Step 2: Deploying yUSDXCustomFeedFDC...\n");
    const customFeed = await deployAndVerifyContract(vaultAddress, apiUrl);

    // Step 3: Test basic functionality
    console.log("Step 3: Testing basic functionality...\n");
    await testBasicFunctionality(customFeed);

    // Step 4: Test vault fallback first (if on testnet)
    if (chainId !== 14) {
        console.log("Step 4: Testing vault fallback...\n");
        await testVaultFallback(customFeed);
    }

    // Step 5: Prepare and submit FDC attestation request
    console.log("Step 5: Preparing FDC attestation request...\n");
    console.log(`API URL: ${apiUrl}`);
    console.log(`JQ Filter: ${postProcessJq}`);
    console.log(`ABI Signature: ${abiSignature}\n`);

    try {
        const data = await prepareAttestationRequest(apiUrl);
        console.log("Attestation request prepared:", data, "\n");

        const abiEncodedRequest = data.abiEncodedRequest;

        // Step 6: Submit to FDC Hub
        console.log("Step 6: Submitting to FDC Hub...\n");
        const roundId = await submitAttestationRequest(abiEncodedRequest);

        // Step 7: Wait for proof and retrieve it
        console.log("Step 7: Waiting for round finalization and proof...\n");
        const proof = await retrieveDataAndProof(abiEncodedRequest, roundId);

        // Step 8: Update contract with verified data
        console.log("Step 8: Updating contract with FDC proof...\n");
        await updateWithFDCProof(customFeed, proof);

    } catch (error: any) {
        console.log(`FDC attestation failed: ${error.message}`);
        console.log("\nMake sure:");
        console.log("  1. Environment variables are set correctly in .env");
        console.log("  2. The API URL is accessible from the FDC verifiers");
        console.log("  3. GitHub Pages is deployed: https://amadiaflare.github.io/hex-custom-feeds/\n");
    }

    console.log("=== Deployment Complete ===");
    console.log(`Contract: ${customFeed.address}`);
    console.log(`Vault: ${vaultAddress}`);
    console.log(`API URL: ${apiUrl}`);
}

void main().then(() => {
    process.exit(0);
}).catch((error) => {
    console.error(error);
    process.exit(1);
});
