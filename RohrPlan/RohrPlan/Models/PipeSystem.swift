import SwiftUI
import UIKit

/// Leitungssysteme der TGA-Gewerke Heizung, Sanitär, Gas und Lüftung.
/// Jedes System hat eine feste Farbe (angelehnt an übliche Plan-Konventionen),
/// einen Kurzcode für Beschriftungen und einen eigenen DXF-Layer.
enum PipeSystem: String, Codable, CaseIterable, Identifiable {
    case heizungVorlauf
    case heizungRuecklauf
    case kaltwasser
    case warmwasser
    case zirkulation
    case abwasser
    case gas
    case lueftung

    var id: String { rawValue }

    var label: String {
        switch self {
        case .heizungVorlauf: return "Heizung Vorlauf"
        case .heizungRuecklauf: return "Heizung Rücklauf"
        case .kaltwasser: return "Kaltwasser"
        case .warmwasser: return "Warmwasser"
        case .zirkulation: return "Zirkulation"
        case .abwasser: return "Abwasser"
        case .gas: return "Gas"
        case .lueftung: return "Lüftung"
        }
    }

    var shortCode: String {
        switch self {
        case .heizungVorlauf: return "HZ-VL"
        case .heizungRuecklauf: return "HZ-RL"
        case .kaltwasser: return "TW-K"
        case .warmwasser: return "TW-W"
        case .zirkulation: return "TW-Z"
        case .abwasser: return "AW"
        case .gas: return "GAS"
        case .lueftung: return "LÜ"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .heizungVorlauf: return .systemRed
        case .heizungRuecklauf: return .systemBlue
        case .kaltwasser: return .systemCyan
        case .warmwasser: return .systemOrange
        case .zirkulation: return .systemPurple
        case .abwasser: return .systemBrown
        case .gas: return .systemYellow
        case .lueftung: return .systemGreen
        }
    }

    var color: Color { Color(uiColor: uiColor) }

    /// Rücklauf und Zirkulation werden im Plan gestrichelt gezeichnet.
    var dashed: Bool {
        self == .heizungRuecklauf || self == .zirkulation
    }

    var dxfLayer: String {
        switch self {
        case .heizungVorlauf: return "HZ_VORLAUF"
        case .heizungRuecklauf: return "HZ_RUECKLAUF"
        case .kaltwasser: return "TW_KALT"
        case .warmwasser: return "TW_WARM"
        case .zirkulation: return "TW_ZIRK"
        case .abwasser: return "ABWASSER"
        case .gas: return "GAS"
        case .lueftung: return "LUEFTUNG"
        }
    }

    /// AutoCAD-Farbindex (ACI) für den DXF-Export.
    var dxfColorIndex: Int {
        switch self {
        case .heizungVorlauf: return 1   // rot
        case .heizungRuecklauf: return 5 // blau
        case .kaltwasser: return 4       // cyan
        case .warmwasser: return 30      // orange
        case .zirkulation: return 6      // magenta
        case .abwasser: return 8         // grau
        case .gas: return 2              // gelb
        case .lueftung: return 3         // grün
        }
    }
}

/// Nennweiten nach DN; `displayRadius` ist der Radius für die 3D-Darstellung
/// (etwas größer als real, damit dünne Leitungen sichtbar bleiben).
enum NominalDiameter: Int, Codable, CaseIterable, Identifiable {
    case dn12 = 12
    case dn15 = 15
    case dn20 = 20
    case dn25 = 25
    case dn32 = 32
    case dn40 = 40
    case dn50 = 50
    case dn65 = 65
    case dn80 = 80
    case dn100 = 100

    var id: Int { rawValue }

    var label: String { "DN \(rawValue)" }

    var displayRadius: Float {
        Float(rawValue) / 2000 + 0.006
    }

    /// Linienstärke im 2D-Plan in Punkten.
    var planLineWidth: CGFloat {
        switch self {
        case .dn12, .dn15: return 2
        case .dn20, .dn25: return 3
        case .dn32, .dn40: return 4
        case .dn50, .dn65: return 5
        case .dn80, .dn100: return 6
        }
    }
}
