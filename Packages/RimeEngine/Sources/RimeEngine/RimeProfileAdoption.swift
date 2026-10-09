import Foundation

// MARK: - Adopting a profile change

/// What a profile change should do at this moment, which is S1 §8's order as one decision: never mid-composition,
/// one rebind, and nothing at all when nothing moved.
///
/// It lived in the keyboard extension, where nothing on this machine can test it — the rule is pure, and the
/// extension is the only place it was written. Keeping it here means the deferral can be pinned: a change that
/// arrives while a composition is in progress is *deferred*, not dropped, and the next appearance (no
/// composition) rebinds.
public enum RimeProfileAdoption: Sendable, Equatable {
  /// The profile, generation, build path and engine directories are already bound: nothing to do.
  case unchanged
  /// A different profile is available, but a composition is in progress. The caller keeps its current binding
  /// and asks again at the next appearance.
  case deferred
  /// Bind to this profile now.
  case rebind(RimeResolvedProfile)

  public static func decide(resolved: RimeResolvedProfile,
                            current: RimeResolvedProfile,
                            isComposing: Bool) -> RimeProfileAdoption {
    // A redeploy replaces the build at the same path. Its generation must still force a rebind
    // so librime discards the old session and cached configuration.
    guard resolved.profileID != current.profileID
      || resolved.generation != current.generation
      || resolved.buildDirectory != current.buildDirectory
      || resolved.directories != current.directories else { return .unchanged }
    return isComposing ? .deferred : .rebind(resolved)
  }
}
