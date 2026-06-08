require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },

  networks: {
    // Local Hardhat network — used for testing
    hardhat: {
      chainId: 31337,
    },

amoy: {
  url: process.env.AMOY_RPC_URL || "https://rpc-amoy.polygon.technology",
  accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
  chainId: 80002,
},
  },

  
etherscan: {
  apiKey: {
    amoy: process.env.POLYGONSCAN_API_KEY || "",
  },
  customChains: [
    {
      network: "amoy",
      chainId: 80002,
      urls: {
        apiURL: "https://api-amoy.polygonscan.com/api",
        browserURL: "https://amoy.polygonscan.com",
      },
    },
  ],
},
  // Gas reporting (printed after each test run)
  gasReporter: {
    enabled: process.env.REPORT_GAS === "true",
    currency: "USD",
  },

  // Coverage output folder
  coverageDirectory: "coverage",
};
