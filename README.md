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

## FluentKeys (src/keys) — mainnet deploy (Jonni-gated, run from your terminal)

```bash
# 1. Deploy to mainnet under YOUR identity (cycles from your wallet):
dfx deploy keys --network ic --with-cycles 1000000000000

# 2. Claim admin (first caller wins — do this IMMEDIATELY after deploy):
dfx canister call keys bootstrapAdmin '()' --network ic

# 3. Record the canister id (Phase 4 config needs it):
dfx canister id keys --network ic

# 4. Entitle the first merchant principal (the PM dashboard identity):
dfx canister call keys addEntitled '(principal "<merchant-principal>")' --network ic
```
Key name ships as `test_key_1`; the `key_1` flip is a source-constant change +
redeploy, ONLY on Jonni's confirmation (existing ciphertexts do not survive it).

## Decisions & Memory — 2026-07-12 (Day-3 Phases 3 + 5)

- **FluentKeys** (`src/keys`, `239c93b`): self-owned vetKD canister. Context
  `fluent_customer_email_v1` (exact bytes, forever); `KEY_NAME = "test_key_1"`
  (`key_1` ONLY via Jonni-confirmed redeploy — ciphertexts not portable);
  derive input = msg.caller ALWAYS; entitlement allowlist stub = the premium
  seam. Local proofs: non-entitled rejected, two principals → different keys.
  LESSON: attach a cycles CEILING (30B) — unspent management-call cycles
  refund; the local replica charged >10B for the "10B" test key.
  Mainnet deploy DONE 2026-07-12 by Jonni: canister **m5w6h-pqaaa-aaaau-ag22q-cai**, upgraded to key_1 same session (skipping the test_key_1 interim — no ciphertext migration ever needed). Recorded
  here when run.
- **Live event wire** (`ebb6c19`): `processLiveRewardEvents` pulls the LIVE
  billing canister's `getBillingEventsSince` (config default `x2sod`;
  architect read-only ruling 2026-07-12; allowlisting stays R0A item 6).
  Proven against the 3 REAL live payment.succeeded events (seeded verbatim
  into `src/billing_stub` — a local canister cannot call mainnet): accrued
  3/3, rescan 0/0 (idempotent), the 2026-07-10 x402 machine payment now has a
  #pending FLUENT accrual. Rewards canister remains LOCAL (no mainnet token
  movement — R0A gates unchanged).
