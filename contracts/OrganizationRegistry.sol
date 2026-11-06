// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title OrganizationRegistry — manages employer organizations for PayStream
contract OrganizationRegistry is Ownable {

    struct Organization {
        uint256 id;
        address owner;
        string name;
        string description;
        bool active;
        bool exists;
        uint256 createdAt;
    }

    uint256 public orgCount;
    mapping(uint256 => Organization) public organizations;
    mapping(address => uint256[]) public orgsByOwner;
    mapping(address => uint256) public primaryOrgByOwner; // convenience: first org per address

    event OrganizationCreated(uint256 indexed orgId, address indexed owner, string name);
    event OrganizationUpdated(uint256 indexed orgId, string name);
    event OrganizationDeactivated(uint256 indexed orgId);

    constructor() Ownable(msg.sender) {}

    /// @notice Create a new employer organization
    function createOrganization(string calldata name, string calldata description)
        external returns (uint256 orgId) {
        require(bytes(name).length > 0 && bytes(name).length <= 200, "Invalid name");

        orgId = ++orgCount;
        organizations[orgId] = Organization({
            id: orgId,
            owner: msg.sender,
            name: name,
            description: description,
            active: true,
            exists: true,
            createdAt: block.timestamp
        });

        orgsByOwner[msg.sender].push(orgId);
        if (primaryOrgByOwner[msg.sender] == 0) primaryOrgByOwner[msg.sender] = orgId;

        emit OrganizationCreated(orgId, msg.sender, name);
    }

    /// @notice Update organization metadata
    function updateOrganization(uint256 orgId, string calldata name, string calldata description) external {
        Organization storage org = organizations[orgId];
        require(org.exists, "Not found");
        require(org.owner == msg.sender, "Not owner");
        org.name = name;
        org.description = description;
        emit OrganizationUpdated(orgId, name);
    }

    function getOrganization(uint256 orgId) external view returns (Organization memory) {
        require(organizations[orgId].exists, "Not found");
        return organizations[orgId];
    }

    function getOrgsByOwner(address owner) external view returns (uint256[] memory) {
        return orgsByOwner[owner];
    }

    function isOrgOwner(uint256 orgId, address addr) external view returns (bool) {
        return organizations[orgId].exists && organizations[orgId].owner == addr;
    }
}
