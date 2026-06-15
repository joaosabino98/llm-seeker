//
//  GlassComponents.swift
//  LLM Seeker
//

import SwiftUI

// MARK: - GlassCard
struct GlassCard<Content: View>: View {
    let content: () -> Content
    var cornerRadius: CGFloat = Theme.BorderRadius.lg
    var padding: CGFloat = Theme.Spacing.lg
    var backgroundColor: Color = Theme.surface

    var body: some View {
        VStack(alignment: .leading) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .background(
            ZStack {
                if #available(iOS 26, *) {
                    Rectangle()
                        .fill(backgroundColor.opacity(0.7))
                        .glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius))
                } else {
                    backgroundColor.opacity(0.9)
                }
            }
        )
        .cornerRadius(cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - GlassChip
struct GlassChip: View {
    let label: String
    let icon: String?
    var backgroundColor: Color = Theme.primary
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: Theme.Spacing.sm) {
                if let icon {
                    Image(systemName: icon).font(.caption)
                }
                Text(label)
                    .font(Theme.Typography.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                ZStack {
                    if #available(iOS 26, *) {
                        Capsule()
                            .fill(isSelected ? backgroundColor.opacity(0.8) : backgroundColor.opacity(0.5))
                            .glassEffect(in: Capsule())
                    } else {
                        Capsule()
                            .fill(isSelected ? backgroundColor.opacity(0.8) : backgroundColor.opacity(0.5))
                    }
                }
            )
            .foregroundStyle(Color.white)
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
        }
    }
}

// MARK: - GlassToolbar
struct ToolbarAction {
    let id = UUID()
    let icon: String
    let onTap: () -> Void
}

struct GlassToolbar: View {
    let title: String
    var onBackTap: (() -> Void)? = nil
    var actions: [ToolbarAction] = []

    var body: some View {
        HStack {
            if onBackTap != nil {
                Button(action: { onBackTap?() }) {
                    Image(systemName: "chevron.left").font(.headline)
                }
                .foregroundStyle(Theme.text)
            }
            Text(title)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.text)
            Spacer()
            HStack(spacing: Theme.Spacing.md) {
                ForEach(actions, id: \.id) { action in
                    Button(action: { action.onTap() }) {
                        Image(systemName: action.icon).font(.headline)
                    }
                    .foregroundStyle(Theme.primary)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            ZStack {
                if #available(iOS 26, *) {
                    Rectangle()
                        .fill(Theme.surfaceElevated.opacity(0.6))
                        .glassEffect(in: Rectangle())
                } else {
                    Theme.surfaceElevated.opacity(0.8)
                }
            }
        )
    }
}

// MARK: - LiquidGlassBackground
struct LiquidGlassBackground: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    colorScheme == .dark
                        ? Color(.sRGB, red: 0.10, green: 0.10, blue: 0.15, opacity: 1)
                        : Color(.sRGB, red: 0.95, green: 0.97, blue: 1.00, opacity: 1),
                    colorScheme == .dark
                        ? Color(.sRGB, red: 0.08, green: 0.08, blue: 0.10, opacity: 1)
                        : Color(.sRGB, red: 1.00, green: 1.00, blue: 1.00, opacity: 1)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if #available(iOS 26, *) {
                Circle()
                    .fill(Theme.primary.opacity(0.05))
                    .frame(width: 400, height: 400)
                    .offset(x: -100, y: -100)
                    .blur(radius: 60)
                Circle()
                    .fill(Theme.accent.opacity(0.05))
                    .frame(width: 400, height: 400)
                    .offset(x: 100, y: 300)
                    .blur(radius: 60)
            }
        }
    }
}

// MARK: - Badges
struct QuantBadge: View {
    let text: String
    let backgroundColor: Color

    var body: some View {
        Text(text)
            .font(Theme.Typography.caption2)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(backgroundColor.opacity(0.3))
            .foregroundStyle(backgroundColor)
            .cornerRadius(Theme.BorderRadius.sm)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.BorderRadius.sm)
                    .stroke(backgroundColor.opacity(0.5), lineWidth: 1)
            )
    }
}

struct FrameworkBadge: View {
    let text: String
    let icon: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(Theme.Typography.caption2)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.primary.opacity(0.2))
        .foregroundStyle(Theme.primary)
        .cornerRadius(Theme.BorderRadius.sm)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.BorderRadius.sm)
                .stroke(Theme.primary.opacity(0.5), lineWidth: 1)
        )
    }
}

struct FitIndicatorBadge: View {
    enum Fit {
        case comfortable, tight, overflow

        var color: Color {
            switch self {
            case .comfortable: return Theme.success
            case .tight: return .yellow
            case .overflow: return Theme.danger
            }
        }

        var label: String {
            switch self {
            case .comfortable: return "Comfortable fit"
            case .tight: return "Tight fit"
            case .overflow: return "Overflow"
            }
        }
    }

    let fit: Fit
    let macName: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "checkmark.circle.fill").font(.caption2)
            VStack(alignment: .leading, spacing: 0) {
                Text(fit.label).font(Theme.Typography.caption2).fontWeight(.semibold)
                Text(macName).font(Theme.Typography.caption2).opacity(0.7)
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(fit.color.opacity(0.2))
        .foregroundStyle(fit.color)
        .cornerRadius(Theme.BorderRadius.sm)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.BorderRadius.sm)
                .stroke(fit.color.opacity(0.5), lineWidth: 1)
        )
    }
}

#Preview {
    VStack(spacing: Theme.Spacing.lg) {
        GlassCard {
            Text("Glass Card Example").font(Theme.Typography.headline)
        }
        HStack(spacing: Theme.Spacing.md) {
            GlassChip(label: "MLX", icon: "cpu")
            GlassChip(label: "GGUF", icon: "square.fill", isSelected: true)
        }
        .padding()
        QuantBadge(text: "Q4_K_M", backgroundColor: Theme.accent)
        FrameworkBadge(text: "MLX", icon: "cube.fill")
        FitIndicatorBadge(fit: .comfortable, macName: "M3 Pro 18GB")
    }
    .padding()
    .background(LiquidGlassBackground())
}
