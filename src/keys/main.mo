// src/keys/main.mo
//
// FluentKeys — self-owned vetKD key-derivation canister (#107 v1, Day-3 Phase 3).
//
// Sibling of the rewards canisters: SELF-OWNED (Jonni's identity + cycles),
// deliberately OUTSIDE the Caffeine-managed billing canister so key derivation
// authority and its cycle budget never depend on the platform deploy pipeline.
//
// Design (architect-final):
//   - context  : "fluent_customer_email_v1" — exact bytes, everywhere, forever.
//   - key name : CONFIG CONSTANT below — "test_key_1" now; flipping to "key_1"
//     happens ONLY via a Jonni-confirmed redeploy (ciphertexts are NOT portable
//     across key names — re-capture contacts at the switch).
//   - getVerificationKey : vetkd_public_key. Free, public by design — a vetKD
//     PUBLIC key is public information (clients IBE-encrypt against it and
//     verify derived keys with it).
//   - getContactVetKey : vetkd_derive_key with input = Principal.toBlob(msg.caller)
//     ALWAYS — never a parameter. That IS the authorization model: you can only
//     ever derive the key for your own identity. Caller captured BEFORE the
//     await. Cycles attached (10B test key / 26B production).
//   - ENTITLEMENT STUB (premium tier, invariant #6): v1 = admin-managed
//     allowlist of merchant principals, checked before deriving. Billing-
//     canister attestation or FLUENT-holdings gating is a later evolution —
//     this is the seam.
//   - Anonymous callers rejected on derivation; admin methods are
//     bootstrap-then-locked (same first-caller pattern the billing canister's
//     bootstrapPlatformAdmin uses, proven on live 2026-07-10).
//
// DEVIATION (reported): the brief sketches `-> async Blob` returns; both
// methods return Result<Blob, Text> instead so "reject with a clear error"
// is an error VALUE, not a trap — consistent with the billing canister's
// getEmailVerificationKey shape.

import Array "mo:base/Array";
import Cycles "mo:base/ExperimentalCycles";
import Error "mo:base/Error";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Text "mo:base/Text";

persistent actor FluentKeys {

  // ── Config constants ──────────────────────────────────────────────────
  let CONTEXT : Blob = Text.encodeUtf8("fluent_customer_email_v1");
  let KEY_NAME : Text = "test_key_1"; // "key_1" ONLY via Jonni-confirmed redeploy
  // Attach a ceiling, not the exact price: unspent cycles on management-
  // canister calls are REFUNDED, so over-attachment costs nothing while
  // under-attachment rejects (test_key_1 ≈ 10B mainnet, key_1 ≈ 26B; the
  // local replica charged >10B in the Phase 3 smoke).
  let DERIVE_CYCLES : Nat = 30_000_000_000;

  // ── Management canister (vetKD system API) ────────────────────────────
  type VetKdCurve = { #bls12_381_g2 };
  type VetKdKeyId = { curve : VetKdCurve; name : Text };
  transient let ic = actor "aaaaa-aa" : actor {
    vetkd_public_key : ({
      canister_id : ?Principal;
      context : Blob;
      key_id : VetKdKeyId;
    }) -> async ({ public_key : Blob });
    vetkd_derive_key : ({
      input : Blob;
      context : Blob;
      key_id : VetKdKeyId;
      transport_public_key : Blob;
    }) -> async ({ encrypted_key : Blob });
  };
  func keyId() : VetKdKeyId { { curve = #bls12_381_g2; name = KEY_NAME } };

  // ── Admin (bootstrap-then-locked) ─────────────────────────────────────
  var admin : ?Principal = null;

  public shared ({ caller }) func bootstrapAdmin() : async Result.Result<(), Text> {
    if (Principal.isAnonymous(caller)) { return #err("Anonymous caller cannot be admin") };
    switch (admin) {
      case (?_) { #err("Admin already configured") };
      case null { admin := ?caller; #ok };
    };
  };

  func isAdmin(caller : Principal) : Bool {
    switch (admin) { case (?a) { a == caller }; case null false };
  };

  // ── Entitlement allowlist (v1 stub — the premium-tier seam) ───────────
  var entitled : [Principal] = [];

  public shared ({ caller }) func addEntitled(p : Principal) : async Result.Result<(), Text> {
    if (not isAdmin(caller)) { return #err("Unauthorized: admin only") };
    if (Principal.isAnonymous(p)) { return #err("Cannot entitle the anonymous principal") };
    if (Array.find<Principal>(entitled, func(x) { x == p }) != null) { return #ok };
    entitled := Array.append(entitled, [p]);
    #ok;
  };

  public shared ({ caller }) func removeEntitled(p : Principal) : async Result.Result<(), Text> {
    if (not isAdmin(caller)) { return #err("Unauthorized: admin only") };
    entitled := Array.filter<Principal>(entitled, func(x) { x != p });
    #ok;
  };

  public query func isEntitled(p : Principal) : async Bool {
    Array.find<Principal>(entitled, func(x) { x == p }) != null;
  };

  // ── Public verification key (free, public information) ────────────────
  public shared func getVerificationKey() : async Result.Result<Blob, Text> {
    try {
      let res = await ic.vetkd_public_key({
        canister_id = null; // this canister
        context = CONTEXT;
        key_id = keyId();
      });
      #ok(res.public_key);
    } catch (e) {
      #err("vetkd_public_key failed: " # Error.message(e));
    };
  };

  // ── Caller-bound key derivation (the #107 decrypt path) ───────────────
  public shared ({ caller }) func getContactVetKey(transportPubKey : Blob) : async Result.Result<Blob, Text> {
    // Capture + gate BEFORE any await (caller is stable across awaits in
    // Motoko, but the discipline is the brief's and it costs nothing).
    let who = caller;
    if (Principal.isAnonymous(who)) { return #err("Anonymous callers cannot derive keys") };
    if (Array.find<Principal>(entitled, func(x) { x == who }) == null) {
      return #err("Not entitled: contact encryption is a premium feature — ask the platform admin to enable it for your merchant principal");
    };
    try {
      Cycles.add<system>(DERIVE_CYCLES);
      let res = await ic.vetkd_derive_key({
        input = Principal.toBlob(who); // ALWAYS the caller — never a parameter
        context = CONTEXT;
        key_id = keyId();
        transport_public_key = transportPubKey;
      });
      #ok(res.encrypted_key);
    } catch (e) {
      #err("vetkd_derive_key failed: " # Error.message(e));
    };
  };
}
