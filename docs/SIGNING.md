# Server integration

Use the exact deployed BetPool address from the launch handoff; no address is predetermined
in this repository. All messages use the following EIP-712 domain, with the actual chain ID
and verifying contract filled by the server:

```text
name:              NightshiftBets
version:           1
chainId:           1 on Ethereum mainnet
verifyingContract: the confirmed BetPool deployment
```

The domain type is
`EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)`.
There is no salt. `eip712Domain()` exposes the deployed domain via EIP-5267.

Use these exact primary types, field order, names and widths:

```text
Market(bytes32 marketId,address token,uint64 closesAt,bytes32 game)
Ticket(bytes32 marketId,address bettor,uint8 side,uint256 amount,uint16 weightBps,uint64 expiry,bytes32 nonce)
Outcome(bytes32 marketId,uint8 outcome,uint256 deadline)
```

For each primary type:

```text
typeHash   = keccak256(UTF8(exact type string above))
structHash = keccak256(abi.encode(typeHash, each field in declared order))
digest     = keccak256(0x1901 || domainSeparator || structHash)
signature  = r (32 bytes) || s (32 bytes, low-s) || v (1 byte, 27 or 28)
```

Do not use packed encoding for fields, an Ethereum personal-message prefix, or a different
integer width. Token amounts are integers in 18-decimal base units. JavaScript integrations
must keep amounts and deadlines as bigint or decimal strings, not floating-point numbers.
`marketId`, `game` and `nonce` are 32-byte values selected by the server; their encoding is
not inferred on-chain. Hashing a canonical UTF-8 identifier is one option if used consistently.
No game-ID whitelist prevents later games from using the same application.

`Market` and `Outcome` authorizations can be relayed by any account. `Ticket` authorizations
can only be exercised by the signed `bettor`; contract wallets can call BetPool directly and
must use their own contract address as `bettor`. Approve the correct token to the confirmed
BetPool address before calling `bet`.

Before issuing a ticket, read the market and current token limits. Check:

- Market exists, is unsettled, and time is strictly below its hard cutoff.
- Entry is not paused and the signing address matches `signer()`.
- Side is 0 or 1; amount is within current limits and generates at least one rounded share.
- Weight is within 500–10000, expiry is short enough for inclusion, and nonce is globally unique.
- The match is still fair to bet on according to the server's live game state.

The server must account for transport and block-inclusion delay. Giving tickets an expiry
more than 120 seconds beyond the inclusion block causes rejection until they enter that
window. Future-dated signatures are not a substitute for live ticket issuance. Nonces need
durable uniqueness across server restarts and across IMD/SHIFT markets.

Publish a single canonical outcome with a suitable submission deadline after verification.
Conflicting valid outcomes are resolved by whichever arrives first; the contract cannot
adjudicate contradictory server signatures. Outcome 2 intentionally refunds all participants.
Once a result deadline expires, obtain a fresh authorization or use permissionless expiry
when its delay has elapsed. The owner does not have a separate settlement bypass.

Index the `MarketCreated`, `BetPlaced`, `Settled`, `Expired`, `Claimed`, `SignerSet`,
`LimitsSet`, `Paused` and `Unpaused` events, with normal chain reorganization handling.
`BetPlaced` reports the actual rounded shares. `Settled` reports the fee transferred in
that transaction. `Expired` itself represents final settlement as refundable outcome 2;
it does not additionally emit `Settled`. All state is also queryable on-chain.
