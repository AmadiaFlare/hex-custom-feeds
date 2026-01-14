import { artifacts, web3, run, network } from "hardhat";
import { CUSDXCustomFeedInstance } from "../../typechain-types";

const cUSDXCustomFeed = artifacts.require("cUSDXCustomFeed");

// --- Configuration Constants ---
const FEED_SYMBOL = "cUSDX";

// cUSDX token address on Flare mainnet (T-Pool LP token)
// Reference: https://flarescan.com/address/0xfe2907dfa8db6e320cdbf45f0aa888f6135ec4f8
const MAINNET_CUSDX_TOKEN = "0xfe2907dfa8db6e320cdbf45f0aa888f6135ec4f8";

// USDX/USD FTSO feed ID (category 0x01 for crypto + "USDX/USD" encoded)
// Reference: https://flare-systems-explorer.flare.network/price-feeds/ftso?feed=0x01555344582f555344000000000000000000000000
const USDX_FEED_ID = "0x01555344582f555344000000000000000000000000";

/**
 * Gets the cUSDX token address based on the network.
 */
async function getCUSDXTokenAddress(): Promise<string> {
    const chainId = await web3.eth.getChainId();

    // Flare mainnet (chainId 14)
    if (chainId === 14) {
        console.log(`Using cUSDX token on Flare mainnet: ${MAINNET_CUSDX_TOKEN}`);
        return MAINNET_CUSDX_TOKEN;
    }

    // For testnets, we'll use the mainnet address since the feed reads from FTSO
    // which is available on testnets as well
    console.log(`Testnet detected (chainId: ${chainId}). Using mainnet cUSDX address for reference.`);
    console.log(`Note: FTSO feeds should be available on testnet.`);
    return MAINNET_CUSDX_TOKEN;
}

/**
 * Deploys and verifies the cUSDXCustomFeed contract.
 */
async function deployAndVerifyContract(cUSDXTokenAddress: string): Promise<CUSDXCustomFeedInstance> {
    const feedIdString = `${FEED_SYMBOL}/USD`;
    const feedNameHash = web3.utils.keccak256(feedIdString);
    // Custom feed ID: 0x21 (custom feed category) + first 20 bytes of hash
    const finalFeedIdHex = `0x21${feedNameHash.substring(2, 42)}`;

    console.log(`\nDeploying cUSDXCustomFeed with:`);
    console.log(`  Feed ID: ${finalFeedIdHex}`);
    console.log(`  cUSDX Token: ${cUSDXTokenAddress}`);
    console.log(`  USDX Feed ID: ${USDX_FEED_ID}`);

    const customFeedArgs: any[] = [finalFeedIdHex, cUSDXTokenAddress, USDX_FEED_ID];
    const customFeed: CUSDXCustomFeedInstance = await cUSDXCustomFeed.new(...customFeedArgs);
    console.log(`cUSDXCustomFeed deployed to: ${customFeed.address}`);

    try {
        await run("verify:verify", {
            address: customFeed.address,
            constructorArguments: customFeedArgs,
            contract: "contracts/customFeeds/cUSDXCustomFeed.sol:cUSDXCustomFeed",
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
async function testCustomFeed(customFeed: CUSDXCustomFeedInstance) {
    console.log("\n--- Testing cUSDXCustomFeed ---");

    // Test read() function - use .call() since it's not a view function
    const price = await customFeed.read.call();
    const decimals = await customFeed.decimals();
    const formattedPrice = Number(price) / 10 ** Number(decimals);
    console.log(`read() -> Price: ${price.toString()} (${formattedPrice.toFixed(6)} USD)`);

    // Test getLiveRate() function - use .call() since it's not a view function
    const liveRate = await customFeed.getLiveRate.call();
    console.log(`getLiveRate() -> Rate: ${liveRate.toString()} (${(Number(liveRate) / 1e6).toFixed(6)} USD)`);

    // Test updateRate() - this is a transaction
    console.log("\nCalling updateRate() to cache the current rate...");
    const tx = await customFeed.updateRate();
    console.log(`updateRate() tx: ${tx.tx}`);

    // Read cached values (view function)
    const { _value, _decimals, _timestamp } = await customFeed.getFeedDataView();
    const cachedPrice = Number(_value) / 10 ** Number(_decimals);
    const updateTime = new Date(Number(_timestamp) * 1000).toISOString();
    console.log(`Cached price: ${cachedPrice.toFixed(6)} USD`);
    console.log(`Last update: ${updateTime}`);

    // Test feedId (view function)
    const feedIdResult = await customFeed.feedId();
    console.log(`Feed ID: ${feedIdResult}`);

    // Test getTotalSupply (view function)
    try {
        const totalSupply = await customFeed.getTotalSupply();
        console.log(`Total cUSDX supply: ${(Number(totalSupply) / 1e6).toLocaleString()} cUSDX`);
    } catch (e) {
        console.log("getTotalSupply() failed:", (e as Error).message);
    }
}

async function main() {
    console.log(`--- Starting cUSDX/USD Custom Feed Deployment ---`);
    console.log(`Network: ${network.name}`);

    // 1. Get cUSDX token address
    const cUSDXTokenAddress = await getCUSDXTokenAddress();

    // 2. Deploy custom feed
    const customFeed = await deployAndVerifyContract(cUSDXTokenAddress);

    // 3. Test the feed
    await testCustomFeed(customFeed);

    console.log("\ncUSDX/USD Custom Feed deployment completed successfully.");
}

void main().then(() => {
    process.exit(0);
});
