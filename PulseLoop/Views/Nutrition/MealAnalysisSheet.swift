import SwiftUI
import PhotosUI
import SwiftData

/// In-context AI meal analysis from the Nutrition page: snap/pick a photo or describe the
/// meal in text → one single-shot structured LLM call (user's configured provider, no tools)
/// → an *editable* prefilled estimate the user reviews before saving. Keeps the user on the
/// nutrition page; the coach chat remains the conversational alternative.
///
/// Only reachable when the coach + nutrition photo analysis gates allow it (callers gate the
/// entry buttons); photos go to the provider only when the user explicitly analyzes here.
struct MealAnalysisSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let day: Date
    var presetMealType: MealType?
    /// Start in camera mode (vs describe mode).
    var startWithCamera = false

    private enum Phase { case input, analyzing, review, failed(String) }

    @State private var phase: Phase = .input
    @State private var mealType: MealType = .snack
    @State private var describeText = ""
    @State private var image: UIImage?
    @State private var showCamera = false
    @State private var photosItem: PhotosPickerItem?
    // Review-phase editable fields (prefilled from the estimate).
    @State private var name = ""
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var assumptions = ""
    @State private var confidence = "medium"
    @State private var loaded = false

    private var canAnalyze: Bool {
        image != nil || describeText.trimmingCharacters(in: .whitespaces).count >= 3
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && Double(calories) != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Meal", selection: $mealType) {
                        ForEach(MealType.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch phase {
                    case .input:
                        inputPhase
                    case .analyzing:
                        analyzingPhase
                    case .review:
                        reviewPhase
                    case .failed(let message):
                        failedPhase(message)
                    }
                }
                .padding(16)
            }
            .background(PulseColors.background)
            .navigationTitle("AI meal log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            guard !loaded else { return }
            loaded = true
            mealType = presetMealType ?? .inferred()
            if startWithCamera { showCamera = true }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image = $0 }
                .ignoresSafeArea()
        }
        .onChange(of: photosItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let picked = UIImage(data: data) {
                    image = picked
                }
                photosItem = nil
            }
        }
    }

    // MARK: - Phases

    private var inputPhase: some View {
        VStack(spacing: 14) {
            if let image {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Button { self.image = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(PulseFont.title3)
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(8)
                        }
                    }
            } else {
                HStack(spacing: 12) {
                    photoButton("camera", "Camera") { showCamera = true }
                    PhotosPicker(selection: $photosItem, matching: .images) {
                        photoLabel("photo.on.rectangle", "Library")
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(image == nil ? "OR DESCRIBE IT" : "ADD DETAIL (OPTIONAL)")
                    .font(PulseFont.caption2)
                    .tracking(1.4)
                    .foregroundStyle(PulseColors.textMuted)
                TextField("e.g. two eggs, toast with butter, black coffee", text: $describeText, axis: .vertical)
                    .font(PulseFont.body)
                    .foregroundStyle(PulseColors.textPrimary)
                    .lineLimit(3...6)
                    .padding(12)
                    .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.compact, style: .continuous))
            }

            PrimaryButton(title: "Analyze", systemImage: "sparkles") {
                Task { await analyze() }
            }
            .disabled(!canAnalyze)
            .opacity(canAnalyze ? 1 : 0.5)

            Text("Sent to your configured AI provider only when you tap Analyze. Estimates are labeled and editable.")
                .font(PulseFont.caption.weight(.regular))
                .foregroundStyle(PulseColors.textMuted)
                .multilineTextAlignment(.center)
        }
    }

    private var analyzingPhase: some View {
        VStack(spacing: 12) {
            if let image {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
                    .opacity(0.7)
            }
            ProgressView()
            Text("Estimating nutrition…")
                .font(PulseFont.subheadline)
                .foregroundStyle(PulseColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var reviewPhase: some View {
        VStack(spacing: 14) {
            HStack {
                ProvenanceBadge(source: .llmEstimate)
                if confidence != "high" {
                    Text("\(confidence.capitalized) confidence")
                        .font(PulseFont.caption.weight(.regular))
                        .foregroundStyle(PulseColors.textMuted)
                }
                Spacer()
            }
            if !assumptions.isEmpty {
                Text(assumptions)
                    .font(PulseFont.caption.weight(.regular))
                    .foregroundStyle(PulseColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.compact, style: .continuous))
            }
            DetailCard(title: "Review & adjust", color: PulseColors.calories) {
                VStack(spacing: 10) {
                    editRow("Name") {
                        TextField("Meal", text: $name).multilineTextAlignment(.trailing)
                    }
                    editRow("Calories (kcal)") { numericField($calories) }
                    editRow("Protein (g)") { numericField($protein) }
                    editRow("Carbs (g)") { numericField($carbs) }
                    editRow("Fat (g)") { numericField($fat) }
                }
                .padding(.top, 12)
            }
            PrimaryButton(title: "Log meal", systemImage: "checkmark") { save() }
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
            Button("Re-analyze") { phase = .input }
                .font(PulseFont.subheadline)
                .foregroundStyle(PulseColors.accent)
        }
    }

    private func failedPhase(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(PulseFont.title2)
                .foregroundStyle(PulseColors.warning)
            Text(message)
                .font(PulseFont.subheadline.weight(.regular))
                .foregroundStyle(PulseColors.textSecondary)
                .multilineTextAlignment(.center)
            SecondaryButton(title: "Try again", systemImage: "arrow.clockwise") { phase = .input }
        }
        .padding(.vertical, 16)
    }

    // MARK: - Small helpers

    private func photoButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { photoLabel(symbol, label) }.buttonStyle(.plain)
    }

    private func photoLabel(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(PulseFont.title2.weight(.regular))
                .foregroundStyle(PulseColors.calories)
            Text(label)
                .font(PulseFont.caption)
                .foregroundStyle(PulseColors.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.compact, style: .continuous))
        .contentShape(Rectangle())
    }

    private func editRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label).font(PulseFont.subheadline).foregroundStyle(PulseColors.textSecondary)
            Spacer()
            content()
                .font(PulseFont.body.monospacedDigit())
                .foregroundStyle(PulseColors.textPrimary)
                .frame(maxWidth: 160)
        }
    }

    private func numericField(_ text: Binding<String>) -> some View {
        TextField("—", text: text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
    }

    // MARK: - Analysis + save

    private func analyze() async {
        phase = .analyzing
        let result = await MealEstimator.estimate(
            description: describeText.trimmingCharacters(in: .whitespacesAndNewlines),
            image: image
        )
        switch result {
        case .success(let estimate):
            name = estimate.name
            calories = "\(Int(estimate.calories.rounded()))"
            protein = "\(Int(estimate.proteinG.rounded()))"
            carbs = "\(Int(estimate.carbsG.rounded()))"
            fat = "\(Int(estimate.fatG.rounded()))"
            assumptions = estimate.assumptions
            confidence = estimate.confidence
            phase = .review
        case .failure(let error):
            phase = .failed(error.message)
        }
    }

    private func save() {
        guard let kcal = Double(calories) else { return }
        let now = Date()
        let isToday = Calendar.current.isDateInToday(day)
        let clock = Calendar.current.dateComponents([.hour, .minute], from: now)
        let timestamp = Calendar.current.date(
            bySettingHour: isToday ? (clock.hour ?? 12) : 12,
            minute: isToday ? (clock.minute ?? 0) : 0,
            second: 0, of: day
        ) ?? day
        // Keep the photo with the entry (stored via the coach attachment store; bytes on device).
        let photoRef = image.flatMap { CoachAttachmentStore.save($0) }
        let entry = MealEntry(
            timestamp: timestamp,
            name: name.trimmingCharacters(in: .whitespaces),
            mealType: mealType,
            calories: kcal,
            proteinG: Double(protein) ?? 0,
            carbsG: Double(carbs) ?? 0,
            fatG: Double(fat) ?? 0,
            source: .llmEstimate,
            confidence: confidence == "high" ? .known : (confidence == "medium" ? .partial : .unknown),
            photoRefJSON: photoRef.flatMap { CoachAttachmentRef.encode([$0]) },
            notes: assumptions.isEmpty ? nil : assumptions
        )
        NutritionRepository.insert(entry, context: modelContext)
        dismiss()
    }
}

