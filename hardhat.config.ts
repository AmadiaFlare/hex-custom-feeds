import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomiclabs/hardhat-web3";
require("@nomiclabs/hardhat-truffle5");
require("dotenv").config();

// Load environment variables
const PRIVATE_KEY = process.env.PRIVATE_KEY ?? "";
const FLARE_RPC_API_KEY = process.env.FLARE_RPC_API_KEY ?? "";
const FLARESCAN_API_KEY = process.env.FLARESCAN_API_KEY ?? "";
const FLARE_EXPLORER_API_KEY = process.env.FLARE_EXPLORER_API_KEY ?? "";

const config: HardhatUserConfig = {
    solidity: {
        compilers: [
            {
                version: "0.8.25",
                settings: {
                    evmVersion: "cancun",
                    optimizer: {
                        enabled: true,
                        runs: 200,
                    },
                },
            },
        ],
    },
    networks: {
        coston: {
            url: FLARE_RPC_API_KEY
                ? `https://coston-api-tracer.flare.network/ext/C/rpc?x-apikey=${FLARE_RPC_API_KEY}`
                : "https://coston-api.flare.network/ext/C/rpc",
            accounts: [`${PRIVATE_KEY}`],
            chainId: 16,
        },
        coston2: {
            url: FLARE_RPC_API_KEY
                ? `https://coston2-api-tracer.flare.network/ext/C/rpc?x-apikey=${FLARE_RPC_API_KEY}`
                : "https://coston2-api.flare.network/ext/C/rpc",
            accounts: [`${PRIVATE_KEY}`],
            chainId: 114,
        },
        songbird: {
            url: FLARE_RPC_API_KEY
                ? `https://songbird-api-tracer.flare.network/ext/C/rpc?x-apikey=${FLARE_RPC_API_KEY}`
                : "https://songbird-api.flare.network/ext/C/rpc",
            accounts: [`${PRIVATE_KEY}`],
            chainId: 19,
        },
        flare: {
            url: FLARE_RPC_API_KEY
                ? `https://flare-api-tracer.flare.network/ext/C/rpc?x-apikey=${FLARE_RPC_API_KEY}`
                : "https://flare-api.flare.network/ext/C/rpc",
            accounts: [`${PRIVATE_KEY}`],
            chainId: 14,
        },
    },
    etherscan: {
        apiKey: {
            coston: `${FLARESCAN_API_KEY}`,
            coston2: `${FLARESCAN_API_KEY}`,
            songbird: `${FLARESCAN_API_KEY}`,
            flare: `${FLARESCAN_API_KEY}`,
        },
        customChains: [
            {
                network: "coston",
                chainId: 16,
                urls: {
                    apiURL:
                        "https://coston-explorer.flare.network/api" +
                        (FLARE_EXPLORER_API_KEY ? `?x-apikey=${FLARE_EXPLORER_API_KEY}` : ""),
                    browserURL: "https://coston-explorer.flare.network",
                },
            },
            {
                network: "coston2",
                chainId: 114,
                urls: {
                    apiURL:
                        "https://coston2-explorer.flare.network/api" +
                        (FLARE_EXPLORER_API_KEY ? `?x-apikey=${FLARE_EXPLORER_API_KEY}` : ""),
                    browserURL: "https://coston2-explorer.flare.network",
                },
            },
            {
                network: "songbird",
                chainId: 19,
                urls: {
                    apiURL:
                        "https://songbird-explorer.flare.network/api" +
                        (FLARE_EXPLORER_API_KEY ? `?x-apikey=${FLARE_EXPLORER_API_KEY}` : ""),
                    browserURL: "https://songbird-explorer.flare.network/",
                },
            },
            {
                network: "flare",
                chainId: 14,
                urls: {
                    apiURL:
                        "https://flare-explorer.flare.network/api" +
                        (FLARE_EXPLORER_API_KEY ? `?x-apikey=${FLARE_EXPLORER_API_KEY}` : ""),
                    browserURL: "https://flare-explorer.flare.network/",
                },
            },
        ],
    },
    paths: {
        sources: "./contracts/",
        tests: "./test/",
        cache: "./cache",
        artifacts: "./artifacts",
    },
    typechain: {
        target: "truffle-v5",
    },
};

export default config;
