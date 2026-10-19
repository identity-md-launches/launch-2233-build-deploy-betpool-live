# Local security review

Scope: BetPool's source, its inherited OpenZeppelin v5.0.2 paths, deployment configuration,
and tests. This is the implementation's local adversarial review, not an independent audit
or a verification of the deployed IMD/SHIFT contracts. No live transactions were sent.

## Accounting argument

For each market, every accepted deposit increases exactly one side's total and one wallet's
amount by the same value. Its individually rounded shares increase the side and wallet share
counts equally. Consequently, each side's amounts and shares equal the sums of its positions.
The exact token balance increase is checked; failed transfers revert all changes, including
nonce use. Per-bet hard caps bound `amount * weightBps` far below uint256 overflow.

The zero-share rejection guarantees that a side with any accepted bet has positive total
shares, even if the owner later lowers minimums to a few wei. This is necessary because the
specified integer formula could otherwise yield a nonempty winning side with a zero divisor.
The validation is explicit in the ABI (`ZeroShares`), tests, and integration documentation.

Settlement fixes all totals permanently. A refundable market's liabilities sum exactly to
its deposits. Otherwise, writing losing total as L, fee as F = floor(L / 20), and winning
share total as S, the total bonus is:

```text
sum_i floor((L - F) * shares_i / S) <= L - F
```

Winning principals sum to the winning-side total. Thus fees plus all possible payouts never
exceed deposits. Because every floor discards less than one wei and all shares sum to S,
residual bonus dust is strictly less than the count of winning wallets. There is no extra
per-claim fee or rounding on principal. `Math.mulDiv` performs the potentially large product
with full precision; claim order cannot affect an entitlement.

`remainingPot` is increased only on a validated deposit and decreased only by that market's
fee and claims. Every claim is bounded by that remaining reserve before transfer. The reserve
includes both unpaid liabilities and final dust. No function can spend a different market's
reserve or treat an unsolicited transfer as a bet.

The invariant handler maintains its own amounts, shares, fees, paid sums and claim flags.
It compares them with the public state and payout views after randomized action sequences.
For each token it checks actual balance against outstanding liabilities, reserve sums plus
donations, and total deposits less fees and claims. It then expires all unfinished markets
and claims every participant to verify complete withdrawal and the final dust bound.

## Authorization and lifecycle review

| Surface | Required authority / checks | Fund effect |
| --- | --- | --- |
| Constructor | No caller authority; owner and assets fixed | No external calls or funding |
| `setSigner` | Fixed owner; nonzero address | Changes future authorization checks only |
| `setLimits` | Fixed owner; supported token, ordered positive limits, immutable cap | Applies to future bets only |
| `pause`, `unpause` | Fixed owner | Gates new markets and bets only |
| `createMarket` | Current signer's exact typed message; unused ID, allowed token, time bounds, unpaused | None |
| `bet` | Current signer; caller-bound ticket, exact fields, global unused nonce, expiry, current limits, positive shares, open market, unpaused | Exact transfer from caller |
| `settle` | Current signer's exact typed result; valid outcome/deadline, existing unsettled market | Fixed losing-side fee to fixed splitter |
| `expire` | Anyone after timeout on an unsettled existing market | Enables full refunds, no transfer |
| `claim`, `claimMany` | Position of caller; finalized market; not already claimed | Entitlement to caller only |

Markets never reopen and IDs never become reusable. Deadline equality and cutoff exclusivity
are tested. Timed expiry and signed settlement compete for the same terminal state, so only
the first successful transaction can determine it. A result may settle before the hard cutoff;
the server's verified result is authoritative. Losing or empty claims consume only the
caller's own claim flag. Invalid batches revert all earlier transfers and flags in that batch.

