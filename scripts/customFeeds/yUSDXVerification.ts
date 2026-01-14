import { artifacts, web3, run, network } from "hardhat";
import { YUSDXCustomFeedInstance } from "../../typechain-types";

const yUSDXCustomFeed = artifacts.require("yUSDXCustomFeed");
const MockClearpoolVault = artifacts.require("MockClearpoolVault");

// --- Configuration Constants ---
const FEED_SYMBOL = "yUSDX";

// Clearpool X-Pool vault address on Flare mainnet
// Reference: https://mainnet.flarescan.com/address/0xd006185B765cA59F29FDd0c57526309726b69d99
const MAINNET_VAULT_ADDRESS = "0xd006185B765cA59F29FDd0c57526309726b69d99";

// Initial mock rate for testnet (e.g., $1.05 = 1.05e18)
const MOCK_INITIAL_RATE = web3.utils.toWei("1.05", "ether");

/**
 * Determines the vault address based on the network.
 * On mainnet, uses the real Clearpool vault.
 * On testnet, deploys a mock vault.
 */
async function getVaultAddress(): Promise<string> {
    const chainId = await web3.eth.getChainId();

    // Flare mainnet (chainId 14)
    if (chainId === 14) {
        console.log(`Using Clearpool X-Pool vault on Flare mainnet: ${MAINNET_VAULT_ADDRESS}`);
        return MAINNET_VAULT_ADDRESS;
    }

    // Testnet - deploy mock vault
    console.log(`Testnet detected (chainId: ${chainId}). Deploying MockClearpoolVault...`);
    const mockVault = await MockClearpoolVault.new(MOCK_INITIAL_RATE);
    console.log(`MockClearpoolVault deployed to: ${mockVault.address}`);
    console.log(`Mock initial rate: ${web3.utils.fromWei(MOCK_INITIAL_RATE, "ether")} (1e18 = $1.00)`);

    try {
        await run("verify:verify", {
            address: mockVault.address,
            constructorArguments: [MOCK_INITIAL_RATE],
            contract: "contracts/customFeeds/mocks/MockClearpoolVault.sol:MockClearpoolVault",
        });
        console.log("MockClearpoolVault verification successful.");
    } catch (e: any) {
        if (e.message?.toLowerCase().includes("already verified")) {
            console.log("MockClearpoolVault is already verified.");
        } else {
            console.log("MockClearpoolVault verification failed:", e.message);
        }
    }

    return mockVault.address;
}

/**
 * Deploys and verifies the yUSDXCustomFeed contract.
 */
async function deployAndVerifyContract(vaultAddress: string): Promise<YUSDXCustomFeedInstance> {
    const feedIdString = `${FEED_SYMBOL}/USD`;
    const feedNameHash = web3.utils.keccak256(feedIdString);
    // Custom feed ID: 0x21 (custom feed category) + first 20 bytes of hash
    const finalFeedIdHex = `0x21${feedNameHash.substring(2, 42)}`;

    console.log(`\nDeploying yUSDXCustomFeed with Feed ID: ${finalFeedIdHex}`);
    console.log(`Vault address: ${vaultAddress}`);

    const customFeedArgs: any[] = [finalFeedIdHex, vaultAddress];
    const customFeed: YUSDXCustomFeedInstance = await yUSDXCustomFeed.new(...customFeedArgs);
    console.log(`yUSDXCustomFeed deployed to: ${customFeed.address}`);

    try {
        await run("verify:verify", {
            address: customFeed.address,
            constructorArguments: customFeedArgs,
            contract: "contracts/customFeeds/yUSDXCustomFeed.sol:yUSDXCustomFeed",
        });
        console.log("Contract verification successful.");
    } catch (e: any) {
        if (e.message?.toLowerCase().includes("already verified")) {
            console.log("Contract is already verified.");
        } else {
            console.log("Contract verification failed:", e.message);
        }
    }

    return customFeed;
}

/**
 * Tests the deployed custom feed by reading the current price.
 */
async function testCustomFeed(customFeed: YUSDXCustomFeedInstance) {
    console.log("\n--- Testing yUSDXCustomFeed ---");

    // Test read() function
    const price = await customFeed.read();
    const decimals = await customFeed.decimals();
    const formattedPrice = Number(price) / 10 ** Number(decimals);
    console.log(`read() -> Price: ${price.toString()} (${formattedPrice.toFixed(6)} USD)`);

    // Test getLiveRate() function
    const liveRate = await customFeed.getLiveRate();
    const liveRateFormatted = Number(web3.utils.fromWei(liveRate.toString(), "ether"));
    console.log(`getLiveRate() -> Rate: ${liveRate.toString()} (${liveRateFormatted.toFixed(6)} in 1e18 scale)`);

    // Test updateRate() and cache
    console.log("\nCalling updateRate() to cache the current rate...");
    const tx = await customFeed.updateRate();
    console.log(`updateRate() tx: ${tx.tx}`);

    // Read cached values
    const { _value, _decimals, _timestamp } = await customFeed.getFeedDataView();
    const cachedPrice = Number(_value) / 10 ** Number(_decimals);
    const updateTime = new Date(Number(_timestamp) * 1000).toISOString();
    console.log(`Cached price: ${cachedPrice.toFixed(6)} USD`);
    console.log(`Last update: ${updateTime}`);

    // Test feedId
    const feedIdResult = await customFeed.feedId();
    console.log(`Feed ID: ${feedIdResult}`);
}

async function main() {
    console.log(`--- Starting yUSDX/USD Custom Feed Deployment ---`);
    console.log(`Network: ${network.name}`);

    // 1. Get or deploy vault
    const vaultAddress = await getVaultAddress();

    // 2. Deploy custom feed
    const customFeed = await deployAndVerifyContract(vaultAddress);

    // 3. Test the feed
    await testCustomFeed(customFeed);

    console.log("\nyUSDX/USD Custom Feed deployment completed successfully.");
}

void main().then(() => {
    process.exit(0);
});
