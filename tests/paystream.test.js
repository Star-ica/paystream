const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("PayStream", function () {
  let owner, employer, employee1, employee2, other;
  let orgRegistry, employeeRegistry, payrollManager;
  let mockToken;
  let orgId, employeeId1, streamId;

  const WEEKLY = 7 * 24 * 3600;
  const SALARY = ethers.parseEther("100"); // 100 BOT/week

  beforeEach(async function () {
    [owner, employer, employee1, employee2, other] = await ethers.getSigners();

    // Deploy contracts
    const OrgRegistry = await ethers.getContractFactory("OrganizationRegistry");
    orgRegistry = await OrgRegistry.deploy();
    await orgRegistry.waitForDeployment();

    const EmpRegistry = await ethers.getContractFactory("EmployeeRegistry");
    employeeRegistry = await EmpRegistry.deploy();
    await employeeRegistry.waitForDeployment();

    const PayrollMgr = await ethers.getContractFactory("PayrollStreamManager");
    payrollManager = await PayrollMgr.deploy(
      await orgRegistry.getAddress(), await employeeRegistry.getAddress()
    );
    await payrollManager.waitForDeployment();

    // Authorize PayrollStreamManager on EmployeeRegistry
    await employeeRegistry.setPayrollManager(await payrollManager.getAddress());

    // Mock ERC-20
    const MockToken = await ethers.getContractFactory("MockERC20");
    mockToken = await MockToken.deploy("USDT", "USDT", ethers.parseEther("1000000"));
    await mockToken.waitForDeployment();

    // Setup: create org
    const tx = await orgRegistry.connect(employer).createOrganization("Acme Corp", "Test org");
    const receipt = await tx.wait();
    orgId = 1n;

    // Add employee via payrollManager owner workaround: grant employer ability
    // In production, employer calls via org ownership. Here we simulate.
    await employeeRegistry.connect(owner).setPayrollManager(employer.address);
    const addTx = await employeeRegistry.connect(employer).addEmployee(orgId, employee1.address, "Alice");
    await addTx.wait();
    employeeId1 = 1n;
    await employeeRegistry.connect(owner).setPayrollManager(await payrollManager.getAddress());
  });

  // ──────────────────────────────────────────────
  // ORGANIZATION
  // ──────────────────────────────────────────────
  describe("Organization", function () {
    it("creates an organization", async function () {
      const org = await orgRegistry.getOrganization(orgId);
      expect(org.name).to.equal("Acme Corp");
      expect(org.owner).to.equal(employer.address);
    });
    it("non-owner cannot call org-owner functions", async function () {
      await expect(payrollManager.connect(other).depositBOT(orgId, { value: ethers.parseEther("1") }))
        .to.be.revertedWith("Not org owner");
    });
  });

  // ──────────────────────────────────────────────
  // PAYROLL STREAM
  // ──────────────────────────────────────────────
  describe("Stream Creation", function () {
    beforeEach(async function () {
      // Deposit funds
      await payrollManager.connect(employer).depositBOT(orgId, { value: ethers.parseEther("1000") });
    });

    it("creates a stream", async function () {
      const tx = await payrollManager.connect(employer).createStream(
        orgId, employeeId1, ethers.ZeroAddress, SALARY, WEEKLY, 0
      );
      await tx.wait();
      streamId = 1n;
      const s = await payrollManager.streams(streamId);
      expect(s.salaryPerPeriod).to.equal(SALARY);
      expect(s.employeeWallet).to.equal(employee1.address);
    });

    it("reverts on zero salary", async function () {
      await expect(payrollManager.connect(employer).createStream(
        orgId, employeeId1, ethers.ZeroAddress, 0, WEEKLY, 0
      )).to.be.revertedWith("Zero salary");
    });
  });

  // ──────────────────────────────────────────────
  // SALARY CLAIM
  // ──────────────────────────────────────────────
  describe("Salary Claiming", function () {
    beforeEach(async function () {
      await payrollManager.connect(employer).depositBOT(orgId, { value: ethers.parseEther("1000") });
      await payrollManager.connect(employer).createStream(
        orgId, employeeId1, ethers.ZeroAddress, SALARY, WEEKLY, 0
      );
      streamId = 1n;
    });

    it("employee has nothing to claim immediately", async function () {
      const claimable = await payrollManager.getClaimable(streamId);
      expect(claimable).to.equal(0n);
    });

    it("accrues salary proportionally over time", async function () {
      await time.increase(WEEKLY / 2); // half a week
      const claimable = await payrollManager.getClaimable(streamId);
      // Should be approximately SALARY/2
      expect(claimable).to.be.closeTo(SALARY / 2n, ethers.parseEther("1"));
    });

    it("employee can claim after one full period", async function () {
      await time.increase(WEEKLY);
      const before = await ethers.provider.getBalance(employee1.address);
      const tx = await payrollManager.connect(employee1).claimSalary(streamId);
      const receipt = await tx.wait();
      const gas = receipt.gasUsed * receipt.gasPrice;
      const after = await ethers.provider.getBalance(employee1.address);
      expect(after - before + gas).to.be.closeTo(SALARY, ethers.parseEther("1"));
    });

    it("non-employee cannot claim", async function () {
      await time.increase(WEEKLY);
      await expect(payrollManager.connect(other).claimSalary(streamId))
        .to.be.revertedWith("Not employee");
    });

    it("cannot claim from paused stream", async function () {
      await payrollManager.connect(employer).setStreamStatus(streamId, 1); // Paused
      await time.increase(WEEKLY);
      await expect(payrollManager.connect(employee1).claimSalary(streamId))
        .to.be.revertedWith("Stream not active");
    });

    it("reverts when treasury is empty", async function () {
      await payrollManager.connect(employer).withdrawTreasury(orgId, ethers.ZeroAddress, ethers.parseEther("1000"));
      await time.increase(WEEKLY);
      await expect(payrollManager.connect(employee1).claimSalary(streamId))
        .to.be.revertedWith("Insufficient payroll funds");
    });
  });

  // ──────────────────────────────────────────────
  // ERC-20 PAYROLL
  // ──────────────────────────────────────────────
  describe("ERC-20 Payroll", function () {
    let tokenStreamId;

    beforeEach(async function () {
      const amount = ethers.parseEther("5000");
      await mockToken.connect(owner).transfer(employer.address, amount);
      await mockToken.connect(employer).approve(await payrollManager.getAddress(), amount);
      await payrollManager.connect(employer).depositToken(orgId, await mockToken.getAddress(), amount);

      await payrollManager.connect(employer).createStream(
        orgId, employeeId1, await mockToken.getAddress(), ethers.parseEther("500"), WEEKLY * 4, 0
      );
      tokenStreamId = 2n;
    });

    it("employee claims USDT salary", async function () {
      await time.increase(WEEKLY * 4);
      await payrollManager.connect(employee1).claimSalary(tokenStreamId);
      const bal = await mockToken.balanceOf(employee1.address);
      expect(bal).to.be.closeTo(ethers.parseEther("500"), ethers.parseEther("5"));
    });
  });

  // ──────────────────────────────────────────────
  // SALARY UPDATE
  // ──────────────────────────────────────────────
  describe("Salary Update", function () {
    beforeEach(async function () {
      await payrollManager.connect(employer).depositBOT(orgId, { value: ethers.parseEther("1000") });
      await payrollManager.connect(employer).createStream(
        orgId, employeeId1, ethers.ZeroAddress, SALARY, WEEKLY, 0
      );
      streamId = 1n;
    });

    it("employer can update salary", async function () {
      await time.increase(WEEKLY / 2);
      const newSalary = ethers.parseEther("200");
      await payrollManager.connect(employer).updateSalary(streamId, newSalary);
      const s = await payrollManager.streams(streamId);
      expect(s.salaryPerPeriod).to.equal(newSalary);
    });

    it("accrued balance preserved after salary update", async function () {
      await time.increase(WEEKLY / 2);
      await payrollManager.connect(employer).updateSalary(streamId, ethers.parseEther("200"));
      const claimable = await payrollManager.getClaimable(streamId);
      expect(claimable).to.be.gte(ethers.parseEther("49")); // approx half of old salary
    });
  });

  // ──────────────────────────────────────────────
  // TREASURY
  // ──────────────────────────────────────────────
  describe("Treasury", function () {
    it("employer can deposit and check balance", async function () {
      await payrollManager.connect(employer).depositBOT(orgId, { value: ethers.parseEther("500") });
      const bal = await payrollManager.getTreasuryBalance(orgId, ethers.ZeroAddress);
      expect(bal).to.equal(ethers.parseEther("500"));
    });

    it("employer can withdraw unallocated funds", async function () {
      await payrollManager.connect(employer).depositBOT(orgId, { value: ethers.parseEther("500") });
      await payrollManager.connect(employer).withdrawTreasury(orgId, ethers.ZeroAddress, ethers.parseEther("200"));
      const bal = await payrollManager.getTreasuryBalance(orgId, ethers.ZeroAddress);
      expect(bal).to.equal(ethers.parseEther("300"));
    });

    it("non-owner cannot withdraw", async function () {
      await payrollManager.connect(employer).depositBOT(orgId, { value: ethers.parseEther("500") });
      await expect(payrollManager.connect(other).withdrawTreasury(orgId, ethers.ZeroAddress, ethers.parseEther("100")))
        .to.be.revertedWith("Not org owner");
    });
  });
});

// ──────────────────────────────────────────────
// MOCK ERC20 (for testing)
// ──────────────────────────────────────────────
// Add to contracts/MockERC20.sol for tests only
