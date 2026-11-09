// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IArcleFXCore {
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function OPERATOR_ROLE() external view returns (bytes32);
    function FEE_MANAGER_ROLE() external view returns (bytes32);
}

/**
 * @title  TransferRoles
 * @notice Grants DEFAULT_ADMIN_ROLE, OPERATOR_ROLE, and FEE_MANAGER_ROLE to the
 *         Gnosis Safe multisig, then revokes them from the deployer.
 *
 * Usage (run for each network):
 *
 *   Ethereum:
 *     forge script script/TransferRoles.s.sol --rpc-url $ETH_RPC_URL \
 *       --private-key $DEPLOYER_PRIVATE_KEY --broadcast -vvv
 *
 *   Arbitrum:
 *     forge script script/TransferRoles.s.sol --rpc-url $ARB_RPC_URL \
 *       --private-key $DEPLOYER_PRIVATE_KEY --broadcast -vvv
 *
 *   Base:
 *     forge script script/TransferRoles.s.sol --rpc-url $BASE_RPC_URL \
 *       --private-key $DEPLOYER_PRIVATE_KEY --broadcast -vvv
 *
 *   Arc:
 *     forge script script/TransferRoles.s.sol --rpc-url $ARC_RPC_URL \
 *       --private-key $DEPLOYER_PRIVATE_KEY --broadcast -vvv
 *
 * ⚠️  IMPORTANT: Verify Safe has DEFAULT_ADMIN_ROLE BEFORE revoking deployer.
 */
contract TransferRoles is Script {

    // ── Gnosis Safe (same address on all networks) ────────────
    address constant SAFE    = 0x80de28827B6774bd4C9e04D15D72632A97C2f490;

    // ── ArcleFXCore per-network addresses ────────────────────
    // Script detects the network automatically via block.chainid.
    function contractAddress() internal view returns (address) {
        if (block.chainid == 1)     return 0x0C4618fC1cE49C0b4b4D3328799c1248d577c257; // Ethereum
        if (block.chainid == 42161) return 0x0C4618fC1cE49C0b4b4D3328799c1248d577c257; // Arbitrum
        if (block.chainid == 8453)  return 0x6beD8B11b39Ed27d402De6728654B10CC25a39F5; // Base
        if (block.chainid == 5042)  return 0x0C4618fC1cE49C0b4b4D3328799c1248d577c257; // Arc
        revert("Unsupported chain");
    }

    function run() external {
        address core     = contractAddress();
        IArcleFXCore fx  = IArcleFXCore(core);

        bytes32 ADMIN    = fx.DEFAULT_ADMIN_ROLE();
        bytes32 OPERATOR = fx.OPERATOR_ROLE();
        bytes32 FEE_MGR  = fx.FEE_MANAGER_ROLE();

        address deployer = msg.sender;

        console.log("=== TransferRoles ===");
        console.log("Chain ID  :", block.chainid);
        console.log("Contract  :", core);
        console.log("Deployer  :", deployer);
        console.log("Safe      :", SAFE);

        // ── Pre-flight checks ────────────────────────────────
        require(fx.hasRole(ADMIN,    deployer), "Deployer missing DEFAULT_ADMIN_ROLE");
        require(fx.hasRole(OPERATOR, deployer), "Deployer missing OPERATOR_ROLE");

        vm.startBroadcast();

        // 1. Grant all roles to Safe
        fx.grantRole(ADMIN,    SAFE);
        fx.grantRole(OPERATOR, SAFE);
        fx.grantRole(FEE_MGR,  SAFE);
        console.log("Roles granted to Safe");

        // 2. Revoke all roles from deployer
        //    DEFAULT_ADMIN_ROLE is self-managed — Safe must call renounceRole
        //    or the current admin revokes; deployer still holds ADMIN here so revoke directly.
        fx.revokeRole(FEE_MGR,  deployer);
        fx.revokeRole(OPERATOR, deployer);
        fx.revokeRole(ADMIN,    deployer); // Must be last — loses admin after this

        vm.stopBroadcast();

        // ── Post-flight verification ──────────────────────────
        require(fx.hasRole(ADMIN,    SAFE),     "Safe missing DEFAULT_ADMIN_ROLE");
        require(fx.hasRole(OPERATOR, SAFE),     "Safe missing OPERATOR_ROLE");
        require(fx.hasRole(FEE_MGR,  SAFE),     "Safe missing FEE_MANAGER_ROLE");
        require(!fx.hasRole(ADMIN,    deployer), "Deployer still has DEFAULT_ADMIN_ROLE");
        require(!fx.hasRole(OPERATOR, deployer), "Deployer still has OPERATOR_ROLE");

        console.log("=== SUCCESS: All roles transferred to Safe ===");
    }
}
