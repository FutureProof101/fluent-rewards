# fluent_ledger — FLUENT ICRC-1/2/3 ledger (D1)

This is **not custom Motoko**. It is the standard, verified DFINITY ICRC-1/2/3 ledger
WASM, deployed via `dfx` as a `custom` canister. Config lives in the repo-root
[`dfx.json`](../../dfx.json) (`fluent_ledger` canister) and
[`fluent_ledger_init.did`](../../fluent_ledger_init.did).

## Pinned ledger version

- Release: **`ledger-suite-icrc-2025-10-27`** (the dedicated ICRC ledger-suite release —
  the same family that powers ckUSDC/ckBTC).
- WASM: `https://github.com/dfinity/ic/releases/download/ledger-suite-icrc-2025-10-27/ic-icrc1-ledger.wasm.gz`
- Candid: `https://github.com/dfinity/ic/releases/download/ledger-suite-icrc-2025-10-27/ledger.did`

> Before mainnet deploy, re-confirm this matches the ledger version ckUSDC currently
> runs, and re-verify the init-arg schema against this release's `ledger.did`
> (`LedgerArg = variant { Init : InitArgs; ... }`).

## Confirmed parameters (PM, 2026-07-09)

| Param | Value |
|---|---|
| total supply | 1,000,000,000 FLUENT |
| decimals | 8 |
| transfer_fee | 0 |

Supply check: sum of `initial_balances` = **100,000,000,000,000,000** base units
(250M + 300M + 100M + 50M + 150M + 50M + 100M = 1,000M FLUENT × 1e8).

## ⛔ Deploy gate

**No mainnet deploy without explicit PM sign-off on every init arg** (builder brief).
`fluent_ledger_init.did` ships with `[PLACEHOLDER: ...]` principals (all set to the
inert `aaaaa-aa` management-canister id) — these are **not** real accounts. Before any
deploy:

1. Replace the 7 reserve-account principals + `minting_account` + archive `controller_id`
   with real principals (open question 1 in the scope doc decides whether these are your
   personal principal now or an entity principal).
2. PM confirms every init arg.

**Local/testnet:** substitute your own dfx identity principal for all placeholders in a
local copy (`fluent_ledger_init.local.did`, git-ignored) and point `dfx.json` at it, then
`dfx deploy fluent_ledger --network local`. Not done in this scaffold pass — the committed
init file is the mainnet template with placeholders intact, and this sandbox cannot reach
`github.com` to download the ledger WASM anyway.
