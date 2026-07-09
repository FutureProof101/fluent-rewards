// src/rewards/main.mo
//
// Fluent Rewards accounting canister — R2 SCAFFOLD (testnet-only).
//
// Downstream, eventually-consistent consumer of finalized payment events. Does
// NOT connect to the billing canister yet (R1 not built): it reads from a local
// mock event buffer (injectMockEvent) instead of the future getBillingEventsSince.
// Claims NEVER mint — claimRewards would icrc1_transfer already-allocated FLUENT
// out of a campaign pool; that ledger call is STUBBED here (returns a mock block
// index). Do NOT deploy to mainnet (see builder brief stop conditions).
//
// Anti-abuse invariants enforced here (required from day 1):
//   - one accrual per (paymentId, campaignId) — processedPayments dedup set
//   - claimRewards / getAccruals derive the buyer from msg.caller, never a param
//   - claimRewards never mints (stubbed transfer)
//   - processRewardEvents clamps limit to MAX_SCAN_LIMIT server-side
//   - processRewardEvents reads from lastSeenEventSeq only (no caller cursor)

import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Time "mo:base/Time";
import Nat "mo:base/Nat";
import Int "mo:base/Int";
import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import T "types/rewards";
import Store "lib/store";
import Config "lib/config";

persistent actor Rewards {

  type Result<Ok, Err> = Result.Result<Ok, Err>;

  // ── Stable storage (the 4 collections named in the builder brief) ─────────
  var campaigns : [(Text, T.MerchantRewardCampaign)] = [];
  var accruals : [(Text, T.RewardAccrual)] = [];
  var scannerState : T.RewardsScannerState = {
    lastSeenEventSeq = 0;
    processedPayments = [];
  };
  var claimResults : [(Text, T.RewardClaimResult)] = [];

  // ── Scaffold infrastructure stable vars (required by the brief's own
  //    admin-gating + mock-feed + id-generation requirements; flagged in the
  //    merge report as additions beyond the 4 data collections above) ────────
  var admin : ?Principal = null; // admin-only gating (merchant-gating is future)
  var mockEventBuffer : [T.RewardEligiblePaymentEvent] = []; // injectMockEvent feed
  var idCounter : Nat = 0; // monotonic id source

  // Scaffold constants live in lib/config.mo (module-scope, not actor-scope).

  // ── id / admin helpers ───────────────────────────────────────────────────
  func nextId(prefix : Text) : Text {
    idCounter += 1;
    prefix # Nat.toText(idCounter) # "_" # Int.toText(Time.now());
  };

  func isAdmin(caller : Principal) : Bool {
    switch (admin) { case (?a) Principal.equal(caller, a); case null false };
  };

  // First non-anonymous caller claims admin (one-shot, like bootstrapPlatformAdmin).
  public shared ({ caller }) func bootstrapAdmin() : async Result<Principal, Text> {
    switch (admin) {
      case (?_) { #err("Admin already set") };
      case null {
        if (Principal.isAnonymous(caller)) {
          return #err("Anonymous caller cannot bootstrap admin");
        };
        admin := ?caller;
        #ok(caller);
      };
    };
  };

  public query func getAdmin() : async ?Principal { admin };

  // ── Campaign management (admin-only for now; merchant-gated in future) ─────
  public shared ({ caller }) func createCampaign(config : T.MerchantRewardCampaignInput) : async Result<Text, Text> {
    if (not isAdmin(caller)) { return #err("Unauthorized: admin only") };
    // reward-shape validation
    switch (config.rewardType) {
      case (#bps) {
        switch (config.rewardBps) {
          case null { return #err("rewardBps required for a bps campaign") };
          case (?b) { if (b == 0 or b > 10_000) { return #err("rewardBps must be 1..10000") } };
        };
      };
      case (#fixed) {
        switch (config.fixedRewardAmount) {
          case null { return #err("fixedRewardAmount required for a fixed campaign") };
          case (?a) { if (a == 0) { return #err("fixedRewardAmount must be > 0") } };
        };
      };
    };
    let campaignId = nextId("camp_");
    let campaign : T.MerchantRewardCampaign = {
      campaignId;
      merchantId = config.merchantId;
      enabled = true;
      fundingSource = config.fundingSource;
      rewardType = config.rewardType;
      rewardBps = config.rewardBps;
      fixedRewardAmount = config.fixedRewardAmount;
      minPurchaseAmount = config.minPurchaseAmount;
      maxRewardPerTxn = config.maxRewardPerTxn;
      dailyRewardCap = config.dailyRewardCap;
      totalCampaignCap = config.totalCampaignCap;
      fundedRewardPool = config.fundedRewardPool;
      reservedRewardPool = 0;
      claimedRewardPool = 0;
      remainingRewardPool = config.fundedRewardPool;
      startsAt = config.startsAt;
      endsAt = config.endsAt;
      eligibilityRules = config.eligibilityRules;
    };
    campaigns := Store.put(campaigns, campaignId, campaign);
    #ok(campaignId);
  };

  public shared ({ caller }) func pauseCampaign(campaignId : Text) : async Result<(), Text> {
    if (not isAdmin(caller)) { return #err("Unauthorized: admin only") };
    switch (Store.get(campaigns, campaignId)) {
      case null { #err("Campaign not found") };
      case (?c) {
        campaigns := Store.put(campaigns, campaignId, { c with enabled = false });
        #ok(());
      };
    };
  };

  public query func getCampaign(campaignId : Text) : async ?T.MerchantRewardCampaign {
    Store.get(campaigns, campaignId);
  };

  public query func listCampaigns(merchantId : Text) : async [T.MerchantRewardCampaign] {
    Array.filter<T.MerchantRewardCampaign>(
      Store.values(campaigns),
      func(c) { c.merchantId == merchantId },
    );
  };

  // ── Accrual ────────────────────────────────────────────────────────────
  // Pure-ish internal accrual: dedup, eligibility, pool check, create accrual,
  // update campaign pools, mark processed. Callable only via the trusted paths
  // below (the keeper scanner over the trusted event feed, or an admin).
  func computeReward(campaign : T.MerchantRewardCampaign, event : T.RewardEligiblePaymentEvent) : Nat {
    var amount : Nat = switch (campaign.rewardType) {
      case (#fixed) { switch (campaign.fixedRewardAmount) { case (?a) a; case null 0 } };
      case (#bps) {
        switch (campaign.rewardBps) {
          case (?b) { event.grossAmount * b / 10_000 };
          case null 0;
        };
      };
    };
    switch (campaign.maxRewardPerTxn) {
      case (?mx) { if (amount > mx) { amount := mx } };
      case null {};
    };
    amount;
  };

  func accrueInternal(event : T.RewardEligiblePaymentEvent, campaignId : Text) : Result<Text, Text> {
    // one accrual per (paymentId, campaign)
    let dedupKey = event.paymentId # ":" # campaignId;
    if (Store.has(scannerState.processedPayments, dedupKey)) {
      return #err("Already accrued for this payment + campaign");
    };
    let campaign = switch (Store.get(campaigns, campaignId)) {
      case (?c) c;
      case null { return #err("Campaign not found") };
    };
    if (not campaign.enabled) { return #err("Campaign disabled") };
    // minimum purchase threshold
    switch (campaign.minPurchaseAmount) {
      case (?m) { if (event.grossAmount < m) { return #err("Below minimum purchase amount") } };
      case null {};
    };
    let amount = computeReward(campaign, event);
    if (amount == 0) { return #err("Zero reward computed") };
    if (campaign.remainingRewardPool < amount) { return #err("Insufficient remaining campaign pool") };

    let now = Time.now();
    let rewardId = nextId("rwd_");
    let accrual : T.RewardAccrual = {
      rewardId;
      paymentId = event.paymentId;
      campaignId;
      merchantId = event.merchantId;
      buyerPrincipal = event.buyerPrincipal;
      fluentAmount = amount;
      status = #pending;
      source = #purchase;
      createdAt = now;
      claimableAt = now + Config.REWARD_CLAIM_DELAY_NS;
      claimedAt = null;
      voidReason = null;
    };
    accruals := Store.put(accruals, rewardId, accrual);
    campaigns := Store.put(
      campaigns,
      campaignId,
      {
        campaign with
        reservedRewardPool = campaign.reservedRewardPool + amount;
        remainingRewardPool = campaign.remainingRewardPool - amount;
      },
    );
    scannerState := {
      scannerState with
      processedPayments = Store.put(scannerState.processedPayments, dedupKey, true);
    };
    #ok(rewardId);
  };

  // Admin-gated manual accrual (testing / ops). The permissionless path is
  // processRewardEvents, which accrues only from the trusted event feed — a
  // caller-supplied event here must be admin-authorized so nobody can forge
  // reward-eligible events into existence.
  public shared ({ caller }) func accrueReward(event : T.RewardEligiblePaymentEvent, campaignId : Text) : async Result<Text, Text> {
    if (not isAdmin(caller)) { return #err("Unauthorized: admin only") };
    accrueInternal(event, campaignId);
  };

  // Caller-scoped: returns ONLY the calling buyer's accruals (msg.caller, never a
  // parameter — no cross-buyer enumeration; privacy boundary from the scope doc).
  public query ({ caller }) func getAccruals() : async [T.RewardAccrual] {
    let bp = Principal.toText(caller);
    Array.filter<T.RewardAccrual>(Store.values(accruals), func(a) { a.buyerPrincipal == bp });
  };

  // ── Claim (buyer-facing) ─────────────────────────────────────────────────
  // Buyer identity is msg.caller (never a parameter). NEVER mints: this would
  // icrc1_transfer already-allocated FLUENT out of the campaign pool — STUBBED
  // here (mock block index) until the ledger is wired (R3).
  public shared ({ caller }) func claimRewards() : async Result<T.RewardClaimResult, Text> {
    if (Principal.isAnonymous(caller)) { return #err("Anonymous caller cannot claim") };
    let bp = Principal.toText(caller);
    let now = Time.now();
    let mine = Array.filter<T.RewardAccrual>(
      Store.values(accruals),
      func(a) {
        a.buyerPrincipal == bp and now >= a.claimableAt and (a.status == #pending or a.status == #claimable);
      },
    );
    if (mine.size() == 0) { return #err("No claimable rewards") };

    var total : Nat = 0;
    let idBuf = Buffer.Buffer<Text>(mine.size());
    for (a in mine.vals()) {
      total += a.fluentAmount;
      idBuf.add(a.rewardId);
      // mark accrual claimed
      accruals := Store.put(accruals, a.rewardId, { a with status = #claimed; claimedAt = ?now });
      // update campaign pools: reserved -> claimed
      switch (Store.get(campaigns, a.campaignId)) {
        case (?c) {
          let newReserved : Nat = if (c.reservedRewardPool >= a.fluentAmount) {
            c.reservedRewardPool - a.fluentAmount;
          } else { 0 };
          campaigns := Store.put(
            campaigns,
            a.campaignId,
            {
              c with
              reservedRewardPool = newReserved;
              claimedRewardPool = c.claimedRewardPool + a.fluentAmount;
            },
          );
        };
        case null {};
      };
    };

    // STUB: real impl calls icrc1_transfer on the FLUENT ledger (already-allocated
    // FLUENT, never a mint). Returns a mock block index for the scaffold.
    let mockBlockIndex : Nat = 1_000_000 + idCounter;

    let claimId = nextId("claim_");
    let result : T.RewardClaimResult = {
      claimId;
      buyerPrincipal = bp;
      totalClaimed = total;
      rewardIds = Buffer.toArray(idBuf);
      ledgerBlockIndex = ?mockBlockIndex;
      claimedAt = now;
    };
    claimResults := Store.put(claimResults, claimId, result);
    #ok(result);
  };

  // ── Scanner (permissionless keeper — bounded + idempotent) ───────────────
  // Reads strictly forward from the persisted lastSeenEventSeq; NO caller cursor.
  // limit clamped server-side to MAX_SCAN_LIMIT. Idempotent via the per-(payment,
  // campaign) dedup set — calling twice over the same range never double-accrues.
  public func processRewardEvents(limit : Nat) : async { processed : Nat; nextCursor : Nat } {
    let cap : Nat = if (limit > Config.MAX_SCAN_LIMIT) Config.MAX_SCAN_LIMIT else limit;
    var processed : Nat = 0;
    var cursor : Nat = scannerState.lastSeenEventSeq;

    // ascending by eventSeq
    let sorted = Array.sort<T.RewardEligiblePaymentEvent>(
      mockEventBuffer,
      func(a, b) { Nat.compare(a.eventSeq, b.eventSeq) },
    );

    label scan for (ev in sorted.vals()) {
      if (ev.eventSeq <= cursor) { continue scan };
      if (processed >= cap) { break scan };
      // accrue to every enabled campaign of the event's merchant (dedup handles repeats)
      let merchantCampaigns = Array.filter<T.MerchantRewardCampaign>(
        Store.values(campaigns),
        func(c) { c.merchantId == ev.merchantId and c.enabled },
      );
      for (c in merchantCampaigns.vals()) {
        ignore accrueInternal(ev, c.campaignId);
      };
      cursor := ev.eventSeq;
      processed += 1;
    };

    scannerState := { scannerState with lastSeenEventSeq = cursor };
    { processed; nextCursor = cursor };
  };

  public query func getScannerState() : async T.RewardsScannerState { scannerState };

  // ── Mock event feed (admin-only, test mode) ──────────────────────────────
  // Appends directly to the local test buffer the scanner reads from. Stands in
  // for the future getBillingEventsSince pull from the (Caffeine) billing canister.
  public shared ({ caller }) func injectMockEvent(event : T.RewardEligiblePaymentEvent) : async Result<(), Text> {
    if (not isAdmin(caller)) { return #err("Unauthorized: admin only") };
    let b = Buffer.fromArray<T.RewardEligiblePaymentEvent>(mockEventBuffer);
    b.add(event);
    mockEventBuffer := Buffer.toArray(b);
    #ok(());
  };

  public query func getMockEventCount() : async Nat { mockEventBuffer.size() };
};
