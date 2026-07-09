# fluent-rewards

FLUENT token (ICRC-1/2/3 ledger) + rewards accounting canister. **Self-managed —
deployed via `dfx`/`icp-cli`, never through Caffeine.** Separate repo and toolchain from
the Fluent app (that lives in the Caffeine/Motoko repo).

Source of truth for the data model, genesis allocation, and all parameters:
`fluent-rewards-token-scope-v1.md` (PM/architect doc, not in this repo).

## Two sub-parts, two readiness tracks

| Part | What | Track |
|---|---|---|
| **D1 — FLUENT ledger** | Standard ICRC-1/2/3 ledger WASM + init args | Near mainnet-ready; **PM-gated** on real principals + init-arg sign-off. See [`src/fluent_ledger/README.md`](src/fluent_ledger/README.md). |
| **D2 — rewards canister** | Custom Motoko: campaigns, accrual, claim, keeper scanner | **Testnet scaffold only.** Mock event feed; claim transfer stubbed. Real design gated on R0A + R1. |

## Layout

```
dfx.json                    both canisters
mops.toml                   Motoko deps (mo:base) for the rewards canister
fluent_ledger_init.did      D1 ledger init args (MAINNET TEMPLATE — placeholders, gated)
src/
  fluent_ledger/README.md   D1 notes (pinned ledger version, deploy gate)
  rewards/
    main.mo                 D2 actor (methods, anti-abuse, mock feed)
    types/rewards.mo        D2 data model (ported from the scope doc)
    lib/store.mo            assoc-list helpers over [(Text, T)] stable storage
```

## Build / deploy (local)

```bash
# rewards canister (the custom Motoko — builds & deploys locally, no download needed)
npx mops install
dfx start --background
dfx deploy rewards
dfx canister call rewards bootstrapAdmin        # first caller becomes admin
dfx canister call rewards getScannerState

# ledger (D1) — DO NOT deploy to mainnet without PM sign-off on every init arg.
# Local deploy needs real placeholder principals substituted; see src/fluent_ledger/README.md.
```

## Guardrails (builder brief)

- **No FLUENT mainnet deploy without explicit PM sign-off on every init arg.**
- Rewards canister is **testnet-only**; its mainnet principal must be known before it can be
  allowlisted on the Lane 1 billing canister for `getBillingEventsSince`.
- Not in scope here: Mode D fee-differential logic (R5), the live rewards↔billing connection
  (R1), `getBillingEventsSince` access-control allowlisting, R0A legal/entity decisions.
