// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IArcleFXCore
/// @notice Public interface for the ArcleFXCore fee vault
interface IArcleFXCore {

    enum OpType { Bridge, Swap, UnifiedBalance }

    struct FeeRecipient {
        address account;
        uint16  shareBps; // out of 10_000
    }

    function registerFee(address token, uint256 amount, OpType opType) external;
    function distribute(address token) external;
    function setFeeRecipients(FeeRecipient[] calldata recipients) external;
    function emergencyWithdraw(address token, address to, uint256 amount) external;

    function totalFeesReceived(address token) external view returns (uint256);
    function feesReceived(address token, OpType opType) external view returns (uint256);
    function feesWithdrawn(address token) external view returns (uint256);
    function getFeeRecipients() external view returns (FeeRecipient[4] memory, uint8 count);
}
