import SwiftUI

enum PhotoSwipeTheme {
  static let backgroundTop = Color(hex: "07111F")
  static let backgroundBottom = Color(hex: "111F35")
  static let surface = Color.white.opacity(0.075)
  static let surfaceStrong = Color.white.opacity(0.12)
  static let hairline = Color.white.opacity(0.12)

  static let accent = Color(hex: "55B8FF")
  static let accentStrong = Color(hex: "3478F6")
  static let delete = Color(hex: "FF5A67")
  static let favorite = Color(hex: "FF5A91")
  static let success = Color(hex: "38D39F")
  static let warning = Color(hex: "FFB95C")

  static let textPrimary = Color.white.opacity(0.96)
  static let textSecondary = Color.white.opacity(0.64)
  static let textTertiary = Color.white.opacity(0.50)

  static let smallRadius: CGFloat = 12
  static let mediumRadius: CGFloat = 18
  static let largeRadius: CGFloat = 26
}

extension Color {
  init(hex: String) {
    let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&int)
    let a: UInt64
    let r: UInt64
    let g: UInt64
    let b: UInt64
    switch hex.count {
    case 3:
      (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
    case 6:
      (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
    case 8:
      (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
    default:
      (a, r, g, b) = (255, 0, 0, 0)
    }
    self.init(
      .sRGB,
      red: Double(r) / 255,
      green: Double(g) / 255,
      blue: Double(b) / 255,
      opacity: Double(a) / 255
    )
  }
}
