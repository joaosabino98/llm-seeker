//
//  Theme.swift
//  LLM Seeker
//

import SwiftUI

struct Theme {
    // MARK: - Semantic Colors
    static let primary = Color(.sRGB, red: 0.2, green: 0.5, blue: 1.0, opacity: 1.0)
    static let accent = Color(.sRGB, red: 1.0, green: 0.5, blue: 0.2, opacity: 1.0)
    static let success = Color(.sRGB, red: 0.2, green: 0.8, blue: 0.4, opacity: 1.0)
    static let danger = Color(.sRGB, red: 1.0, green: 0.3, blue: 0.3, opacity: 1.0)

    // MARK: - Surfaces
    static let surface = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
            : UIColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1.0)
    })

    static let surfaceElevated = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 1.0)
            : UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    })

    static let surfaceOverlay = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 0.8)
            : UIColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 0.8)
    })

    static let text = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0)
            : UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0)
    })

    static let textSecondary = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.70, green: 0.70, blue: 0.72, alpha: 1.0)
            : UIColor(red: 0.30, green: 0.30, blue: 0.32, alpha: 1.0)
    })

    static let background = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1.0)
            : UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    })

    // MARK: - Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Border Radius
    enum BorderRadius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: - Typography
    enum Typography {
        static let title1 = Font.system(size: 32, weight: .bold)
        static let title2 = Font.system(size: 28, weight: .bold)
        static let title3 = Font.system(size: 24, weight: .semibold)
        static let headline = Font.system(size: 20, weight: .semibold)
        static let subheadline = Font.system(size: 16, weight: .semibold)
        static let body = Font.system(size: 16, weight: .regular)
        static let caption = Font.system(size: 14, weight: .regular)
        static let caption2 = Font.system(size: 12, weight: .regular)
    }
}
