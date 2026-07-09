// src/rewards/lib/store.mo
//
// Minimal association-list helpers over the [(Text, T)] stable-storage shape the
// builder brief specifies for campaigns / accruals / claimResults / the scanner
// dedup set. Linear scans are fine at scaffold scale; if this canister ever holds
// production volume, swap these for a proper stable map (flagged in the report).

import Array "mo:base/Array";
import Buffer "mo:base/Buffer";

module {

  public func get<T>(entries : [(Text, T)], key : Text) : ?T {
    for ((k, v) in entries.vals()) {
      if (k == key) { return ?v };
    };
    null;
  };

  public func has<T>(entries : [(Text, T)], key : Text) : Bool {
    for ((k, _) in entries.vals()) {
      if (k == key) { return true };
    };
    false;
  };

  // Upsert: replace the value for key if present, else append a new entry.
  public func put<T>(entries : [(Text, T)], key : Text, value : T) : [(Text, T)] {
    var found = false;
    let mapped = Array.map<(Text, T), (Text, T)>(
      entries,
      func((k, v)) { if (k == key) { found := true; (k, value) } else (k, v) },
    );
    if (found) { return mapped };
    let b = Buffer.fromArray<(Text, T)>(mapped);
    b.add((key, value));
    Buffer.toArray(b);
  };

  public func values<T>(entries : [(Text, T)]) : [T] {
    Array.map<(Text, T), T>(entries, func((_, v)) { v });
  };

  public func size<T>(entries : [(Text, T)]) : Nat { entries.size() };
};
