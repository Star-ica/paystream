// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./OrganizationRegistry.sol";
import "./EmployeeRegistry.sol";

/// @title PayrollStreamManager — core payroll accrual and treasury management
/// @notice Employers fund payroll pools; employees accrue salaries over time and claim on-chain.
/// @dev No automatic execution — claims and administrative actions require explicit transactions.
contract PayrollStreamManager is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────── CONSTANTS ───────────────
    address public constant NATIVE = address(0); // BOT native token
    uint256 public constant PERIOD_WEEKLY   = 7 days;
    uint256 public constant PERIOD_BIWEEKLY = 14 days;
    uint256 public constant PERIOD_MONTHLY  = 30 days;

    // ─────────────── STRUCTS ───────────────
    enum StreamStatus { Active, Paused, Terminated }

    struct PayrollStream {
        uint256 id;
        uint256 orgId;
        uint256 employeeId;
        address employeeWallet;
        address token;          // address(0) = BOT native
        uint256 salaryPerPeriod;
        uint256 periodDuration; // seconds
        uint256 startTime;
        uint256 lastClaimTime;
        uint256 totalPaid;
        StreamStatus status;
        bool exists;
    }

    // ─────────────── STATE ───────────────
    uint256 public streamCount;
    mapping(uint256 => PayrollStream) public streams;
    mapping(uint256 => uint256[]) public streamsByOrg;      // orgId → stream IDs
    mapping(uint256 => uint256) public streamByEmployee;    // employeeId → streamId (latest)

    // Treasury balances per org per token
    mapping(uint256 => mapping(address => uint256)) public orgTreasury; // orgId → token → balance
    // Total accrued but unclaimed per stream
    mapping(uint256 => uint256) public accruedBalance; // streamId → accrued

    OrganizationRegistry public immutable orgRegistry;
    EmployeeRegistry public immutable employeeRegistry;

    // ─────────────── EVENTS ───────────────
    event StreamCreated(uint256 indexed streamId, uint256 indexed orgId, uint256 indexed employeeId, address token, uint256 salary);
    event StreamStatusChanged(uint256 indexed streamId, StreamStatus status);
    event StreamSalaryUpdated(uint256 indexed streamId, uint256 newSalary, uint256 effectiveTime);
    event FundsDeposited(uint256 indexed orgId, address token, uint256 amount);
    event SalaryClaimed(uint256 indexed streamId, address indexed employee, uint256 amount, address token);
    event FundsWithdrawn(uint256 indexed orgId, address token, uint256 amount);

    // ─────────────── MODIFIERS ───────────────
    modifier onlyOrgOwner(uint256 orgId) {
        require(orgRegistry.isOrgOwner(orgId, msg.sender), "Not org owner");
        _;
    }

    constructor(address _orgRegistry, address _employeeRegistry) Ownable(msg.sender) {
        orgRegistry = OrganizationRegistry(_orgRegistry);
        employeeRegistry = EmployeeRegistry(_employeeRegistry);
    }

    // ─────────────── EMPLOYER FUNCTIONS ───────────────

    /// @notice Deposit BOT into org payroll treasury
    function depositBOT(uint256 orgId) external payable onlyOrgOwner(orgId) {
        require(msg.value > 0, "Zero deposit");
        orgTreasury[orgId][NATIVE] += msg.value;
        emit FundsDeposited(orgId, NATIVE, msg.value);
    }

    /// @notice Deposit ERC-20 token into org payroll treasury
    function depositToken(uint256 orgId, address token, uint256 amount) external onlyOrgOwner(orgId) {
        require(token != address(0), "Use depositBOT for native");
        require(amount > 0, "Zero deposit");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        orgTreasury[orgId][token] += amount;
        emit FundsDeposited(orgId, token, amount);
    }

    /// @notice Create a payroll stream for an employee
    function createStream(
        uint256 orgId,
        uint256 employeeId,
        address token,
        uint256 salaryPerPeriod,
        uint256 periodDuration,
        uint256 startTime
    ) external onlyOrgOwner(orgId) whenNotPaused returns (uint256 streamId) {
        require(salaryPerPeriod > 0, "Zero salary");
        require(periodDuration >= 1 days, "Period too short");
        require(startTime == 0 || startTime >= block.timestamp, "Invalid start");

        EmployeeRegistry.Employee memory emp = employeeRegistry.getEmployee(employeeId);
        require(emp.orgId == orgId, "Employee not in org");
        require(emp.status == EmployeeRegistry.EmployeeStatus.Active, "Employee not active");

        uint256 actualStart = startTime == 0 ? block.timestamp : startTime;
        streamId = ++streamCount;

        streams[streamId] = PayrollStream({
            id: streamId,
            orgId: orgId,
            employeeId: employeeId,
            employeeWallet: emp.wallet,
            token: token,
            salaryPerPeriod: salaryPerPeriod,
            periodDuration: periodDuration,
            startTime: actualStart,
            lastClaimTime: actualStart,
            totalPaid: 0,
            status: StreamStatus.Active,
            exists: true
        });

        streamsByOrg[orgId].push(streamId);
        streamByEmployee[employeeId] = streamId;

        emit StreamCreated(streamId, orgId, employeeId, token, salaryPerPeriod);
    }

    /// @notice Pause or resume a payroll stream
    function setStreamStatus(uint256 streamId, StreamStatus status) external {
        PayrollStream storage s = streams[streamId];
        require(s.exists, "Not found");
        require(orgRegistry.isOrgOwner(s.orgId, msg.sender), "Not org owner");
        require(status != StreamStatus.Active || s.status == StreamStatus.Paused, "Invalid transition");
        s.status = status;
        emit StreamStatusChanged(streamId, status);
    }

    /// @notice Update salary amount with effective date
    function updateSalary(uint256 streamId, uint256 newSalary) external {
        PayrollStream storage s = streams[streamId];
        require(s.exists, "Not found");
        require(orgRegistry.isOrgOwner(s.orgId, msg.sender), "Not org owner");
        require(newSalary > 0, "Zero salary");

        // Accrue existing balance before changing salary
        _accrue(streamId);
        s.salaryPerPeriod = newSalary;

        emit StreamSalaryUpdated(streamId, newSalary, block.timestamp);
    }

    /// @notice Withdraw unallocated treasury funds (not covering accrued employee balances)
    function withdrawTreasury(uint256 orgId, address token, uint256 amount)
        external nonReentrant onlyOrgOwner(orgId) {
        require(amount > 0, "Zero amount");
        uint256 available = orgTreasury[orgId][token];
        require(available >= amount, "Insufficient treasury");
        orgTreasury[orgId][token] -= amount;

        if (token == NATIVE) {
            (bool ok,) = msg.sender.call{value: amount}("");
            require(ok, "BOT transfer failed");
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
        emit FundsWithdrawn(orgId, token, amount);
    }

    // ─────────────── EMPLOYEE FUNCTIONS ───────────────

    /// @notice Accrue and claim available salary
    function claimSalary(uint256 streamId) external nonReentrant whenNotPaused {
        PayrollStream storage s = streams[streamId];
        require(s.exists, "Stream not found");
        require(s.employeeWallet == msg.sender, "Not employee");
        require(s.status == StreamStatus.Active, "Stream not active");

        _accrue(streamId);
        uint256 claimable = accruedBalance[streamId];
        require(claimable > 0, "Nothing to claim");

        // Check treasury has enough
        require(orgTreasury[s.orgId][s.token] >= claimable, "Insufficient payroll funds");

        // EFFECTS
        accruedBalance[streamId] = 0;
        s.lastClaimTime = block.timestamp;
        s.totalPaid += claimable;
        orgTreasury[s.orgId][s.token] -= claimable;

        // INTERACTIONS
        if (s.token == NATIVE) {
            (bool ok,) = msg.sender.call{value: claimable}("");
            require(ok, "BOT transfer failed");
        } else {
            IERC20(s.token).safeTransfer(msg.sender, claimable);
        }

        emit SalaryClaimed(streamId, msg.sender, claimable, s.token);
    }

    // ─────────────── VIEW FUNCTIONS ───────────────

    /// @notice Calculate currently claimable amount for a stream
    function getClaimable(uint256 streamId) external view returns (uint256) {
        PayrollStream storage s = streams[streamId];
        if (!s.exists || s.status != StreamStatus.Active) return accruedBalance[streamId];
        return accruedBalance[streamId] + _pendingAccrual(streamId);
    }

    /// @notice Get all streams for an organization
    function getStreamsByOrg(uint256 orgId) external view returns (uint256[] memory) {
        return streamsByOrg[orgId];
    }

    /// @notice Get treasury balance for an org and token
    function getTreasuryBalance(uint256 orgId, address token) external view returns (uint256) {
        return orgTreasury[orgId][token];
    }

    // ─────────────── INTERNAL ───────────────

    function _pendingAccrual(uint256 streamId) internal view returns (uint256) {
        PayrollStream storage s = streams[streamId];
        if (s.status != StreamStatus.Active) return 0;
        if (block.timestamp <= s.lastClaimTime) return 0;
        uint256 elapsed = block.timestamp - s.lastClaimTime;
        // Proportional accrual: salaryPerPeriod * elapsed / periodDuration
        return (s.salaryPerPeriod * elapsed) / s.periodDuration;
    }

    function _accrue(uint256 streamId) internal {
        uint256 pending = _pendingAccrual(streamId);
        if (pending > 0) {
            accruedBalance[streamId] += pending;
            streams[streamId].lastClaimTime = block.timestamp;
        }
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    receive() external payable {}
}