EIP-712 binds name, version, current chain ID and contract address. Every supplied field,
including bettor, side, amount, weight, expiry and nonce, is encoded with its declared width.
OpenZeppelin's ECDSA recovery rejects malformed lengths, high-s signatures and invalid v.
The unset signer is rejected before recovery. Nonces are consumed before transfer and revert
atomically on failure. Market ID uniqueness and terminal settlement prevent replay of the
other two authorization types. Chain-ID changes invalidate cached domain authorizations.

## External calls and custody

All token-moving entry points share the same reentrancy guard. Amounts, shares and nonces
are recorded before transferFrom; finalization and fee reserve are recorded before the fee
transfer; claim status and reserve are recorded before payout. Initial/final balance queries
are static calls. Reentrant token callbacks cannot enter another market operation or claim.
Tests inject callbacks during deposits, settlement fees and payouts and check the guard error.
Action events are emitted after accounting effects and before state-changing token calls;
any later failure reverts both the accounting and logs.

SafeERC20 accepts standard success or an empty token return, and rejects false returns.
Incoming tax transfers are rejected by exact balance measurement. Tests show deposit,
settlement and claim state rolls back on failed token movement, so a user can retry. A failed
fee transfer also leaves the timeout refund path available. Refund activation requires no
token call, so it can proceed even while the token itself is temporarily unable to transfer.

The public ABI has no transfer, sweep, upgrade, arbitrary-call, ownership-transfer or
recipient-setting path. The compiled runtime is checked against the protected floor's
instruction scanner, skipping PUSH operands and rejecting DELEGATECALL, CALLCODE and
SELFDESTRUCT. Creation code has no linked-library placeholders. The measured runtime is
8,083 bytes, below EIP-170's 24,576-byte limit; creation code is 9,909 bytes.

## Remaining trust and operational limits

- The signer attests real matches, fair live weights and correct outcomes. BetPool does not
  independently verify gameplay or restrict the server's game identifiers. Conflicting
  signatures or late ticket issuance can produce unfair outcomes while satisfying the ABI.
- The owner can choose the signer and therefore has indirect authority over those attestations.
  This is a requested trust relationship, not a separate direct withdrawal privilege.
- Positive weights cannot promise zero profit on an obvious last-second winner. The server
  must stop ticket issuance sufficiently early and settle promptly; already-signed tickets
  can remain executable for their short window.
- Claims rely on the two fixed tokens' continued ability to transfer exact base units.
  A token control outside BetPool can affect availability. Unknown tokens, rebasing tokens,
  ERC-1271 signers and token changes are outside the supported model.
- Dust, wrong-token deposits, unsolicited transfers and any forcibly sent native ETH have
  no recovery path. This preserves the prohibition on arbitrary sweeping.
- There is no fee-funded keeper incentive or automatic on-chain timer. A user or operator
  must submit settlement/expiry and each user must claim. Single claims are constant-time;
  only the caller-selected `claimMany` loop grows with input size.
- Signer rotation uses the current signer, without an epoch field. Restoring a previous signer
  can reactivate its unexpired, unused tickets and still-eligible market/result authorizations.

## Verification performed

The Foundry suite covers both tokens, each result type, multiple bettors and weights,
repeated/both-side bets, odd amounts, bounds, replay, malformed signatures, failures,
administration, rollback, reentrancy, local deployment, and independent conservation models.
The assignment's fuzz seed is used for the full test run. Compilation is pinned to 0.8.26.
Forge lint's timestamp warnings describe intentional deadline/cutoff comparisons, not a
source of randomness. Its loop-revert warnings reflect the documented atomic `claimMany`
semantics. Event-order notices can also flag read-only balance queries and ECDSA's recovery
precompile; those calls cannot mutate state or reenter a state-changing path. These patterns
were reviewed alongside the transfer callbacks rather than treated as evidence of a defect.
The protected launch harness itself needs the deployment service's later manifest and
environment; the repository tests reproduce its applicable constructor/runtime properties
without requiring those inputs.

No Slither, Mythril, live fork simulation, backend security assessment, or independent audit
was performed. The network's independent review and deployment attestation remain separate
release steps. Test and build output report local evidence only.
