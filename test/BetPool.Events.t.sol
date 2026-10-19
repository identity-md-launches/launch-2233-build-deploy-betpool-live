// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPoolTestBase, BetPool} from "./helpers/BetPoolTestBase.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract BetPoolEventsTest is BetPoolTestBase {
    function test_MarketBetSettleAndClaimEvents() public {
        uint64 cutoff = uint64(block.timestamp + 1 hours);
        bytes memory signature = _sign(address(pool), 1, SIGNER_KEY, _marketHash(MARKET, IMD, cutoff, GAME));
        vm.expectEmit(true, true, false, true, address(pool));
        emit BetPool.MarketCreated(MARKET, IMD, cutoff, GAME);
        pool.createMarket(MARKET, IMD, cutoff, GAME, signature);
        Ticket memory t = _ticket(MARKET, alice, 0, 1 ether, 5_000);
        signature = _ticketSignature(t);
        vm.expectEmit(true, true, false, true, address(pool));
        emit BetPool.BetPlaced(MARKET, alice, 0, 1 ether, 5_000, 0.5 ether);
        _submit(t, signature);
        _place(MARKET, bob, 1, 1 ether + 1, 500);
        signature = _sign(address(pool), 1, SIGNER_KEY, _outcomeHash(MARKET, 0, block.timestamp));
        vm.expectEmit(true, false, false, true, address(pool));
        emit BetPool.Settled(MARKET, 0, 0.05 ether);
        pool.settle(MARKET, 0, block.timestamp, signature);
        vm.expectEmit(true, true, false, true, address(pool));
        emit BetPool.Claimed(MARKET, alice, 1.95 ether + 1);
        _claim(MARKET, alice);
        vm.expectEmit(true, true, false, true, address(pool));
        emit BetPool.Claimed(MARKET, bob, 0);
        _claim(MARKET, bob);
    }

    function test_ExpiryAndAdministrativeEvents() public {
        uint64 cutoff = _create(MARKET, IMD);
        address firstSigner = vm.addr(SIGNER_KEY);
        address nextSigner = vm.addr(OTHER_KEY);
        vm.expectEmit(true, true, false, true, address(pool));
        emit BetPool.SignerSet(firstSigner, nextSigner);
        vm.prank(OWNER);
        pool.setSigner(nextSigner);
        vm.expectEmit(true, false, false, true, address(pool));
        emit BetPool.LimitsSet(IMD, 1 ether, 1_000 ether);
        vm.prank(OWNER);
        pool.setLimits(IMD, 1 ether, 1_000 ether);
        vm.expectEmit(false, false, false, true, address(pool));
        emit Pausable.Paused(OWNER);
        vm.prank(OWNER);
        pool.pause();
        vm.expectEmit(false, false, false, true, address(pool));
        emit Pausable.Unpaused(OWNER);
        vm.prank(OWNER);
        pool.unpause();
        vm.warp(uint256(cutoff) + 24 hours);
        vm.expectEmit(true, false, false, true, address(pool));
        emit BetPool.Expired(MARKET);
        pool.expire(MARKET);
    }
}
