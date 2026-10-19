// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPoolTestBase, MockToken} from "./helpers/BetPoolTestBase.sol";

contract BetPoolFuzzTest is BetPoolTestBase {
    struct Model {
        uint256[8] amountsA;
        uint256[8] amountsB;
        uint256[8] sharesA;
        uint256[8] sharesB;
        uint256 totalA;
        uint256 totalB;
        uint256 totalSharesA;
        uint256 totalSharesB;
    }

    function testFuzz_WeightedPayoutsConserveFunds(uint256 seed, bool useShift, uint8 outcomeSeed) public {
        address tokenAddress = useShift ? SHIFT : IMD;
        MockToken token = MockToken(tokenAddress);
        (uint256 min, uint256 max) = pool.limits(tokenAddress);
        _create(MARKET, tokenAddress);
        Model memory model;
        for (uint256 i; i < 8; ++i) {
            address wallet = address(uint160(0x10000 + i));
            _fund(wallet);
            uint256 a = min + uint256(keccak256(abi.encode(seed, i, "amountA"))) % (max - min + 1);
            uint256 b = min + uint256(keccak256(abi.encode(seed, i, "amountB"))) % (max - min + 1);
            uint16 wa = uint16(500 + uint256(keccak256(abi.encode(seed, i, "weightA"))) % 9_501);
            uint16 wb = uint16(500 + uint256(keccak256(abi.encode(seed, i, "weightB"))) % 9_501);
            _place(MARKET, wallet, 0, a, wa);
            _place(MARKET, wallet, 1, b, wb);
            model.amountsA[i] = a;
            model.amountsB[i] = b;
            model.sharesA[i] = a * wa / 10_000;
            model.sharesB[i] = b * wb / 10_000;
            model.totalA += a;
            model.totalB += b;
            model.totalSharesA += model.sharesA[i];
            model.totalSharesB += model.sharesB[i];
        }
        uint8 outcome = outcomeSeed % 3;
        _settle(MARKET, outcome);
        uint256 losing = outcome == 0 ? model.totalB : model.totalA;
        uint256 fee = outcome == 2 ? 0 : losing / 20;
        assertEq(token.balanceOf(SPLITTER), fee);
        uint256 paid;
        uint256 expectedOutstanding;
        for (uint256 i; i < 8; ++i) {
            expectedOutstanding += _expected(model, i, outcome, losing - fee);
        }
        // The permutation changes claim order without changing an individual entitlement.
        uint256 offset = seed % 8;
        for (uint256 i; i < 8; ++i) {
            uint256 index = (i + offset) % 8;
            address wallet = address(uint160(0x10000 + index));
            uint256 expected = _expected(model, index, outcome, losing - fee);
            assertEq(pool.claimable(MARKET, wallet), expected);
            assertGe(token.balanceOf(address(pool)), expectedOutstanding);
            uint256 before = token.balanceOf(wallet);
            uint256 received = _claim(MARKET, wallet);
            assertEq(received, expected);
            assertEq(token.balanceOf(wallet) - before, expected);
            paid += received;
            expectedOutstanding -= received;
            assertLe(paid + fee, model.totalA + model.totalB);
        }
        uint256 dust = token.balanceOf(address(pool));
        assertEq(paid + fee + dust, model.totalA + model.totalB);
        assertEq(pool.remainingPot(MARKET), dust);
        assertLt(dust, 8);
        if (outcome == 2) assertEq(dust, 0);
    }

    function _expected(Model memory m, uint256 index, uint8 outcome, uint256 distributable)
        private
        pure
        returns (uint256)
    {
        if (outcome == 2) return m.amountsA[index] + m.amountsB[index];
        if (outcome == 0) return m.amountsA[index] + distributable * m.sharesA[index] / m.totalSharesA;
        return m.amountsB[index] + distributable * m.sharesB[index] / m.totalSharesB;
    }

    function testFuzz_ManySmallOddBetsMaintainDustBound(uint256 seed, uint8 winnerCountSeed) public {
        uint256 count = bound(winnerCountSeed, 1, 32);
        vm.prank(OWNER);
        pool.setLimits(IMD, 20, 500 ether);
        _create(MARKET, IMD);
        uint256[] memory principals = new uint256[](count);
        uint256[] memory shares = new uint256[](count);
        uint256 principal;
        uint256 totalShares;
        for (uint256 i; i < count; ++i) {
            address wallet = address(uint160(0x10000 + i));
            _fund(wallet);
            uint256 amount = 20 + uint256(keccak256(abi.encode(seed, i))) % 10_000;
            uint16 weight = uint16(500 + uint256(keccak256(abi.encode(i, seed))) % 9_501);
            _place(MARKET, wallet, 0, amount, weight);
            principals[i] = amount;
            shares[i] = amount * weight / 10_000;
            principal += amount;
            totalShares += shares[i];
        }
        uint256 losing = 20 + seed % 100_000;
        _place(MARKET, bob, 1, losing, 500);
        _settle(MARKET, 0);
        uint256 fee = losing / 20;
        assertEq(imd.balanceOf(SPLITTER), fee);
        uint256 paid;
        for (uint256 i; i < count; ++i) {
            uint256 expected = principals[i] + (losing - fee) * shares[i] / totalShares;
            assertEq(_claim(MARKET, address(uint160(0x10000 + i))), expected);
            paid += expected;
        }
        uint256 dust = imd.balanceOf(address(pool));
        assertEq(paid + fee + dust, principal + losing);
        assertLt(dust, count);
    }
}
