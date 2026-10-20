// Compatibility.swift
// macOS 12 backward-compatibility wrappers for newer SwiftUI APIs.

import SwiftUI

// MARK: - ViewThatFits Fallback (macOS 13+)

/// A macOS 12-compatible replacement for `ViewThatFits(in: .horizontal)`.
/// Uses the compact layout on macOS 12, retaining its intrinsic height in scroll views.
struct HorizontalViewThatFits<First: View, Second: View>: View {
    let first: () -> First
    let second: () -> Second

    init(
        @ViewBuilder first: @escaping () -> First,
        @ViewBuilder second: @escaping () -> Second
    ) {
        self.first = first
        self.second = second
    }

    var body: some View {
        if #available(macOS 13, *) {
            ViewThatFits(in: .horizontal) {
                first()
                second()
            }
        } else {
            second()
        }
    }
}

// MARK: - onChange Fallback (macOS 14+)

extension View {
    /// Backward-compatible `onChange` that works on macOS 12.
    /// On macOS 14+ uses the two-parameter variant; on older systems
    /// uses the single-closure variant available since macOS 12.
    func onChangeBackward<V: Equatable>(
        of value: V,
        perform action: @escaping () -> Void
    ) -> some View {
        if #available(macOS 14, *) {
            return onChange(of: value) { _, _ in action() }
        } else {
            return onChange(of: value) { _ in action() }
        }
    }
}

// MARK: - Scroll Indicators Fallback (macOS 13+)

extension View {
    /// Applies `.scrollIndicators(.hidden)` on macOS 13+, no-op on macOS 12.
    @ViewBuilder
    func scrollIndicatorsHiddenCompat() -> some View {
        if #available(macOS 13, *) {
            self.scrollIndicators(.hidden)
        } else {
            self
        }
    }
}

// MARK: - Scroll Content Background Fallback (macOS 13+)

extension View {
    /// Applies `.scrollContentBackground(.hidden)` on macOS 13+, no-op on macOS 12.
    @ViewBuilder
    func scrollContentBackgroundHiddenCompat() -> some View {
        if #available(macOS 13, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

// Keep the native focus appearance on systems without the newer override.
extension View {
    @ViewBuilder
    func focusEffectDisabledCompat() -> some View {
        if #available(macOS 14, *) {
            self.focusEffectDisabled()
        } else {
            self
        }
    }
}
