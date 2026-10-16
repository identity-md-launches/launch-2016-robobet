# Robobet (ROBOBET)

A fixed-supply ERC-20 token for Robobet, which is live at https://x.com/robobet_fun.

| Field | Value |
| --- | --- |
| Solidity contract | `RobobetToken` (`src/RobobetToken.sol`) |
| `name()` | `Robobet` |
| `symbol()` | `ROBOBET` |
| `decimals()` | `18` |
| Total supply | 1,000,000,000 ROBOBET = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Owner / admin | none |
| Transfer tax, burn on transfer, reflections | none |
| Mint after deployment | impossible |

## What it does

The constructor mints the whole supply once to `msg.sender` (the deployer) and emits a
`SupplyMinted(deployer, supply)` event alongside the standard `Transfer(0x0, deployer, supply)`. After
that the token is a plain OpenZeppelin 5.0.2 `ERC20`: `transfer`, `approve`, `transferFrom`,
`allowance`, `balanceOf`, `totalSupply`, `name`, `symbol`, `decimals`. There is nothing else.

Deliberately absent:

- no `Ownable`, no owner-only functions, no `renounceOwnership` because there is nothing to renounce;
- no `mint`, `burn` or `burnFrom`, so the supply is fixed at deployment and can never grow;
- no `pause`, blacklist, freeze, lock or seize, so nobody can move or block a holder's balance;
- no proxy, `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` in the runtime bytecode;
- no `receive`/`fallback`, so the contract refuses ether and unknown calls.

## Launch assumptions

This token is built for an IMD custom-token launch on Ethereum (chain id 1), paired with IMD.
The launch factory is the deployer, so it receives the whole supply and pays it out:

- 10% to the launch's MerkleDistributor (the swarm's share);
- 88% (`economics.poolBps` = 8800) seeds the single-sided Uniswap v4 pool, opened at the price the
  deployer derives from a 2,500 IMD market cap for the whole supply;
- the remaining 2% goes to `economics.remainderTo`, `0x0120a4ccc7516344dbfedc9d43ff7859b7ccca97`.

Because transfers are untaxed and there are no exemptions to configure, every launch flow (factory to
distributor, distributor to claimant, factory to PoolManager, trader buys and sells) moves exactly
what it says. The constructor takes no arguments, reads no other contract and needs no address to
have code, so it runs on an empty chain. Nothing is reserved or sent to any other contract at
launch; there are no application contracts in this project.

The manifest step writes `launch.json`; this repository does not contain one. For that step the
relevant values are: `token.contract = "RobobetToken"`, `token.name = "Robobet"`,
`token.symbol = "ROBOBET"`, `token.decimals = 18`, `token.constructorArgs = []`,
`token.totalSupply = "1000000000000000000000000000"`.

## Deployment parameters

There are none. `script/DeployRobobetToken.s.sol` exists for local or manual deployments only:
`deploy()` creates the token (the caller receives the supply) and `run()` wraps it in a broadcast.
The IMD launch does not use this script; it deploys the attested bytecode through the factory.

```sh
forge script script/DeployRobobetToken.s.sol --rpc-url <rpc> --broadcast
```

## After launch

Nothing to set. The token has no owner-settable values, no roles and no configuration.

## Operational responsibilities

- **Holders** are responsible for their own keys and allowances. Approvals follow the ERC-20 standard
  (the allowance race is inherent to `approve`; use exact amounts or `transferFrom` patterns that
  check the resulting allowance).
- **Nobody** can recover tokens sent to the token contract itself or to a wrong address: there is no
  admin and no rescue function.
- **Supply** can only shrink if holders send tokens to an address nobody controls; it can never grow.
- **Explorer verification** of the deployed source is the launch deployer's responsibility after the
  launch; the build uses `bytecode_hash = "none"` so the deployed bytes are reproducible from this
  repository with solc 0.8.26.

## Building and testing

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, the optimizer at 200 runs and
`bytecode_hash = "none"`. `ffi` is off and there are no filesystem permissions. Dependencies are
vendored as ordinary files under `lib/` (forge-std 1.9.7, OpenZeppelin Contracts 5.0.2: only the
`token`, `utils` and `interfaces` trees); there are no git submodules.

Tests (`test/`) cover: metadata and supply; the constructor minting once to the deployer and emitting
its events; the launch split (10% / 88% / 2%) arriving whole and conserving supply; exact transfers,
approvals and `transferFrom`; reverts for insufficient balance, insufficient allowance, zero-address
receiver and zero-address spender; a sweep of common admin selectors (`mint`, `pause`, `blacklist`,
`burnFrom`, `upgradeTo`, ...) from a stranger and from the deployer, none of which change supply or
a holder's balance; a bytecode scan for `DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT`; and fuzz tests for
transfer and `transferFrom` conservation and bounds. Tests read no environment variables and pass in
any order and in parallel.

## Security notes

The eth-security checklist in `.imd/reads/skills/eth-security/REFERENCE.md` was used as the design
checklist. Items that apply: no reentrancy surface (no external calls), checked arithmetic
(Solidity 0.8.26), no `tx.origin`, no owner or upgrade power to document as a trust assumption, no
oracle, no randomness, no ether handling. The only tool run was Foundry (`forge build`, `forge test`
with the verifier's fuzz seed, `forge fmt --check`); Slither and Mythril were not run. Passing tests
are not an audit; the launch's independent review follows.
