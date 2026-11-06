// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl}  from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable}        from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20}       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title  Arcle FX Core
 * @author Arcle FX Protocol
 *
 * @notice On-chain fee vault and distributor for the Arcle FX.
 *
 * @dev    The Circle App Kit SDK handles all bridge and swap execution.
 *         This contract only:
 *           1. Acts as `developerFee.recipient` in the App Kit config
 *           2. Tracks fees by operation type and token
 *           3. Distributes collected fees to configured recipients
 *
 *         App Kit SDK config:
 *           developerFee: {
 *             bridgeFee:         { recipient: ARCLE_FX_CORE, basisPoints: 5  },
 *             swapFee:           { recipient: ARCLE_FX_CORE, basisPoints: 30 },
 *             unifiedBalanceFee: { recipient: ARCLE_FX_CORE, basisPoints: 10 },
 *           }
 *
 *         Security model:
 *           1. `distribute` is gated by `whenNotPaused` so an emergency pause
 *              halts both fee registration and distribution atomically.
 *           2. `setFeeRecipients` should be called through a TimelockController
 *              so that any recipient change is subject to a mandatory delay and
 *              is publicly visible before it takes effect.
 *
 * Supported tokens   : USDC | EURC | cirBTC
 * Supported networks : Arc Testnet (5042002) | Ethereum Sepolia (11155111) | Arbitrum Sepolia (421614) | Base Sepolia (84532)
 */
