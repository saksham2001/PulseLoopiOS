import SwiftUI
import SwiftData

/// Meal logging sheet. New entries open search-first: an Open Food Facts search box with
/// RECENT foods beneath it (local, zero network), a barcode scan button, and an
/// "Enter manually" fallback. Picking a product pushes `ServingPickerView` (per-100g →
/// per-serving math); saving writes a database-verified `MealEntry`. Editing an existing
/// entry goes straight to the manual form prefilled.
///
/// Rate-limit friendliness: search fires only after a 600 ms debounce on ≥2 characters,
/// in-flight requests are cancelled on change, and failures show a manual-entry fallback —
/// never an auto-retry.
struct MealLogSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The day the entry belongs to (startOfDay); the time picker supplies the clock time.
    let day: Date
    var presetMealType: MealType?
    var editingId: UUID?
    var client: FoodDatabaseClient = OpenFoodFactsClient()

    @State private var mealType: MealType = .snack
    @State private var showManualForm = false
    @State private var query = ""
    @State private var results: [FoodProduct] = []
    @State private var recents: [FoodProduct] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var showScanner = false
    @State private var scanLookupFailed = false
    @State private var loaded = false

    private struct PickedProduct: Hashable {
        let product: FoodProduct
        let viaBarcode: Bool
    }

    var body: some View {
        NavigationStack {
            // One meal-type picker for the whole sheet (search and manual paths share it —
            // it used to repeat inside the manual form).
            VStack(spacing: 0) {
                Picker("Meal", selection: $mealType) {
                    ForEach(MealType.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
                if editingId != nil || showManualForm {
                    ManualMealForm(day: day, mealType: $mealType, editingId: editingId) { dismiss() }
                } else {
                    searchScreen
                }
            }
            .background(PulseColors.background)
            .navigationTitle(editingId == nil ? "Log meal" : "Edit meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .navigationDestination(for: PickedProduct.self) { picked in
                ServingPickerView(
                    day: day,
                    mealType: mealType,
                    product: picked.product,
                    viaBarcode: picked.viaBarcode
                ) { dismiss() }
            }
        }
        .presentationDetents([.large])
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        mealType = presetMealType ?? .inferred()
        recents = NutritionRepository.recentProducts(context: modelContext).map { $0.asFoodProduct() }
    }

    // MARK: - Search-first screen

    private var searchScreen: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(PulseFont.subheadline)
                            .foregroundStyle(PulseColors.textMuted)
                        TextField("Search foods", text: $query)
                            .font(PulseFont.body)
                            .foregroundStyle(PulseColors.textPrimary)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                        if searching {
                            ProgressView().controlSize(.small)
                        } else if !query.isEmpty {
                            Button {
                                query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(PulseColors.textMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .pulseGlass(Capsule())

                    Button { showScanner = true } label: {
                        Image(systemName: "barcode.viewfinder")
                            .font(PulseFont.title3.weight(.regular))
                            .foregroundStyle(PulseColors.textPrimary)
                            .frame(width: 46, height: 46)
                            .pulseGlass(Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Scan barcode")
                }

                if let searchError {
                    inlineNotice(searchError)
                }
                if scanLookupFailed {
                    inlineNotice("Product not found for that barcode. Enter it manually instead.")
                }

                if query.trimmingCharacters(in: .whitespaces).count >= 2 {
                    resultsList
                } else {
                    recentsList
                }

                Spacer(minLength: 12)

                SecondaryButton(title: "Enter manually", systemImage: "pencil") {
                    showManualForm = true
                }
            }
            .padding(16)
        }
        .background(PulseColors.background)
        .scrollDismissesKeyboard(.immediately)
        .task(id: query) { await runSearch() }
        .sheet(isPresented: $showScanner) {
            BarcodeScannerSheet { code in
                showScanner = false
                Task { await lookupBarcode(code) }
            }
        }
    }

    private func inlineNotice(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(PulseFont.caption)
                .foregroundStyle(PulseColors.warning)
            Text(text)
                .font(PulseFont.caption.weight(.regular))
                .foregroundStyle(PulseColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.compact, style: .continuous))
    }

    @ViewBuilder
    private var resultsList: some View {
        if !results.isEmpty {
            productSection("RESULTS", products: results, viaBarcode: false)
        } else if !searching && searchError == nil {
            Text("No matches — try another name or enter it manually.")
                .font(PulseFont.caption.weight(.regular))
                .foregroundStyle(PulseColors.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var recentsList: some View {
        if !recents.isEmpty {
            productSection("RECENT", products: recents, viaBarcode: false)
        }
    }

    private func productSection(_ header: String, products: [FoodProduct], viaBarcode: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header)
                .font(PulseFont.caption2)
                .tracking(1.4)
                .foregroundStyle(PulseColors.textMuted)
            ForEach(products, id: \.code) { product in
                NavigationLink(value: PickedProduct(product: product, viaBarcode: viaBarcode)) {
                    FoodProductRow(product: product)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Network

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        searchError = nil
        guard trimmed.count >= 2 else {
            results = []
            searching = false
            return
        }
        // Debounce: wait out further typing; `.task(id:)` cancels this on every keystroke.
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            let found = try await client.search(query: trimmed, pageSize: 10)
            guard !Task.isCancelled else { return }
            results = found
            // Deliberately NOT cached here: caching every transient result did up to ~20
            // main-actor SwiftData saves per search (visible keyboard jank). The picked
            // product is cached on save in ServingPickerView instead.
        } catch is CancellationError {
            // superseded by newer input
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            searchError = (error as? OpenFoodFactsError) == .rateLimited
                ? "The food database is busy — try again in a minute, or enter the meal manually."
                : "Food search hit a snag. Try again, or enter the meal manually."
        }
    }

    private func lookupBarcode(_ code: String) async {
        scanLookupFailed = false
        searching = true
        defer { searching = false }
        // Cache-first: a rescanned product never hits the API again.
        if let cached = NutritionRepository.cachedProduct(code: code, context: modelContext) {
            results = [cached.asFoodProduct()]
            query = cached.name
            return
        }
        do {
            if let product = try await client.product(barcode: code) {
                NutritionRepository.upsertCachedProduct(product, context: modelContext)
                results = [product]
                query = product.name
            } else {
                scanLookupFailed = true
            }
        } catch {
            searchError = "Couldn't look up that barcode. Check your connection or enter the meal manually."
        }
    }
}

// MARK: - Product row

struct FoodProductRow: View {
    let product: FoodProduct

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal")
                .font(PulseFont.subheadline)
                .foregroundStyle(PulseColors.success)
                .frame(width: 36, height: 36)
                .background(PulseColors.success.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(product.name)
                    .font(PulseFont.subheadline.weight(.semibold))
                    .foregroundStyle(PulseColors.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(PulseFont.caption.weight(.regular).monospacedDigit())
                    .foregroundStyle(PulseColors.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(PulseFont.caption.weight(.semibold))
                .foregroundStyle(PulseColors.textMuted)
        }
        .padding(12)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.compact, style: .continuous))
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []
        if let brand = product.brand { parts.append(brand) }
        parts.append("\(Int(product.energyKcal100g.rounded())) kcal / 100 g")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Serving picker

/// Serving/quantity selection for a database product, with a live nutrition preview.
/// Grams are the base unit; when OFF provides a resolvable serving, a servings mode is
/// offered (and is the default).
struct ServingPickerView: View {
    @Environment(\.modelContext) private var modelContext

    let day: Date
    let mealType: MealType
    let product: FoodProduct
    let viaBarcode: Bool
    let onSaved: () -> Void

    private enum Mode: String, CaseIterable { case servings, grams }

    @State private var mode: Mode = .grams
    @State private var servings: Double = 1
    @State private var gramsText = "100"
    @State private var loaded = false

    private var servingGrams: Double? { product.servingQuantityG }

    /// Total grams represented by the current selection.
    private var totalGrams: Double {
        switch mode {
        case .servings: return (servingGrams ?? 100) * servings
        case .grams: return Double(gramsText) ?? 0
        }
    }

    private var canSave: Bool { totalGrams > 0 }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.name)
                        .font(PulseFont.title3)
                        .foregroundStyle(PulseColors.textPrimary)
                    HStack(spacing: 8) {
                        if let brand = product.brand {
                            Text(brand)
                                .font(PulseFont.caption.weight(.regular))
                                .foregroundStyle(PulseColors.textMuted)
                        }
                        ProvenanceBadge(source: viaBarcode ? .offBarcode : .offSearch)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DetailCard(title: "Amount", color: PulseColors.calories) {
                    VStack(spacing: 12) {
                        if servingGrams != nil {
                            Picker("Mode", selection: $mode) {
                                Text(servingLabel).tag(Mode.servings)
                                Text("Grams").tag(Mode.grams)
                            }
                            .pickerStyle(.segmented)
                        }
                        if mode == .servings {
                            Stepper(value: $servings, in: 0.25...20, step: 0.25) {
                                HStack {
                                    Text("Servings").font(PulseFont.body).foregroundStyle(PulseColors.textPrimary)
                                    Spacer()
                                    Text(servingsText)
                                        .font(PulseFont.subheadline.monospacedDigit())
                                        .foregroundStyle(PulseColors.textSecondary)
                                }
                            }
                            .tint(PulseColors.accent)
                        } else {
                            HStack {
                                Text("Grams").font(PulseFont.body).foregroundStyle(PulseColors.textPrimary)
                                Spacer()
                                TextField("100", text: $gramsText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .font(PulseFont.body.monospacedDigit())
                                    .foregroundStyle(PulseColors.textPrimary)
                                    .frame(width: 80)
                            }
                        }
                    }
                    .padding(.top, 12)
                }

                DetailCard(title: "Nutrition", color: PulseColors.calories) {
                    VStack(spacing: 8) {
                        previewRow("Calories", scaled(product.energyKcal100g), "kcal")
                        previewRow("Protein", scaled(product.protein100g), "g", color: PulseColors.macroProtein)
                        previewRow("Carbs", scaled(product.carbs100g), "g", color: PulseColors.macroCarbs)
                        previewRow("Fat", scaled(product.fat100g), "g", color: PulseColors.macroFat)
                        if let fiber = product.fiber100g {
                            previewRow("Fiber", scaled(fiber), "g")
                        }
                        if let sugars = product.sugars100g {
                            previewRow("Sugar", scaled(sugars), "g")
                        }
                    }
                    .padding(.top, 12)
                }

                PrimaryButton(title: "Add to \(mealType.label)", systemImage: "checkmark") { save() }
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)
            }
            .padding(16)
        }
        .background(PulseColors.background)
        .navigationTitle("Serving")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if servingGrams != nil { mode = .servings }
        }
    }

    private var servingLabel: String {
        if let text = product.servingSizeText, !text.isEmpty { return "Serving (\(text))" }
        if let grams = servingGrams { return "Serving (\(Int(grams)) g)" }
        return "Serving"
    }

    private var servingsText: String {
        let count = servings == servings.rounded() ? "\(Int(servings))" : String(format: "%.2g", servings)
        return "\(count) · \(Int(totalGrams.rounded())) g"
    }

    private func scaled(_ per100g: Double) -> Double {
        NutritionMath.scaled(per100g: per100g, grams: totalGrams)
    }

    private func previewRow(_ label: String, _ value: Double, _ unit: String, color: Color = PulseColors.textSecondary) -> some View {
        HStack {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(PulseFont.subheadline).foregroundStyle(PulseColors.textSecondary)
            }
            Spacer()
            Text("\(Int(value.rounded())) \(unit)")
                .font(PulseFont.subheadline.monospacedDigit())
                .foregroundStyle(PulseColors.textPrimary)
        }
    }

    private func save() {
        let now = Date()
        let clock = Calendar.current.dateComponents([.hour, .minute], from: now)
        let timestamp = Calendar.current.date(
            bySettingHour: Calendar.current.isDateInToday(day) ? (clock.hour ?? 12) : 12,
            minute: Calendar.current.isDateInToday(day) ? (clock.minute ?? 0) : 0,
            second: 0, of: day
        ) ?? day

        let quantity = mode == .servings ? servings : 1
        let perServingGrams = mode == .servings ? servingGrams : totalGrams
        let entry = MealEntry(
            timestamp: timestamp,
            name: product.brand.map { "\(product.name) (\($0))" } ?? product.name,
            mealType: mealType,
            calories: scaled(product.energyKcal100g),
            proteinG: scaled(product.protein100g),
            carbsG: scaled(product.carbs100g),
            fatG: scaled(product.fat100g),
            fiberG: product.fiber100g.map(scaled),
            sugarG: product.sugars100g.map(scaled),
            sodiumMg: product.sodiumMg100g.map(scaled),
            source: viaBarcode ? .offBarcode : .offSearch,
            offProductCode: product.code,
            servingDescription: mode == .servings ? (product.servingSizeText ?? servingGrams.map { "\(Int($0)) g" }) : "\(Int(totalGrams.rounded())) g",
            servingGrams: perServingGrams,
            quantity: quantity
        )
        // Cache-on-pick: only foods the user actually logs enter the recents cache
        // (search results are never cached — that write storm caused typing jank).
        let cached = NutritionRepository.upsertCachedProduct(product, context: modelContext)
        NutritionRepository.touchProduct(cached)
        NutritionRepository.insert(entry, context: modelContext)
        onSaved()
    }
}

