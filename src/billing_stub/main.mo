// src/billing_stub/main.mo
//
// LOCAL-PROOF ONLY: a minimal stand-in for the live Fluent billing canister's
// getBillingEventsSince, because a local-replica canister cannot call mainnet
// x2sod. The Phase 5 proof seeds this stub with REAL events fetched from the
// live canister (verbatim payloads) so the rewards scanner exercises a real
// inter-canister pull over real event shapes and real data. Never deployed to
// mainnet; production rewards config points at x2sod directly.

import Array "mo:base/Array";
import Nat "mo:base/Nat";

persistent actor BillingStub {
  type BillingEvent = {
    eventType : Text;
    merchantId : Text;
    payloadJson : Text;
    eventSeq : ?Nat;
    createdAt : Int;
  };

  var events : [BillingEvent] = [];

  public func seed(e : BillingEvent) : async () {
    events := Array.append(events, [e]);
  };

  // Same contract as the live producer: ascending by (eventSeq ?? 0), cursor
  // strictly exclusive, nextCursor = last examined seq.
  public query func getBillingEventsSince(cursor : Nat, limit : Nat) : async {
    events : [BillingEvent];
    nextCursor : Nat;
    hasMore : Bool;
  } {
    func seqOf(e : BillingEvent) : Nat {
      switch (e.eventSeq) { case (?s) s; case null 0 };
    };
    let sorted = Array.sort<BillingEvent>(events, func(a, b) { Nat.compare(seqOf(a), seqOf(b)) });
    let matched = Array.filter<BillingEvent>(sorted, func(e) { seqOf(e) > cursor });
    let page = if (matched.size() > limit) Array.subArray(matched, 0, limit) else matched;
    var next = cursor;
    for (e in page.vals()) { if (seqOf(e) > next) { next := seqOf(e) } };
    { events = page; nextCursor = next; hasMore = matched.size() > page.size() };
  };
}
