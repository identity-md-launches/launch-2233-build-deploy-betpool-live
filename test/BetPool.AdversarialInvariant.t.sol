// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPoolTestBase, BetPool, MockToken} from "./helpers/BetPoolTestBase.sol";

/// @dev Drives valid market activity interleaved with attacks that must always fail: ticket replay,
/// re-settlement with a different signed result, double claims, late bets, forged results, early
/// expiry and non-owner administration. Every attack is wrapped in try/catch so the run never
/// reverts; a succeeding attack is counted and fails the invariant.
contract AdversarialHandler is BetPoolTestBase {
    struct Ghost {
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

    struct Pos {
        uint256[2] amounts;
        uint256[2] shares;
        bool claimed;
    }

    struct Used {
        Ticket ticket;
        bytes signature;
    }

    address[4] internal actors;
    address internal attacker;
    Ghost[] internal ghosts;
    mapping(uint256 => mapping(uint256 => Pos)) internal pos;
    Used[] internal used;
    uint256[2] public totalIn;
    uint256[2] public totalOut;
    uint256 public attackSuccesses;
    uint256 public attacksTried;
    string public lastSuccessfulAttack;

    constructor(BetPool target, address[4] memory wallets, address evil) {
        pool = target;
        imd = MockToken(IMD);
        shift = MockToken(SHIFT);
        actors = wallets;
        attacker = evil;
        for (uint256 i; i < 4; ++i) {
            _fund(wallets[i]);
        }
        _fund(evil);
    }

    // ---- valid actions ----------------------------------------------------------------

    function open(uint256 tokenSeed, uint256 lifeSeed) public {
        if (ghosts.length >= 24) return;
        uint8 ti = uint8(tokenSeed % 2);
        bytes32 id = keccak256(abi.encode("adversarial", ghosts.length));
        uint64 closesAt = uint64(vm.getBlockTimestamp() + 10 minutes + lifeSeed % 1 days);
        _createAt(id, ti == 0 ? IMD : SHIFT, closesAt);
        ghosts.push();
        Ghost storage g = ghosts[ghosts.length - 1];
        g.id = id;
        g.tokenIndex = ti;
        g.closesAt = closesAt;
    }

    function placeBet(uint256 mSeed, uint256 aSeed, uint256 sSeed, uint256 amtSeed, uint256 wSeed) public {
        if (ghosts.length == 0) return;
        uint256 index = mSeed % ghosts.length;
        Ghost storage g = ghosts[index];
        if (g.settled || vm.getBlockTimestamp() >= g.closesAt) return;
        uint256 actor = aSeed % 4;
        uint8 side = uint8(sSeed % 2);
        (uint256 min, uint256 max) = pool.limits(g.tokenIndex == 0 ? IMD : SHIFT);
        // Bias towards the limits themselves.
        uint256 pick = amtSeed % 4;
        uint256 amount = pick == 0 ? min : pick == 1 ? max : min + amtSeed % (max - min + 1);
        uint16 weight = uint16(wSeed % 3 == 0 ? 500 : wSeed % 3 == 1 ? 10_000 : 500 + wSeed % 9_501);
        Ticket memory t = _ticket(g.id, actors[actor], side, amount, weight);
        bytes memory signature = _ticketSignature(t);
        _submit(t, signature);
        used.push(Used(t, signature));
        uint256 shares = amount * weight / 10_000;
        pos[index][actor].amounts[side] += amount;
        pos[index][actor].shares[side] += shares;
        g.totals[side] += amount;
        g.shares[side] += shares;
        totalIn[g.tokenIndex] += amount;
    }

    function settle(uint256 mSeed, uint8 oSeed) public {
        if (ghosts.length == 0) return;
        uint256 index = mSeed % ghosts.length;
        Ghost storage g = ghosts[index];
        if (g.settled) return;
        uint8 outcome = oSeed % 3;
        _settle(g.id, outcome);
        g.settled = true;
        g.outcome = outcome;
        g.refundable = outcome == 2 || g.totals[0] == 0 || g.totals[1] == 0;
        if (!g.refundable) {
            g.fee = g.totals[1 - outcome] * 500 / 10_000;
            totalOut[g.tokenIndex] += g.fee;
        }
    }

    function expire(uint256 mSeed) public {
        if (ghosts.length == 0) return;
        uint256 index = mSeed % ghosts.length;
        Ghost storage g = ghosts[index];
        if (g.settled || vm.getBlockTimestamp() < uint256(g.closesAt) + 24 hours) return;
        pool.expire(g.id);
        g.settled = true;
        g.outcome = 2;
        g.refundable = true;
    }

    function claim(uint256 mSeed, uint256 aSeed) public {
        if (ghosts.length == 0) return;
        uint256 index = mSeed % ghosts.length;
        uint256 actor = aSeed % 4;
        if (!ghosts[index].settled || pos[index][actor].claimed) return;
        uint256 expected = owedTo(index, actor);
        MockToken token = ghosts[index].tokenIndex == 0 ? imd : shift;
        uint256 before = token.balanceOf(actors[actor]);
        _claim(ghosts[index].id, actors[actor]);
        assertEq(token.balanceOf(actors[actor]) - before, expected, "claim pays the weighted entitlement");
        pos[index][actor].claimed = true;
        ghosts[index].paid += expected;
        totalOut[ghosts[index].tokenIndex] += expected;
    }

    function warp(uint256 seconds_) public {
        vm.warp(vm.getBlockTimestamp() + seconds_ % 30 hours);
    }

    // ---- attacks: each must fail and move nothing ---------------------------------------

    function attackReplayTicket(uint256 seed, bool asAttacker) public {
        if (used.length == 0) return;
        Used memory u = used[seed % used.length];
        address caller = asAttacker ? attacker : u.ticket.bettor;
        _snapshot();
        vm.prank(caller);
        try pool.bet(
            u.ticket.marketId,
            u.ticket.side,
            u.ticket.amount,
            u.ticket.weightBps,
            u.ticket.expiry,
            u.ticket.nonce,
            u.signature
        ) {
            _succeeded("ticket replay");
        } catch {}
        _checkUnchanged();
    }

    function attackResettle(uint256 mSeed, uint8 oSeed) public {
        if (ghosts.length == 0) return;
        Ghost storage g = ghosts[mSeed % ghosts.length];
        if (!g.settled) return;
        // Even a genuine signer-signed result cannot change a finished market.
        uint8 outcome = uint8((g.outcome + 1 + oSeed % 2) % 3);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory signature = _sign(address(pool), block.chainid, SIGNER_KEY, _outcomeHash(g.id, outcome, deadline));
        _snapshot();
        try pool.settle(g.id, outcome, deadline, signature) {
            _succeeded("re-settle");
        } catch {}
        _checkUnchanged();
    }

    function attackForgedSettle(uint256 mSeed, uint8 oSeed) public {
        if (ghosts.length == 0) return;
        Ghost storage g = ghosts[mSeed % ghosts.length];
        if (g.settled) return;
        uint8 outcome = oSeed % 3;
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory signature = _sign(address(pool), block.chainid, OTHER_KEY, _outcomeHash(g.id, outcome, deadline));
        _snapshot();
        vm.prank(attacker);
        try pool.settle(g.id, outcome, deadline, signature) {
            _succeeded("forged settle");
        } catch {}
        _checkUnchanged();
    }

    function attackDoubleClaim(uint256 mSeed, uint256 aSeed) public {
        if (ghosts.length == 0) return;
        uint256 index = mSeed % ghosts.length;
        uint256 actor = aSeed % 4;
        if (!pos[index][actor].claimed) return;
        _snapshot();
        vm.prank(actors[actor]);
        try pool.claim(ghosts[index].id) {
            _succeeded("double claim");
        } catch {}
        _checkUnchanged();
    }

    function attackClaimUnsettled(uint256 mSeed, uint256 aSeed) public {
        if (ghosts.length == 0) return;
        Ghost storage g = ghosts[mSeed % ghosts.length];
        if (g.settled) return;
        _snapshot();
        vm.prank(actors[aSeed % 4]);
        try pool.claim(g.id) {
            _succeeded("claim before settlement");
        } catch {}
        _checkUnchanged();
    }

    function attackLateBet(uint256 mSeed, uint256 aSeed) public {
        if (ghosts.length == 0) return;
        Ghost storage g = ghosts[mSeed % ghosts.length];
        if (!g.settled && vm.getBlockTimestamp() < g.closesAt) return;
        (uint256 min,) = pool.limits(g.tokenIndex == 0 ? IMD : SHIFT);
        Ticket memory t = _ticket(g.id, actors[aSeed % 4], uint8(aSeed % 2), min, 10_000);
        bytes memory signature = _ticketSignature(t);
        _snapshot();
        vm.prank(t.bettor);
        try pool.bet(t.marketId, t.side, t.amount, t.weightBps, t.expiry, t.nonce, signature) {
            _succeeded("bet on closed market");
        } catch {}
        _checkUnchanged();
    }

    function attackStolenTicket(uint256 mSeed, uint256 aSeed) public {
        if (ghosts.length == 0) return;
        Ghost storage g = ghosts[mSeed % ghosts.length];
        if (g.settled || vm.getBlockTimestamp() >= g.closesAt) return;
        (uint256 min,) = pool.limits(g.tokenIndex == 0 ? IMD : SHIFT);
        // A ticket issued to a real bettor, submitted by the attacker.
        Ticket memory t = _ticket(g.id, actors[aSeed % 4], uint8(aSeed % 2), min, 10_000);
        bytes memory signature = _ticketSignature(t);
        _snapshot();
        vm.prank(attacker);
        try pool.bet(t.marketId, t.side, t.amount, t.weightBps, t.expiry, t.nonce, signature) {
            _succeeded("ticket used by another wallet");
        } catch {}
        _checkUnchanged();
    }

    function attackEarlyExpire(uint256 mSeed) public {
        if (ghosts.length == 0) return;
        Ghost storage g = ghosts[mSeed % ghosts.length];
        if (g.settled || vm.getBlockTimestamp() >= uint256(g.closesAt) + 24 hours) return;
        _snapshot();
        vm.prank(attacker);
        try pool.expire(g.id) {
            _succeeded("early expire");
        } catch {}
        _checkUnchanged();
    }

    function attackAdmin(uint256 seed) public {
        _snapshot();
        vm.startPrank(attacker);
        uint256 which = seed % 4;
        if (which == 0) {
            try pool.setSigner(attacker) {
                _succeeded("non-owner setSigner");
            } catch {}
        } else if (which == 1) {
            try pool.setLimits(IMD, 1, 10_000 ether) {
                _succeeded("non-owner setLimits");
            } catch {}
        } else if (which == 2) {
            try pool.pause() {
                _succeeded("non-owner pause");
            } catch {}
        } else {
            try pool.unpause() {
                _succeeded("non-owner unpause");
            } catch {}
        }
        vm.stopPrank();
        _checkUnchanged();
        assertEq(pool.signer(), vm.addr(SIGNER_KEY));
        assertFalse(pool.paused());
    }

    // ---- views for the invariants -----------------------------------------------------

    function owedTo(uint256 index, uint256 actor) public view returns (uint256) {
        Ghost storage g = ghosts[index];
        Pos storage p = pos[index][actor];
        if (p.claimed) return 0;
        if (!g.settled || g.refundable) return p.amounts[0] + p.amounts[1];
        uint8 w = g.outcome;
        return p.amounts[w] + (g.totals[1 - w] - g.fee) * p.shares[w] / g.shares[w];
    }

    function checkSolvent() external view {
        uint256[2] memory owed;
        for (uint256 i; i < ghosts.length; ++i) {
            uint256 marketOwed;
            for (uint256 j; j < 4; ++j) {
                marketOwed += owedTo(i, j);
            }
            Ghost storage g = ghosts[i];
            assertLe(g.paid + g.fee, g.totals[0] + g.totals[1], "market never pays more than it took");
            assertGe(g.totals[0] + g.totals[1] - g.paid - g.fee, marketOwed, "market covers what it owes");
            owed[g.tokenIndex] += marketOwed;
        }
        for (uint256 t; t < 2; ++t) {
            uint256 balance = (t == 0 ? imd : shift).balanceOf(address(pool));
            assertGe(balance, owed[t], "pool holds at least what it owes");
            assertLe(totalOut[t], totalIn[t], "payouts plus fees never exceed bets");
            assertEq(balance + totalOut[t], totalIn[t], "conservation");
        }
    }

    function checkFinishedNeverReopens() external view {
        for (uint256 i; i < ghosts.length; ++i) {
            Ghost storage g = ghosts[i];
            (,,, uint256 totalA, uint256 totalB,,, bool settled, uint8 outcome, bool refundable) = pool.markets(g.id);
            assertEq(settled, g.settled, "settled flag");
            assertEq(totalA, g.totals[0]);
            assertEq(totalB, g.totals[1]);
            if (g.settled) {
                assertEq(outcome, g.outcome, "outcome fixed once settled");
                assertEq(refundable, g.refundable, "refundability fixed once settled");
            }
            for (uint256 j; j < 4; ++j) {
                (,,,, bool claimed) = pool.betsOf(g.id, actors[j]);
                assertEq(claimed, pos[i][j].claimed, "claim flag");
            }
        }
    }

    function ghostCount() external view returns (uint256) {
        return ghosts.length;
    }

    // ---- helpers ----------------------------------------------------------------------

    uint256 private snapImd;
    uint256 private snapShift;
    uint256 private snapAttackerImd;
    uint256 private snapAttackerShift;

    function _snapshot() private {
        ++attacksTried;
        snapImd = imd.balanceOf(address(pool));
        snapShift = shift.balanceOf(address(pool));
        snapAttackerImd = imd.balanceOf(attacker);
        snapAttackerShift = shift.balanceOf(attacker);
    }

    function _checkUnchanged() private view {
        assertEq(imd.balanceOf(address(pool)), snapImd, "attack moved IMD");
        assertEq(shift.balanceOf(address(pool)), snapShift, "attack moved SHIFT");
        assertEq(imd.balanceOf(attacker), snapAttackerImd, "attacker gained IMD");
        assertEq(shift.balanceOf(attacker), snapAttackerShift, "attacker gained SHIFT");
    }

    function _succeeded(string memory what) private {
        ++attackSuccesses;
        lastSuccessfulAttack = what;
    }
}

contract BetPoolAdversarialInvariantTest is BetPoolTestBase {
    AdversarialHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new AdversarialHandler(pool, [alice, bob, carol, dave], makeAddr("mallory"));
        handler.open(0, 12 hours);
        handler.open(1, 12 hours);
        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = handler.open.selector;
        selectors[1] = handler.placeBet.selector;
        selectors[2] = handler.settle.selector;
        selectors[3] = handler.expire.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.warp.selector;
        selectors[6] = handler.attackReplayTicket.selector;
        selectors[7] = handler.attackResettle.selector;
        selectors[8] = handler.attackForgedSettle.selector;
        selectors[9] = handler.attackDoubleClaim.selector;
        selectors[10] = handler.attackClaimUnsettled.selector;
        selectors[11] = handler.attackLateBet.selector;
        selectors[12] = handler.attackStolenTicket.selector;
        selectors[13] = handler.attackEarlyExpire.selector;
        selectors[14] = handler.attackAdmin.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 80
    function invariant_NoAttackEverSucceeds() public view {
        assertEq(handler.attackSuccesses(), 0, handler.lastSuccessfulAttack());
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 80
    function invariant_PoolHoldsWhatItOwesAndNeverOverpays() public view {
        handler.checkSolvent();
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 80
    function invariant_FinishedMarketsNeverReopen() public view {
        handler.checkFinishedNeverReopens();
    }

    /// @dev Deterministic sequence proving each attack path is reachable and refused.
    function test_EveryAttackPathIsReachableAndRefused() public {
        handler.placeBet(0, 0, 0, 0, 0);
        handler.placeBet(0, 1, 1, 1, 1);
        handler.placeBet(0, 2, 0, 2, 2);
        handler.placeBet(1, 3, 1, 3, 4);
        handler.attackReplayTicket(0, false);
        handler.attackReplayTicket(1, true);
        handler.attackStolenTicket(0, 1);
        handler.attackForgedSettle(0, 0);
        handler.attackClaimUnsettled(0, 0);
        handler.attackEarlyExpire(0);
        handler.attackAdmin(0);
        handler.attackAdmin(1);
        handler.attackAdmin(2);
        handler.attackAdmin(3);
        handler.settle(0, 0);
        handler.attackResettle(0, 0);
        handler.attackResettle(0, 1);
        handler.attackLateBet(0, 0);
        handler.claim(0, 0);
        handler.claim(0, 1);
        handler.attackDoubleClaim(0, 0);
        handler.attackDoubleClaim(0, 1);
        handler.warp(29 hours);
        handler.warp(29 hours);
        handler.attackLateBet(1, 3);
        handler.expire(1);
        handler.claim(1, 3);
        handler.checkSolvent();
        handler.checkFinishedNeverReopens();
        assertEq(handler.attacksTried(), 16);
        assertEq(handler.attackSuccesses(), 0);
    }
}
