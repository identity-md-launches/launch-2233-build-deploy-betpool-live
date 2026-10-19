// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPoolTestBase, BetPool, MockToken} from "./helpers/BetPoolTestBase.sol";

/// @dev A separate accounting model, driven by successful actions, never by contract payout views.
contract BetPoolHandler is BetPoolTestBase {
    struct ModelMarket {
        bytes32 id;
        uint8 tokenIndex;
        uint64 closesAt;
        uint256[2] totals;
        uint256[2] shares;
        uint256 fee;
        uint256 paid;
        bool settled;
        bool refundable;
        uint8 outcome;
    }

    struct Position {
        uint256[2] amounts;
        uint256[2] shares;
        bool claimed;
    }

    address[6] private actors;
    ModelMarket[] private model;
    mapping(uint256 market => mapping(uint256 actor => Position)) private positions;
    uint256[2] public deposits;
    uint256[2] public fees;
    uint256[2] public paid;
    uint256[2] public donations;
    uint256 public successfulBets;
    uint256 public successfulClaims;
    uint256 public successfulSettlements;
    uint256 public successfulExpiries;

    constructor(BetPool target, address[6] memory wallets) {
        pool = target;
        imd = MockToken(IMD);
        shift = MockToken(SHIFT);
        actors = wallets;
        for (uint256 i; i < wallets.length; ++i) {
            _fund(wallets[i]);
        }
    }

    function open(uint256 tokenSeed, uint256 lifetimeSeed) public {
        if (pool.paused() || model.length >= 32) return;
        uint8 tokenIndex = uint8(tokenSeed % 2);
        bytes32 id = keccak256(abi.encode("invariant-market", model.length));
        uint64 closesAt = uint64(vm.getBlockTimestamp() + 1 hours + lifetimeSeed % 2 days);
        _createAt(id, tokenIndex == 0 ? IMD : SHIFT, closesAt);
        model.push();
        ModelMarket storage m = model[model.length - 1];
        m.id = id;
        m.tokenIndex = tokenIndex;
        m.closesAt = closesAt;
    }

    function betOn(uint256 marketSeed, uint256 actorSeed, uint256 sideSeed, uint256 amountSeed, uint16 weightSeed)
        public
    {
        if (pool.paused()) return;
        (bool found, uint256 index) = _findMarket(marketSeed, 0);
        if (!found) return;
        ModelMarket storage m = model[index];
        uint256 actor = actorSeed % actors.length;
        uint8 side = uint8(sideSeed % 2);
        address tokenAddress = m.tokenIndex == 0 ? IMD : SHIFT;
        (uint256 min, uint256 max) = pool.limits(tokenAddress);
        uint256 amount = min + amountSeed % (max - min + 1);
        uint16 weight = uint16(500 + uint256(weightSeed) % 9_501);
        // Each action has sufficient funds and a precise allowance; no action is silently reverted.
        MockToken(tokenAddress).mint(actors[actor], amount);
        vm.prank(actors[actor]);
        MockToken(tokenAddress).approve(address(pool), amount);
        _place(m.id, actors[actor], side, amount, weight);
        uint256 shares = amount * weight / 10_000;
        positions[index][actor].amounts[side] += amount;
        positions[index][actor].shares[side] += shares;
        m.totals[side] += amount;
        m.shares[side] += shares;
        deposits[m.tokenIndex] += amount;
        ++successfulBets;
    }

    function settleMarket(uint256 marketSeed, uint8 outcomeSeed) public {
        (bool found, uint256 index) = _findMarket(marketSeed, 1);
        if (!found) return;
        ModelMarket storage m = model[index];
        uint8 outcome = outcomeSeed % 3;
        _settle(m.id, outcome);
        m.settled = true;
        m.outcome = outcome;
        m.refundable = outcome == 2 || m.totals[0] == 0 || m.totals[1] == 0;
        if (!m.refundable) {
            m.fee = m.totals[1 - outcome] / 20;
            fees[m.tokenIndex] += m.fee;
        }
        ++successfulSettlements;
    }

    function expireMarket(uint256 marketSeed) public {
        (bool found, uint256 index) = _findMarket(marketSeed, 2);
        if (!found) return;
        _expire(index);
    }

    function claimOne(uint256 marketSeed, uint256 actorSeed) public {
        if (model.length == 0) return;
        uint256 index = marketSeed % model.length;
        uint256 actor = actorSeed % actors.length;
        if (!model[index].settled || positions[index][actor].claimed) return;
        _doClaim(index, actor);
    }

    function claimBatch(uint256 firstSeed, uint256 secondSeed, uint256 actorSeed) public {
        if (model.length < 2) return;
        uint256 first = firstSeed % model.length;
        uint256 second = secondSeed % model.length;
        uint256 actor = actorSeed % actors.length;
        if (
            first == second || !model[first].settled || !model[second].settled || positions[first][actor].claimed
                || positions[second][actor].claimed
        ) return;
        uint256 firstAmount = _expected(first, actor);
        uint256 secondAmount = _expected(second, actor);
        uint256 imdBefore = imd.balanceOf(actors[actor]);
        uint256 shiftBefore = shift.balanceOf(actors[actor]);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = model[first].id;
        ids[1] = model[second].id;
        vm.prank(actors[actor]);
        pool.claimMany(ids);
        uint256 expectedIMD =
            (model[first].tokenIndex == 0 ? firstAmount : 0) + (model[second].tokenIndex == 0 ? secondAmount : 0);
        uint256 expectedSHIFT =
            (model[first].tokenIndex == 1 ? firstAmount : 0) + (model[second].tokenIndex == 1 ? secondAmount : 0);
        assertEq(imd.balanceOf(actors[actor]) - imdBefore, expectedIMD);
        assertEq(shift.balanceOf(actors[actor]) - shiftBefore, expectedSHIFT);
        _recordClaim(first, actor, firstAmount);
        _recordClaim(second, actor, secondAmount);
    }

    function advance(uint256 secondsSeed) public {
        vm.warp(vm.getBlockTimestamp() + secondsSeed % 36 hours);
    }

    function togglePause() public {
        bool wasPaused = pool.paused();
        vm.prank(OWNER);
        if (wasPaused) pool.unpause();
        else pool.pause();
    }

    function donate(uint256 tokenSeed, uint256 amountSeed) public {
        uint256 index = tokenSeed % 2;
        uint256 amount = amountSeed % 1_000 ether;
        MockToken token = index == 0 ? imd : shift;
        token.mint(address(this), amount);
        token.transfer(address(pool), amount);
        donations[index] += amount;
    }

    function assertSolventAndConserved() external view {
        uint256[2] memory owed;
        uint256[2] memory reserves;
        for (uint256 i; i < model.length; ++i) {
            ModelMarket storage m = model[i];
            uint256 remaining = m.totals[0] + m.totals[1] - m.fee - m.paid;
            assertEq(pool.remainingPot(m.id), remaining, "isolated market reserve");
            reserves[m.tokenIndex] += remaining;
            uint256 marketOwed;
            if (!m.settled) {
                marketOwed = m.totals[0] + m.totals[1];
            } else {
                for (uint256 j; j < actors.length; ++j) {
                    marketOwed += _expected(i, j);
                }
            }
            assertGe(remaining, marketOwed, "each market covers its own liabilities");
            owed[m.tokenIndex] += marketOwed;
        }
        for (uint256 i; i < 2; ++i) {
            MockToken token = i == 0 ? imd : shift;
            uint256 balance = token.balanceOf(address(pool));
            assertGe(balance, owed[i], "balance covers all outstanding claims and unsettled bets");
            assertEq(balance, reserves[i] + donations[i], "all funds accounted for");
            assertEq(token.balanceOf(SPLITTER), fees[i], "only exact losing-side fees paid");
            assertLe(paid[i] + fees[i], deposits[i], "no overpayment even with donations");
            assertEq(balance + paid[i] + fees[i], deposits[i] + donations[i], "conservation");
        }
    }

    function assertStateMatchesModel() external view {
        for (uint256 i; i < model.length; ++i) {
            ModelMarket storage m = model[i];
            BetPool.Market memory actual = _readMarket(m.id);
            assertEq(actual.token, m.tokenIndex == 0 ? IMD : SHIFT);
            assertEq(actual.closesAt, m.closesAt);
            assertEq(actual.game, GAME);
            assertEq(actual.totalA, m.totals[0]);
            assertEq(actual.totalB, m.totals[1]);
            assertEq(actual.sharesA, m.shares[0]);
            assertEq(actual.sharesB, m.shares[1]);
            assertEq(actual.settled, m.settled);
            assertEq(actual.outcome, m.outcome);
            assertEq(actual.refundable, m.refundable);
            for (uint256 j; j < actors.length; ++j) {
                Position storage p = positions[i][j];
                BetPool.Bet memory b = _readBet(m.id, actors[j]);
                assertEq(b.amountA, p.amounts[0]);
                assertEq(b.amountB, p.amounts[1]);
                assertEq(b.sharesA, p.shares[0]);
                assertEq(b.sharesB, p.shares[1]);
                assertEq(b.claimed, p.claimed);
                assertEq(pool.claimable(m.id, actors[j]), _expected(i, j));
            }
        }
    }

    /// @dev Drain every valid entitlement at the end of each invariant run, proving liveness too.
    function finishAndClaim() external {
        uint256 finalTime = vm.getBlockTimestamp();
        for (uint256 i; i < model.length; ++i) {
            uint256 timeout = uint256(model[i].closesAt) + 24 hours;
            if (timeout > finalTime) finalTime = timeout;
        }
        vm.warp(finalTime);
        for (uint256 i; i < model.length; ++i) {
            if (!model[i].settled) _expire(i);
            for (uint256 j; j < actors.length; ++j) {
                if (!positions[i][j].claimed) _doClaim(i, j);
            }
            if (model[i].refundable) {
                assertEq(pool.remainingPot(model[i].id), 0, "refunds leave no dust");
            } else {
                uint256 winners;
                for (uint256 j; j < actors.length; ++j) {
                    if (positions[i][j].amounts[model[i].outcome] != 0) ++winners;
                }
                assertLt(pool.remainingPot(model[i].id), winners, "dust is less than one wei per winner");
            }
        }
    }

    function _expected(uint256 index, uint256 actor) private view returns (uint256) {
        ModelMarket storage m = model[index];
        Position storage p = positions[index][actor];
        if (!m.settled || p.claimed) return 0;
        if (m.refundable) return p.amounts[0] + p.amounts[1];
        return p.amounts[m.outcome] + (m.totals[1 - m.outcome] - m.fee) * p.shares[m.outcome] / m.shares[m.outcome];
    }

    function _doClaim(uint256 index, uint256 actor) private {
        uint256 expected = _expected(index, actor);
        MockToken token = model[index].tokenIndex == 0 ? imd : shift;
        uint256 before = token.balanceOf(actors[actor]);
        assertEq(_claim(model[index].id, actors[actor]), expected, "model payout");
        assertEq(token.balanceOf(actors[actor]) - before, expected, "actual payout");
        _recordClaim(index, actor, expected);
    }

    function _recordClaim(uint256 index, uint256 actor, uint256 amount) private {
        positions[index][actor].claimed = true;
        model[index].paid += amount;
        paid[model[index].tokenIndex] += amount;
        ++successfulClaims;
    }

    function _expire(uint256 index) private {
        pool.expire(model[index].id);
        model[index].settled = true;
        model[index].refundable = true;
        model[index].outcome = 2;
        ++successfulExpiries;
    }

    // mode 0: open for bets, 1: unsettled, 2: eligible for expiry.
    function _findMarket(uint256 seed, uint256 mode) private view returns (bool, uint256) {
        uint256 count = model.length;
        if (count == 0) return (false, 0);
        uint256 start = seed % count;
        for (uint256 i; i < count; ++i) {
            uint256 index = (start + i) % count;
            ModelMarket storage m = model[index];
            if (m.settled) continue;
            if (mode == 0 && vm.getBlockTimestamp() >= m.closesAt) continue;
            if (mode == 2 && vm.getBlockTimestamp() < uint256(m.closesAt) + 24 hours) continue;
            return (true, index);
        }
        return (false, 0);
    }
}

