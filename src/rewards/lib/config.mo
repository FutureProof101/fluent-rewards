// src/rewards/lib/config.mo
//
// Scaffold constants. Kept in a module (not actor-scope) so they're neither
// stable nor implicitly-transient — compatible across moc versions.

module {
  // Reward claim delay (refund window) before a pending accrual becomes claimable.
  // 0 in the scaffold for immediate local testability; a real window MUST be set
  // before any live (non-stubbed) token movement ships (anti-abuse invariant).
  public let REWARD_CLAIM_DELAY_NS : Int = 0;

  // processRewardEvents batch clamp (brief: 100-500). Callers cannot exceed this.
  public let MAX_SCAN_LIMIT : Nat = 500;
};
