// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EmployeeRegistry — manages employee records per organization
contract EmployeeRegistry is Ownable {

    enum EmployeeStatus { Active, Paused, Terminated }

    struct Employee {
        uint256 id;
        uint256 orgId;
        address wallet;
        string name;
        EmployeeStatus status;
        bool exists;
        uint256 addedAt;
    }

    uint256 public employeeCount;
    mapping(uint256 => Employee) public employees;
    mapping(uint256 => uint256[]) public employeesByOrg;        // orgId → employee IDs
    mapping(address => uint256[]) public employeesByWallet;     // wallet → employee IDs

    address public payrollManager; // authorized to update status

    event EmployeeAdded(uint256 indexed employeeId, uint256 indexed orgId, address wallet, string name);
    event EmployeeStatusChanged(uint256 indexed employeeId, EmployeeStatus status);

    modifier onlyPayrollManager() {
        require(msg.sender == payrollManager || msg.sender == owner(), "Not authorized");
        _;
    }

    constructor() Ownable(msg.sender) {}

    function setPayrollManager(address _pm) external onlyOwner {
        payrollManager = _pm;
    }

    /// @notice Add a new employee to an organization
    function addEmployee(uint256 orgId, address wallet, string calldata name)
        external onlyPayrollManager returns (uint256 employeeId) {
        require(wallet != address(0), "Invalid wallet");
        require(bytes(name).length > 0 && bytes(name).length <= 200, "Invalid name");

        employeeId = ++employeeCount;
        employees[employeeId] = Employee({
            id: employeeId,
            orgId: orgId,
            wallet: wallet,
            name: name,
            status: EmployeeStatus.Active,
            exists: true,
            addedAt: block.timestamp
        });

        employeesByOrg[orgId].push(employeeId);
        employeesByWallet[wallet].push(employeeId);

        emit EmployeeAdded(employeeId, orgId, wallet, name);
    }

    /// @notice Update employee status
    function setEmployeeStatus(uint256 employeeId, EmployeeStatus status) external onlyPayrollManager {
        require(employees[employeeId].exists, "Not found");
        employees[employeeId].status = status;
        emit EmployeeStatusChanged(employeeId, status);
    }

    function getEmployee(uint256 employeeId) external view returns (Employee memory) {
        require(employees[employeeId].exists, "Not found");
        return employees[employeeId];
    }

    function getEmployeesByOrg(uint256 orgId) external view returns (uint256[] memory) {
        return employeesByOrg[orgId];
    }

    function getEmployeesByWallet(address wallet) external view returns (uint256[] memory) {
        return employeesByWallet[wallet];
    }
}
