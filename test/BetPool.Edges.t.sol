// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPoolTestBase, BetPool, MockToken} from "./helpers/BetPoolTestBase.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @dev Pinned boundaries and properties not covered by the flow, signature and security suites.
contract BetPoolEdgesTest is BetPoolTestBase {
    function test_WeightBoundariesExact() public {
        _create(MARKET, IMD);
        uint16[2] memory bad = [uint16(499), uint16(10_001)];
        for (uint256 i; i < 2; ++i) {
            Ticket memory t = _ticket(MARKET, alice, 0, 1 ether, bad[i]);
            bytes memory signature = _ticketSignature(t);
            vm.expectRevert(BetPool.InvalidWeight.selector);
            _submit(t, signature);
            assertFalse(pool.usedNonce(t.nonce));
        }
        Ticket memory zero = _ticket(MARKET, alice, 0, 1 ether, 0);
        bytes memory zeroSig = _ticketSignature(zero);
        vm.expectRevert(BetPool.InvalidWeight.selector);
        _submit(zero, zeroSig);

        _place(MARKET, alice, 0, 1 ether, 500);
        _place(MARKET, alice, 0, 1 ether, 10_000);
        BetPool.Bet memory b = _readBet(MARKET, alice);
        assertEq(b.amountA, 2 ether);
        assertEq(b.sharesA, 0.05 ether + 1 ether);
        assertEq(imd.balanceOf(address(pool)), 2 ether);
    }

    function test_ExactLimitsAcceptedForBothTokens() public {
        bytes32 shiftMarket = keccak256("shift-market");
        _create(MARKET, IMD);
        _create(shiftMarket, SHIFT);
        _place(MARKET, alice, 0, 0.1 ether, 10_000);
        _place(MARKET, alice, 1, 500 ether, 10_000);
        _place(shiftMarket, bob, 0, 1_000 ether, 10_000);
        _place(shiftMarket, bob, 1, 25_000_000 ether, 10_000);
        assertEq(imd.balanceOf(address(pool)), 500.1 ether);
        assertEq(shift.balanceOf(address(pool)), 25_001_000 ether);
    }

    function test_BetAtLastSecondBeforeCloseThenRefused() public {
        uint64 cutoff = _create(MARKET, IMD);
        vm.warp(uint256(cutoff) - 1);
        _place(MARKET, alice, 0, 1 ether, 5_000);
        vm.warp(cutoff);
        Ticket memory t = _ticket(MARKET, bob, 1, 1 ether, 5_000);
        bytes memory signature = _ticketSignature(t);
        vm.expectRevert(BetPool.BettingClosed.selector);
        _submit(t, signature);
        vm.warp(uint256(cutoff) + 1 days);
        t = _ticket(MARKET, bob, 1, 1 ether, 5_000);
        signature = _ticketSignature(t);
        vm.expectRevert(BetPool.BettingClosed.selector);
        _submit(t, signature);
        assertEq(_readMarket(MARKET).totalB, 0);
    }

    function test_WinnerCannotClaimTwiceInAnyForm() public {
        _create(MARKET, IMD);
        _place(MARKET, alice, 0, 10 ether, 10_000);
        _place(MARKET, bob, 1, 10 ether, 10_000);
        _settle(MARKET, 0);
        assertEq(_claim(MARKET, alice), 19.5 ether);
        uint256 balance = imd.balanceOf(alice);
        vm.expectRevert(BetPool.AlreadyClaimed.selector);
        _claim(MARKET, alice);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = MARKET;
        vm.expectRevert(BetPool.AlreadyClaimed.selector);
        vm.prank(alice);
        pool.claimMany(ids);
        assertEq(imd.balanceOf(alice), balance);
        assertEq(pool.claimable(MARKET, alice), 0);
        assertEq(imd.balanceOf(address(pool)), 0);
    }

    function test_LoserClaimsNothingAndCannotTakeWinnerFunds() public {
        _create(MARKET, SHIFT);
        _place(MARKET, alice, 0, 5_000 ether, 7_000);
        _place(MARKET, bob, 1, 3_000 ether, 9_000);
        _place(MARKET, carol, 1, 2_000 ether, 1_000);
        _settle(MARKET, 0);
        assertEq(pool.claimable(MARKET, bob), 0);
        uint256 bobBefore = shift.balanceOf(bob);
        assertEq(_claim(MARKET, bob), 0);
        assertEq(shift.balanceOf(bob), bobBefore);
        assertTrue(_readBet(MARKET, bob).claimed);
        vm.expectRevert(BetPool.AlreadyClaimed.selector);
        _claim(MARKET, bob);
        // A wallet that never bet also gets nothing.
        assertEq(_claim(MARKET, dave), 0);
        // The fee is 5% of the 5000 losing SHIFT; alice takes everything else.
        assertEq(shift.balanceOf(SPLITTER), 250 ether);
        assertEq(_claim(MARKET, alice), 5_000 ether + 4_750 ether);
        assertEq(shift.balanceOf(address(pool)), 0);
    }

    function test_WeightNotAmountDecidesShareOfLosers() public {
        // Same stake: an early bettor at full weight and a late bettor at the minimum weight.
        _create(MARKET, IMD);
        _place(MARKET, alice, 0, 100 ether, 10_000);
        _place(MARKET, bob, 0, 100 ether, 500);
        _place(MARKET, carol, 1, 100 ether, 10_000);
        _settle(MARKET, 0);
        uint256 alicePaid = _claim(MARKET, alice);
        uint256 bobPaid = _claim(MARKET, bob);
        // 95 IMD distributable split 100:5 by weighted shares.
        assertEq(alicePaid, 100 ether + uint256(95 ether) * 100 / 105);
        assertEq(bobPaid, 100 ether + uint256(95 ether) * 5 / 105);
        assertEq((alicePaid - 100 ether) / (bobPaid - 100 ether), 20);
        assertLe(imd.balanceOf(address(pool)), 2);
    }

    function test_HedgedWalletKeepsOnlyWinningSide() public {
        _create(MARKET, IMD);
        _place(MARKET, alice, 0, 10 ether, 10_000);
        _place(MARKET, alice, 1, 10 ether, 10_000);
        _place(MARKET, bob, 1, 30 ether, 10_000);
        _settle(MARKET, 1);
        // Losing A side 10 IMD: fee 0.5, 9.5 split 10:30 among B shares.
        assertEq(imd.balanceOf(SPLITTER), 0.5 ether);
        assertEq(_claim(MARKET, alice), 10 ether + 2.375 ether);
        assertEq(_claim(MARKET, bob), 30 ether + 7.125 ether);
        assertEq(imd.balanceOf(address(pool)), 0);
    }

    function test_PausedMarketStillSettlesAndExpiresButRejectsNewWork() public {
        uint64 cutoff = _create(MARKET, IMD);
        _place(MARKET, alice, 0, 1 ether, 10_000);
        vm.prank(OWNER);
        pool.pause();
        // A ticket signed before pausing cannot be used while paused.
        Ticket memory t = _ticket(MARKET, bob, 1, 1 ether, 10_000);
        bytes memory signature = _ticketSignature(t);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _submit(t, signature);
        assertFalse(pool.usedNonce(t.nonce));
        vm.warp(uint256(cutoff) + 24 hours);
        pool.expire(MARKET);
        assertEq(_claim(MARKET, alice), 1 ether);
        vm.prank(OWNER);
        pool.unpause();
        // The market is finished; the old ticket can never be used.
        vm.expectRevert(BetPool.MarketAlreadySettled.selector);
        _submit(t, signature);
    }

    function test_ExpireRefusedBeforeDelayEvenAfterClose() public {
        uint64 cutoff = _create(MARKET, IMD);
        _place(MARKET, alice, 0, 1 ether, 10_000);
        vm.expectRevert(BetPool.TooEarlyToExpire.selector);
        pool.expire(MARKET);
        vm.warp(cutoff);
        vm.expectRevert(BetPool.TooEarlyToExpire.selector);
        pool.expire(MARKET);
        assertFalse(_readMarket(MARKET).settled);
        vm.expectRevert(BetPool.MarketNotSettled.selector);
        _claim(MARKET, alice);
    }

    function test_OwnerCannotSettleExpireEarlyOrClaimOthers() public {
        _create(MARKET, IMD);
        _place(MARKET, alice, 0, 1 ether, 10_000);
        _place(MARKET, bob, 1, 1 ether, 10_000);
        vm.startPrank(OWNER);
        vm.expectRevert(BetPool.TooEarlyToExpire.selector);
        pool.expire(MARKET);
        uint256 deadline = block.timestamp + 1 hours;
        // A result signed by any key other than the configured signer is refused, owner or not.
        bytes memory forged = _sign(address(pool), 1, OTHER_KEY, _outcomeHash(MARKET, 0, deadline));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(MARKET, 0, deadline, forged);
        vm.stopPrank();
        _settle(MARKET, 1);
        vm.prank(OWNER);
        assertEq(pool.claim(MARKET), 0);
        assertEq(imd.balanceOf(OWNER), 0);
        assertEq(_claim(MARKET, bob), 1.95 ether);
    }

    function test_LimitsOnlyAffectTheNamedToken() public {
        vm.prank(OWNER);
        pool.setLimits(SHIFT, 1 ether, 2 ether);
        (uint256 min, uint256 max) = pool.limits(IMD);
        assertEq(min, 0.1 ether);
        assertEq(max, 500 ether);
        (min, max) = pool.limits(alice);
        assertEq(min, 0);
        assertEq(max, 0);
    }

    // ---- property fuzzes -------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_FeeIsExactlyFivePercentOfLosingSide(uint256 seed, uint8 losersSeed, bool aWins, bool useShift)
        public
    {
        address tokenAddress = useShift ? SHIFT : IMD;
        (uint256 min, uint256 max) = pool.limits(tokenAddress);
        uint256 losers = bound(losersSeed, 1, 10);
        _create(MARKET, tokenAddress);
        uint8 winSide = aWins ? 0 : 1;
        _place(MARKET, alice, winSide, min, 5_000);
        uint256 losingTotal;
        for (uint256 i; i < losers; ++i) {
            address wallet = address(uint160(0x20000 + i));
            _fund(wallet);
            uint256 amount = min + uint256(keccak256(abi.encode(seed, i))) % (max - min + 1);
            _place(MARKET, wallet, 1 - winSide, amount, uint16(500 + i * 900));
            losingTotal += amount;
        }
        uint256 before = MockToken(tokenAddress).balanceOf(SPLITTER);
        _settle(MARKET, winSide);
        uint256 fee = MockToken(tokenAddress).balanceOf(SPLITTER) - before;
        assertEq(fee, losingTotal * 5 / 100);
        assertLe(fee * 20, losingTotal);
        assertGt((fee + 1) * 20, losingTotal);
        // The only winner takes back the entire pot minus the fee.
        assertEq(_claim(MARKET, alice), min + losingTotal - fee);
        assertEq(MockToken(tokenAddress).balanceOf(address(pool)), 0);
    }

    /// @dev Monotonicity: with equal stakes, a higher weight never earns less.
    function testFuzz_PayoutMonotonicInWeight(uint16 w1, uint16 w2, uint256 amountSeed, uint256 loserSeed) public {
        w1 = uint16(bound(w1, 500, 10_000));
        w2 = uint16(bound(w2, 500, 10_000));
        uint256 amount = bound(amountSeed, 0.1 ether, 500 ether);
        uint256 losing = bound(loserSeed, 0.1 ether, 500 ether);
        _create(MARKET, IMD);
        _place(MARKET, alice, 0, amount, w1);
        _place(MARKET, bob, 0, amount, w2);
        _place(MARKET, carol, 1, losing, 10_000);
        _settle(MARKET, 0);
        uint256 a = _claim(MARKET, alice);
        uint256 b = _claim(MARKET, bob);
        if (w1 >= w2) assertGe(a, b);
        if (w2 >= w1) assertGe(b, a);
        assertGe(a, amount, "winner never loses principal");
        assertGe(b, amount, "winner never loses principal");
        assertLe(a + b, 2 * amount + losing - losing / 20);
        assertLe(imd.balanceOf(address(pool)), 1);
    }

    function testFuzz_TicketExpiryWindow(uint64 offset) public {
        _create(MARKET, IMD);
        offset = uint64(bound(offset, 0, 1_000));
        Ticket memory t = _ticket(MARKET, alice, 0, 1 ether, 5_000);
        t.expiry = uint64(block.timestamp) + offset;
        bytes memory signature = _ticketSignature(t);
        if (offset > 120) vm.expectRevert(BetPool.TicketExpiryTooFar.selector);
        _submit(t, signature);
        assertEq(pool.usedNonce(t.nonce), offset <= 120);
    }

    function testFuzz_MarketCloseWindow(uint256 offset) public {
        offset = bound(offset, 0, 30 days);
        uint64 closesAt = uint64(block.timestamp + offset);
        bytes memory signature = _sign(address(pool), 1, SIGNER_KEY, _marketHash(MARKET, IMD, closesAt, GAME));
        bool valid = offset > 0 && offset <= 7 days;
        if (!valid) vm.expectRevert(BetPool.InvalidCloseTime.selector);
        pool.createMarket(MARKET, IMD, closesAt, GAME, signature);
        assertEq(_readMarket(MARKET).token, valid ? IMD : address(0));
    }

    function testFuzz_OutcomeOutOfRangeRefused(uint8 outcome) public {
        outcome = uint8(bound(outcome, 3, type(uint8).max));
        _create(MARKET, IMD);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _sign(address(pool), 1, SIGNER_KEY, _outcomeHash(MARKET, outcome, deadline));
        vm.expectRevert(BetPool.InvalidOutcome.selector);
        pool.settle(MARKET, outcome, deadline, signature);
        assertFalse(_readMarket(MARKET).settled);
    }

    function testFuzz_SetLimitsRespectsCaps(uint256 min, uint256 max, bool useShift) public {
        address token = useShift ? SHIFT : IMD;
        uint256 cap = useShift ? 500_000_000 ether : 10_000 ether;
        min = bound(min, 0, cap + 10);
        max = bound(max, 0, cap + 10);
        (uint256 oldMin, uint256 oldMax) = pool.limits(token);
        bool valid = min != 0 && min <= max && max <= cap;
        if (!valid) vm.expectRevert(BetPool.InvalidLimits.selector);
        vm.prank(OWNER);
        pool.setLimits(token, min, max);
        (uint256 newMin, uint256 newMax) = pool.limits(token);
        assertEq(newMin, valid ? min : oldMin);
        assertEq(newMax, valid ? max : oldMax);
    }

    function testFuzz_VoidAndExpiryRefundExactStakes(uint256 a, uint256 b, uint16 wa, uint16 wb, bool viaExpiry)
        public
    {
        a = bound(a, 1_000 ether, 25_000_000 ether);
        b = bound(b, 1_000 ether, 25_000_000 ether);
        wa = uint16(bound(wa, 500, 10_000));
        wb = uint16(bound(wb, 500, 10_000));
        uint64 cutoff = _create(MARKET, SHIFT);
        _place(MARKET, alice, 0, a, wa);
        _place(MARKET, bob, 1, b, wb);
        _place(MARKET, carol, 0, b, wb);
        if (viaExpiry) {
            vm.warp(uint256(cutoff) + 24 hours);
            pool.expire(MARKET);
        } else {
            _settle(MARKET, 2);
        }
        assertEq(_claim(MARKET, alice), a);
        assertEq(_claim(MARKET, bob), b);
        assertEq(_claim(MARKET, carol), b);
        assertEq(shift.balanceOf(SPLITTER), 0);
        assertEq(shift.balanceOf(address(pool)), 0);
    }
}
