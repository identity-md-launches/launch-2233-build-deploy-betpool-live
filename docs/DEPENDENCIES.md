# Vendored dependencies

All dependency sources are ordinary repository files, with no package manager or submodule
required during compilation. They were retrieved from the following pinned upstream releases:

| Dependency | Release | Included files | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | v5.0.2 | Unmodified transitive Solidity dependencies of BetPool and its ERC-20 mock | MIT, `lib/openzeppelin-contracts/LICENSE` |
| forge-std | v1.9.7 | Upstream `src/` | MIT and Apache-2.0, included in `lib/forge-std/` |

Source archives:

- https://github.com/OpenZeppelin/openzeppelin-contracts/releases/tag/v5.0.2
- https://github.com/foundry-rs/forge-std/releases/tag/v1.9.7

`DEPENDENCY_HASHES.sha256` records the included file bytes. Verify them from the repository
root with `sha256sum -c docs/DEPENDENCY_HASHES.sha256`.

BetPool uses OpenZeppelin's `SafeERC20`, `ECDSA`, `EIP712`, `Math`, `Pausable` and
`ReentrancyGuard`. All library functions used by the application are internal and inlined;
the deployment bytecode needs no external library addresses. `Address.sol` contains upstream
helpers that are unused by BetPool; the optimized application runtime is separately tested
for the absence of DELEGATECALL, CALLCODE and SELFDESTRUCT instructions.
