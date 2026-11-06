// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console}    from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ArcleFXCore}        from "../contracts/Arcle FX Core.sol";

/**
 * @title  Deploy
 * @notice Deploys ArcleFXCore + TimelockController on all 4 supported networks
 *         using CREATE2.  The same salt produces the SAME contract address on
 *         every chain, which lets the App Kit SDK use a single recipient address
 *         everywhere.
 *
 * ─── Architecture ─────────────────────────────────────────────────────────────
 *   TimelockController (2-day min delay)
 *     └─ holds FEE_MANAGER_ROLE on ArcleFXCore
 *        → Any setFeeRecipients / distribute call must pass through
 *          the timelock, giving a mandatory 48-hour public window before
 *          any fee configuration change takes effect.
 *
 * ─── Supported Networks ───────────────────────────────────────────────────────
 *   Chain            │ Chain ID  │ Role
 *   ─────────────────┼───────────┼──────────────────────────────────────────
 *   Arc Testnet      │ 5042002   │ Swap fees + primary DApp chain
 *   Ethereum Sepolia │ 11155111  │ Bridge source → fee collected here
 *   Arbitrum Sepolia │ 421614    │ Bridge source → fee collected here
 *   Base Sepolia     │ 84532     │ Bridge source → fee collected here
 *
 * ─── Supported Tokens ─────────────────────────────────────────────────────────
 *   USDC | EURC | cirBTC
 *
 * ─── Pre-deploy ───────────────────────────────────────────────────────────────
 *   1. Copy .env.example → .env and fill in all values
 *   2. Ensure DEPLOYER_PRIVATE_KEY, PROTOCOL_FEE_RECIPIENT, DEV_FEE_RECIPIENT are set
 *
 * ─── Deploy Commands ──────────────────────────────────────────────────────────
 *   forge script script/Deploy.s.sol:Deploy --rpc-url arcTestnet      --broadcast --verify -vvvv
 *   forge script script/Deploy.s.sol:Deploy --rpc-url ethSepolia      --broadcast --verify -vvvv
 *   forge script script/Deploy.s.sol:Deploy --rpc-url arbitrumSepolia --broadcast --verify -vvvv
 *   forge script script/Deploy.s.sol:Deploy --rpc-url baseSepolia     --broadcast --verify -vvvv
 */
contract Deploy is Script {

    // CREATE2 salt — same salt = same address on every chain
    bytes32 constant SALT = keccak256("ARCLEFX_V1");

    // TimelockController minimum delay: 2 days (172 800 seconds)
    uint256 constant TIMELOCK_DELAY = 2 days;

    // ─── Chain metadata ────────────────────────────────────────────────────────

    struct ChainInfo {
        string name;
        string explorer;
    }

    function _chainInfo() internal view returns (ChainInfo memory info) {
        uint256 id = block.chainid;
        if      (id == 5042002)  return ChainInfo("Arc Testnet",     "https://testnet.arcscan.app/address/");
        else if (id == 11155111) return ChainInfo("Ethereum Sepolia", "https://sepolia.etherscan.io/address/");
        else if (id == 421614)   return ChainInfo("Arbitrum Sepolia", "https://sepolia.arbiscan.io/address/");
        else if (id == 84532)    return ChainInfo("Base Sepolia",     "https://sepolia.basescan.org/address/");
        else                     return ChainInfo("Unknown",          "");
    }

    // ─── Run ───────────────────────────────────────────────────────────────────

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        // Fee recipients — fall back to deployer if not set
        address protocolRecipient  = vm.envOr("PROTOCOL_FEE_RECIPIENT", deployer);
        address developerRecipient = vm.envOr("DEV_FEE_RECIPIENT",      deployer);

        ChainInfo memory chain = _chainInfo();

        console.log("=================================================");
        console.log("Network    :", chain.name);
        console.log("Chain ID   :", block.chainid);
        console.log("Deployer   :", deployer);
        console.log("Protocol   :", protocolRecipient);
        console.log("Developer  :", developerRecipient);
        console.log("=================================================");

        // 80% protocol, 20% developer
        ArcleFXCore.FeeRecipient[] memory recipients = new ArcleFXCore.FeeRecipient[](2);
        recipients[0] = ArcleFXCore.FeeRecipient({ account: protocolRecipient,  shareBps: 8_000 });
        recipients[1] = ArcleFXCore.FeeRecipient({ account: developerRecipient, shareBps: 2_000 });

        vm.startBroadcast(deployerKey);

        // ── 1. Deploy TimelockController ──────────────────────────────────────
        //    proposers  = [deployer]  (can schedule delayed calls)
        //    executors  = [deployer]  (can execute after the delay)
        //    admin      = address(0) = no one; the timelock governs itself
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = deployer;
        executors[0] = deployer;

        TimelockController timelock = new TimelockController(
            TIMELOCK_DELAY,
            proposers,
            executors,
            address(0)   // self-administered
        );

        // ── 2. CREATE2 deploy ArcleFXCore ─────────────────────────────────────
        //    Constructor grants deployer DEFAULT_ADMIN_ROLE, OPERATOR_ROLE,
        //    and FEE_MANAGER_ROLE.  We immediately transfer FEE_MANAGER_ROLE
        //    to the timelock so all fee management is time-locked.
        ArcleFXCore core = new ArcleFXCore{salt: SALT}(deployer, recipients);

        // ── 3. Wire FEE_MANAGER_ROLE to the TimelockController ────────────────
        core.grantRole(core.FEE_MANAGER_ROLE(), address(timelock));
        core.revokeRole(core.FEE_MANAGER_ROLE(), deployer);

        vm.stopBroadcast();

        console.log("");
        console.log("TimelockController deployed:", address(timelock));
        console.log("  Min delay               :", TIMELOCK_DELAY, "seconds (2 days)");
        console.log("ArcleFXCore deployed       :", address(core));
        console.log("Explorer (Core)            :", string.concat(chain.explorer, vm.toString(address(core))));
        console.log("");
        console.log("FEE_MANAGER_ROLE           : TimelockController");
        console.log("OPERATOR_ROLE              : deployer");
        console.log("DEFAULT_ADMIN_ROLE          : deployer");
        console.log("");
        console.log("App Kit SDK config (use ArcleFXCore address on all 4 chains):");
        console.log("  bridgeFee:         { recipient: \"<core>\", basisPoints: 5  }");
        console.log("  swapFee:           { recipient: \"<core>\", basisPoints: 30 }");
        console.log("  unifiedBalanceFee: { recipient: \"<core>\", basisPoints: 10 }");
        console.log("");
        console.log("Supported tokens  : USDC | EURC | cirBTC");
        console.log("Supported networks: Arc | Ethereum | Arbitrum | Base");
    }
}
