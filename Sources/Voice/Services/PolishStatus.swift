// PolishStatus.swift
//
// Singleton observable that exposes which polish engine is currently
// active. The transcribing pill watches `isCloudPolishing` so the cloud
// glyph only shows during the actual Cerebras request — not during ASR,
// not during local polish, not when idle.
//
// Set true when CerebrasPolisher starts a request; reset when the
// request returns (success or failure). Pure UI signal, no business logic.

import Foundation
import SwiftUI

@Observable
@MainActor
public final class PolishStatus {
    public static let shared = PolishStatus()

    /// True while a Cerebras request is in flight. The transcribing pill
    /// reads this to morph between the breathing circle and a cloud icon.
    public var isCloudPolishing: Bool = false

    /// Engine label of the most recent polish, used by the history view.
    /// Format: "cloud:qwen-3-235b" / "local:qwen3-4b" / "local:qwen3-1.7b" / "rules-only"
    public var lastEngine: String?

    private init() {}
}
