// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BetPool} from "../../src/BetPool.sol";
import {MockToken} from "./MockToken.sol";

/// @dev Foundry's uncached chain-ID reader, absent from the pinned forge-std interface.
interface VmChainReader {
    function getChainId() external view returns (uint256 chainId);
}

abstract contract BetPoolTestBase is Test {
    // Local signing fixtures only; these keys are not deployment parameters.
    uint256 internal constant SIGNER_KEY = 0x51873;
    uint256 internal constant OTHER_KEY = 0x51874;
    address internal constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant SHIFT = 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC;
    address internal constant SPLITTER = 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44;
    bytes32 internal constant GAME = keccak256("NIGHT CHESS");
    bytes32 internal constant MARKET = keccak256("match-1");
    bytes32 internal constant DOMAIN_TYPE =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant MARKET_TYPE =
        keccak256("Market(bytes32 marketId,address token,uint64 closesAt,bytes32 game)");
    bytes32 internal constant TICKET_TYPE = keccak256(
        "Ticket(bytes32 marketId,address bettor,uint8 side,uint256 amount,uint16 weightBps,uint64 expiry,bytes32 nonce)"
    );
    bytes32 internal constant OUTCOME_TYPE = keccak256("Outcome(bytes32 marketId,uint8 outcome,uint256 deadline)");

    BetPool internal pool;
    MockToken internal imd;
    MockToken internal shift;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal dave;
    uint256 internal nonceCounter;

    struct Ticket {
        bytes32 marketId;
        address bettor;
        uint8 side;
        uint256 amount;
        uint16 weightBps;
        uint64 expiry;
        bytes32 nonce;
    }

    function setUp() public virtual {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        pool = new BetPool();
        vm.prank(OWNER);
        pool.setSigner(vm.addr(SIGNER_KEY));
        MockToken implementation = new MockToken();
        vm.etch(IMD, address(implementation).code);
        vm.etch(SHIFT, address(implementation).code);
        imd = MockToken(IMD);
        shift = MockToken(SHIFT);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        dave = makeAddr("dave");
        _fund(alice);
        _fund(bob);
        _fund(carol);
        _fund(dave);
    }

    function _fund(address wallet) internal {
        imd.mint(wallet, 1_000_000_000 ether);
        shift.mint(wallet, 1_000_000_000 ether);
        vm.startPrank(wallet);
        imd.approve(address(pool), 1_000_000_000 ether);
        shift.approve(address(pool), 1_000_000_000 ether);
        vm.stopPrank();
    }

    function _sign(address target, uint256 chainId, uint256 key, bytes32 structHash)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 domain =
            keccak256(abi.encode(DOMAIN_TYPE, keccak256("NightshiftBets"), keccak256("1"), chainId, target));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _marketHash(bytes32 id, address token, uint64 closesAt, bytes32 game) internal pure returns (bytes32) {
        return keccak256(abi.encode(MARKET_TYPE, id, token, closesAt, game));
    }

    function _create(bytes32 id, address token) internal returns (uint64 closesAt) {
        closesAt = uint64(vm.getBlockTimestamp() + 1 hours);
        _createAt(id, token, closesAt);
    }

    function _createAt(bytes32 id, address token, uint64 closesAt) internal {
        bytes memory signature = _sign(
            address(pool), VmChainReader(address(vm)).getChainId(), SIGNER_KEY, _marketHash(id, token, closesAt, GAME)
        );
        pool.createMarket(id, token, closesAt, GAME, signature);
    }

    function _ticket(bytes32 id, address bettor, uint8 side, uint256 amount, uint16 weight)
        internal
        returns (Ticket memory)
    {
        return Ticket(id, bettor, side, amount, weight, uint64(vm.getBlockTimestamp() + 120), bytes32(++nonceCounter));
    }

    function _ticketHash(Ticket memory t) internal pure returns (bytes32) {
        return
            keccak256(abi.encode(TICKET_TYPE, t.marketId, t.bettor, t.side, t.amount, t.weightBps, t.expiry, t.nonce));
    }

    function _ticketSignature(Ticket memory t) internal view returns (bytes memory) {
        return _sign(address(pool), VmChainReader(address(vm)).getChainId(), SIGNER_KEY, _ticketHash(t));
    }

    function _submit(Ticket memory t, bytes memory signature) internal {
        vm.prank(t.bettor);
        pool.bet(t.marketId, t.side, t.amount, t.weightBps, t.expiry, t.nonce, signature);
    }

    function _place(bytes32 id, address bettor, uint8 side, uint256 amount, uint16 weight) internal {
        Ticket memory t = _ticket(id, bettor, side, amount, weight);
        _submit(t, _ticketSignature(t));
    }

    function _outcomeHash(bytes32 id, uint8 outcome, uint256 deadline) internal pure returns (bytes32) {
        return keccak256(abi.encode(OUTCOME_TYPE, id, outcome, deadline));
    }

    function _settle(bytes32 id, uint8 outcome) internal {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory signature = _sign(
            address(pool), VmChainReader(address(vm)).getChainId(), SIGNER_KEY, _outcomeHash(id, outcome, deadline)
        );
        pool.settle(id, outcome, deadline, signature);
    }

    function _claim(bytes32 id, address wallet) internal returns (uint256) {
        vm.prank(wallet);
        return pool.claim(id);
    }

    function _readMarket(bytes32 id) internal view returns (BetPool.Market memory m) {
        (m.token, m.closesAt, m.game, m.totalA, m.totalB, m.sharesA, m.sharesB, m.settled, m.outcome, m.refundable) =
            pool.markets(id);
    }

    function _readBet(bytes32 id, address wallet) internal view returns (BetPool.Bet memory b) {
        (b.amountA, b.amountB, b.sharesA, b.sharesB, b.claimed) = pool.betsOf(id, wallet);
    }
}
