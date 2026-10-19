// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPoolTestBase, BetPool} from "./helpers/BetPoolTestBase.sol";
import {DeployBetPool} from "../script/DeployBetPool.s.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract BetPoolSecurityTest is BetPoolTestBase {
    function test_DeploymentWorksOnEmptyChainFromFactoryAndFixesOwner() public {
        vm.etch(IMD, "");
        vm.etch(SHIFT, "");
        vm.etch(SPLITTER, "");
        DeployBetPool factory = new DeployBetPool();
        vm.prank(dave);
        BetPool fresh = factory.run();
        assertEq(fresh.owner(), OWNER);
        assertTrue(fresh.owner() != address(factory));
        assertTrue(fresh.owner() != dave);
        assertEq(fresh.IMD(), IMD);
        assertEq(fresh.SHIFT(), SHIFT);
        assertEq(fresh.FEE_RECIPIENT(), SPLITTER);
        assertEq(fresh.FEE_BPS(), 500);
        assertEq(fresh.signer(), address(0));
        assertFalse(fresh.paused());
        (uint256 min, uint256 max) = fresh.limits(IMD);
        assertEq(min, 0.1 ether);
        assertEq(max, 500 ether);
        (min, max) = fresh.limits(SHIFT);
        assertEq(min, 1_000 ether);
        assertEq(max, 25_000_000 ether);
    }

    function test_UnconfiguredSignerFailsClearlyAndOwnerCanConfigure() public {
        pool = new BetPool();
        uint64 cutoff = uint64(block.timestamp + 1 hours);
        vm.expectRevert(BetPool.SignerNotConfigured.selector);
        pool.createMarket(MARKET, IMD, cutoff, GAME, "");
        vm.expectRevert(BetPool.NotOwner.selector);
        pool.setSigner(vm.addr(SIGNER_KEY));
        vm.startPrank(OWNER);
        vm.expectRevert(BetPool.InvalidSigner.selector);
        pool.setSigner(address(0));
        pool.setSigner(vm.addr(SIGNER_KEY));
        vm.stopPrank();
        _create(MARKET, IMD);
        assertEq(_readMarket(MARKET).token, IMD);
    }

    function test_EIP712DomainAndTypeHashesMatchIntegrationDefinition() public view {
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifying,,) =
            pool.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "NightshiftBets");
        assertEq(version, "1");
        assertEq(chainId, 1);
        assertEq(verifying, address(pool));
        assertEq(pool.MARKET_TYPEHASH(), MARKET_TYPE);
        assertEq(pool.TICKET_TYPEHASH(), TICKET_TYPE);
        assertEq(pool.OUTCOME_TYPEHASH(), OUTCOME_TYPE);
    }

    function test_RuntimeBoundedAndContainsNoEscapeOpcodes() public view {
        bytes memory code = address(pool).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function test_SignerRotationInvalidatesAllOldAuthorizations() public {
        _create(MARKET, IMD);
        Ticket memory t = _ticket(MARKET, alice, 0, 1 ether, 5_000);
        bytes memory ticketSignature = _ticketSignature(t);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory outcomeSignature = _sign(address(pool), 1, SIGNER_KEY, _outcomeHash(MARKET, 0, deadline));
        bytes32 second = keccak256("second");
        uint64 cutoff = uint64(deadline);
        bytes memory marketSignature = _sign(address(pool), 1, SIGNER_KEY, _marketHash(second, IMD, cutoff, GAME));
        vm.prank(OWNER);
        pool.setSigner(vm.addr(OTHER_KEY));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        _submit(t, ticketSignature);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(MARKET, 0, deadline, outcomeSignature);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(second, IMD, cutoff, GAME, marketSignature);
        _submit(t, _sign(address(pool), 1, OTHER_KEY, _ticketHash(t)));
        pool.createMarket(
            second, IMD, cutoff, GAME, _sign(address(pool), 1, OTHER_KEY, _marketHash(second, IMD, cutoff, GAME))
        );
        pool.settle(MARKET, 0, deadline, _sign(address(pool), 1, OTHER_KEY, _outcomeHash(MARKET, 0, deadline)));
        assertEq(_claim(MARKET, alice), 1 ether);
    }

    function test_OnlyOwnerCanAdminister() public {
        vm.startPrank(alice);
        vm.expectRevert(BetPool.NotOwner.selector);
        pool.setSigner(alice);
        vm.expectRevert(BetPool.NotOwner.selector);
        pool.setLimits(IMD, 1, 100);
        vm.expectRevert(BetPool.NotOwner.selector);
        pool.pause();
        vm.expectRevert(BetPool.NotOwner.selector);
        pool.unpause();
        vm.stopPrank();
    }

    function test_LimitsCannotChangeTokensOrExceedCaps() public {
        vm.startPrank(OWNER);
        vm.expectRevert(BetPool.UnsupportedToken.selector);
        pool.setLimits(alice, 1, 100);
        vm.expectRevert(BetPool.InvalidLimits.selector);
        pool.setLimits(IMD, 0, 100);
        vm.expectRevert(BetPool.InvalidLimits.selector);
        pool.setLimits(IMD, 100, 99);
        vm.expectRevert(BetPool.InvalidLimits.selector);
        pool.setLimits(IMD, 1, 10_000 ether + 1);
        vm.expectRevert(BetPool.InvalidLimits.selector);
        pool.setLimits(SHIFT, 1, 500_000_000 ether + 1);
        pool.setLimits(IMD, 10_000 ether, 10_000 ether);
        pool.setLimits(SHIFT, 500_000_000 ether, 500_000_000 ether);
        vm.stopPrank();
        (uint256 min, uint256 max) = pool.limits(IMD);
        assertEq(min, 10_000 ether);
        assertEq(max, 10_000 ether);
        (min, max) = pool.limits(SHIFT);
        assertEq(min, 500_000_000 ether);
        assertEq(max, 500_000_000 ether);
        _create(MARKET, IMD);
        _place(MARKET, alice, 0, 10_000 ether, 500);
        _create(keccak256("shift"), SHIFT);
        _place(keccak256("shift"), alice, 0, 500_000_000 ether, 10_000);
    }

    function test_LimitChangeAppliesToOutstandingTicketsButNotExistingClaims() public {
        _create(MARKET, IMD);
        _place(MARKET, alice, 0, 1 ether, 10_000);
        Ticket memory t = _ticket(MARKET, bob, 1, 1 ether, 5_000);
        bytes memory signature = _ticketSignature(t);
        vm.prank(OWNER);
        pool.setLimits(IMD, 2 ether, 10 ether);
        vm.expectRevert(BetPool.AmountOutsideLimits.selector);
        _submit(t, signature);
        _settle(MARKET, 2);
        assertEq(_claim(MARKET, alice), 1 ether);
    }

    function test_PauseStopsOnlyNewMarketsAndBets() public {
        uint64 cutoff = _create(MARKET, IMD);
        bytes32 second = keccak256("second");
        _create(second, SHIFT);
        _place(MARKET, alice, 0, 1 ether, 10_000);
        _place(MARKET, bob, 1, 1 ether, 5_000);
        _place(second, alice, 0, 1_000 ether, 500);
        Ticket memory t = _ticket(MARKET, alice, 0, 1 ether, 5_000);
        bytes memory signature = _ticketSignature(t);
        vm.prank(OWNER);
        pool.pause();
        assertTrue(pool.paused());
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _submit(t, signature);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pool.createMarket(keccak256("new"), IMD, cutoff, GAME, "");
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(OWNER);
        pool.pause();
        _settle(MARKET, 0);
        assertEq(_claim(MARKET, alice), 1.95 ether);
        vm.warp(uint256(cutoff) + 24 hours);
        pool.expire(second);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = second;
        vm.prank(alice);
        pool.claimMany(ids);
        assertEq(shift.balanceOf(address(pool)), 0);
        vm.prank(OWNER);
        pool.unpause();
        _create(keccak256("new"), IMD);
        _place(keccak256("new"), alice, 0, 1 ether, 5_000);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vm.prank(OWNER);
        pool.unpause();
    }

    function test_OwnerHasNoCustodyOrUnsignedSettlementRoute() public {
        _create(MARKET, IMD);
        _place(MARKET, alice, 0, 1 ether, 10_000);
        _place(MARKET, bob, 1, 1 ether, 10_000);
        vm.startPrank(OWNER);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(MARKET, 0, block.timestamp, "");
        bytes[8] memory attempts = [
            abi.encodeWithSignature("withdraw(address,uint256)", IMD, 2 ether),
            abi.encodeWithSignature("sweep(address,address,uint256)", IMD, OWNER, 2 ether),
            abi.encodeWithSignature("rescueTokens(address,uint256)", IMD, 2 ether),
            abi.encodeWithSignature("setFeeRecipient(address)", OWNER),
            abi.encodeWithSignature("setFee(uint256)", 0),
            abi.encodeWithSignature("transferOwnership(address)", alice),
            abi.encodeWithSignature("upgradeTo(address)", alice),
            abi.encodeWithSignature(
                "execute(address,bytes)", IMD, abi.encodeWithSignature("transfer(address,uint256)", OWNER, 2 ether)
            )
        ];
        for (uint256 i; i < attempts.length; ++i) {
            (bool success,) = address(pool).call(attempts[i]);
            assertFalse(success);
        }
        vm.stopPrank();
        assertEq(imd.balanceOf(OWNER), 0);
        assertEq(imd.balanceOf(address(pool)), 2 ether);
        _settle(MARKET, 0);
        assertEq(_claim(MARKET, OWNER), 0);
        assertEq(_claim(MARKET, alice), 1.95 ether);
    }

    function test_FalseReturnAndTaxedTransfersRollBackBetAndNonce() public {
        _create(MARKET, IMD);
        Ticket memory t = _ticket(MARKET, alice, 0, 1 ether, 5_000);
        bytes memory signature = _ticketSignature(t);
        uint256 initial = imd.balanceOf(alice);
        imd.setBehavior(false, true, false, 0);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        _submit(t, signature);
        assertEq(imd.balanceOf(alice), initial);
        assertEq(_readMarket(MARKET).totalA, 0);
        assertFalse(pool.usedNonce(t.nonce));
        imd.setBehavior(false, false, false, 100);
        vm.expectRevert(BetPool.IncorrectTransferAmount.selector);
        _submit(t, signature);
        assertEq(imd.balanceOf(address(pool)), 0);
        assertEq(pool.remainingPot(MARKET), 0);
        assertFalse(pool.usedNonce(t.nonce));
        imd.setBehavior(false, false, false, 0);
        _submit(t, signature);
    }

    function test_NoReturnTokensWorkThroughSafeERC20() public {
        imd.setBehavior(false, false, true, 0);
        _create(MARKET, IMD);
        _place(MARKET, alice, 0, 1 ether, 10_000);
        _place(MARKET, bob, 1, 1 ether, 10_000);
        _settle(MARKET, 0);
        assertEq(_claim(MARKET, alice), 1.95 ether);
        assertEq(imd.balanceOf(SPLITTER), 0.05 ether);
    }

    function test_FailedFeeTransferRollsBackSettlementAndCanExpire() public {
        uint64 cutoff = _create(MARKET, IMD);
        _place(MARKET, alice, 0, 1 ether, 10_000);
        _place(MARKET, bob, 1, 1 ether, 10_000);
        imd.setBehavior(true, false, false, 0);
        bytes memory signature = _sign(address(pool), 1, SIGNER_KEY, _outcomeHash(MARKET, 0, block.timestamp));
        vm.expectRevert(bytes("mock transfer failure"));
        pool.settle(MARKET, 0, block.timestamp, signature);
        assertFalse(_readMarket(MARKET).settled);
        assertEq(pool.remainingPot(MARKET), 2 ether);
        assertEq(imd.balanceOf(SPLITTER), 0);
        vm.warp(uint256(cutoff) + 24 hours);
        pool.expire(MARKET);
        imd.setBehavior(false, false, false, 0);
        assertEq(_claim(MARKET, alice), 1 ether);
        assertEq(_claim(MARKET, bob), 1 ether);
    }

    function test_FailedClaimTransferDoesNotConsumeClaim() public {
        _create(MARKET, IMD);
        _place(MARKET, alice, 0, 1 ether, 10_000);
        _settle(MARKET, 2);
        imd.setBehavior(false, true, false, 0);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        _claim(MARKET, alice);
        assertFalse(_readBet(MARKET, alice).claimed);
        assertEq(pool.remainingPot(MARKET), 1 ether);
        assertEq(pool.claimable(MARKET, alice), 1 ether);
        imd.setBehavior(false, false, false, 0);
        assertEq(_claim(MARKET, alice), 1 ether);
    }

    function test_ReentrancyBlockedDuringBetFeeAndClaimTransfers() public {
        _create(MARKET, IMD);
        // Token callbacks attempt guarded functions with otherwise well-formed calldata.
        imd.setCallback(address(pool), abi.encodeCall(BetPool.expire, (MARKET)), true);
        _place(MARKET, alice, 0, 1 ether, 10_000);
        _assertGuardCaughtCallback();
        imd.setCallback(address(0), "", false);
        _place(MARKET, bob, 1, 1 ether, 10_000);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = MARKET;
        imd.setCallback(address(pool), abi.encodeCall(BetPool.claimMany, (ids)), false);
        _settle(MARKET, 0);
        _assertGuardCaughtCallback();
        imd.setCallback(address(pool), abi.encodeCall(BetPool.claim, (MARKET)), false);
        assertEq(_claim(MARKET, alice), 1.95 ether);
        _assertGuardCaughtCallback();
        assertEq(imd.balanceOf(address(pool)), 0);
        assertEq(imd.balanceOf(SPLITTER), 0.05 ether);
    }

    function _assertGuardCaughtCallback() private view {
        assertTrue(imd.callbackAttempted());
        assertFalse(imd.callbackSucceeded());
        assertEq(imd.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    function test_InsufficientAllowanceDoesNotRecordBet() public {
        _create(MARKET, IMD);
        vm.prank(alice);
        imd.approve(address(pool), 0);
        Ticket memory t = _ticket(MARKET, alice, 0, 1 ether, 5_000);
        bytes memory signature = _ticketSignature(t);
        vm.expectRevert();
        _submit(t, signature);
        assertFalse(pool.usedNonce(t.nonce));
        assertEq(pool.remainingPot(MARKET), 0);
        assertEq(_readBet(MARKET, alice).amountA, 0);
    }
}
