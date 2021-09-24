require('@nomiclabs/hardhat-ethers');
require("@nomiclabs/hardhat-etherscan");
require('@openzeppelin/hardhat-upgrades');
require('dotenv').config()
/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
    solidity: "0.8.0",
    defaultNetwork: "mainnet",
    networks: {
        localhost: {
            url: "http://127.0.0.1:8545"
        },
        hardhat: {},
        testnet: {
            url: "https://data-seed-prebsc-1-s1.binance.org:8545",
            chainId: 97,
            gasPrice: 20000000000,
            accounts: ['0999ffef3b3cf6dc1e85f4cae30edb83920b9c71e6d30c2d1b6345fc253a6795']
        },
        mainnet: {
            url: process.env.RPC_MAINNET_URL,
            chainId: 56,
            gasPrice: 5000000000,
            gas: 9000000,
            gasLimit : 9000000,
            accounts: [process.env.PRIVATE_KEY_MAINET]
        }
    },
    etherscan: {
        // Your API key for Etherscan
        // Obtain one at https://etherscan.io/
        apiKey: "RT1E1F2J16CTCCJZIZ5U8SFDACJ6VKF7U4"
    },
    paths: {
        sources: "./contracts",
        tests: "./test",
        cache: "./cache",
        artifacts: "./artifacts"
    },
    mocha: {
        timeout: 20000
    }
};
