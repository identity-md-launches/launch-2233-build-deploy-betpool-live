# BetPool

BetPool is NIGHTSHIFT's live, signed-ticket pari-mutuel betting contract for NIGHT CHESS,
Space Pinball, Agent Arena and later games. It accepts only the two specified ERC-20 tokens,
holds separate accounting for each match, and pays winners according to their accumulated
weighted shares. The application is `src/BetPool.sol:BetPool`.

## Build and test offline

Dependencies are included as ordinary source files in `lib/`; no install, submodules, RPC,
environment values, wallet, or network access are needed for the tests. Foundry must have
Solidity **0.8.26** available. The configuration pins that compiler, the Paris EVM target,
optimization with 200 runs, IR compilation, and `bytecode_hash = "none"`.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x6e946b809129e26d9971f37c2aa855f87654afae78608c1b1aa14b9e04dff70f forge test
forge fmt --check
```

The suite includes full flows for each token and outcome; ticket, market and result
signature tampering; exact time and amount boundaries; signer rotation; pause behavior;
malformed ECDSA; token failures and reentrancy; event payloads; local factory deployment;
runtime opcode checks; numerical fuzz tests; and stateful accounting invariants.
Fuzz tests run 512 cases each. Each invariant runs 128 sequences of 96 actions with
unexpected reverts treated as failures, followed by closing all remaining markets and
claiming every entitlement. Tests neither read nor set environment variables.

## Deployment parameters

Deploy **only BetPool**, on **Ethereum mainnet (chain ID 1)**. Its nonpayable constructor
has **no arguments** and calls no external contracts. It does not deploy any other
contract. Its owner is fixed independently of the factory, transaction sender, and origin.

| Setting | Value |
| --- | --- |
| Owner | `0x6c4c78f2c3bdf4c4318fe305fb1c8bc1694d19b5` |
| IMD | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| SHIFT | `0xe5e58e53d0bb204aa62c995a6c8cc8a48e60c3ac` |
| Fee splitter | `0x1119d5df2f046bc2d3c0f6279ef2e9ce49422d44` |
| Fee | 500 / 10000 = 5% of losing stakes only |
| IMD default min / max | 0.1 / 500 whole tokens |
| SHIFT default min / max | 1000 / 25000000 whole tokens |
| IMD permanent per-bet cap | 10000 whole tokens |
| SHIFT permanent per-bet cap | 500000000 whole tokens |
| Token precision | 18 decimals for both; all function amounts use base units |
| Ticket weight | 500 through 10000 basis points, inclusive |
| Maximum ticket expiry | 120 seconds after the inclusion block's timestamp |
| Maximum market duration | 7 days from creation |
| Permissionless refund delay | 24 hours after `closesAt` |
| Initial signer | Unconfigured; signed operations revert `SignerNotConfigured` |
| Initial pause state | Unpaused, but no market can be created without a configured signer |

The supplied token and splitter addresses are fixed requirements, not discovered or replaced
by this project. Their deployed implementations were not checked against a live RPC in this
assignment. The accounting assumes the specified plain, nonrebasing, fee-free tokens.

`script/DeployBetPool.s.sol` is a local rehearsal: its `run()` creates BetPool without
broadcasting or reading configuration. The launch service deploys BetPool's compiled creation
bytecode directly through its factory after acceptance and independent review. This project
does not broadcast, produce a mainnet deployment address, or write the service's `launch.json`.

## After launch

The fixed owner must call **`setSigner(actualNightshiftResultSigner)`** using the verified
ECDSA signing address supplied by the NIGHTSHIFT server operator. Obtain and independently
confirm that address with the operator of the existing GameEscrow
`0xf460fd9ad76f18414f54a2431870e8a116193489`. BetPool does not query or depend on GameEscrow,
and its separate EIP-712 domain prevents escrow signatures from being used as betting tickets.
No guessed signer or deployment key is included. The initial zero storage value is an
explicitly disabled configuration state, never a valid signer; `setSigner(0)` is rejected.

Confirm `owner()`, both token constants, `FEE_RECIPIENT()`, `limits()`, `signer()` and
`eip712Domain()` against this handoff and the confirmed deployment address. The server must
then use that address and chain ID in every authorization. The owner may adjust limits with
`setLimits(token, min, max)` and pause/unpause entry. No other configuration is required.

The deployment service is responsible for source verification and the final deployment record.
An independent adversarial review is required before accepting live stakes; the included tests
and local review are not an independent audit.

## Market and payout lifecycle

1. The server signs a `Market` for a unique match ID and one supported token. Anyone submits
   it to `createMarket`. The cutoff must be strictly in the future and at most seven days away.
2. The bettor obtains a short-lived, wallet-bound `Ticket` from the server and approves
   BetPool for the intended amount. The bettor calls `bet`; the contract checks the signature,
   current limits, nonce, timestamps and market state before collecting exactly that amount.
3. Each accepted bet adds `floor(amount * weightBps / 10000)` shares to that wallet and side.
   Amounts and rounded shares accumulate across repeated bets. One wallet may back both sides.
4. A signed `Outcome` settles immediately, even before the cutoff. Anyone can relay it. No
   later bet is possible. Outcome 0 is A, 1 is B, and 2 is void.
5. A void market, or any market where either side has no stakes, refunds all amounts. There
   is no fee. In an ordinary result, the fee is paid at settlement and winners claim the rest.
6. If no settlement has occurred by `closesAt + 24 hours`, anyone calls `expire`. This marks
   outcome 2 and enables full refunds with no signer or owner involvement.
7. Each wallet calls `claim` once. It receives its entitlement directly; callers cannot
   specify a different recipient. `claimMany` performs the same operation for multiple markets.

For an ordinary result, let `L` be total losing stakes, `S` total winning shares, and `a_i`
and `s_i` the wallet's winning principal and accumulated winning shares:

```text
fee       = floor(L * 500 / 10000)
rewardPot = L - fee
payout_i  = a_i + floor(rewardPot * s_i / S)
```

The losing-side principal of a wallet that backed both sides is not separately refunded.
Refundable markets instead pay `amountA + amountB`, independent of weights. Losers and
wallets with no position can claim zero; that still marks the wallet claimed and emits
`Claimed(..., 0)`. A second claim reverts.

The fee is rounded once on the total losing amount, not on individual bets. The reward
pot is **`L - floor(L / 20)`**, which can differ by one wei from `floor(0.95 * L)`.
Each wallet's reward is rounded once at claim time, independent of claim order. After all
winning wallets claim, residual payout rounding dust is strictly less than the number of
winning wallets in wei. Refunds leave no dust. Dust and unsolicited token transfers are
permanently inaccessible; neither is redistributed or swept.

Full-precision `Math.mulDiv` protects the reward multiplication. `remainingPot(marketId)`
also checks and decrements a separate reserve on every fee and payout, preventing a claim
from using another market's allocation. The sum of wallet rewards cannot exceed `rewardPot`.
Checks, effects and a reentrancy guard protect all token-moving entry points; SafeERC20
handles token return values. A transfer failure rolls back the entire action.

## Boundary decisions and assumptions

- Ticket and result deadlines are inclusive: equality with the current timestamp is valid.
  Betting is exclusive at `closesAt`; expiry refunds are inclusive at `closesAt + 24 hours`.
- The 120-second check uses transaction inclusion time, not issuance time. The signed ticket
  has no `issuedAt` field; the server must never pre-sign tickets that become usable much later.
- **Zero-share tickets are rejected.** If the owner lowers minimums below 20 base units,
  some small amounts at low weights round to zero. `ZeroShares` rejects them before collection
  or nonce consumption. This ensures every accepted side has a positive payout denominator.
  All weights are usable for amounts of at least 20 wei; default minimums are far higher.
- Limits are per bet, not per wallet or market. A change affects outstanding unsubmitted
  tickets; it does not alter existing amounts, shares or entitlements. Min must be nonzero,
  min must not exceed max, and max must stay within the immutable token cap.
- Nonces are global across both tokens, all markets and every bettor. A rejected transaction
  does not consume its nonce. Market IDs remain occupied forever, including after expiry.
- The current signer is checked at execution time. Rotation invalidates old authorizations;
  restoring an old signer can make its still-valid unused authorizations valid again.
- Results may be relayed after the refund delay if `expire` has not executed. The first
  successful settlement or expiry wins; neither can overwrite the other.
- `claimMany` is atomic. Duplicate IDs, already-claimed positions, unknown markets or
  unsettled markets revert the entire batch. An empty batch is a no-op. Callers choose their
  own batch size and can always use individual claims.
- Only standard 65-byte, low-s ECDSA signatures with v = 27/28 are accepted. ERC-1271
  contract signers, compact signatures, personal-sign messages and meta-transaction betting
  are not implemented. `msg.sender` is always the ticket's bettor.
- Both tokens are assumed to retain their stated behavior. Incoming transfers are checked
  for an exact balance increase. A token's own pause, blacklist, upgrade or transfer failure
  can prevent payouts; BetPool cannot bypass token controls.
- The contract is not chain-ID-locked. Signatures use the actual chain ID, but the fixed token
  addresses make Ethereum mainnet the intended deployment.

## Server and owner responsibilities

The server verifies real match creation and final outcomes, calculates fair live weights,
and issues tickets only for the requesting wallet's exact side and amount. It must use unique
nonces, short expiries, synchronized time, and one canonical game/match mapping. It must stop
issuing tickets before an outcome becomes obvious and promptly publish or relay final results.
Already-issued tickets remain usable until expiry, cutoff or settlement. A low positive weight
reduces a winning reward share; it does **not** mathematically eliminate late-bet profit.
The contract cannot observe gameplay, detect collusion, or prove the result or weight is fair.

The owner controls signer rotation, bounded limits and entry pausing only. It cannot change
tokens, the fee, the splitter, existing stakes, cutoff times, or claim recipients, and cannot
withdraw, upgrade, sweep, transfer ownership or settle without a valid signer authorization.
However, the owner's ability to choose a signer means it is trusted indirectly for results
and future ticket authorizations. The signer is also trusted directly for those facts.
Neither pause nor signer loss can prevent permissionless timeout refunds once eligible.

The operator should monitor match state, ticket replay, fees, unclaimed funds and stalled
settlements. Anyone may relay results or activate expiry, but no keeper reward is built in.
Frontend balances should use `claimable` rather than approximate odds, display changing live
weights and the possible refund path, and avoid presenting projected payouts as guaranteed.

See [docs/SIGNING.md](docs/SIGNING.md) for exact integration types and
[docs/SECURITY.md](docs/SECURITY.md) for the local review and accounting argument.