contract BetPoolInvariantTest is BetPoolTestBase {
    BetPoolHandler private handler;

    function setUp() public override {
        super.setUp();
        address[6] memory actors = [alice, bob, carol, dave, makeAddr("eve"), makeAddr("frank")];
        handler = new BetPoolHandler(pool, actors);
        for (uint256 i; i < 4; ++i) {
            handler.open(i, 1 days);
            handler.betOn(i, 0, 0, 5 ether, 9_500);
            handler.betOn(i, 1, 0, 10 ether, 2_000);
            handler.betOn(i, 2, 1, 3 ether, 500);
        }
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.open.selector;
        selectors[1] = handler.betOn.selector;
        selectors[2] = handler.settleMarket.selector;
        selectors[3] = handler.expireMarket.selector;
        selectors[4] = handler.claimOne.selector;
        selectors[5] = handler.claimBatch.selector;
        selectors[6] = handler.advance.selector;
        selectors[7] = handler.togglePause.selector;
        selectors[8] = handler.donate.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_BalanceCoversLiabilitiesAndTotalPayoutsNeverExceedBets() public view {
        handler.assertSolventAndConserved();
    }

    function invariant_RecordedStakesAndPayoutsMatchIndependentModel() public view {
        handler.assertStateMatchesModel();
    }

    function afterInvariant() public {
        handler.finishAndClaim();
        handler.assertSolventAndConserved();
        handler.assertStateMatchesModel();
    }

    function test_HandlerExercisesPayoutExpiryPauseAndBatch() public {
        handler.settleMarket(0, 0);
        handler.settleMarket(1, 1);
        handler.claimBatch(0, 1, 0);
        handler.claimOne(0, 1);
        handler.togglePause();
        handler.advance(35 hours);
        handler.advance(35 hours);
        handler.expireMarket(2);
        handler.claimOne(2, 0);
        handler.donate(0, 1 ether);
        handler.finishAndClaim();
        handler.assertSolventAndConserved();
        handler.assertStateMatchesModel();
        assertGt(handler.successfulBets(), 0);
        assertGt(handler.successfulClaims(), 0);
        assertGt(handler.successfulSettlements(), 0);
        assertGt(handler.successfulExpiries(), 0);
    }
}
