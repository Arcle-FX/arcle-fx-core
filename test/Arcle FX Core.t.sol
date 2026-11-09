// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console}  from "forge-std/Test.sol";
import {ArcleFXCore}    from "../contracts/Arcle FX Core.sol";
import {ERC20}          from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============================================================
//                        MOCK TOKENS
// ============================================================

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract MockEURC is ERC20 {
    constructor() ERC20("Euro Coin", "EURC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

// ============================================================
//                         TEST SUITE
// ============================================================

contract ArcleFXCoreTest is Test {
    ArcleFXCore internal core;
    MockUSDC    internal usdc;
    MockEURC    internal eurc;

    address internal admin     = makeAddr("admin");
    address internal protocol  = makeAddr("protocol");
    address internal developer = makeAddr("developer");
    address internal alice     = makeAddr("alice");

    // ============================================================
    //                           SETUP
    // ============================================================

    function setUp() public {
        usdc = new MockUSDC();
        eurc = new MockEURC();

        ArcleFXCore.FeeRecipient[] memory recipients = new ArcleFXCore.FeeRecipient[](2);
        recipients[0] = ArcleFXCore.FeeRecipient({ account: protocol,  shareBps: 8_000 });
        recipients[1] = ArcleFXCore.FeeRecipient({ account: developer, shareBps: 2_000 });

        vm.prank(admin);
        core = new ArcleFXCore(admin, recipients);
    }

    // ============================================================
    //                        registerFee
    // ============================================================

    function test_RegisterFee_Bridge() public {
        usdc.mint(address(core), 5e6);
        vm.prank(admin);
        core.registerFee(address(usdc), 5e6, ArcleFXCore.OpType.Bridge);
        assertEq(core.feesReceived(address(usdc), ArcleFXCore.OpType.Bridge), 5e6);
    }

    function test_RegisterFee_Swap() public {
        usdc.mint(address(core), 30e4);
        vm.prank(admin);
        core.registerFee(address(usdc), 30e4, ArcleFXCore.OpType.Swap);
        assertEq(core.feesReceived(address(usdc), ArcleFXCore.OpType.Swap), 30e4);
    }

    function test_RegisterFee_UnifiedBalance() public {
        usdc.mint(address(core), 10e4);
        vm.prank(admin);
        core.registerFee(address(usdc), 10e4, ArcleFXCore.OpType.UnifiedBalance);
        assertEq(core.feesReceived(address(usdc), ArcleFXCore.OpType.UnifiedBalance), 10e4);
    }

    function test_RegisterFee_EmitsFeeReceived() public {
        // Grant alice OPERATOR_ROLE through admin (who holds DEFAULT_ADMIN_ROLE)
        bytes32 operatorRole = core.OPERATOR_ROLE();
        vm.prank(admin);
        core.grantRole(operatorRole, alice);

        usdc.mint(address(core), 5e6);
        vm.expectEmit(true, true, true, true);
        emit ArcleFXCore.FeeReceived(address(usdc), ArcleFXCore.OpType.Bridge, alice, 5e6);
        vm.prank(alice);
        core.registerFee(address(usdc), 5e6, ArcleFXCore.OpType.Bridge);
    }

    function test_RegisterFee_RevertIf_ZeroToken() public {
        vm.prank(admin);
        vm.expectRevert(ArcleFXCore.ZeroAddress.selector);
        core.registerFee(address(0), 5e6, ArcleFXCore.OpType.Bridge);
    }

    function test_RegisterFee_RevertIf_ZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(ArcleFXCore.ZeroAmount.selector);
        core.registerFee(address(usdc), 0, ArcleFXCore.OpType.Bridge);
    }

    /// @dev No tokens sent → tracked amount would exceed real inflows → revert
    function test_RegisterFee_RevertIf_AccountingOverflow() public {
        // Contract balance = 0, but caller tries to register 100 USDC
        vm.prank(admin);
        vm.expectRevert(ArcleFXCore.AccountingOverflow.selector);
        core.registerFee(address(usdc), 100e6, ArcleFXCore.OpType.Bridge);
    }

    /// @dev Partial inflation: only 10 USDC in contract, trying to register 100
    function test_RegisterFee_RevertIf_PartialAccountingOverflow() public {
        usdc.mint(address(core), 10e6);
        vm.prank(admin);
        vm.expectRevert(ArcleFXCore.AccountingOverflow.selector);
        core.registerFee(address(usdc), 100e6, ArcleFXCore.OpType.Bridge);
    }

    /// @dev After distribute, feesWithdrawn increases realInflows → re-registration allowed
    function test_RegisterFee_AllowedAfterDistribute() public {
        usdc.mint(address(core), 100e6);

        vm.prank(admin);
        core.registerFee(address(usdc), 100e6, ArcleFXCore.OpType.Bridge);

        vm.prank(admin);
        core.distribute(address(usdc)); // feesWithdrawn[usdc] = 100e6

        // New 50 USDC arrives
        usdc.mint(address(core), 50e6);
        vm.prank(admin);
        core.registerFee(address(usdc), 50e6, ArcleFXCore.OpType.Swap); // OK ✅
        assertEq(core.feesReceived(address(usdc), ArcleFXCore.OpType.Swap), 50e6);
    }

    // ============================================================
    //                     totalFeesReceived
    // ============================================================

    function test_TotalFeesReceived_SumsAllOpTypes() public {
        usdc.mint(address(core), 5e6 + 30e4 + 10e4);
        vm.startPrank(admin);
        core.registerFee(address(usdc), 5e6,  ArcleFXCore.OpType.Bridge);
        core.registerFee(address(usdc), 30e4, ArcleFXCore.OpType.Swap);
        core.registerFee(address(usdc), 10e4, ArcleFXCore.OpType.UnifiedBalance);
        vm.stopPrank();
        assertEq(core.totalFeesReceived(address(usdc)), 5e6 + 30e4 + 10e4);
    }

    // ============================================================
    //                         distribute
    // ============================================================

    function test_Distribute_SplitsCorrectly() public {
        usdc.mint(address(core), 1000e6);
        vm.prank(admin);
        core.distribute(address(usdc));

        assertEq(usdc.balanceOf(protocol),      800e6);
        assertEq(usdc.balanceOf(developer),     200e6);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    /// @dev Last recipient absorbs dust — no wei left in contract
    function test_Distribute_NoDustRemains() public {
        // 3 wei: cannot split 80/20 cleanly
        usdc.mint(address(core), 3);
        vm.prank(admin);
        core.distribute(address(usdc));
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function test_Distribute_TracksWithdrawn() public {
        usdc.mint(address(core), 500e6);
        vm.prank(admin);
        core.distribute(address(usdc));
        assertEq(core.feesWithdrawn(address(usdc)), 500e6);
    }

    function test_Distribute_MultipleTokens() public {
        usdc.mint(address(core), 1000e6);
        eurc.mint(address(core), 500e6);
        vm.startPrank(admin);
        core.distribute(address(usdc));
        core.distribute(address(eurc));
        vm.stopPrank();
        assertEq(usdc.balanceOf(protocol), 800e6);
        assertEq(eurc.balanceOf(protocol), 400e6);
    }

    function test_Distribute_EmitsFeeDistributed() public {
        usdc.mint(address(core), 1000e6);
        vm.expectEmit(true, true, false, true);
        emit ArcleFXCore.FeeDistributed(address(usdc), protocol, 800e6);
        vm.prank(admin);
        core.distribute(address(usdc));
    }

    function test_Distribute_RevertIf_NothingToDistribute() public {
        vm.prank(admin);
        vm.expectRevert(ArcleFXCore.NothingToDistribute.selector);
        core.distribute(address(usdc));
    }

    function test_Distribute_RevertIf_NotFeeManager() public {
        usdc.mint(address(core), 100e6);
        vm.prank(alice);
        vm.expectRevert();
        core.distribute(address(usdc));
    }

    // ============================================================
    //                    emergencyWithdraw
    // ============================================================

    function test_EmergencyWithdraw_SuccessAndEmitsEvent() public {
        usdc.mint(address(core), 100e6);
        vm.expectEmit(true, true, false, true);
        emit ArcleFXCore.EmergencyWithdraw(address(usdc), admin, 100e6);
        vm.prank(admin);
        core.emergencyWithdraw(address(usdc), admin, 100e6);
        assertEq(usdc.balanceOf(admin), 100e6);
    }

    /// @dev BUG-FIX [L-1]: token zero-address check was missing before
    function test_EmergencyWithdraw_RevertIf_ZeroToken() public {
        vm.prank(admin);
        vm.expectRevert(ArcleFXCore.ZeroAddress.selector);
        core.emergencyWithdraw(address(0), admin, 100e6);
    }

    function test_EmergencyWithdraw_RevertIf_ZeroTo() public {
        usdc.mint(address(core), 100e6);
        vm.prank(admin);
        vm.expectRevert(ArcleFXCore.ZeroAddress.selector);
        core.emergencyWithdraw(address(usdc), address(0), 100e6);
    }

    function test_EmergencyWithdraw_RevertIf_NotAdmin() public {
        usdc.mint(address(core), 100e6);
        vm.prank(alice);
        vm.expectRevert();
        core.emergencyWithdraw(address(usdc), alice, 100e6);
    }

    // ============================================================
    //                  emergencyWithdrawNative
    // ============================================================

    function test_EmergencyWithdrawNative_Success() public {
        // Send 1 ETH to contract
        vm.deal(address(core), 1 ether);

        vm.expectEmit(true, false, false, true);
        emit ArcleFXCore.EmergencyNativeWithdraw(admin, 1 ether);

        vm.prank(admin);
        core.emergencyWithdrawNative(payable(admin), 1 ether);

        assertEq(admin.balance, 1 ether);
        assertEq(address(core).balance, 0);
    }

    function test_EmergencyWithdrawNative_RevertIf_ZeroTo() public {
        vm.deal(address(core), 1 ether);
        vm.prank(admin);
        vm.expectRevert(ArcleFXCore.ZeroAddress.selector);
        core.emergencyWithdrawNative(payable(address(0)), 1 ether);
    }

    function test_EmergencyWithdrawNative_RevertIf_NotAdmin() public {
        vm.deal(address(core), 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        core.emergencyWithdrawNative(payable(alice), 1 ether);
    }

    // ============================================================
    //                     setFeeRecipients
    // ============================================================

    function test_SetFeeRecipients_UpdatesCorrectly() public {
        ArcleFXCore.FeeRecipient[] memory r = new ArcleFXCore.FeeRecipient[](2);
        r[0] = ArcleFXCore.FeeRecipient({ account: makeAddr("p2"), shareBps: 7_000 });
        r[1] = ArcleFXCore.FeeRecipient({ account: makeAddr("d2"), shareBps: 3_000 });
        vm.prank(admin);
        core.setFeeRecipients(r);
        (, uint8 count) = core.getFeeRecipients();
        assertEq(count, 2);
    }

    /// @dev BUG-FIX: stale slots must be cleared when reducing recipient count
    function test_SetFeeRecipients_ClearsStaleSlots() public {
        // Add 4 recipients
        ArcleFXCore.FeeRecipient[] memory four = new ArcleFXCore.FeeRecipient[](4);
        four[0] = ArcleFXCore.FeeRecipient({ account: makeAddr("a"), shareBps: 4_000 });
        four[1] = ArcleFXCore.FeeRecipient({ account: makeAddr("b"), shareBps: 3_000 });
        four[2] = ArcleFXCore.FeeRecipient({ account: makeAddr("c"), shareBps: 2_000 });
        four[3] = ArcleFXCore.FeeRecipient({ account: makeAddr("d"), shareBps: 1_000 });
        vm.prank(admin);
        core.setFeeRecipients(four);

        // Reduce to 2
        ArcleFXCore.FeeRecipient[] memory two = new ArcleFXCore.FeeRecipient[](2);
        two[0] = ArcleFXCore.FeeRecipient({ account: protocol,  shareBps: 8_000 });
        two[1] = ArcleFXCore.FeeRecipient({ account: developer, shareBps: 2_000 });
        vm.prank(admin);
        core.setFeeRecipients(two);

        // Slots 2 and 3 must be cleared
        (ArcleFXCore.FeeRecipient[4] memory slots, uint8 cnt) = core.getFeeRecipients();
        assertEq(cnt, 2);
        assertEq(slots[2].account,  address(0));
        assertEq(slots[2].shareBps, 0);
        assertEq(slots[3].account,  address(0));
        assertEq(slots[3].shareBps, 0);
    }

    function test_SetFeeRecipients_RevertIf_InvalidShares() public {
        ArcleFXCore.FeeRecipient[] memory r = new ArcleFXCore.FeeRecipient[](2);
        r[0] = ArcleFXCore.FeeRecipient({ account: protocol,  shareBps: 5_000 });
        r[1] = ArcleFXCore.FeeRecipient({ account: developer, shareBps: 4_000 }); // 9000 ≠ 10000
        vm.prank(admin);
        vm.expectRevert(ArcleFXCore.InvalidShares.selector);
        core.setFeeRecipients(r);
    }

    /// @dev BUG-FIX: zero-BPS recipient must be rejected
    function test_SetFeeRecipients_RevertIf_ZeroShareBps() public {
        ArcleFXCore.FeeRecipient[] memory r = new ArcleFXCore.FeeRecipient[](2);
        r[0] = ArcleFXCore.FeeRecipient({ account: protocol,  shareBps: 10_000 });
        r[1] = ArcleFXCore.FeeRecipient({ account: developer, shareBps: 0 });
        vm.prank(admin);
        vm.expectRevert(ArcleFXCore.InvalidShares.selector);
        core.setFeeRecipients(r);
    }

    function test_SetFeeRecipients_RevertIf_TooMany() public {
        ArcleFXCore.FeeRecipient[] memory r = new ArcleFXCore.FeeRecipient[](5);
        for (uint8 i; i < 5; i++)
            r[i] = ArcleFXCore.FeeRecipient({ account: makeAddr(string(abi.encode(i))), shareBps: 2_000 });
        vm.prank(admin);
        vm.expectRevert(ArcleFXCore.TooManyRecipients.selector);
        core.setFeeRecipients(r);
    }

    // ============================================================
    //                       pause / unpause
    // ============================================================

    function test_Pause_BlocksRegisterFee() public {
        vm.prank(admin);
        core.pause();
        usdc.mint(address(core), 5e6);
        vm.expectRevert();
        core.registerFee(address(usdc), 5e6, ArcleFXCore.OpType.Bridge);
    }

    function test_Unpause_AllowsRegisterFee() public {
        vm.startPrank(admin);
        core.pause();
        core.unpause();
        vm.stopPrank();
        usdc.mint(address(core), 5e6);
        vm.prank(admin);
        core.registerFee(address(usdc), 5e6, ArcleFXCore.OpType.Bridge);
        assertEq(core.feesReceived(address(usdc), ArcleFXCore.OpType.Bridge), 5e6);
    }

    /**
     * @dev Verifies that the `whenNotPaused` modifier on `distribute()` works
     *      correctly: when the contract is paused, any distribution attempt
     *      must revert regardless of the caller's role.
     */
    function test_Distribute_RevertIf_Paused() public {
        // Mint USDC so there is something to distribute
        usdc.mint(address(core), 100e6);

        // Admin pauses the contract
        vm.prank(admin);
        core.pause();

        // Even with FEE_MANAGER_ROLE, distribute must revert while paused
        vm.prank(admin);
        vm.expectRevert();
        core.distribute(address(usdc));
    }

    /**
     * @dev Verifies that distribute works again after the contract is unpaused.
     */
    function test_Distribute_SucceedsAfterUnpause() public {
        usdc.mint(address(core), 100e6);

        vm.startPrank(admin);
        core.pause();
        core.unpause();
        core.distribute(address(usdc));
        vm.stopPrank();

        // Full balance must have been distributed — zero dust left
        assertEq(usdc.balanceOf(address(core)), 0);
        assertEq(usdc.balanceOf(protocol),  80e6);
        assertEq(usdc.balanceOf(developer), 20e6);
    }

    // ============================================================
    //                         FUZZ TESTS
    // ============================================================

    function testFuzz_Distribute_NoDustRemains(uint256 amount) public {
        amount = bound(amount, 1, 100_000e6);
        usdc.mint(address(core), amount);
        vm.prank(admin);
        core.distribute(address(usdc));
        // Dust fix: last recipient absorbs remainder → zero balance
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function testFuzz_RegisterFee_CannotExceedBalance(uint256 balance, uint256 excess) public {
        balance = bound(balance, 1,    100_000e6);
        excess  = bound(excess,  1,    100_000e6);
        usdc.mint(address(core), balance);
        vm.prank(admin);
        core.registerFee(address(usdc), balance, ArcleFXCore.OpType.Bridge); // OK
        vm.prank(admin);
        vm.expectRevert(ArcleFXCore.AccountingOverflow.selector);
        core.registerFee(address(usdc), excess, ArcleFXCore.OpType.Swap);    // REVERT
    }

    function testFuzz_TotalFeesReceived_SumsAllOpTypes(
        uint256 bridgeFee,
        uint256 swapFee,
        uint256 ubFee
    ) public {
        bridgeFee = bound(bridgeFee, 0, 1_000e6);
        swapFee   = bound(swapFee,   0, 1_000e6);
        ubFee     = bound(ubFee,     0, 1_000e6);

        uint256 total = bridgeFee + swapFee + ubFee;
        if (total > 0) usdc.mint(address(core), total);

        vm.startPrank(admin);
        if (bridgeFee > 0) core.registerFee(address(usdc), bridgeFee, ArcleFXCore.OpType.Bridge);
        if (swapFee   > 0) core.registerFee(address(usdc), swapFee,   ArcleFXCore.OpType.Swap);
        if (ubFee     > 0) core.registerFee(address(usdc), ubFee,     ArcleFXCore.OpType.UnifiedBalance);
        vm.stopPrank();

        assertEq(core.totalFeesReceived(address(usdc)), total);
    }
}