// MARK: - Manual form

/// The manual entry / edit form (a stock `Form`). Blank optional nutrients stay nil
/// (unknown), never 0. Editing a database/AI entry's numbers flips `userEdited`.
struct ManualMealForm: View {
    @Environment(\.modelContext) private var modelContext

    let day: Date
    @Binding var mealType: MealType
    var editingId: UUID?
    let onSaved: () -> Void

    @State private var name = ""
    @State private var time = Date()
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var showMoreNutrients = false
    @State private var fiber = ""
    @State private var sugar = ""
    @State private var sodium = ""
    @State private var notes = ""
    @State private var loaded = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && Double(calories) != nil
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
            }
            Section("Nutrition") {
                numericField("Calories (kcal)", text: $calories)
                numericField("Protein (g)", text: $protein)
                numericField("Carbs (g)", text: $carbs)
                numericField("Fat (g)", text: $fat)
            }
            Section {
                if showMoreNutrients {
                    numericField("Fiber (g)", text: $fiber)
                    numericField("Sugar (g)", text: $sugar)
                    numericField("Sodium (mg)", text: $sodium)
                } else {
                    Button("More nutrients") { showMoreNutrients = true }
                }
            }
            Section("Notes") {
                TextField("Optional", text: $notes, axis: .vertical)
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
        }
        .onAppear(perform: load)
    }

    private func numericField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("—", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let editingId, let entry = NutritionRepository.entry(id: editingId, context: modelContext) {
            name = entry.name
            mealType = entry.mealType
            time = entry.timestamp
            calories = fieldText(entry.calories)
            protein = fieldText(entry.proteinG)
            carbs = fieldText(entry.carbsG)
            fat = fieldText(entry.fatG)
            fiber = entry.fiberG.map(fieldText) ?? ""
            sugar = entry.sugarG.map(fieldText) ?? ""
            sodium = entry.sodiumMg.map(fieldText) ?? ""
            notes = entry.notes ?? ""
            showMoreNutrients = entry.fiberG != nil || entry.sugarG != nil || entry.sodiumMg != nil
        } else if !Calendar.current.isDateInToday(day) {
            // Logging on a past day: default to midday rather than the current clock time.
            time = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        }
    }

    private func fieldText(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }

    private func save() {
        guard let kcal = Double(calories) else { return }
        let clock = Calendar.current.dateComponents([.hour, .minute], from: time)
        let timestamp = Calendar.current.date(
            bySettingHour: clock.hour ?? 12, minute: clock.minute ?? 0, second: 0, of: day
        ) ?? day
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        if let editingId, let entry = NutritionRepository.entry(id: editingId, context: modelContext) {
            let numbersChanged = entry.calories != kcal
                || entry.proteinG != (Double(protein) ?? 0)
                || entry.carbsG != (Double(carbs) ?? 0)
                || entry.fatG != (Double(fat) ?? 0)
            entry.name = trimmedName
            entry.mealType = mealType
            entry.setTimestamp(timestamp)
            entry.calories = kcal
            entry.proteinG = Double(protein) ?? 0
            entry.carbsG = Double(carbs) ?? 0
            entry.fatG = Double(fat) ?? 0
            entry.fiberG = Double(fiber)
            entry.sugarG = Double(sugar)
            entry.sodiumMg = Double(sodium)
            entry.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
            if numbersChanged && entry.source != .manual { entry.userEdited = true }
            NutritionRepository.update(entry, context: modelContext)
        } else {
            let entry = MealEntry(
                timestamp: timestamp,
                name: trimmedName,
                mealType: mealType,
                calories: kcal,
                proteinG: Double(protein) ?? 0,
                carbsG: Double(carbs) ?? 0,
                fatG: Double(fat) ?? 0,
                fiberG: Double(fiber),
                sugarG: Double(sugar),
                sodiumMg: Double(sodium),
                source: .manual,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes
            )
            NutritionRepository.insert(entry, context: modelContext)
        }
        onSaved()
    }
}
