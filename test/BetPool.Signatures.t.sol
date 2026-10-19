// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPoolTestBase, BetPool} from "./helpers/BetPoolTestBase.sol";

contract BetPoolSignaturesTest is BetPoolTestBase {
    function test_TicketBindsEveryField() public {
        _create(MARKET, IMD);
        bytes32 second = keccak256("second");
        _create(second, IMD);
        for (uint256 field; field < 7; ++field) {
            Ticket memory t = _ticket(MARKET, alice, 0, 1 ether, 5_000);
            bytes memory signature = _ticketSignature(t);
            if (field == 0) t.marketId = second;
            if (field == 1) t.bettor = bob;
            if (field == 2) t.side = 1;
            if (field == 3) ++t.amount;
            if (field == 4) ++t.weightBps;
            if (field == 5) --t.expiry;
            if (field == 6) t.nonce = keccak256("tampered");
            vm.expectRevert(BetPool.InvalidSignature.selector);
            _submit(t, signature);
            assertFalse(pool.usedNonce(t.nonce));
        }
        assertEq(imd.balanceOf(address(pool)), 0);
    }

    function test_TicketRejectsWrongSignerContractChainNameAndVersion() public {
        _create(MARKET, IMD);
        Ticket memory t = _ticket(MARKET, alice, 0, 1 ether, 5_000);
        bytes32 h = _ticketHash(t);
        bytes[5] memory signatures;
        signatures[0] = _sign(address(pool), block.chainid, OTHER_KEY, h);
        signatures[1] = _sign(address(this), block.chainid, SIGNER_KEY, h);
        signatures[2] = _sign(address(pool), block.chainid + 1, SIGNER_KEY, h);
        for (uint256 i; i < 2; ++i) {
            bytes32 domain = keccak256(
                abi.encode(
                    DOMAIN_TYPE,
                    i == 0 ? keccak256("WrongName") : keccak256("NightshiftBets"),
                    i == 1 ? keccak256("2") : keccak256("1"),
                    block.chainid,
                    address(pool)
                )
            );
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, keccak256(abi.encodePacked(hex"1901", domain, h)));
            signatures[i + 3] = abi.encodePacked(r, s, v);
        }
        for (uint256 i; i < signatures.length; ++i) {
            vm.expectRevert(BetPool.InvalidSignature.selector);
            _submit(t, signatures[i]);
        }
    }

    function test_ChainIdChangeInvalidatesCachedDomainAndAcceptsNewDomain() public {
        _create(MARKET, IMD);
        Ticket memory t = _ticket(MARKET, alice, 0, 1 ether, 5_000);
        bytes memory oldSignature = _ticketSignature(t);
        vm.chainId(2);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        _submit(t, oldSignature);
        _submit(t, _ticketSignature(t));
        assertEq(_readBet(MARKET, alice).amountA, 1 ether);
    }

    function test_TicketsCannotReplayOnAnotherPool() public {
        _create(MARKET, IMD);
        BetPool first = pool;
        Ticket memory t = _ticket(MARKET, alice, 0, 1 ether, 5_000);
        bytes memory signature = _ticketSignature(t);
        pool = new BetPool();
        vm.prank(OWNER);
        pool.setSigner(vm.addr(SIGNER_KEY));
        _create(MARKET, IMD);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        _submit(t, signature);
        pool = first;
        _submit(t, signature);
    }

    function test_RejectsMalformedHighSAndInvalidVSignatures() public {
        _create(MARKET, IMD);
        Ticket memory t = _ticket(MARKET, alice, 0, 1 ether, 5_000);
        bytes memory signature = _ticketSignature(t);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        uint256 order = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        bytes[6] memory bad;
        bad[0] = hex"";
        bad[1] = new bytes(64);
        bad[2] = new bytes(66);
        bad[3] = abi.encodePacked(r, bytes32(order - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        bad[4] = abi.encodePacked(r, s, uint8(0));
        bad[5] = new bytes(65);
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(BetPool.InvalidSignature.selector);
            _submit(t, bad[i]);
        }
        _submit(t, signature);
    }

    function test_NonceIsGlobalAndUsedOnlyOnce() public {
        bytes32 second = keccak256("second");
        _create(MARKET, IMD);
        _create(second, SHIFT);
        Ticket memory t = _ticket(MARKET, alice, 0, 1 ether, 5_000);
        bytes memory signature = _ticketSignature(t);
        _submit(t, signature);
        assertTrue(pool.usedNonce(t.nonce));
        vm.expectRevert(BetPool.NonceAlreadyUsed.selector);
        _submit(t, signature);
        t.bettor = bob;
        t.marketId = second;
        t.side = 1;
        t.amount = 1_000 ether;
        signature = _ticketSignature(t);
        vm.expectRevert(BetPool.NonceAlreadyUsed.selector);
        _submit(t, signature);
    }

    function test_TicketExpiryBoundaries() public {
        _create(MARKET, IMD);
        Ticket memory t = _ticket(MARKET, alice, 0, 1 ether, 5_000);
        t.expiry = uint64(block.timestamp - 1);
        bytes memory signature = _ticketSignature(t);
        vm.expectRevert(BetPool.TicketExpired.selector);
        _submit(t, signature);
        assertFalse(pool.usedNonce(t.nonce));
        t.expiry = uint64(block.timestamp + 121);
        signature = _ticketSignature(t);
        vm.expectRevert(BetPool.TicketExpiryTooFar.selector);
        _submit(t, signature);
        t.expiry = uint64(block.timestamp);
        _submit(t, _ticketSignature(t));
        t = _ticket(MARKET, alice, 1, 1 ether, 500);
        _submit(t, _ticketSignature(t));
    }

    function test_ExpiredTicketFailsEvenWithValidSignature() public {
        _create(MARKET, IMD);
        Ticket memory t = _ticket(MARKET, alice, 0, 1 ether, 5_000);
        bytes memory signature = _ticketSignature(t);
        vm.warp(uint256(t.expiry) + 1);
        vm.expectRevert(BetPool.TicketExpired.selector);
        _submit(t, signature);
    }

    function testFuzz_InvalidWeightsRefused(uint16 weight) public {
        vm.assume(weight < 500 || weight > 10_000);
        _create(MARKET, IMD);
        Ticket memory t = _ticket(MARKET, alice, 0, 1 ether, weight);
        bytes memory signature = _ticketSignature(t);
        vm.expectRevert(BetPool.InvalidWeight.selector);
        _submit(t, signature);
    }

    function testFuzz_InvalidSidesRefused(uint8 side) public {
        side = uint8(bound(side, 2, type(uint8).max));
        _create(MARKET, IMD);
        Ticket memory t = _ticket(MARKET, alice, side, 1 ether, 5_000);
        bytes memory signature = _ticketSignature(t);
        vm.expectRevert(BetPool.InvalidSide.selector);
        _submit(t, signature);
    }

    function test_BelowAndAboveLimitsForBothTokens() public {
        address[2] memory tokens = [IMD, SHIFT];
        for (uint256 i; i < 2; ++i) {
            bytes32 id = bytes32(i);
            _create(id, tokens[i]);
            (uint256 min, uint256 max) = pool.limits(tokens[i]);
            Ticket memory t = _ticket(id, alice, 0, min - 1, 5_000);
            bytes memory signature = _ticketSignature(t);
            vm.expectRevert(BetPool.AmountOutsideLimits.selector);
            _submit(t, signature);
            t.amount = max + 1;
            signature = _ticketSignature(t);
            vm.expectRevert(BetPool.AmountOutsideLimits.selector);
            _submit(t, signature);
        }
    }

    function test_ZeroSharesAreRejectedWithoutConsumingNonce() public {
        vm.prank(OWNER);
        pool.setLimits(IMD, 1, 500 ether);
        _create(MARKET, IMD);
        Ticket memory t = _ticket(MARKET, alice, 0, 19, 500);
        bytes memory signature = _ticketSignature(t);
        vm.expectRevert(BetPool.ZeroShares.selector);
        _submit(t, signature);
        assertFalse(pool.usedNonce(t.nonce));
        t.amount = 20;
        _submit(t, _ticketSignature(t));
        assertEq(_readBet(MARKET, alice).sharesA, 1);
    }

    function test_BetsOnUnknownSettledAndClosedMarketsFail() public {
        Ticket memory t = _ticket(MARKET, alice, 0, 1 ether, 5_000);
        bytes memory signature = _ticketSignature(t);
        vm.expectRevert(BetPool.UnknownMarket.selector);
        _submit(t, signature);
        uint64 cutoff = _create(MARKET, IMD);
        vm.warp(cutoff);
        t.expiry = cutoff + 120;
        signature = _ticketSignature(t);
        vm.expectRevert(BetPool.BettingClosed.selector);
        _submit(t, signature);
        _settle(MARKET, 2);
        vm.expectRevert(BetPool.MarketAlreadySettled.selector);
        _submit(t, signature);
    }

    function test_EarlySettlementImmediatelyClosesBetting() public {
        _create(MARKET, IMD);
        Ticket memory t = _ticket(MARKET, alice, 0, 1 ether, 5_000);
        bytes memory signature = _ticketSignature(t);
        _settle(MARKET, 0);
        vm.expectRevert(BetPool.MarketAlreadySettled.selector);
        _submit(t, signature);
    }

    function test_MarketSignatureBindsEveryField() public {
        uint64 cutoff = uint64(block.timestamp + 1 hours);
        bytes memory signature = _sign(address(pool), 1, SIGNER_KEY, _marketHash(MARKET, IMD, cutoff, GAME));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(keccak256("other"), IMD, cutoff, GAME, signature);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(MARKET, SHIFT, cutoff, GAME, signature);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(MARKET, IMD, cutoff + 1, GAME, signature);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(MARKET, IMD, cutoff, keccak256("Space Pinball"), signature);
        vm.prank(dave);
        pool.createMarket(MARKET, IMD, cutoff, GAME, signature);
        BetPool.Market memory market = _readMarket(MARKET);
        assertEq(market.token, IMD);
        assertEq(market.closesAt, cutoff);
        assertEq(market.game, GAME);
    }

    function test_MarketWrongSignerContractAndChainFail() public {
        uint64 cutoff = uint64(block.timestamp + 1 hours);
        bytes32 h = _marketHash(MARKET, IMD, cutoff, GAME);
        bytes[4] memory bad = [
            _sign(address(pool), 1, OTHER_KEY, h),
            _sign(address(this), 1, SIGNER_KEY, h),
            _sign(address(pool), 2, SIGNER_KEY, h),
            bytes("")
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(BetPool.InvalidSignature.selector);
            pool.createMarket(MARKET, IMD, cutoff, GAME, bad[i]);
        }
    }

    function test_MarketTimeTokenAndUniquenessValidation() public {
        vm.expectRevert(BetPool.InvalidCloseTime.selector);
        pool.createMarket(MARKET, IMD, uint64(block.timestamp), GAME, "");
        vm.expectRevert(BetPool.InvalidCloseTime.selector);
        pool.createMarket(MARKET, IMD, uint64(block.timestamp - 1), GAME, "");
        vm.expectRevert(BetPool.InvalidCloseTime.selector);
        pool.createMarket(MARKET, IMD, uint64(block.timestamp + 7 days + 1), GAME, "");
        vm.expectRevert(BetPool.UnsupportedToken.selector);
        pool.createMarket(MARKET, alice, uint64(block.timestamp + 1), GAME, "");
        vm.expectRevert(BetPool.UnsupportedToken.selector);
        pool.createMarket(MARKET, address(0), uint64(block.timestamp + 1), GAME, "");
        _createAt(MARKET, IMD, uint64(block.timestamp + 7 days));
        vm.expectRevert(BetPool.MarketAlreadyExists.selector);
        pool.createMarket(MARKET, IMD, uint64(block.timestamp + 1), GAME, "");
        _settle(MARKET, 2);
        vm.expectRevert(BetPool.MarketAlreadyExists.selector);
        pool.createMarket(MARKET, IMD, uint64(block.timestamp + 1), GAME, "");
        _createAt(bytes32(0), SHIFT, uint64(block.timestamp + 1));
    }

    function test_OutcomeBindsEveryFieldAndDomain() public {
        _create(MARKET, IMD);
        bytes32 second = keccak256("second");
        _create(second, IMD);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 h = _outcomeHash(MARKET, 0, deadline);
        bytes memory signature = _sign(address(pool), 1, SIGNER_KEY, h);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(second, 0, deadline, signature);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(MARKET, 1, deadline, signature);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(MARKET, 0, deadline + 1, signature);
        bytes[3] memory bad = [
            _sign(address(pool), 1, OTHER_KEY, h),
            _sign(address(this), 1, SIGNER_KEY, h),
            _sign(address(pool), 2, SIGNER_KEY, h)
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(BetPool.InvalidSignature.selector);
            pool.settle(MARKET, 0, deadline, bad[i]);
        }
        vm.prank(carol);
        pool.settle(MARKET, 0, deadline, signature);
        vm.expectRevert(BetPool.MarketAlreadySettled.selector);
        pool.settle(MARKET, 0, deadline, signature);
    }

    function test_OutcomeDeadlineAndValidation() public {
        vm.expectRevert(BetPool.UnknownMarket.selector);
        pool.settle(MARKET, 0, block.timestamp, "");
        _create(MARKET, IMD);
        vm.expectRevert(BetPool.InvalidOutcome.selector);
        pool.settle(MARKET, 3, block.timestamp, "");
        vm.expectRevert(BetPool.OutcomeExpired.selector);
        pool.settle(MARKET, 0, block.timestamp - 1, "");
        bytes memory signature = _sign(address(pool), 1, SIGNER_KEY, _outcomeHash(MARKET, 0, block.timestamp));
        pool.settle(MARKET, 0, block.timestamp, signature);
    }

    function test_ExpiredMarketRejectsSignedSettlement() public {
        uint64 cutoff = _create(MARKET, IMD);
        vm.warp(uint256(cutoff) + 24 hours);
        pool.expire(MARKET);
        bytes memory signature = _sign(address(pool), 1, SIGNER_KEY, _outcomeHash(MARKET, 0, block.timestamp));
        vm.expectRevert(BetPool.MarketAlreadySettled.selector);
        pool.settle(MARKET, 0, block.timestamp, signature);
    }

    function test_ClaimsBeforeSettlementAndUnknownActionsRefused() public {
        assertEq(pool.claimable(MARKET, alice), 0);
        vm.expectRevert(BetPool.UnknownMarket.selector);
        pool.claim(MARKET);
        vm.expectRevert(BetPool.UnknownMarket.selector);
        pool.expire(MARKET);
        _create(MARKET, IMD);
        vm.expectRevert(BetPool.MarketNotSettled.selector);
        pool.claim(MARKET);
    }
}
