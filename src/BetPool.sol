// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BetPool
/// @notice NIGHTSHIFT's signed-ticket, weighted pari-mutuel markets for IMD and SHIFT.
/// @dev The signer attests matches, live weights and results. The immutable owner can rotate that
/// signer, adjust bounded limits, and pause entry. Neither role has a withdrawal or upgrade path.
contract BetPool is EIP712, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Permanent launch owner; ownership cannot be transferred or renounced.
    address public constant owner = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    /// @notice The only supported IMD token (18 decimals).
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    /// @notice The only supported SHIFT token (18 decimals).
    address public constant SHIFT = 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC;
    /// @notice Immutable recipient of the fee on the losing side.
    address public constant FEE_RECIPIENT = 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44;
    /// @notice Fee basis points, applied only to losing stakes in a nonrefundable market.
    uint256 public constant FEE_BPS = 500;
    /// @notice Basis-point denominator for weights and fees.
    uint256 public constant BPS = 10_000;
    /// @notice Lowest accepted live ticket weight.
    uint16 public constant MIN_WEIGHT_BPS = 500;
    /// @notice Highest accepted live ticket weight.
    uint16 public constant MAX_WEIGHT_BPS = 10_000;
    /// @notice Maximum future ticket expiry, measured at transaction inclusion.
    uint256 public constant MAX_TICKET_LIFETIME = 120 seconds;
    /// @notice Maximum time from market creation to its hard betting cutoff.
    uint256 public constant MAX_MARKET_DURATION = 7 days;
    /// @notice Delay after the hard betting cutoff before permissionless refunds can be activated.
    uint256 public constant REFUND_DELAY = 24 hours;
    /// @notice Permanent per-bet IMD ceiling in base units.
    uint256 public constant IMD_HARD_CAP = 10_000 ether;
    /// @notice Permanent per-bet SHIFT ceiling in base units.
    uint256 public constant SHIFT_HARD_CAP = 500_000_000 ether;

    /// @notice Exact EIP-712 type hash for market authorizations.
    bytes32 public constant MARKET_TYPEHASH =
        keccak256("Market(bytes32 marketId,address token,uint64 closesAt,bytes32 game)");
    /// @notice Exact EIP-712 type hash for bettor-bound tickets.
    bytes32 public constant TICKET_TYPEHASH = keccak256(
        "Ticket(bytes32 marketId,address bettor,uint8 side,uint256 amount,uint16 weightBps,uint64 expiry,bytes32 nonce)"
    );
    /// @notice Exact EIP-712 type hash for results.
    bytes32 public constant OUTCOME_TYPEHASH = keccak256("Outcome(bytes32 marketId,uint8 outcome,uint256 deadline)");

    struct Market {
        address token;
        uint64 closesAt;
        bytes32 game;
        uint256 totalA;
        uint256 totalB;
        uint256 sharesA;
        uint256 sharesB;
        bool settled;
        uint8 outcome;
        bool refundable;
    }

    struct Bet {
        uint256 amountA;
        uint256 amountB;
        uint256 sharesA;
        uint256 sharesB;
        bool claimed;
    }

    struct Limits {
        uint256 min;
        uint256 max;
    }

    /// @notice Current ECDSA signer; unset until the owner configures it with setSigner.
    address public signer;
    /// @notice Market information; token is zero for a market that has never existed.
    mapping(bytes32 marketId => Market) public markets;
    /// @notice Wallet stakes, individually rounded weighted shares, and claim status.
    mapping(bytes32 marketId => mapping(address wallet => Bet)) public betsOf;
    /// @notice Current per-bet limits in base units; unsupported tokens return zeroes.
    mapping(address token => Limits) public limits;
    /// @notice Whether a ticket nonce has been consumed, globally across wallets and markets.
    mapping(bytes32 nonce => bool) public usedNonce;
    /// @notice Market funds remaining after fees and claims, including any permanent rounding dust.
    mapping(bytes32 marketId => uint256) public remainingPot;

    error NotOwner();
    error SignerNotConfigured();
    error InvalidSigner();
    error InvalidSignature();
    error UnsupportedToken();
    error InvalidLimits();
    error MarketAlreadyExists();
    error UnknownMarket();
    error InvalidCloseTime();
    error MarketAlreadySettled();
    error MarketNotSettled();
    error BettingClosed();
    error InvalidSide();
    error AmountOutsideLimits();
    error InvalidWeight();
    error TicketExpired();
    error TicketExpiryTooFar();
    error NonceAlreadyUsed();
    error ZeroShares();
    error IncorrectTransferAmount();
    error InvalidOutcome();
    error OutcomeExpired();
    error TooEarlyToExpire();
    error AlreadyClaimed();
    error InsufficientMarketFunds();

    event MarketCreated(bytes32 indexed marketId, address indexed token, uint64 closesAt, bytes32 game);
    event BetPlaced(
        bytes32 indexed marketId, address indexed bettor, uint8 side, uint256 amount, uint16 weightBps, uint256 shares
    );
    event Settled(bytes32 indexed marketId, uint8 outcome, uint256 fee);
    event Claimed(bytes32 indexed marketId, address indexed bettor, uint256 amount);
    event Expired(bytes32 indexed marketId);
    event SignerSet(address indexed previousSigner, address indexed newSigner);
    event LimitsSet(address indexed token, uint256 min, uint256 max);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Deploys with fixed launch addresses and default limits, without external calls.
    /// @dev The owner must set the real server signer before any signed operation is possible.
    constructor() EIP712("NightshiftBets", "1") {
        _setLimits(IMD, 0.1 ether, 500 ether);
        _setLimits(SHIFT, 1_000 ether, 25_000_000 ether);
    }

    /// @notice Rotates the server ECDSA signer; outstanding authorizations use the current signer.
    /// @param newSigner The actual server signing address; zero cannot be configured.
    function setSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert InvalidSigner();
        address previous = signer;
        signer = newSigner;
        emit SignerSet(previous, newSigner);
    }

    /// @notice Changes one supported token's per-bet limits within its permanent hard cap.
    /// @param token IMD or SHIFT.
    /// @param min Smallest amount in base units, strictly greater than zero.
    /// @param max Largest amount in base units, at least min and no higher than the hard cap.
    function setLimits(address token, uint256 min, uint256 max) external onlyOwner {
        _setLimits(token, min, max);
    }

    /// @notice Pauses market creation and betting; settlement, expiry and claims remain available.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Re-enables market creation and betting.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Opens a new match authorized by the current server signer; anyone may submit it.
    /// @param marketId Unique match identifier, never reusable even after settlement or expiry.
    /// @param token IMD or SHIFT.
    /// @param closesAt Hard betting cutoff, in the future and no more than seven days away.
    /// @param game Server-defined game identifier, covered by the authorization.
    /// @param signature EIP-712 Market authorization (65-byte ECDSA signature).
    function createMarket(bytes32 marketId, address token, uint64 closesAt, bytes32 game, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
    {
        if (markets[marketId].token != address(0)) revert MarketAlreadyExists();
        _hardCap(token);
        if (closesAt <= block.timestamp || uint256(closesAt) - block.timestamp > MAX_MARKET_DURATION) {
            revert InvalidCloseTime();
        }
        _verify(keccak256(abi.encode(MARKET_TYPEHASH, marketId, token, closesAt, game)), signature);
        Market storage market = markets[marketId];
        market.token = token;
        market.closesAt = closesAt;
        market.game = game;
        emit MarketCreated(marketId, token, closesAt, game);
    }

    /// @notice Places a server-weighted bet for the caller, consuming its globally unique nonce.
    /// @param marketId An open market.
    /// @param side Zero for A, one for B.
    /// @param amount Token base units, within the current limits.
    /// @param weightBps Live weight in [500, 10000]; the rounded shares must be nonzero.
    /// @param expiry Last valid timestamp, from now through now plus 120 seconds inclusive.
    /// @param nonce Unique across every ticket issued for this contract.
    /// @param signature EIP-712 Ticket authorization binding all fields and msg.sender.
    function bet(
        bytes32 marketId,
        uint8 side,
        uint256 amount,
        uint16 weightBps,
        uint64 expiry,
        bytes32 nonce,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        Market storage market = _market(marketId);
        if (market.settled) revert MarketAlreadySettled();
        if (block.timestamp >= market.closesAt) revert BettingClosed();
        if (side > 1) revert InvalidSide();
        Limits memory bounds = limits[market.token];
        if (amount < bounds.min || amount > bounds.max) revert AmountOutsideLimits();
        if (weightBps < MIN_WEIGHT_BPS || weightBps > MAX_WEIGHT_BPS) revert InvalidWeight();
        if (expiry < block.timestamp) revert TicketExpired();
        if (uint256(expiry) - block.timestamp > MAX_TICKET_LIFETIME) revert TicketExpiryTooFar();
        if (usedNonce[nonce]) revert NonceAlreadyUsed();
        _verify(
            keccak256(abi.encode(TICKET_TYPEHASH, marketId, msg.sender, side, amount, weightBps, expiry, nonce)),
            signature
        );

        _recordAndCollect(marketId, side, amount, weightBps, nonce);
    }

    function _recordAndCollect(bytes32 marketId, uint8 side, uint256 amount, uint16 weightBps, bytes32 nonce) private {
        Market storage market = markets[marketId];

        // Per-bet hard caps make this multiplication safe. Reject zero-share tickets even if
        // the owner later lowers limits to a handful of wei: every accepted side has a divisor.
        uint256 shares = amount * weightBps / BPS;
        if (shares == 0) revert ZeroShares();
        IERC20 token = IERC20(market.token);
        uint256 balanceBefore = token.balanceOf(address(this));

        usedNonce[nonce] = true;
        Bet storage position = betsOf[marketId][msg.sender];
        if (side == 0) {
            market.totalA += amount;
            market.sharesA += shares;
            position.amountA += amount;
            position.sharesA += shares;
        } else {
            market.totalB += amount;
            market.sharesB += shares;
            position.amountB += amount;
            position.sharesB += shares;
        }
        remainingPot[marketId] += amount;
        emit BetPlaced(marketId, msg.sender, side, amount, weightBps, shares);
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = token.balanceOf(address(this));
        if (balanceAfter < balanceBefore || balanceAfter - balanceBefore != amount) revert IncorrectTransferAmount();
    }

    /// @notice Finalizes the server's result immediately, even before closesAt or while paused.
    /// @param marketId An existing, unsettled market.
    /// @param outcome Zero for A, one for B, two for void. Void and one-sided markets refund all stakes.
    /// @param deadline Last valid timestamp for this result, inclusive.
    /// @param signature EIP-712 Outcome authorization from the current signer.
    function settle(bytes32 marketId, uint8 outcome, uint256 deadline, bytes calldata signature) external nonReentrant {
        Market storage market = _market(marketId);
        if (market.settled) revert MarketAlreadySettled();
        if (outcome > 2) revert InvalidOutcome();
        if (block.timestamp > deadline) revert OutcomeExpired();
        _verify(keccak256(abi.encode(OUTCOME_TYPEHASH, marketId, outcome, deadline)), signature);

        market.settled = true;
        market.outcome = outcome;
        market.refundable = outcome == 2 || market.totalA == 0 || market.totalB == 0;
        uint256 fee = 0;
        if (!market.refundable) {
            uint256 losingTotal = outcome == 0 ? market.totalB : market.totalA;
            fee = Math.mulDiv(losingTotal, FEE_BPS, BPS);
            remainingPot[marketId] -= fee;
        }
        emit Settled(marketId, outcome, fee);
        if (fee != 0) IERC20(market.token).safeTransfer(FEE_RECIPIENT, fee);
    }

    /// @notice Makes an unsettled market refundable at closesAt + 24 hours, permissionlessly.
    /// @param marketId An existing market that has not already settled or expired.
    function expire(bytes32 marketId) external nonReentrant {
        Market storage market = _market(marketId);
        if (market.settled) revert MarketAlreadySettled();
        if (block.timestamp < uint256(market.closesAt) + REFUND_DELAY) revert TooEarlyToExpire();
        market.settled = true;
        market.outcome = 2;
        market.refundable = true;
        emit Expired(marketId);
    }

    /// @notice Pays the caller's entitlement exactly once; a losing or empty position claims zero.
    /// @param marketId A settled or expired market.
    /// @return amount Token base units paid to the caller.
    function claim(bytes32 marketId) external nonReentrant returns (uint256 amount) {
        return _claim(marketId, msg.sender);
    }

    /// @notice Claims multiple markets for the caller atomically, including markets in different tokens.
    /// @dev A duplicate, already-claimed, unknown or unsettled entry reverts the entire batch.
    /// @param marketIds Markets to claim; keep batches small enough for the transaction gas limit.
    function claimMany(bytes32[] calldata marketIds) external nonReentrant {
        for (uint256 i; i < marketIds.length; ++i) {
            _claim(marketIds[i], msg.sender);
        }
    }

    /// @notice Returns the current payout, or zero for unknown/unsettled/already-claimed positions.
    /// @param marketId Match identifier.
    /// @param wallet Bettor whose entitlement to inspect.
    /// @return amount Token base units payable now.
    function claimable(bytes32 marketId, address wallet) public view returns (uint256 amount) {
        Market storage market = markets[marketId];
        Bet storage position = betsOf[marketId][wallet];
        if (!market.settled || position.claimed) return 0;
        if (market.refundable) return position.amountA + position.amountB;
        bool wonA = market.outcome == 0;
        uint256 principal = wonA ? position.amountA : position.amountB;
        uint256 shares = wonA ? position.sharesA : position.sharesB;
        uint256 totalShares = wonA ? market.sharesA : market.sharesB;
        uint256 losingTotal = wonA ? market.totalB : market.totalA;
        uint256 distributable = losingTotal - Math.mulDiv(losingTotal, FEE_BPS, BPS);
        return principal + Math.mulDiv(distributable, shares, totalShares);
    }

    function _claim(bytes32 marketId, address wallet) private returns (uint256 amount) {
        Market storage market = _market(marketId);
        if (!market.settled) revert MarketNotSettled();
        Bet storage position = betsOf[marketId][wallet];
        if (position.claimed) revert AlreadyClaimed();
        amount = claimable(marketId, wallet);
        if (amount > remainingPot[marketId]) revert InsufficientMarketFunds();
        position.claimed = true;
        remainingPot[marketId] -= amount;
        emit Claimed(marketId, wallet, amount);
        if (amount != 0) IERC20(market.token).safeTransfer(wallet, amount);
    }

    function _market(bytes32 marketId) private view returns (Market storage market) {
        market = markets[marketId];
        if (market.token == address(0)) revert UnknownMarket();
    }

    function _verify(bytes32 structHash, bytes calldata signature) private view {
        address currentSigner = signer;
        if (currentSigner == address(0)) revert SignerNotConfigured();
        (address recovered, ECDSA.RecoverError error,) = ECDSA.tryRecover(_hashTypedDataV4(structHash), signature);
        if (error != ECDSA.RecoverError.NoError || recovered != currentSigner) revert InvalidSignature();
    }

    function _setLimits(address token, uint256 min, uint256 max) private {
        uint256 cap = _hardCap(token);
        if (min == 0 || min > max || max > cap) revert InvalidLimits();
        limits[token] = Limits(min, max);
        emit LimitsSet(token, min, max);
    }

    function _hardCap(address token) private pure returns (uint256) {
        if (token == IMD) return IMD_HARD_CAP;
        if (token == SHIFT) return SHIFT_HARD_CAP;
        revert UnsupportedToken();
    }
}
