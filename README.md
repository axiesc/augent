# AUGENT ($AUGENT)

**An Agent-ID-native token launch on BNB Smart Chain, built for the Binance Agent ID Hackathon.**

AUGENT (Au + Agent) puts the token and its launch sale in a single verified, open-source contract. Every interaction with that contract is gated on-chain by Binance Agent ID: before any free claim or paid purchase executes, the contract checks the caller's balance in the SPACE ID Agent ID registry and reverts if the caller holds no Agent ID. No vouchers, no backend signatures, no off-chain allowlists — the Agent ID itself is the access key.

- Website: https://augent.fun
- X: https://x.com/AugentFun
- Contract (BNB Smart Chain, chainId 56): `0xAAdD9058b3DaaB00439457D82c2C508a5cc1c393`
- BscScan: https://bscscan.com/address/0xAAdD9058b3DaaB00439457D82c2C508a5cc1c393
- Sourcify: exact match (creation + runtime)

## How Agent ID is used

1. **Free claims** — each Agent ID holder can claim 1 free share (200,000 AUGENT), up to 2,999 shares, in a single on-chain call (`claimFree()`).
2. **Paid purchases** — only Agent ID holders can buy paid shares (`mint()`), 0.001 BNB per share, max 10 per wallet, 2,000,000 AUGENT per share.
3. **Referrals** — a referrer is paid 10% of each purchase instantly in BNB, only if the referrer holds an Agent ID at that moment.
4. **Agent operation** — the site publishes machine-readable manuals ([llms.txt](https://augent.fun/llms.txt), [operative.md](https://augent.fun/operative.md), [skill.md](https://augent.fun/skill.md)) so AI agents can claim and buy for their owners under strict owner-confirmation rules: no bypassed confirmations, no credential handling, preview-before-execute.

## Launch mechanics

- Sale window: 2026-11-18 12:52 UTC → 2026-11-21 12:52 UTC (3 days).
- Every payment is split by the contract in the same transaction: 75% liquidity escrow / 15% treasury / 10% referral pot.
- At the deadline the liquidity pool **always** opens from the escrow, sold out or not; LP tokens are burned. `finalize()` is permissionless.
- Before the deadline, paid buyers may reclaim 80% of the escrowed portion (0.0006 BNB per share). After the deadline refunds close permanently.
- Total supply: 10,000,000,000 AUGENT (18 decimals), fixed at deployment. Allocation: paid shares 60% · pool reserve 30% · free shares ~6% · referral/ecosystem reserve ~3% · owner 1%.
- Trading tax after the pool opens: 3% buy / 3% sell, auto-swapped to BNB and routed to the treasury by the contract.

## Contract

Source: [`contracts/AugentToken.sol`](contracts/AugentToken.sol) — Solidity 0.8.26, MIT license.
Agent ID registry (SPACE ID): `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`. An address holds an Agent ID iff `balanceOf(address) > 0` on the registry.

## Risk warning

AUGENT is a new, illiquid, experimental token. It carries no promise of profit or return and can go to zero. Nothing in this repository is financial advice.