contract ArcleFXCore is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================
    //                           ROLES
    // ============================================================

    bytes32 public constant OPERATOR_ROLE    = keccak256("OPERATOR_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    // ============================================================
    //                     TYPES & STORAGE
    // ============================================================

    enum OpType { Bridge, Swap, UnifiedBalance }

    struct FeeRecipient {
        address account;  // Address to receive fees
        uint16  shareBps; // Share out of 10_000 (e.g. 8000 = 80%)
    }

    FeeRecipient[4] public feeRecipients;
    uint8           public recipientCount;

    /// token → OpType → cumulative fees received
    mapping(address => mapping(OpType => uint256)) public feesReceived;

    /// token → cumulative fees distributed
    mapping(address => uint256) public feesWithdrawn;

    // ============================================================
    //                          EVENTS
    // ============================================================

    event FeeReceived(address indexed token, OpType indexed opType, address indexed sender, uint256 amount);
    event FeeDistributed(address indexed token, address indexed recipient, uint256 amount);
    event FeeRecipientsUpdated(FeeRecipient[4] recipients, uint8 count);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
    event EmergencyNativeWithdraw(address indexed to, uint256 amount);

    // ============================================================
    //                       CUSTOM ERRORS
    // ============================================================

    error ZeroAddress();
    error ZeroAmount();
    error InvalidShares();
    error TooManyRecipients();
    error NothingToDistribute();
    error NativeTransferFailed();
    error AccountingOverflow();

    // ============================================================
    //                        CONSTRUCTOR
    // ============================================================

    constructor(address admin, FeeRecipient[] memory initialRecipients) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE,      admin);
        _grantRole(FEE_MANAGER_ROLE,   admin);
        _setFeeRecipients(initialRecipients);
    }

    // ============================================================
    //                   FEE RECEPTION & ACCOUNTING
    // ============================================================

    /**
     * @notice Register a fee received from the App Kit SDK.
     *         The SDK sends fees as plain ERC-20 transfers to this address.
     *         Must be called by OPERATOR_ROLE after each SDK transfer to
     *         record the accounting on-chain.
     *
     * @dev    Guards against accounting inflation: cumulative tracked amount
     *         cannot exceed real historical inflows (balance + already distributed).
     *
     * @param token   ERC-20 token address (USDC, EURC, cirBTC)
     * @param amount  Fee amount to register
     * @param opType  Operation that generated the fee (Bridge / Swap / UnifiedBalance)
     */
    function registerFee(address token, uint256 amount, OpType opType)
        external
        whenNotPaused
        onlyRole(OPERATOR_ROLE)
    {
        if (token  == address(0)) revert ZeroAddress();
        if (amount == 0)          revert ZeroAmount();

        uint256 realInflows    = IERC20(token).balanceOf(address(this)) + feesWithdrawn[token];
        uint256 alreadyTracked = totalFeesReceived(token);
        if (alreadyTracked + amount > realInflows) revert AccountingOverflow();

        feesReceived[token][opType] += amount;
        emit FeeReceived(token, opType, msg.sender, amount);
    }

    // ============================================================
    //                      FEE DISTRIBUTION
    // ============================================================

    /**
     * @notice Distribute the full token balance to all fee recipients.
     *         The last recipient receives any remaining dust to prevent
     *         rounding leftovers from accumulating in the contract.
     *
     * @dev    Guarded by `whenNotPaused` — an emergency pause halts both
     *         fee registration and distribution atomically, giving the admin
     *         full control to freeze all fund movement in a single call.
     *
     * @param token  ERC-20 token to distribute (e.g. USDC)
     */
    function distribute(address token)
        external
        nonReentrant
        whenNotPaused
        onlyRole(FEE_MANAGER_ROLE)
    {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert NothingToDistribute();

        uint8   count            = recipientCount;
        uint256 distributedTotal = 0;

        for (uint8 i; i < count; ++i) {
            FeeRecipient memory r = feeRecipients[i];

            // Last recipient gets exact remainder — eliminates rounding dust
            uint256 share = (i == count - 1)
                ? balance - distributedTotal
                : (balance * r.shareBps) / 10_000;

            if (share == 0) continue;

            distributedTotal     += share;
            feesWithdrawn[token] += share;
            IERC20(token).safeTransfer(r.account, share);
            emit FeeDistributed(token, r.account, share);
        }
    }

    // ============================================================
    //                    EMERGENCY WITHDRAWALS
    // ============================================================

    /**
     * @notice Emergency ERC-20 withdrawal — only DEFAULT_ADMIN_ROLE.
     */
    function emergencyWithdraw(address token, address to, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (token  == address(0)) revert ZeroAddress();
        if (to     == address(0)) revert ZeroAddress();
        if (amount == 0)          revert ZeroAmount();
        feesWithdrawn[token] += amount;
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }

    /**
     * @notice Emergency native gas rescue (ETH on Ethereum/Arbitrum/Base).
     *         Not needed on Arc Testnet (native gas = USDC) but included
     *         as a safety net for the other supported chains.
     */
    function emergencyWithdrawNative(address payable to, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (to     == address(0)) revert ZeroAddress();
        if (amount == 0)          revert ZeroAmount();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit EmergencyNativeWithdraw(to, amount);
    }

    // ============================================================
    //                  CONFIGURATION & CONTROLS
    // ============================================================

    /**
     * @notice Update fee recipients. Shares must sum to exactly 10_000.
     *
     * @dev    In production this function should be called exclusively through
     *         the TimelockController so that any recipient change is subject to
     *         a mandatory delay and is publicly visible before it takes effect.
     */
    function setFeeRecipients(FeeRecipient[] calldata recipients)
        external
        onlyRole(FEE_MANAGER_ROLE)
    {
        _setFeeRecipients(recipients);
    }

    /// @notice Pause fee registration and distribution in case of emergency.
    function pause()   external onlyRole(OPERATOR_ROLE) { _pause(); }

    /// @notice Resume normal operations.
    function unpause() external onlyRole(OPERATOR_ROLE) { _unpause(); }

    // ============================================================
    //                        VIEW HELPERS
    // ============================================================

    /**
     * @notice Total fees received for a token across all operation types.
     * @dev    Declared `public` so internal accounting checks can call it.
     */
    function totalFeesReceived(address token) public view returns (uint256 total) {
        total  = feesReceived[token][OpType.Bridge];
        total += feesReceived[token][OpType.Swap];
        total += feesReceived[token][OpType.UnifiedBalance];
    }

    /// @notice Returns the current fee recipient configuration.
    function getFeeRecipients() external view returns (FeeRecipient[4] memory, uint8) {
        return (feeRecipients, recipientCount);
    }

    // ============================================================
    //                       INTERNAL LOGIC
    // ============================================================

    function _setFeeRecipients(FeeRecipient[] memory recipients) internal {
        if (recipients.length == 0 || recipients.length > 4) revert TooManyRecipients();
        uint8 len = uint8(recipients.length);

        uint256 totalShares;
        for (uint8 i; i < len; ++i) {
            if (recipients[i].account  == address(0)) revert ZeroAddress();
            if (recipients[i].shareBps == 0)          revert InvalidShares();
            feeRecipients[i] = recipients[i];
            totalShares += recipients[i].shareBps;
        }
        if (totalShares != 10_000) revert InvalidShares();

        // Clear stale storage slots when recipient count is reduced
        for (uint8 i = len; i < 4; ++i) {
            delete feeRecipients[i];
        }

        recipientCount = len;
        emit FeeRecipientsUpdated(feeRecipients, len);
    }

    // ============================================================
    //                     RECEIVE & FALLBACK
    // ============================================================

    /// @notice Accept native gas (ETH on Ethereum/Arbitrum/Base).
    receive() external payable {}
}