// MARK: - Estimator

/// One-shot structured meal estimation against the user's configured provider — the
/// `CoachNotificationGenerator` pattern: system + user → strict JSON, no tools.
@MainActor
enum MealEstimator {
    struct Estimate: Decodable {
        let name: String
        let calories: Double
        let proteinG: Double
        let carbsG: Double
        let fatG: Double
        let assumptions: String
        let confidence: String

        enum CodingKeys: String, CodingKey {
            case name, calories, proteinG = "protein_g", carbsG = "carbs_g", fatG = "fat_g"
            case assumptions, confidence
        }
    }

    struct EstimateError: Error { let message: String }

    private static let systemPrompt = "You are a nutrition estimator. Given a meal description and/or photo, "
        + "identify the food and estimate total calories and macros for the portion shown or described. "
        + "Be realistic about portion sizes; state your assumptions (portion sizes, preparation) briefly. "
        + "Use confidence \"high\" only for clearly identifiable, standard portions. "
        + "Return only JSON matching the schema."

    private static var textFormat: [String: Any] {
        [
            "type": "json_schema", "name": "meal_estimate", "strict": true,
            "schema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Short display name for the meal"],
                    "calories": ["type": "number"],
                    "protein_g": ["type": "number"],
                    "carbs_g": ["type": "number"],
                    "fat_g": ["type": "number"],
                    "assumptions": ["type": "string", "description": "Portion/preparation assumptions, one short sentence, or empty string"],
                    "confidence": ["type": "string", "enum": ["low", "medium", "high"]],
                ],
                "required": ["name", "calories", "protein_g", "carbs_g", "fat_g", "assumptions", "confidence"],
                "additionalProperties": false,
            ],
        ]
    }

    static func estimate(description: String, image: UIImage?) async -> Result<Estimate, EstimateError> {
        let settings = CoachSettingsStore.shared.settings
        let (apiKey, client) = CoachClientResolver.resolve(
            settings: settings,
            openAIKeyStore: OpenAIKeychainStore(),
            geminiKeyStore: GeminiKeychainStore(),
            openRouterKeyStore: OpenRouterKeychainStore(),
            minimaxKeyStore: MiniMaxKeychainStore()
        )
        let flags = CoachFeatureFlags(
            settings: settings, hasAPIKey: apiKey != nil,
            nutritionPrefs: NutritionPrefsStore.shared.prefs)
        guard flags.coachEnabled else {
            return .failure(EstimateError(message: "AI analysis needs the coach enabled with a cloud provider (Settings → AI Coach). You can still search the database or enter the meal manually."))
        }

        var images: [CoachImagePayload] = []
        if let image {
            // Reuse the attachment pipeline's downscale/encode, then discard the temp file.
            if let ref = CoachAttachmentStore.save(image) {
                if let payload = CoachAttachmentStore.payload(for: ref) { images.append(payload) }
                CoachAttachmentStore.delete(ref)
            }
            guard !images.isEmpty else {
                return .failure(EstimateError(message: "Couldn't process that photo. Try again or describe the meal."))
            }
        }

        let prompt = description.isEmpty ? "Estimate the nutrition of the meal in the photo." : description
        let input: [[String: Any]] = [
            OpenAIRequestBuilder.message(role: "system", content: systemPrompt),
            OpenAIRequestBuilder.message(role: "user", content: prompt, images: images),
        ]
        do {
            let body = try OpenAIRequestBuilder.data(
                model: flags.model, input: input, tools: [],
                textFormat: textFormat, previousResponseId: nil,
                reasoningEffort: flags.settings.reasoningEffort
            )
            let response = try await client.send(requestBody: body)
            guard let estimate = decode(response.outputText) else {
                return .failure(EstimateError(message: "The AI didn't return a usable estimate. Try again or enter the meal manually."))
            }
            return .success(estimate)
        } catch {
            return .failure(EstimateError(message: "Analysis failed: \(error.localizedDescription)"))
        }
    }

    private static func decode(_ text: String) -> Estimate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8), let e = try? JSONDecoder().decode(Estimate.self, from: data) {
            return e
        }
        // Tolerate prose/fences around the object (same as CoachNotification.decode).
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end,
              let data = String(trimmed[start...end]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Estimate.self, from: data)
    }
}
