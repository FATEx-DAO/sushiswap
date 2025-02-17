// hardhat.config.js
require("dotenv").config()
require("@nomiclabs/hardhat-etherscan")
require("@nomiclabs/hardhat-solhint")
require("@tenderly/hardhat-tenderly")
require("@nomiclabs/hardhat-waffle")
require("hardhat-abi-exporter")
require("hardhat-deploy")
require("hardhat-deploy-ethers")
require("hardhat-gas-reporter")
require("hardhat-spdx-license-identifier")
require("hardhat-typechain")
require("hardhat-watcher")
require("solidity-coverage")
require('./tasks')

const { removeConsoleLog } = require("hardhat-preprocessor")

const accounts = {
  mnemonic: process.env.MNEMONIC || "test test test test test test test test test test test junk",
  accountsBalance: "990000000000000000000",
  path: "m/44'/60'/0'/11",
}

module.exports = {
  abiExporter: {
    path: "./abi",
    clear: true,
    flat: true,
    // only: [],
    // except: []
  },
  defaultNetwork: "hardhat",
  etherscan: {
    apiKey: {
      polygon: process.env.POLYGONSCAN_API_KEY
    }
  },
  gasReporter: {
    coinmarketcap: process.env.COINMARKETCAP_API_KEY,
    currency: "USD",
    enabled: process.env.REPORT_GAS === "true",
    excludeContracts: ["contracts/mocks/", "contracts/libraries/"],
  },
  mocha: {
    timeout: 20000,
  },
  namedAccounts: {
    deployer: {
      default: 0, // here this will by default take the first account as deployer
      1: 0, // similarly on mainnet it will take the first account as deployer. Note though that depending on how hardhat network are configured, the account 0 on one network can be different than on another
      harmony_testnet: '0xabB6D4a1015e291b1bc71e7e56ff2c9204665b07'
    },
    alice: {
      default: 1,
      // hardhat: 0,
    },
    bob: {
      default: 2,
      // hardhat: 0,
    },
    carol: {
      default: 3,
      // hardhat: 0,
    },
    dev: {
      // Default to 4
      default: 4,
      // dev address mainnet
      // 1: "",
    },
    token_deployer: {
      default: 5
    }
  },
  networks: {
    mainnet: {
      url: `https://mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
      accounts,
      gasPrice: 120 * 1000000000,
      chainId: 1,
    },
    localhost: {
      live: false,
      saveDeployments: true,
      tags: ["local"],
    },
    hardhat: {
      // Seems to be a bug with this, even when false it complains about being unauthenticated.
      // Reported to HardHat team and fix is incoming
      // forking: {
      //   enabled: process.env.FORKING === "true",
      //   url: `https://a.api.s0.t.hmny.io`,
      // },
      // forking: {
      //   url: "https://a.api.s0.t.hmny.io",
      // },
      live: false,
      saveDeployments: true,
      tags: ["test", "local"],
    },
    ropsten: {
      url: `https://ropsten.infura.io/v3/${process.env.INFURA_API_KEY}`,
      accounts,
      chainId: 3,
      live: true,
      saveDeployments: true,
      tags: ["staging"],
    },
    testnet: {
      url: `${process.env.BSC_TESTNET_URL}`,
      chainId: 97,
      gas: 8500000, // Gas sent with each transaction (default: ~6700000)
      gasPrice: 20000000000, // 20 gwei (in wei) (default: 100 gwei)
      value: 20000000000,
      accounts
    },
    harmony_test: {
      url: "https://api.s0.b.hmny.io",
      chainId: 1666700000,
      gas: 8500000, // Gas sent with each transaction (default: ~6700000)
      gasPrice: 20000000000, // 20 gwei (in wei) (default: 100 gwei)
      value: 20000000000,
      accounts
    },
    rinkeby: {
      url: `https://rinkeby.infura.io/v3/${process.env.INFURA_API_KEY}`,
      accounts,
      chainId: 4,
      live: true,
      saveDeployments: true,
      tags: ["staging"],
    },
    goerli: {
      url: `https://goerli.infura.io/v3/${process.env.INFURA_API_KEY}`,
      accounts,
      chainId: 5,
      live: true,
      saveDeployments: true,
      tags: ["staging"],
    },
    kovan: {
      url: `https://kovan.infura.io/v3/${process.env.INFURA_API_KEY}`,
      accounts,
      chainId: 42,
      live: true,
      saveDeployments: true,
      tags: ["staging"],
    },
    moonbase: {
      url: "https://rpc.testnet.moonbeam.network",
      accounts,
      chainId: 1287,
      live: true,
      saveDeployments: true,
      tags: ["staging"],
    },
    arbitrum: {
      url: "https://kovan3.arbitrum.io/rpc",
      accounts,
      chainId: 79377087078960,
      live: true,
      saveDeployments: true,
      tags: ["staging"],
    },
    harmony: {
      // url: "https://api.harmony.one",
      url: "https://a.api.s0.t.hmny.io",
      accounts,
      chainId: 1666600000,
      live: true,
      saveDeployments: true,
      tags: ["staging"],
      timeout: 100000,
    },
    harmony_testnet: {
      url: "https://api.s0.b.hmny.io",
      accounts,
      chainId: 1666700000,
      live: true,
      saveDeployments: true,
      tags: ["staging"],
    },
    polygon: {
      url: "https://matic-mainnet-full-rpc.bwarelabs.com",
      accounts,
      chainId: 137,
      live: true,
      saveDeployments: true,
      timeout: 100000,
    },
    polygon_testnet: {
      url: "https://matic-testnet-archive-rpc.bwarelabs.com",
      accounts,
      chainId: 80001,
      live: true,
      saveDeployments: true,
      tags: ["staging"],
    },
  },
  paths: {
    artifacts: "artifacts",
    cache: "cache",
    deploy: "deploy",
    deployments: "deployments",
    imports: "imports",
    sources: "contracts",
    tests: "test",
  },
  preprocess: {
    eachLine: removeConsoleLog((bre) => bre.network.name !== "hardhat" && bre.network.name !== "localhost"),
  },
  solidity: {
    compilers: [
      {
        version: "0.6.12",
        settings: {
          optimizer: {
            enabled: true,
            runs: 10000,
          },
        },
      },
    ],
  },
  spdxLicenseIdentifier: {
    overwrite: false,
    runOnCompile: true,
  },
  tenderly: {
    project: process.env.TENDERLY_PROJECT,
    username: process.env.TENDERLY_USERNAME,
  },
  typechain: {
    outDir: "types",
    target: "ethers-v5",
  },
  watcher: {
    compile: {
      tasks: ["compile"],
      files: ["./contracts"],
      verbose: true,
    },
  },
}
