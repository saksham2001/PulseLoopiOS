import XCTest
@testable import PulseLoop

final class OpenFoodFactsMapperTests: XCTestCase {

    private func decodeProduct(_ json: String) throws -> OFFProductDTO {
        try JSONDecoder().decode(OFFProductDTO.self, from: Data(json.utf8))
    }

    func testFullProductMapsAllFields() throws {
        let dto = try decodeProduct("""
        {
            "code": "3017620422003",
            "product_name": "Nutella",
            "brands": "Ferrero, Nutella",
            "serving_size": "15 g",
            "serving_quantity": "15",
            "nutriments": {
                "energy-kcal_100g": 539,
                "energy_100g": 2255,
                "proteins_100g": 6.3,
                "carbohydrates_100g": 57.5,
                "fat_100g": 30.9,
                "fiber_100g": 3.5,
                "sugars_100g": 56.3,
                "saturated-fat_100g": 10.6,
                "sodium_100g": 0.0428
            }
        }
        """)
        let product = try XCTUnwrap(dto.asFoodProduct())
        XCTAssertEqual(product.code, "3017620422003")
        XCTAssertEqual(product.name, "Nutella")
        XCTAssertEqual(product.brand, "Ferrero", "first of the comma list")
        XCTAssertEqual(product.energyKcal100g, 539)
        XCTAssertEqual(product.protein100g, 6.3)
        XCTAssertEqual(product.carbs100g, 57.5)
        XCTAssertEqual(product.fat100g, 30.9)
        XCTAssertEqual(product.fiber100g, 3.5)
        XCTAssertEqual(try XCTUnwrap(product.sodiumMg100g), 42.8, accuracy: 0.001, "OFF grams → app mg")
        XCTAssertEqual(product.servingQuantityG, 15, "string serving_quantity decodes")
    }

    func testKJFallbackWhenKcalMissing() throws {
        let dto = try decodeProduct("""
        {
            "code": "123",
            "product_name": "Mystery bar",
            "nutriments": { "energy_100g": 2092 }
        }
        """)
        let product = try XCTUnwrap(dto.asFoodProduct())
        XCTAssertEqual(product.energyKcal100g, 2092 / 4.184, accuracy: 0.01)
        // Missing macros default to 0, missing optionals stay nil.
        XCTAssertEqual(product.protein100g, 0)
        XCTAssertNil(product.fiber100g)
        XCTAssertNil(product.sodiumMg100g)
    }

    func testStringNumbersDecode() throws {
        let dto = try decodeProduct("""
        {
            "code": "9",
            "product_name": "Stringy",
            "nutriments": { "energy-kcal_100g": "250", "proteins_100g": "12.5" }
        }
        """)
        let product = try XCTUnwrap(dto.asFoodProduct())
        XCTAssertEqual(product.energyKcal100g, 250)
        XCTAssertEqual(product.protein100g, 12.5)
    }

    func testUnusableRowsAreDropped() throws {
        // No energy in any form → nil.
        let noEnergy = try decodeProduct(
            #"{"code": "1", "product_name": "No numbers", "nutriments": {}}"#
        )
        XCTAssertNil(noEnergy.asFoodProduct())
        // No name → nil.
        let noName = try decodeProduct(
            #"{"code": "2", "nutriments": {"energy-kcal_100g": 100}}"#
        )
        XCTAssertNil(noName.asFoodProduct())
    }

    func testSearchEnvelopeDecodesBothShapes() throws {
        let hitJSON = #"{"hits": [{"code": "1", "product_name": "A", "nutriments": {"energy-kcal_100g": 50}}]}"#
        let hits = try JSONDecoder().decode(OFFSearchResponse.self, from: Data(hitJSON.utf8))
        XCTAssertEqual(hits.results.count, 1)

        let productsJSON = #"{"products": [{"code": "2", "product_name": "B", "nutriments": {"energy-kcal_100g": 60}}]}"#
        let products = try JSONDecoder().decode(OFFSearchResponse.self, from: Data(productsJSON.utf8))
        XCTAssertEqual(products.results.count, 1)
    }

    func testScalingMath() {
        XCTAssertEqual(NutritionMath.scaled(per100g: 539, grams: 15), 80.85, accuracy: 0.001)
        XCTAssertEqual(NutritionMath.scaled(per100g: 10, grams: 0), 0)
        XCTAssertEqual(NutritionMath.energyKcal(kcal: 100, kJ: 999), 100, "kcal preferred over kJ")
        XCTAssertNil(NutritionMath.energyKcal(kcal: nil, kJ: nil))
        XCTAssertEqual(try XCTUnwrap(NutritionMath.sodiumMg(fromGrams: 1.5)), 1500)
        XCTAssertNil(NutritionMath.sodiumMg(fromGrams: nil))
    }

    func testCacheRoundTripPreservesValues() {
        let product = FoodProduct(
            code: "42", name: "Oats", brand: "Brand",
            energyKcal100g: 379, protein100g: 13, carbs100g: 68, fat100g: 6.5,
            fiber100g: 10, sugars100g: 1, saturatedFat100g: 1.2, sodiumMg100g: 6,
            servingSizeText: "40 g", servingQuantityG: 40
        )
        XCTAssertEqual(product.asCachedProduct().asFoodProduct(), product)
    }
}
