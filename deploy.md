# PayStream — Deployment Guide

## Prerequisites
- Node.js >= 18, npm >= 9, funded deployer wallet

## 1. Setup
```bash
mkdir paystream-deploy && cd paystream-deploy
npm init -y
npm install --save-dev hardhat @nomicfoundation/hardhat-toolbox @nomicfoundation/hardhat-network-helpers
npm install @openzeppelin/contracts dotenv
npx hardhat init
```

## 2. `.env`
```env
PRIVATE_KEY=0xyour_key
BOT_RPC_URL=https://rpc.botchain.tg
EXPLORER_API_KEY=your_key
USDT_ADDRESS=0xYourUSDTContractOnBotChain
```

## 3. `hardhat.config.js`
```js
require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();
module.exports = {
  solidity: { version: "0.8.20", settings: { optimizer: { enabled: true, runs: 200 } } },
  networks: { botchain: { url: process.env.BOT_RPC_URL, chainId: 677, accounts: [process.env.PRIVATE_KEY] } },
  etherscan: {
    apiKey: { botchain: process.env.EXPLORER_API_KEY || "none" },
    customChains: [{ network: "botchain", chainId: 677,
      urls: { apiURL: "https://explorer.botchain.tg/api", browserURL: "https://explorer.botchain.tg" } }]
  }
};
```

## 4. Deploy Script (`scripts/deploy.js`)
```js
const { ethers } = require("hardhat");
const fs = require("fs");

async function main() {
  const [deployer] = await ethers.getSigners();

  const OrgReg = await ethers.getContractFactory("OrganizationRegistry");
  const orgReg = await OrgReg.deploy(); await orgReg.waitForDeployment();
  console.log("OrganizationRegistry:", await orgReg.getAddress());

  const EmpReg = await ethers.getContractFactory("EmployeeRegistry");
  const empReg = await EmpReg.deploy(); await empReg.waitForDeployment();
  console.log("EmployeeRegistry:", await empReg.getAddress());

  const PayMgr = await ethers.getContractFactory("PayrollStreamManager");
  const payMgr = await PayMgr.deploy(await orgReg.getAddress(), await empReg.getAddress());
  await payMgr.waitForDeployment();
  console.log("PayrollStreamManager:", await payMgr.getAddress());

  // Authorize PayrollStreamManager to call EmployeeRegistry
  await (await empReg.setPayrollManager(await payMgr.getAddress())).wait();
  console.log("PayrollStreamManager authorized on EmployeeRegistry");

  const addrs = {
    OrganizationRegistry: await orgReg.getAddress(),
    EmployeeRegistry: await empReg.getAddress(),
    PayrollStreamManager: await payMgr.getAddress()
  };
  fs.writeFileSync("deployed-addresses.json", JSON.stringify(addrs, null, 2));
}

main().catch(e => { console.error(e); process.exit(1); });
```

```bash
npx hardhat compile
npx hardhat run scripts/deploy.js --network botchain
```

## 5. Verify
```bash
npx hardhat verify --network botchain <ORG_REGISTRY>
npx hardhat verify --network botchain <EMP_REGISTRY>
npx hardhat verify --network botchain <PAYROLL_MGR> "<ORG_REGISTRY>" "<EMP_REGISTRY>"
```

## 6. Frontend Config
In `index.html`, update `CONFIG.contracts` with deployed addresses and set `DEMO = false`.
Set `CONFIG.usdtAddress` to the USDT contract address on BOT Chain.

## 7. Post-Deploy Checklist
- [ ] All 3 contracts verified
- [ ] PayrollStreamManager authorized on EmployeeRegistry
- [ ] Create test org, add employee, create stream
- [ ] Deposit BOT to treasury
- [ ] Advance time (testnet) and claim salary
- [ ] Test USDT stream with mock token
- [ ] Test pause/unpause
- [ ] Test salary update midstream
- [ ] Verify treasury withdrawal works
