import simd

/// Codable-Brücke für `SIMD3<Float>` — ARKit-Koordinaten in Metern, y zeigt nach oben.
struct Vector3: Codable, Hashable {
    var x: Float
    var y: Float
    var z: Float

    init(_ v: SIMD3<Float>) {
        x = v.x; y = v.y; z = v.z
    }

    var simd: SIMD3<Float> { .init(x, y, z) }
}

/// Codable-Brücke für `simd_float4x4`, spaltenweise als 16 Floats gespeichert.
struct Matrix4: Codable {
    var values: [Float]

    init(_ m: simd_float4x4) {
        values = (0..<4).flatMap { c in (0..<4).map { r in m[c][r] } }
    }

    var simd: simd_float4x4 {
        var m = matrix_identity_float4x4
        guard values.count == 16 else { return m }
        for c in 0..<4 {
            for r in 0..<4 {
                m[c][r] = values[c * 4 + r]
            }
        }
        return m
    }

    var translation: SIMD3<Float> {
        let m = simd
        return .init(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// Lokale x-Achse (bei RoomPlan-Flächen die Richtung entlang der Wandbreite).
    var xAxis: SIMD3<Float> {
        let m = simd
        let a = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let len = simd_length(a)
        return len > 0 ? a / len : .init(1, 0, 0)
    }
}
