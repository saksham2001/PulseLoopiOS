import Foundation

// Open Food Facts wire types + the app-facing domain product. OFF data is community-sourced
// and messy: numeric fields arrive as numbers or strings, keys are hyphenated, energy may be
// kJ-only, and sodium is grams. Everything is normalized here (and only here) so the rest of
// the app deals in clean per-100g kcal/grams — with `NutritionMath` holding the pure conversion
// logic, heavily unit-tested.

/// A normalized food product: per-100g values (OFF's canonical shape) plus serving info.
/// Per-serving math happens at use time via `NutritionMath.scaled`.
struct FoodProduct: Equatable, Hashable, Sendable {
    var code: String
    var name: String
    var brand: String?
    var energyKcal100g: Double
    var protein100g: Double
    var carbs100g: Double
    var fat100g: Double
    var fiber100g: Double?
    var sugars100g: Double?
    var saturatedFat100g: Double?
    var sodiumMg100g: Double?
    /// Human serving text, e.g. "30 g" or "1 cup (240 ml)".
    var servingSizeText: String?
    /// Grams per serving when OFF provides a resolvable quantity.
    var servingQuantityG: Double?
}

/// Pure nutrition conversions — the single place OFF's unit quirks are handled.
enum NutritionMath {
    /// kJ → kcal.
    static let kcalPerKJ = 1.0 / 4.184

    /// Nutrient totals for `grams` of a product, scaled from its per-100g values.
    static func scaled(per100g value: Double, grams: Double) -> Double {
        value * grams / 100
    }

    /// Resolve energy in kcal from OFF's fields: prefer `energy-kcal_100g`; fall back to
    /// converting `energy_100g` (kJ). Returns nil when neither is present.
    static func energyKcal(kcal: Double?, kJ: Double?) -> Double? {
        if let kcal { return kcal }
        return kJ.map { $0 * kcalPerKJ }
    }

    /// OFF reports sodium in grams per 100g; the app stores milligrams.
    static func sodiumMg(fromGrams grams: Double?) -> Double? {
        grams.map { $0 * 1000 }
    }
}

// MARK: - Wire DTOs

/// `GET /api/v2/product/{code}` envelope. `status == 1` means found.
struct OFFProductResponse: Decodable {
    let status: Int?
    let product: OFFProductDTO?
}

/// Search envelope. Search-a-licious returns `hits`; the legacy v1/v2 search returns
/// `products` — decode both.
struct OFFSearchResponse: Decodable {
    let hits: [OFFProductDTO]?
    let products: [OFFProductDTO]?

    var results: [OFFProductDTO] { hits ?? products ?? [] }
}

struct OFFProductDTO: Decodable {
    let code: String?
    let productName: String?
    let brands: String?
    let nutriments: OFFNutriments?
    let servingSize: String?
    let servingQuantity: OFFNumber?

    enum CodingKeys: String, CodingKey {
        case code
        case productName = "product_name"
        case brands
        case nutriments
        case servingSize = "serving_size"
        case servingQuantity = "serving_quantity"
    }

    /// Normalize to the domain product. Returns nil for unusable rows (no name, or no
    /// energy in any form) — better to drop a result than present a food with no numbers.
    func asFoodProduct() -> FoodProduct? {
        guard let code, !code.isEmpty,
              let name = productName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let n = nutriments,
              let kcal = NutritionMath.energyKcal(kcal: n.energyKcal100g?.value, kJ: n.energyKJ100g?.value)
        else { return nil }
        // OFF brands is a comma-separated list; show the first.
        let brand = brands?
            .split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return FoodProduct(
            code: code,
            name: name,
            brand: (brand?.isEmpty == false) ? brand : nil,
            energyKcal100g: kcal,
            protein100g: n.proteins100g?.value ?? 0,
            carbs100g: n.carbohydrates100g?.value ?? 0,
            fat100g: n.fat100g?.value ?? 0,
            fiber100g: n.fiber100g?.value,
            sugars100g: n.sugars100g?.value,
            saturatedFat100g: n.saturatedFat100g?.value,
            sodiumMg100g: NutritionMath.sodiumMg(fromGrams: n.sodium100g?.value),
            servingSizeText: servingSize,
            servingQuantityG: servingQuantity?.value
        )
    }
}

struct OFFNutriments: Decodable {
    let energyKcal100g: OFFNumber?
    let energyKJ100g: OFFNumber?
    let proteins100g: OFFNumber?
    let carbohydrates100g: OFFNumber?
    let fat100g: OFFNumber?
    let fiber100g: OFFNumber?
    let sugars100g: OFFNumber?
    let saturatedFat100g: OFFNumber?
    let sodium100g: OFFNumber?

    enum CodingKeys: String, CodingKey {
        case energyKcal100g = "energy-kcal_100g"
        case energyKJ100g = "energy_100g"
        case proteins100g = "proteins_100g"
        case carbohydrates100g = "carbohydrates_100g"
        case fat100g = "fat_100g"
        case fiber100g = "fiber_100g"
        case sugars100g = "sugars_100g"
        case saturatedFat100g = "saturated-fat_100g"
        case sodium100g = "sodium_100g"
    }
}

/// OFF numeric fields arrive as JSON numbers *or* strings ("12.5"). Decode either.
struct OFFNumber: Decodable, Equatable {
    let value: Double

    init(_ value: Double) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self),
                  let double = Double(string.trimmingCharacters(in: .whitespaces)) {
            value = double
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected number or numeric string"
            )
        }
    }
}
