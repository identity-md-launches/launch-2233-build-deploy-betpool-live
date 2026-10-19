// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPoolTestBase, BetPool, MockToken} from "./helpers/BetPoolTestBase.sol";

contract BetPoolFlowsTest is BetPoolTestBase {
    function test_IMDWeightedAWins() public {
        _weightedFlow(IMD, 0);
    }

    function test_IMDWeightedBWins() public {
        _weightedFlow(IMD, 1);
    }

    function test_SHIFTWeightedAWins() public {
        _weightedFlow(SHIFT, 0);
    }

    function test_SHIFTWeightedBWins() public {
        _weightedFlow(SHIFT, 1);
    }

    function _weightedFlow(address tokenAddress, uint8 outcome) private {
        MockToken token = MockToken(tokenAddress);
        (uint256 min, uint256 max) = pool.limits(tokenAddress);
        _create(MARKET, tokenAddress);
        _place(MARKET, alice, 0, min, 10_000);
        _place(MARKET, alice, 0, 3 * min + 7, 2_500);
        _place(MARKET, alice, 1, min, 5_000);
        _place(MARKET, bob, 0, max, 500);
        _place(MARKET, carol, 1, 2 * min + 3, 3_333);
        _place(MARKET, dave, 1, max, 9_999);

        uint256 totalA = 4 * min + 7 + max;
        uint256 totalB = 3 * min + 3 + max;
        uint256 aliceShares = min + (3 * min + 7) * 2_500 / 10_000;
        uint256 sharesA = aliceShares + max * 500 / 10_000;
        uint256 sharesB = min / 2 + (2 * min + 3) * 3_333 / 10_000 + max * 9_999 / 10_000;
        BetPool.Market memory market = _readMarket(MARKET);
        assertEq(market.totalA, totalA);
        assertEq(market.totalB, totalB);
        assertEq(market.sharesA, sharesA);
        assertEq(market.sharesB, sharesB);
        BetPool.Bet memory position = _readBet(MARKET, alice);
        assertEq(position.amountA, 4 * min + 7);
        assertEq(position.amountB, min);
        assertEq(position.sharesA, aliceShares);
        assertEq(position.sharesB, min / 2);
        assertEq(pool.claimable(MARKET, alice), 0);
        assertEq(token.balanceOf(address(pool)), totalA + totalB);

        _settle(MARKET, outcome);
        uint256 losing = outcome == 0 ? totalB : totalA;
        uint256 fee = losing / 20;
        assertEq(token.balanceOf(SPLITTER), fee);
        assertEq(token.balanceOf(address(pool)), totalA + totalB - fee);

        address[4] memory actors = [alice, bob, carol, dave];
        uint256[4] memory amounts =
            outcome == 0 ? [4 * min + 7, max, uint256(0), uint256(0)] : [min, uint256(0), 2 * min + 3, max];
        uint256[4] memory weights = outcome == 0
            ? [aliceShares, max * 500 / 10_000, uint256(0), uint256(0)]
            : [min / 2, uint256(0), (2 * min + 3) * 3_333 / 10_000, max * 9_999 / 10_000];
        uint256 totalPaid;
        // Reverse order also exercises a losing claim before all winning payouts.
        for (uint256 i = 4; i > 0;) {
            --i;
            uint256 expected = amounts[i] + (losing - fee) * weights[i] / (outcome == 0 ? sharesA : sharesB);
            assertEq(pool.claimable(MARKET, actors[i]), expected);
            uint256 before = token.balanceOf(actors[i]);
            assertEq(_claim(MARKET, actors[i]), expected);
            assertEq(token.balanceOf(actors[i]) - before, expected);
            assertEq(pool.claimable(MARKET, actors[i]), 0);
            assertTrue(_readBet(MARKET, actors[i]).claimed);
            totalPaid += expected;
        }
        uint256 dust = token.balanceOf(address(pool));
        assertLt(dust, outcome == 0 ? 2 : 3, "less than one wei of dust per winning wallet");
        assertEq(totalPaid + fee + dust, totalA + totalB);
        assertEq(pool.remainingPot(MARKET), dust);
    }

    function test_ExactlyDivisiblePotPaysAllButFee() public {
        _create(MARKET, IMD);
        _place(MARKET, alice, 0, 1 ether, 10_000);
        _place(MARKET, bob, 0, 2 ether, 5_000);
        _place(MARKET, carol, 1, 20 ether, 10_000);
        _settle(MARKET, 0);
        assertEq(_claim(MARKET, alice), 10.5 ether);
        assertEq(_claim(MARKET, bob), 11.5 ether);
        assertEq(imd.balanceOf(SPLITTER), 1 ether);
        assertEq(imd.balanceOf(address(pool)), 0);
    }

    function test_ManyWinnersOddAmountsAndFeeRoundDown() public {
        vm.prank(OWNER);
        pool.setLimits(IMD, 20, 500 ether);
        _create(MARKET, IMD);
        for (uint256 i; i < 31; ++i) {
            address bettor = address(uint160(0x1000 + i));
            _fund(bettor);
            _place(MARKET, bettor, 0, 20, 500);
        }
        _place(MARKET, bob, 1, 39, 10_000);
        _settle(MARKET, 0);
        assertEq(imd.balanceOf(SPLITTER), 1);
        uint256 payouts;
        for (uint256 i; i < 31; ++i) {
            assertEq(pool.claimable(MARKET, address(uint160(0x1000 + i))), 21);
            payouts += _claim(MARKET, address(uint160(0x1000 + i)));
        }
        assertEq(payouts, 651);
        assertEq(imd.balanceOf(address(pool)), 7);
        assertEq(payouts + imd.balanceOf(SPLITTER) + imd.balanceOf(address(pool)), 659);
    }

    function test_ZeroFeeStillDistributesEntireLosingAmount() public {
        vm.prank(OWNER);
        pool.setLimits(IMD, 1, 500 ether);
        _create(MARKET, IMD);
        _place(MARKET, alice, 0, 1, 10_000);
        _place(MARKET, bob, 1, 19, 10_000);
        _settle(MARKET, 0);
        assertEq(imd.balanceOf(SPLITTER), 0);
        assertEq(_claim(MARKET, alice), 20);
        assertEq(imd.balanceOf(address(pool)), 0);
    }

    function test_VoidRefundsEveryStakeOnBothSides() public {
        _create(MARKET, SHIFT);
        _place(MARKET, alice, 0, 1_000 ether, 500);
        _place(MARKET, alice, 1, 2_000 ether, 10_000);
        _place(MARKET, bob, 0, 1_500 ether + 1, 7_231);
        _place(MARKET, carol, 1, 2_500 ether + 3, 1_111);
        _settle(MARKET, 2);
        assertTrue(_readMarket(MARKET).refundable);
        assertEq(_claim(MARKET, alice), 3_000 ether);
        assertEq(_claim(MARKET, bob), 1_500 ether + 1);
        assertEq(_claim(MARKET, carol), 2_500 ether + 3);
        assertEq(shift.balanceOf(address(pool)), 0);
        assertEq(shift.balanceOf(SPLITTER), 0);
    }

    function testFuzz_OneSidedRefundsEvenWhenPopulatedSideLoses(bool sideB, bool winnerB) public {
        _create(MARKET, IMD);
        uint8 side = sideB ? 1 : 0;
        _place(MARKET, alice, side, 0.1 ether, 500);
        _place(MARKET, bob, side, 500 ether, 10_000);
        _settle(MARKET, winnerB ? 1 : 0);
        assertTrue(_readMarket(MARKET).refundable);
        assertEq(_claim(MARKET, alice), 0.1 ether);
        assertEq(_claim(MARKET, bob), 500 ether);
        assertEq(imd.balanceOf(SPLITTER), 0);
        assertEq(imd.balanceOf(address(pool)), 0);
    }

    function test_EmptyMarketSettlesRefundableAndZeroClaimIsFinal() public {
        _create(MARKET, IMD);
        _settle(MARKET, 1);
        assertTrue(_readMarket(MARKET).refundable);
        assertEq(_claim(MARKET, alice), 0);
        vm.expectRevert(BetPool.AlreadyClaimed.selector);
        _claim(MARKET, alice);
    }

    function test_ExpiryBoundaryRefundsWithoutSigner() public {
        uint64 cutoff = _create(MARKET, IMD);
        _place(MARKET, alice, 0, 1 ether, 500);
        _place(MARKET, alice, 1, 2 ether, 10_000);
        _place(MARKET, bob, 1, 3 ether, 5_000);
        vm.warp(uint256(cutoff) + 24 hours - 1);
        vm.expectRevert(BetPool.TooEarlyToExpire.selector);
        pool.expire(MARKET);
        vm.warp(uint256(cutoff) + 24 hours);
        vm.prank(dave);
        pool.expire(MARKET);
        BetPool.Market memory market = _readMarket(MARKET);
        assertTrue(market.settled);
        assertTrue(market.refundable);
        assertEq(market.outcome, 2);
        assertEq(_claim(MARKET, alice), 3 ether);
        assertEq(_claim(MARKET, bob), 3 ether);
        assertEq(imd.balanceOf(SPLITTER), 0);
        assertEq(imd.balanceOf(address(pool)), 0);
        vm.expectRevert(BetPool.MarketAlreadySettled.selector);
        pool.expire(MARKET);
    }

    function test_SettlementCanWinRaceWithExpireAfterRefundDelay() public {
        uint64 cutoff = _create(MARKET, IMD);
        _place(MARKET, alice, 0, 1 ether, 10_000);
        _place(MARKET, bob, 1, 1 ether, 10_000);
        vm.warp(uint256(cutoff) + 24 hours);
        _settle(MARKET, 0);
        vm.expectRevert(BetPool.MarketAlreadySettled.selector);
        pool.expire(MARKET);
        assertEq(_claim(MARKET, alice), 1.95 ether);
    }

    function test_ClaimManyMixedTokens() public {
        bytes32 second = keccak256("pinball");
        _create(MARKET, IMD);
        _create(second, SHIFT);
        _place(MARKET, alice, 0, 1 ether, 500);
        _place(second, alice, 1, 1_000 ether, 10_000);
        _settle(MARKET, 2);
        _settle(second, 2);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = MARKET;
        ids[1] = second;
        uint256 imdBefore = imd.balanceOf(alice);
        uint256 shiftBefore = shift.balanceOf(alice);
        vm.prank(alice);
        pool.claimMany(ids);
        assertEq(imd.balanceOf(alice) - imdBefore, 1 ether);
        assertEq(shift.balanceOf(alice) - shiftBefore, 1_000 ether);
        assertTrue(_readBet(MARKET, alice).claimed);
        assertTrue(_readBet(second, alice).claimed);
        assertEq(pool.remainingPot(MARKET), 0);
        assertEq(pool.remainingPot(second), 0);
    }

    function test_ClaimManyFailureRollsBackPriorClaim() public {
        _create(MARKET, IMD);
        _place(MARKET, alice, 0, 1 ether, 10_000);
        _settle(MARKET, 2);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = MARKET;
        ids[1] = MARKET;
        uint256 before = imd.balanceOf(alice);
        vm.expectRevert(BetPool.AlreadyClaimed.selector);
        vm.prank(alice);
        pool.claimMany(ids);
        assertEq(imd.balanceOf(alice), before);
        assertFalse(_readBet(MARKET, alice).claimed);
        assertEq(pool.claimable(MARKET, alice), 1 ether);
        ids[1] = keccak256("unknown");
        vm.expectRevert(BetPool.UnknownMarket.selector);
        vm.prank(alice);
        pool.claimMany(ids);
        assertFalse(_readBet(MARKET, alice).claimed);
        pool.claimMany(new bytes32[](0));
    }

    function test_DirectDonationsDoNotChangePayoutOrBelongToAnyMarket() public {
        _create(MARKET, IMD);
        _place(MARKET, alice, 0, 1 ether, 10_000);
        _place(MARKET, bob, 1, 1 ether, 10_000);
        vm.prank(carol);
        imd.transfer(address(pool), 100 ether);
        _settle(MARKET, 0);
        assertEq(_claim(MARKET, alice), 1.95 ether);
        assertEq(pool.remainingPot(MARKET), 0);
        assertEq(imd.balanceOf(address(pool)), 100 ether);
    }
}
