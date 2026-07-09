// src/rewards/types/rewards.mo
//
// Fluent Rewards data model — ported EXACTLY from
// fluent-rewards-token-scope-v1.md § "Data model" (lines 235-313), adapted to
// Motoko conventions:
//   - amounts are Nat base units (e8s/e6s convention, per scope-doc note #8)
//   - timestamps are Int nanoseconds (Time.now())
//   - TokenSymbol reuses the existing Fluent union (ckUSDC/ICP/ckBTC), NOT a
//     free-text asset field (scope-doc note #8)
//   - TS `bigint` -> Nat (amounts/seq) or Int (timestamps)
//
// SCAFFOLD ONLY (R2, testnet). No live FLUENT ledger transfer — claim is stubbed.

module {

  // Existing Fluent TokenSymbol union (do not invent a parallel asset field).
  public type TokenSymbol = { #ckUSDC; #ICP; #ckBTC };

  // ── RewardEligiblePaymentEvent — matches the (future) billing event shape ──
  // eventSeq is the monotonic append-order index from the extended billingEvents
  // log (R1) — NOT idempotencyKey, NOT a new sequence.
  public type RewardEligiblePaymentEvent = {
    eventSeq : Nat;
    paymentId : Text;
    paymentIntentId : Text;
    merchantId : Text;
    planId : ?Text;
    buyerPrincipal : Text; // sourced from PaymentIntent.expectedSenderOwner (Task #47)
    token : TokenSymbol;
    grossAmount : Nat; // base units
    platformFee : Nat;
    merchantNet : Nat;
    blockIndex : ?Nat; // ledger proof (invariant #7)
    finalizedAt : Int;
  };

  // ── Campaign funding modes (A/B/C) ──────────────────────────────────────
  public type Reserve = { #rewardsReserve; #merchantGrowthFund };
  public type PaidAsset = { #ckUSDC; #ICP };
  public type FundingSource = {
    #platform_grant : { reserve : Reserve; approvalId : Text }; // Mode A
    #merchant_fluent : { transferBlockIndex : Nat; amount : Nat }; // Mode B
    #merchant_paid : {
      paymentAsset : PaidAsset;
      paymentAmount : Nat;
      fluentAllocated : Nat;
      paymentId : Text;
    }; // Mode C
  };

  public type RewardType = { #bps; #fixed };

  public type CampaignEligibilityRules = {
    newCustomersOnly : ?Bool;
    excludedPlanIds : ?[Text];
    maxRewardsPerBuyerPerDay : ?Nat;
    maxRewardsPerBuyerTotal : ?Nat;
  };

  public type MerchantRewardCampaign = {
    campaignId : Text;
    merchantId : Text;
    enabled : Bool;
    fundingSource : FundingSource;
    rewardType : RewardType;
    rewardBps : ?Nat;
    fixedRewardAmount : ?Nat;
    minPurchaseAmount : ?Nat;
    maxRewardPerTxn : ?Nat;
    dailyRewardCap : ?Nat;
    totalCampaignCap : ?Nat;
    // Pool accounting: funded = reserved(pending+claimable) + claimed + remaining.
    fundedRewardPool : Nat;
    reservedRewardPool : Nat;
    claimedRewardPool : Nat;
    remainingRewardPool : Nat;
    startsAt : Int;
    endsAt : ?Int;
    eligibilityRules : ?CampaignEligibilityRules;
  };

  // Caller-supplied subset for createCampaign — no campaignId (server-assigned)
  // and no derived pool-accounting fields (reserved/claimed/remaining).
  public type MerchantRewardCampaignInput = {
    merchantId : Text;
    fundingSource : FundingSource;
    rewardType : RewardType;
    rewardBps : ?Nat;
    fixedRewardAmount : ?Nat;
    minPurchaseAmount : ?Nat;
    maxRewardPerTxn : ?Nat;
    dailyRewardCap : ?Nat;
    totalCampaignCap : ?Nat;
    fundedRewardPool : Nat;
    startsAt : Int;
    endsAt : ?Int;
    eligibilityRules : ?CampaignEligibilityRules;
  };

  // ── RewardAccrual — state machine pending -> claimable -> claimed/voided/expired ──
  public type RewardStatus = {
    #pending;
    #claimable;
    #claimed;
    #voided;
    #expired;
  };

  // Provenance of the accrual — distinguishes ordinary per-purchase reward from
  // campaign bonus rules, the two first-N airdrops, and Mode D's gift-split.
  // Required for reporting/audit and per-source anti-abuse caps.
  public type RewardSource = {
    #purchase;
    #campaign_bonus;
    #airdrop_customer;
    #airdrop_merchant;
    #mode_d_gift;
  };

  public type RewardAccrual = {
    rewardId : Text;
    paymentId : Text;
    campaignId : Text;
    merchantId : Text;
    buyerPrincipal : Text;
    fluentAmount : Nat;
    status : RewardStatus;
    source : RewardSource;
    createdAt : Int;
    claimableAt : Int;
    claimedAt : ?Int;
    voidReason : ?Text;
  };

  public type RewardClaimResult = {
    claimId : Text;
    buyerPrincipal : Text;
    totalClaimed : Nat;
    rewardIds : [Text];
    ledgerBlockIndex : ?Nat;
    claimedAt : Int;
  };

  // ── Scanner state (builder brief) ───────────────────────────────────────
  // processedPayments is the one-accrual-per-(paymentId,campaign) dedup set,
  // keyed "paymentId:campaignId". Represented as a stable assoc list (matching
  // the [(Text, T)] stable-storage pattern used for the other collections);
  // the brief's TS type calls it Map<Text, Bool> — same semantics.
  public type RewardsScannerState = {
    lastSeenEventSeq : Nat;
    processedPayments : [(Text, Bool)];
  };

  // ── Mode D — fee-differential tiered-utility config (TYPE ONLY, not wired) ──
  // Logic (comparator rate, buyback/gift split, tier gating) is R5 and out of
  // scope for this scaffold; only the shape is declared here.
  public type MerchantTierLevel = { #none; #bronze; #silver; #gold };

  public type MerchantFeeDifferentialConfig = {
    merchantId : Text;
    enabled : Bool;
    comparatorRateBps : Nat;
    participationPct : Nat;
    buybackSplitPct : Nat; // buybackSplitPct + giftSplitPct = 100
    giftSplitPct : Nat;
    currentTierBalance : Nat;
    currentTier : MerchantTierLevel;
    updatedAt : Int;
  };

  public type MerchantTier = {
    tier : MerchantTierLevel;
    minFluentBalance : Nat;
    rewardBpsBonus : Nat;
    platformFeeBpsDiscount : Nat;
  };
};
