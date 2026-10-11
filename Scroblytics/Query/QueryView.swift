import SwiftUI
import SwiftData

/// The "Query" page: the condition builder (left) driving the generic results
/// table (right). The builder reads ONLY the field registry — every field,
/// operator, parameter and column it offers comes from there.
struct QueryView: View {
    let modelContainer: ModelContainer
    let settings: ChartDateSettings
    let isActive: Bool
    private let isEmbedded: Bool
    @Binding private var askRequest: AskQueryRequest?

    @Environment(\.modelContext) private var modelContext
    @Environment(FlaggedTracksStore.self) private var flaggedTracksStore
    @Environment(PopularityStore.self) private var popularityStore
    @Environment(TagStore.self) private var tagStore
    @Query(sort: \SavedConditionSet.name) private var savedSets: [SavedConditionSet]

    @State private var model: QueryBuilderModel
    @State private var hasLoaded = false
    @State private var showingSaveAs = false
    @State private var saveName = ""
    /// From the request that last loaded a spec here (e.g. a Tool's own name) — defaults Save As
    /// when nothing more specific (an already-loaded saved set's own name) applies.
    @State private var suggestedName: String?
    @State private var setToDelete: SavedConditionSet?
    @State private var persistenceError: String?
    @State private var showsSettings = true
    @State private var showingAsk = false
    @State private var tagSheet: TagSheetPayload?
    @State private var needsScrobbleReload = false
    @State private var ask = AskModel()
    @State private var navigation: DetailNavigationCoordinator
    @AppStorage("query.settingsPanelWidth") private var settingsPanelWidth = 400.0

    init(
        modelContainer: ModelContainer,
        settings: ChartDateSettings,
        isActive: Bool,
        askRequest: Binding<AskQueryRequest?>,
        navigation: DetailNavigationCoordinator? = nil
    ) {
        self.modelContainer = modelContainer
        self.settings = settings
        self.isActive = isActive
        self.isEmbedded = navigation != nil
        _askRequest = askRequest
        _model = State(initialValue: QueryBuilderModel(container: modelContainer))
        _navigation = State(initialValue: navigation ?? DetailNavigationCoordinator(origin: .query))
    }

    private var loadedSet: SavedConditionSet? { savedSets.first { $0.id == model.loadedSetID } }

    private var queryParentBreadcrumb: some View {
        let predecessor = navigation.predecessor
        let source = predecessor?.source ?? "Tools"
        let help = predecessor.map { "Back to \($0.detail)" } ?? "Back to Tools"

        return HStack(spacing: 8) {
            Button(action: returnToQueryParent) {
                Image(systemName: "chevron.left")
                    .font(AppTypography.navigationIcon)
                    .frame(width: 34, height: 34)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().stroke(.separator.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(help)

            Button(source, action: returnToQueryParent)
                .buttonStyle(.plain)
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)

            Image(systemName: "chevron.right")
                .font(AppTypography.denseBadge)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text("Query")
                .font(AppTypography.compactTitle)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    private func returnToQueryParent() {
        if navigation.predecessor != nil {
            navigation.returnToPredecessor()
        } else {
            navigation.path = NavigationPath()
        }
    }

    private var queryPage: some View {
        VStack(spacing: 0) {
            if isEmbedded || navigation.predecessor != nil {
                queryParentBreadcrumb
            }
            pageHeader
            Divider()
            GeometryReader { proxy in
                if showsSettings {
                    if proxy.size.width < 760 {
                        builderPanel
                    } else {
                        QueryResizableSplitView(sidebarWidth: $settingsPanelWidth) {
                            builderPanel
                        } detail: {
                            resultsPane
                        }
                    }
                } else {
                    resultsPane
                }
            }
        }
        .navigationTitle("Query")
        .onAppear { navigation.setOrigin(.query) }
        .navigationDestination(for: ArtistIdentity.self) {
            ArtistDetailView(identity: $0, settings: settings, navigation: navigation)
        }
        .navigationDestination(for: AlbumIdentity.self) {
            AlbumDetailView(identity: $0, settings: settings, navigation: navigation)
        }
        .navigationDestination(for: TrackIdentity.self) {
            TrackDetailView(identity: $0, settings: settings, navigation: navigation)
        }
    }

    var body: some View {
        Group {
            if isEmbedded {
                queryPage
            } else {
                NavigationStack(path: Binding(
                    get: { navigation.path },
                    set: { navigation.path = $0 }
                )) {
                    queryPage
                }
            }
        }
        .task(id: isActive) {
            guard isActive else { return }
            // Coming back to the tab: pick up loves/unloves, lookups and syncs that landed elsewhere.
            if hasLoaded {
                if needsScrobbleReload {
                    needsScrobbleReload = false
                    await model.loadScrobbles()
                } else {
                    model.refreshSnapshots()
                }
                return
            }
            hasLoaded = true
            model.attach(popularity: popularityStore)
            model.attach(tags: tagStore)
            await model.loadScrobbles()
        }
        // Warmer progress arrives every few seconds for an hour after a first sync; while this tab
        // isn't showing, none of it needs acting on — it's picked up on the way back in.
        .onReceive(NotificationCenter.default.publisher(for: DurationEngine.progressNotification)) { _ in
            if isActive { model.refreshSnapshots() }
        }
        .onReceive(NotificationCenter.default.publisher(for: BPMEngine.progressNotification)) { _ in
            if isActive { model.refreshSnapshots() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReleaseDateEngine.progressNotification)) { _ in
            if isActive { model.refreshSnapshots() }
        }
        .onReceive(NotificationCenter.default.publisher(for: EntityTagsEngine.progressNotification)) { _ in
            if isActive { model.refreshSnapshots() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            guard hasLoaded else { return }
            if isActive { Task { await model.loadScrobbles() } } else { needsScrobbleReload = true }
        }
        .onChange(of: flaggedTracksStore.revision) {
            if isActive { model.refreshSnapshots() }
        }
        .onChange(of: askRequest?.id, initial: true) {
            consumeAskRequest()
        }
        .alert("Save condition set", isPresented: $showingSaveAs) {
            TextField("Name", text: $saveName)
            Button("Save") { save(as: saveName, updating: nil) }
                .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the conditions, sort, scope and columns as they are now.")
        }
        .alert("Delete “\(setToDelete?.name ?? "")”?", isPresented: Binding(get: { setToDelete != nil }, set: { if !$0 { setToDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let setToDelete { run { try model.delete(setToDelete, context: modelContext) } }
                setToDelete = nil
            }
            Button("Cancel", role: .cancel) { setToDelete = nil }
        }
        .alert("Couldn’t complete that", isPresented: Binding(get: { persistenceError != nil }, set: { if !$0 { persistenceError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(persistenceError ?? "") }
    }

    /// Hands an interpreted Ask query to the builder — from here it is an ordinary query set: it runs,
    /// shows in the results table, can be edited in the builder and saved like any other.
    private func loadAsked(_ spec: QuerySpec) {
        model.loadedSetID = nil
        model.spec = spec
    }

    private func save(as name: String, updating existing: SavedConditionSet?) {
        run { try model.save(as: name.trimmingCharacters(in: .whitespaces), context: modelContext, updating: existing) }
    }

    private func run(_ body: () throws -> Void) {
        do { try body() } catch { persistenceError = "\(error)" }
    }

    // MARK: - Builder

    private var pageHeader: some View {
        PageSettingsHeader("Query") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        showsSettings.toggle()
                    } label: {
                        Label(
                            showsSettings ? "Hide Query Settings" : "Show Query Settings",
                            systemImage: "sidebar.left"
                        )
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(showsSettings ? "Hide Query Settings" : "Show Query Settings")

                    Picker("Find", selection: Binding(get: { model.spec.target }, set: { model.setTarget($0) })) {
                        Text("Artists").tag(QueryTarget.artist)
                        Text("Albums").tag(QueryTarget.album)
                        Text("Tracks").tag(QueryTarget.track)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(minWidth: 180, maxWidth: 320)
                    .help("What the query finds: artists, albums or tracks. Changing it keeps the conditions that still apply.")

                    Spacer(minLength: 8)
                    askButton
                    setsMenu
                }
                if let loadedSet {
                    Text("Editing “\(loadedSet.name)”")
                        .font(AppTypography.compactMetadata)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private var askButton: some View {
        Button {
            showingAsk = true
        } label: {
            Label("Ask", systemImage: "sparkles")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Describe the artists, albums, or tracks you want to find using natural language.")
        .popover(isPresented: $showingAsk, arrowEdge: .bottom) {
            AskPopoverContent(
                ask: ask,
                registry: model.registry,
                context: askContext,
                onRun: { applyAsked($0, showSettings: false) },
                onEdit: { applyAsked($0, showSettings: true) },
                onSave: saveAsked
            )
        }
    }

    private func askContext() -> AskContext {
        AskContext(
            tags: model.tagVocabulary.prefix(AskContext.tagLimit).map(\.tag),
            knownTags: Set(model.tagVocabulary.map(\.tag)),
            knownArtists: model.knownArtists,
            earliest: model.oldestScrobbleDate,
            container: modelContainer
        )
    }

    private func applyAsked(_ spec: QuerySpec, showSettings: Bool) {
        loadAsked(spec)
        if showSettings { showsSettings = true }
        showingAsk = false
    }

    private func saveAsked(_ spec: QuerySpec) {
        loadAsked(spec)
        showingAsk = false
        saveName = suggestedName ?? ""
        showingSaveAs = true
    }

    private func consumeAskRequest() {
        guard let request = askRequest else { return }
        askRequest = nil
        navigation.goToOrigin()
        suggestedName = request.suggestedName
        if let cameFrom = request.cameFrom { navigation.predecessor = cameFrom }
        switch request.action {
        case .run:
            applyAsked(request.spec, showSettings: false)
        case .edit:
            applyAsked(request.spec, showSettings: true)
        case .save:
            saveAsked(request.spec)
        }
    }

    private var builderPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let notice = model.notice {
                    HStack(alignment: .top) {
                        Image(systemName: "info.circle")
                        Text(notice).font(AppTypography.compactMetadata)
                        Spacer()
                        Button { model.dismissNotice() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    Spacer()
                    Button("Clear all", systemImage: "trash", role: .destructive) {
                        clearAllQuerySettings()
                    }
                    .buttonStyle(.borderless)
                    .disabled(!hasQuerySettings)
                    .help("Remove every condition, sort, scope, limit, and column from this query.")
                }
                conditionsSection
                sortSection
                scopeSection
                columnsSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hasQuerySettings: Bool {
        !model.spec.groups.isEmpty || !model.spec.sorts.isEmpty || model.spec.limit != nil
            || model.spec.period != nil || model.spec.playFilter != nil || model.spec.asOf != nil || !model.spec.columns.isEmpty
            || model.spec.groupLimit != nil
    }

    private func clearAllQuerySettings() {
        model.spec.groups.removeAll()
        model.spec.sorts.removeAll()
        model.spec.limit = nil
        model.spec.period = nil
        model.spec.playFilter = nil
        model.spec.asOf = nil
        model.spec.columns.removeAll()
        model.spec.groupLimit = nil
    }

    private var setsMenu: some View {
        Menu {
            Button("New query") { model.newQuery(); suggestedName = nil }
            Divider()
            Button("Save") {
                if let loadedSet { save(as: loadedSet.name, updating: loadedSet) } else { saveName = suggestedName ?? ""; showingSaveAs = true }
            }
            Button("Save as…") { saveName = loadedSet?.name ?? suggestedName ?? ""; showingSaveAs = true }
            if !savedSets.isEmpty {
                Divider()
                Section("Open") { ForEach(savedSets) { saved in Button(saved.name) { model.load(saved) } } }
                Menu("Delete") { ForEach(savedSets) { saved in Button(saved.name, role: .destructive) { setToDelete = saved } } }
            }
            Divider()
            Section("Templates") {
                Button("Fading Favorites (current Overview range)") {
                    let presets = DateRangePresets.build(oldestScrobbleDate: model.oldestScrobbleDate)
                    let range = (presets.first { $0.id == settings.selectedRangeId } ?? presets[0]).range()
                    model.loadedSetID = nil
                    model.spec = model.fadingFavoritesSpec(for: range)
                }
                Button("Closest to next milestone (Overview card)") {
                    model.loadedSetID = nil
                    model.spec = model.upcomingMilestonesSpec(target: model.spec.target)
                }
                Button("Climbing (Overview card)") {
                    model.loadedSetID = nil
                    model.spec = model.climbingSpec()
                }
                Menu("Time Machine") {
                    ForEach([QueryTimeMachineTemplates.Comparison.weekVsLastYear, .monthVsLastYear], id: \.title) { comparison in
                        Section(comparison.title) {
                            ForEach(QueryTimeMachineTemplates.Scenario.allCases, id: \.self) { scenario in
                                Button(scenario.title) {
                                    model.loadedSetID = nil
                                    model.spec = QueryTimeMachineTemplates.spec(scenario, target: model.spec.target, comparison)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Sets", systemImage: "square.stack")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Save this query, open a saved one, or start from a template (Fading Favorites, Climbing, Time Machine…).")
    }

    // Conditions

    private var conditionsSection: some View {
        QueryConditionsEditor(
            groups: Binding(get: { model.spec.groups }, set: { model.spec.groups = $0 }),
            registry: model.registry, target: model.spec.target,
            tagVocabulary: model.tagVocabulary, asOf: model.spec.asOf ?? Date()
        )
    }

    // Sort

    private func sortHelp(_ sort: QuerySort) -> String {
        switch sort.key {
        case .shuffle: "Rows are in a random order."
        case .field(let ref): (try? model.registry.field(ref.id))?.help ?? ""
        }
    }

    private var sortSection: some View {
        DisclosureGroup("Sort (\(model.spec.sorts.count))") {
            VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(model.spec.sorts.indices), id: \.self) { i in
                // Rows can be evaluated once more with a stale index right after a removal.
                if let sort = model.spec.sorts[safe: i] {
                    VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(sortTitle(sort)).font(AppTypography.metadata).help(sortHelp(sort))
                        Spacer()
                        if model.spec.sorts.count > 1 {
                            Button { moveSort(from: i, to: i - 1) } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless)
                            .disabled(i == 0)
                            .help("Move this sort earlier")

                            Button { moveSort(from: i, to: i + 1) } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(i == model.spec.sorts.count - 1)
                            .help("Move this sort later")
                        }
                        if case .field(let ref) = sort.key, (try? model.registry.field(ref.id))?.supportsScope == true {
                            QueryScopeButton(scope: Binding(
                                get: { if case .field(let r)? = model.spec.sorts[safe: i]?.key { r.scope } else { nil } },
                                set: { new in
                                    guard model.spec.sorts.indices.contains(i), case .field(var r) = model.spec.sorts[i].key else { return }
                                    r.scope = new
                                    model.spec.sorts[i].key = .field(r)
                                }
                            ), asOf: model.spec.asOf ?? Date(), compact: true)
                        }
                        if case .field = sort.key {
                            Button {
                                guard model.spec.sorts.indices.contains(i) else { return }
                                model.spec.sorts[i].direction = sort.direction == .ascending ? .descending : .ascending
                            } label: {
                                Image(systemName: sort.direction == .ascending ? "arrow.up" : "arrow.down")
                            }
                            .buttonStyle(.borderless)
                            .help(sort.direction == .ascending ? "Ascending" : "Descending")
                        }
                        Button {
                            guard model.spec.sorts.indices.contains(i) else { return }
                            model.spec.sorts.remove(at: i)
                        } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            .help("Remove this sort")
                    }
                    // The field's settings (window in days, how ties break…) on their own line, so the row stays inside the panel.
                    if case .field(let ref) = sort.key, let field = try? model.registry.field(ref.id), !field.parameters.isEmpty {
                        AskFlowLayout(spacing: 8) {
                            ForEach(field.parameters, id: \.id) { parameter in
                                QueryParameterMenu(parameter: parameter, selection: Binding(
                                    get: { if case .field(let r)? = model.spec.sorts[safe: i]?.key { r.parameters[parameter.id] ?? parameter.defaultValue } else { parameter.defaultValue } },
                                    set: { new in
                                        guard model.spec.sorts.indices.contains(i), case .field(var r) = model.spec.sorts[i].key else { return }
                                        r.parameters[parameter.id] = new
                                        model.spec.sorts[i].key = .field(r)
                                    }
                                ), fieldHelp: field.help)
                            }
                        }
                    }
                    }
                }
            }
            Menu {
                Button("Shuffle (random)") { model.spec.sorts.append(QuerySort(key: .shuffle(seed: nil))) }
                    .help("Put the matching rows in a random order.")
                Divider()
                ForEach(QueryFieldGroup.allCases, id: \.self) { group in
                    let fields = model.registry.fields(for: model.spec.target, in: group).filter { $0.type != .tags }
                    if !fields.isEmpty {
                        Section(group.title) {
                            ForEach(fields, id: \.id) { field in
                                Button(field.name) {
                                    model.spec.sorts.append(QuerySort(key: .field(QueryFieldRef.starting(field)), direction: .descending))
                                }
                                .help(field.help)
                            }
                        }
                    }
                }
            } label: { Label("Add sort", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize().font(AppTypography.metadata)
                .help("Order the results by a field, or shuffle them. Later sorts break ties in earlier ones.")
            Text("Rows with no value always sort last.").font(AppTypography.supportingDense).foregroundStyle(.tertiary)
            }
            .padding(.top, 6)
        }
        .font(AppTypography.sectionTitle)
    }

    private func moveSort(from source: Int, to destination: Int) {
        guard model.spec.sorts.indices.contains(source),
              model.spec.sorts.indices.contains(destination) else { return }
        model.spec.sorts.swapAt(source, destination)
    }

    private func sortTitle(_ sort: QuerySort) -> String {
        switch sort.key {
        case .shuffle: "Shuffle (random)"
        case .field(let ref):
            (try? model.registry.resolve(ref, target: model.spec.target).title) ?? "Unknown field “\(ref.id)”"
        }
    }

    // Scope

    private var scopeSettingCount: Int {
        [model.spec.limit != nil, model.spec.period != nil, model.spec.playFilter != nil, model.spec.asOf != nil,
         model.spec.groupLimit?.perArtist != nil, model.spec.groupLimit?.perAlbum != nil,
         model.spec.groupLimit?.perReleaseYear != nil]
            .count(where: { $0 })
    }

    /// Changes one cap in place, so editing it can never drop another one; no caps left means no `groupLimit`.
    private func setCap(_ keyPath: WritableKeyPath<QueryGroupLimit, Int?>, to value: Int?) {
        var caps = model.spec.groupLimit ?? QueryGroupLimit()
        caps[keyPath: keyPath] = value
        model.spec.groupLimit = caps.isEmpty ? nil : caps
    }

    private func capBinding(_ keyPath: WritableKeyPath<QueryGroupLimit, Int?>) -> Binding<Int> {
        Binding(
            get: { model.spec.groupLimit?[keyPath: keyPath] ?? 1 },
            set: { setCap(keyPath, to: min(max(1, $0), 20)) }
        )
    }

    private var perArtistLimit: Binding<Int> { capBinding(\.perArtist) }
    private var perAlbumLimit: Binding<Int> { capBinding(\.perAlbum) }
    private var perReleaseYearLimit: Binding<Int> { capBinding(\.perReleaseYear) }

    private var resultLimit: Binding<Int> {
        Binding(
            get: { model.spec.limit ?? 100 },
            set: { model.spec.limit = min(max(1, $0), 100_000) }
        )
    }

    private func incrementResultLimit() {
        let current = model.spec.limit ?? 100
        let next = current < 10 ? 10 : ((current / 10) + 1) * 10
        model.spec.limit = min(next, 100_000)
    }

    private func decrementResultLimit() {
        let current = model.spec.limit ?? 100
        guard current > 10 else {
            model.spec.limit = 1
            return
        }
        let previous = current.isMultiple(of: 10) ? current - 10 : (current / 10) * 10
        model.spec.limit = max(previous, 1)
    }

    private func intBinding(_ b: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(b.wrappedValue) }, set: { b.wrappedValue = Int($0.rounded()) })
    }

    private var scopeSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Limit results", isOn: Binding(get: { model.spec.limit != nil }, set: { model.spec.limit = $0 ? 100 : nil }))
                    .help("Keep only the first N rows after sorting — “top 25”, or one random song with a shuffle.")
                if model.spec.limit != nil {
                    Stepper(onIncrement: incrementResultLimit, onDecrement: decrementResultLimit) {
                        HStack {
                            Text("Top")
                            NumberEntryField(title: "Result limit", value: intBinding(resultLimit))
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .help("Enter the maximum number of sorted results to show, from 1 to 100,000.")
                        }
                        .font(AppTypography.metadata)
                    }
                    .help("How many rows to keep.")
                }
                if model.spec.target != .artist {
                    Toggle("At most N per artist", isOn: Binding(
                        get: { model.spec.groupLimit?.perArtist != nil },
                        set: { setCap(\.perArtist, to: $0 ? 1 : nil) }
                    ))
                    .help("Keep only the top few results per artist, so one artist can't fill the whole list — “top 10 songs, 1 per artist.”")
                    if model.spec.groupLimit?.perArtist != nil {
                        Stepper(value: perArtistLimit, in: 1...20) {
                            HStack {
                                Text("At most")
                                NumberEntryField(title: "Per artist", value: intBinding(perArtistLimit))
                                    .multilineTextAlignment(.trailing).frame(width: 50)
                                Text("per artist")
                            }
                            .font(AppTypography.metadata)
                        }
                    }
                }
                if model.spec.target == .track {
                    Toggle("At most N per album", isOn: Binding(
                        get: { model.spec.groupLimit?.perAlbum != nil },
                        set: { setCap(\.perAlbum, to: $0 ? 1 : nil) }
                    ))
                    .help("Keep only the top few tracks per album — “the most popular song from each Artist A album” is 1 per album, with the artist set to Artist A")
                    if model.spec.groupLimit?.perAlbum != nil {
                        Stepper(value: perAlbumLimit, in: 1...20) {
                            HStack {
                                Text("At most")
                                NumberEntryField(title: "Per album", value: intBinding(perAlbumLimit))
                                    .multilineTextAlignment(.trailing).frame(width: 50)
                                Text("per album")
                            }
                            .font(AppTypography.metadata)
                        }
                    }
                }
                if model.spec.target != .artist {
                    Toggle("At most N per release year", isOn: Binding(
                        get: { model.spec.groupLimit?.perReleaseYear != nil },
                        set: { setCap(\.perReleaseYear, to: $0 ? 1 : nil) }
                    ))
                    .help("Keep only the top few results from each release year — “the most played song from each year” is 1 per release year. Anything with no known release year isn’t capped.")
                    if model.spec.groupLimit?.perReleaseYear != nil {
                        Stepper(value: perReleaseYearLimit, in: 1...20) {
                            HStack {
                                Text("At most")
                                NumberEntryField(title: "Per release year", value: intBinding(perReleaseYearLimit))
                                    .multilineTextAlignment(.trailing).frame(width: 50)
                                Text("per release year")
                            }
                            .font(AppTypography.metadata)
                        }
                    }
                }
                Toggle("Only count plays in a period", isOn: Binding(
                    get: { model.spec.period != nil },
                    set: { model.spec.period = $0 ? QueryPeriod(from: AppCalendars.listening.date(byAdding: .month, value: -1, to: Date())!, to: Date()) : nil }
                ))
                .help("Ignore plays outside a date range before anything is counted. Only items played in the range appear, and their plays, ranks and dates use just that range (a field with its own date scope overrides this for its column).")
                if let period = model.spec.period {
                    DatePicker("From", selection: Binding(get: { period.from }, set: { model.spec.period?.from = $0 }), displayedComponents: .date)
                        .help("First day whose plays count.")
                    DatePicker("To", selection: Binding(get: { period.to }, set: { model.spec.period?.to = $0 }), displayedComponents: .date)
                        .help("Last day whose plays count.")
                }
                Toggle("Only count plays on certain days or hours", isOn: Binding(
                    get: { model.spec.playFilter != nil },
                    set: { model.spec.playFilter = $0 ? QueryPlayFilter(weekdays: [], fromHour: nil, toHour: nil) : nil }
                ))
                .help("Ignore plays made on other days of the week or at other times of day before anything is counted — “Sunday mornings” means the plays made then. Uses your local time.")
                if let filter = model.spec.playFilter {
                    PlayFilterEditor(filter: Binding(get: { filter }, set: { model.spec.playFilter = $0 }))
                }
                Toggle("Evaluate as of a date (default: now)", isOn: Binding(
                    get: { model.spec.asOf != nil }, set: { model.spec.asOf = $0 ? Date() : nil }
                ))
                .help("Treat this date as “now”: “days since last played”, trailing windows, milestones, fading and climbing are all measured from it, so the query reproduces what it would have shown then.")
                if let asOf = model.spec.asOf {
                    DatePicker("As of", selection: Binding(get: { asOf }, set: { model.spec.asOf = $0 }), displayedComponents: .date)
                        .help("The date treated as “now”.")
                }
            }
            .font(AppTypography.metadata)
            .padding(.top, 6)
        } label: {
            Text("Scope & limit (\(scopeSettingCount))")
                .help("Restrict how many results are shown, which plays count, or the date treated as now.")
        }
        .font(AppTypography.sectionTitle)
    }

    // Columns

    private var columnsSection: some View {
        DisclosureGroup("Columns (\(model.spec.columns.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(QueryFieldGroup.allCases, id: \.self) { group in
                    let fields = model.registry.fields(for: model.spec.target, in: group).filter { !$0.comparesPeriods }
                    if !fields.isEmpty {
                        Text(group.title).font(AppTypography.supportingDense).foregroundStyle(.tertiary).padding(.top, 4)
                        ForEach(fields, id: \.id) { field in
                            Toggle(field.name, isOn: Binding(
                                get: { model.spec.columns.contains { $0.id == field.id && $0.isPlain(in: model.registry) } },
                                set: { on in
                                    if on { model.spec.columns.append(QueryFieldRef(field.id)) }
                                    else { model.spec.columns.removeAll { $0.id == field.id && $0.isPlain(in: model.registry) } }
                                }
                            ))
                            .help(field.help)
                        }
                    }
                }
                scopedColumns
                Text("Drag a column header in the table to reorder.").font(AppTypography.supportingDense).foregroundStyle(.tertiary).padding(.top, 6)
            }
            .font(AppTypography.metadata)
            .padding(.top, 6)
        }
        .font(AppTypography.sectionTitle)
    }

    /// Columns that are more than "the field at its defaults": the same field over different date ranges, side by side
    /// ("Plays · Last 7 days" next to "Plays · Same 7 days last year"), or with a different setting ("Plays in last N days"
    /// at 30 and at 365). Each carries its own scope and settings.
    private var scopedColumns: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Customized columns").font(AppTypography.supportingDense).foregroundStyle(.tertiary).padding(.top, 6)
            ForEach(Array(model.spec.columns.enumerated()).filter { !$0.element.isPlain(in: model.registry) }, id: \.offset) { index, ref in
                let field = try? model.registry.field(ref.id)
                // Two lines — the title, then its settings — so a row never grows wider than the panel.
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text((try? model.registry.resolve(ref, target: model.spec.target).title) ?? ref.id).lineLimit(2)
                        Spacer(minLength: 4)
                        Button {
                            guard model.spec.columns.indices.contains(index) else { return }
                            model.spec.columns.remove(at: index)
                        } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            .help("Remove this column")
                    }
                    AskFlowLayout(spacing: 8) {
                        ForEach(field?.parameters ?? [], id: \.id) { parameter in
                            QueryParameterMenu(parameter: parameter, selection: Binding(
                                get: { model.spec.columns[safe: index]?.parameters[parameter.id] ?? parameter.defaultValue },
                                set: { setColumnParameter(at: index, parameter: parameter, to: $0) }
                            ), fieldHelp: field?.help ?? "")
                        }
                        if ref.scope != nil {
                            QueryScopeButton(scope: Binding(
                                get: { model.spec.columns[safe: index]?.scope },
                                set: { new in
                                    guard model.spec.columns.indices.contains(index) else { return }
                                    // Clearing the scope would silently turn it into a plain column — keep it scoped.
                                    if let new { model.spec.columns[index].scope = new }
                                }
                            ), asOf: model.spec.asOf ?? Date(), compact: true)
                        }
                        if ref.baseline != nil {
                            QueryScopeButton(scope: Binding(
                                get: { model.spec.columns[safe: index]?.baseline },
                                set: { new in
                                    guard model.spec.columns.indices.contains(index) else { return }
                                    if let new { model.spec.columns[index].baseline = new }
                                }
                            ), asOf: model.spec.asOf ?? Date(), compact: true, symbol: "arrow.left.arrow.right")
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Menu {
                    ForEach(QueryFieldGroup.allCases, id: \.self) { group in
                        let fields = model.registry.fields(for: model.spec.target, in: group).filter(\.supportsScope)
                        if !fields.isEmpty {
                            Section(group.title) {
                                ForEach(fields, id: \.id) { field in
                                    Button(field.name) {
                                        model.spec.columns.append(field.comparesPeriods ? QueryFieldRef.starting(field) : QueryFieldRef(field.id, scope: .calendar(.month)))
                                    }
                                    .help(field.help)
                                }
                            }
                        }
                    }
                } label: { Label("Add date-scoped column", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Add a column computed over its own date range (or comparing two ranges), next to the same field for another period.")
                Menu {
                    ForEach(model.registry.fields(for: model.spec.target).filter { !$0.parameters.isEmpty }, id: \.id) { field in
                        Button(field.name) { addColumnWithOtherSetting(field) }.help(field.help)
                    }
                } label: { Label("Add column with another setting", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Add a second copy of a field with a different setting — for example plays in the last 30 days beside plays in the last 365.")
            }
        }
    }

    /// Changes a customised column's setting — unless another column already is exactly that (two identical columns would
    /// be the same column drawn twice).
    private func setColumnParameter(at index: Int, parameter: QueryFieldParameter, to value: QueryValue) {
        guard model.spec.columns.indices.contains(index) else { return }
        var ref = model.spec.columns[index]
        ref.parameters[parameter.id] = value
        if columnExists(ref, excluding: index) { return }
        model.spec.columns[index] = ref
    }

    private func columnExists(_ ref: QueryFieldRef, excluding index: Int? = nil) -> Bool {
        guard let key = try? model.registry.resolve(ref, target: model.spec.target).cacheKey else { return false }
        return model.spec.columns.enumerated().contains { offset, other in
            offset != index && (try? model.registry.resolve(other, target: model.spec.target).cacheKey) == key
        }
    }

    /// The first setting of the field's (first) parameter, other than what a plain column already shows, that isn't a column yet.
    private func addColumnWithOtherSetting(_ field: QueryField) {
        guard let parameter = field.parameters.first else { return }
        for option in parameter.options {
            var ref = QueryFieldRef(field.id)
            ref.parameters[parameter.id] = option
            if !columnExists(ref) { model.spec.columns.append(ref); return }
        }
    }

    // MARK: - Results

    private var resultsPane: some View {
        VStack(spacing: 0) {
            resultsHeader
            Divider()
            Group {
                if model.isLoadingScrobbles && model.result == nil {
                    ProgressView("Loading your listening history…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.validationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.displayRows.isEmpty && !model.isRunning {
                    Text("No \(model.spec.target.rawValue)s match.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let result = model.result {
                    QueryResultsTable(
                        rows: model.displayRows, columns: result.columns,
                        identityTitle: model.spec.target.rawValue.capitalized,
                        onMoveColumn: { model.moveColumn($0, before: $1) },
                        onOpen: openEntity
                    )
                } else {
                    Color.clear
                }
            }
        }
    }

    private var resultsHeader: some View {
        HStack(spacing: 10) {
            if let result = model.result, model.validationError == nil {
                Text("\(result.matchedCount.formatted()) of \(result.universeCount.formatted()) \(model.spec.target.rawValue)s match")
                    .font(AppTypography.contentTitle)
                if let limit = model.spec.limit, result.matchedCount > limit {
                    Text("· showing the first \(limit.formatted())").foregroundStyle(.secondary)
                }
            } else {
                Text("Results").font(AppTypography.contentTitle)
            }
            if model.isRunning { ProgressView().controlSize(.small) }
            Spacer()
            if model.spec.target == .track, !model.displayRows.isEmpty {
                Button(allQueryTracksFlagged ? "All Flagged" : "Flag All", systemImage: "flag") {
                    flagAllQueryTracks()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(allQueryTracksFlagged)
                .help(allQueryTracksFlagged ? "Every displayed track is already flagged." : "Add every displayed track to Flagged Tracks.")

                AppleMusicPlaylistExportButton(
                    defaultPlaylistName: "Query Results (\(Date().formatted(date: .abbreviated, time: .omitted)))",
                    tracks: { queryPlaylistTracks }
                )
                .controlSize(.small)

                Button("Tag These…", systemImage: "tag") {
                    tagSheet = TagSheetPayload(tracks: queryFlagTracks.map {
                        TagSourceTrack(artist: $0.artist, track: $0.track, album: $0.album, duration: nil)
                    })
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Add or remove Last.fm tags on every displayed track — you review exactly what would change first.")
            }
            if let result = model.result, !result.pending.isEmpty {
                Label(
                    Self.pendingSummary(result.pending),
                    systemImage: "hourglass"
                )
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                .help("A value that hasn’t been looked up yet shows as “…” and can’t match a comparison or “is missing” until it has.")
                if result.pending.contains(where: { $0.resolver != nil }) {
                    Button(model.isResolving ? "Resolving\(model.resolveProgress.map { " \($0)" } ?? "")…" : "Resolve") { Task { await model.resolvePending() } }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(model.isResolving)
                    .help("Look these up now, using the same background queue as the rest of the app. Results fill in as they arrive.")
                }
            }
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.loadScrobbles() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isLoadingScrobbles)
            .help("Reload query data and results to include changes made elsewhere in the app.")
            if let seconds = model.lastRunSeconds {
                Text(String(format: "%.2fs", seconds)).font(AppTypography.supportingDense).foregroundStyle(.tertiary)
            }
            if let error = model.runError { Text(error).font(AppTypography.compactMetadata).foregroundStyle(.red) }
        }
        .font(AppTypography.metadata)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .sheet(item: $tagSheet) { payload in
            TagTracksSheet(tracks: payload.tracks, modelContainer: modelContainer, navigation: navigation)
        }
    }

    private var queryPlaylistTracks: [AppleMusicPlaylistTrack] {
        guard let result = model.result else { return [] }
        return model.displayRows.compactMap { row in
            guard row.entity.target == .track, !row.entity.artist.isEmpty else { return nil }
            return AppleMusicPlaylistTrack(
                artist: row.entity.artist,
                track: row.entity.name,
                album: result.entityInfo[row.id]?.album ?? ""
            )
        }
    }

    private var queryFlagTracks: [(artist: String, track: String, album: String?)] {
        guard let result = model.result else { return [] }
        return model.displayRows.compactMap { row in
            guard row.entity.target == .track, !row.entity.artist.isEmpty else { return nil }
            return (
                artist: row.entity.artist,
                track: row.entity.name,
                album: result.entityInfo[row.id]?.album
            )
        }
    }

    private var allQueryTracksFlagged: Bool {
        !queryFlagTracks.isEmpty && queryFlagTracks.allSatisfy {
            flaggedTracksStore.isFlagged(artist: $0.artist, track: $0.track, album: $0.album)
        }
    }

    private func flagAllQueryTracks() {
        run {
            try flaggedTracksStore.flagAll(context: modelContext, tracks: queryFlagTracks)
        }
    }

    private func openEntity(_ row: QueryDisplayRow) {
        let entity = row.entity
        switch entity.target {
        case .artist:
            navigation.goToArtist(ArtistIdentity(name: entity.name, imageURL: row.imageURL))
        case .album:
            navigation.goToAlbum(AlbumIdentity(artist: entity.artist, name: entity.name, imageURL: row.imageURL))
        case .track:
            navigation.goToTrack(TrackIdentity(
                artist: entity.artist,
                name: entity.name,
                album: model.result?.entityInfo[row.id]?.album,
                imageURL: row.imageURL
            ))
        }
    }
}

/// The tracks handed to the "Tag These…" sheet — one value, so the sheet is a pure function of it.
private struct TagSheetPayload: Identifiable {
    let id = UUID()
    let tracks: [TagSourceTrack]
}

private struct QueryResizableSplitView<Sidebar: View, Detail: View>: View {
    @Binding var sidebarWidth: Double
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let detail: Detail

    @State private var dragStartWidth: Double?

    private let minimumSidebarWidth = 300.0
    private let maximumSidebarWidth = 480.0
    private let minimumDetailWidth = 360.0
    private let dividerHitWidth = 9.0

    init(
        sidebarWidth: Binding<Double>,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail
    ) {
        _sidebarWidth = sidebarWidth
        self.sidebar = sidebar()
        self.detail = detail()
    }

    var body: some View {
        GeometryReader { proxy in
            let availableMaximum = max(
                minimumSidebarWidth,
                proxy.size.width - minimumDetailWidth - dividerHitWidth
            )
            let effectiveMaximum = min(maximumSidebarWidth, availableMaximum)
            let effectiveWidth = min(max(sidebarWidth, minimumSidebarWidth), effectiveMaximum)

            HStack(spacing: 0) {
                sidebar
                    .frame(width: effectiveWidth)

                Color.clear
                    .frame(width: dividerHitWidth)
                    .overlay {
                        Rectangle()
                            .fill(.separator)
                            .frame(width: 1)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let startWidth = dragStartWidth ?? effectiveWidth
                                if dragStartWidth == nil {
                                    dragStartWidth = startWidth
                                }
                                sidebarWidth = min(
                                    max(startWidth + value.translation.width, minimumSidebarWidth),
                                    effectiveMaximum
                                )
                            }
                            .onEnded { _ in
                                dragStartWidth = nil
                            }
                    )
                    .accessibilityLabel("Resize Query Settings")
                    .accessibilityAdjustableAction { direction in
                        let adjustment = direction == .increment ? 20.0 : -20.0
                        sidebarWidth = min(
                            max(effectiveWidth + adjustment, minimumSidebarWidth),
                            effectiveMaximum
                        )
                    }

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - One condition

struct QueryConditionRow: View {
    @Binding var condition: QueryCondition
    let registry: QueryFieldRegistry
    let target: QueryTarget
    var tagVocabulary: [QueryTagSuggestion] = []
    var asOf: Date = Date()
    let onRemove: () -> Void

    private var field: QueryField? { try? registry.field(condition.field.id) }

    /// A fresh condition for a field: defaults for its parameters, its first
    /// operator, and operands of the right type.
    static func makeCondition(fieldID: String, registry: QueryFieldRegistry) -> QueryCondition {
        guard let field = try? registry.field(fieldID), let op = field.type.operators.first else {
            return QueryCondition(fieldID, .hasValue)
        }
        return QueryCondition((try? registry.field(fieldID)).map(QueryFieldRef.starting) ?? QueryFieldRef(fieldID), op, defaultOperands(for: op))
    }

    static func defaultOperands(for op: QueryOperator) -> [QueryValue] {
        func one() -> QueryValue {
            switch op.operandType {
            case .numeric: .number(0)
            case .text: .text("")
            case .date: .date(Date())
            case .tags: .tags([])
            case .boolean, nil: .bool(true)
            }
        }
        switch op.arity {
        case .none: return []
        case .one, .oneOrMore: return [one()]
        case .two: return [one(), one()]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                fieldMenu
                Spacer()
                Button(action: onRemove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    .help("Remove this condition")
            }
            if let field {
                ForEach(field.parameters, id: \.id) { parameter in
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text(parameter.label).font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                            parameterPicker(parameter, field: field)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(parameter.label).font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                            parameterPicker(parameter, field: field)
                        }
                    }
                }
                if field.comparesPeriods {
                    HStack {
                        Text("Compared with").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                        QueryScopeButton(scope: Binding(get: { condition.field.baseline }, set: { if let new = $0 { condition.field.baseline = new } }), asOf: asOf, symbol: "arrow.left.arrow.right")
                    }
                }
                if field.supportsScope {
                    HStack {
                        Text(field.comparesPeriods ? "This period" : "Scope").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                        QueryScopeButton(scope: Binding(get: { condition.field.scope }, set: { condition.field.scope = $0 }), asOf: asOf)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        operatorPicker(field)
                        operandEditors
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 6) {
                        operatorPicker(field)
                        operandEditors
                    }
                }
                if condition.op.operandType == .tags {
                    QueryTagOperandEditor(tags: tagsBinding, vocabulary: tagVocabulary)
                }
            } else {
                Label("Unknown field “\(condition.field.id)”", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
        .font(AppTypography.metadata)
    }

    private var tagsBinding: Binding<[String]> {
        Binding(
            get: { if case .tags(let tags)? = condition.operands.first { tags } else { [] } },
            set: { tags in
                if case .tags(let normalized) = QueryValue.tags(normalizing: tags) { condition.operands = [.tags(normalized)] }
            }
        )
    }

    private var fieldMenu: some View {
        Menu {
            ForEach(QueryFieldGroup.allCases, id: \.self) { group in
                let fields = registry.fields(for: target, in: group)
                if !fields.isEmpty {
                    Section(group.title) {
                        ForEach(fields, id: \.id) { candidate in Button(candidate.name) { setField(candidate) }.help(candidate.help) }
                    }
                }
            }
        } label: {
            Text(field?.name ?? condition.field.id).fontWeight(.medium)
                .lineLimit(1)
                .help(field?.help ?? "")
        }
        .menuStyle(.borderlessButton)
        .help(field?.help ?? "")
    }

    private func parameterPicker(_ parameter: QueryFieldParameter, field: QueryField) -> some View {
        Picker("", selection: Binding(
            get: { condition.field.parameters[parameter.id] ?? parameter.defaultValue },
            set: { condition.field.parameters[parameter.id] = $0 }
        )) {
            ForEach(parameter.options, id: \.self) { Text(parameter.display($0)).tag($0) }
        }
        .labelsHidden()
        .help(parameter.help.isEmpty ? field.help : parameter.help)
    }

    private func operatorPicker(_ field: QueryField) -> some View {
        Picker("", selection: Binding(get: { condition.op }, set: setOperator)) {
            ForEach(field.type.operators, id: \.self) { Text($0.label).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .help("How the field is compared with the value you enter.")
    }

    private func setField(_ new: QueryField) {
        guard new.id != condition.field.id else { return }
        condition = Self.makeCondition(fieldID: new.id, registry: registry)
    }

    private func setOperator(_ op: QueryOperator) {
        // Keep what the user already entered when the new operator takes the same kind and number
        // of operands (any-of → all-of, ≥ → >); otherwise start from defaults.
        let keepsOperands = condition.op.operandType == op.operandType && condition.op.arity == op.arity
        condition.op = op
        if !keepsOperands { condition.operands = Self.defaultOperands(for: op) }
    }

    @ViewBuilder
    private var operandEditors: some View {
        ForEach(Array(condition.operands.indices), id: \.self) { i in
            if let operand = condition.operands[safe: i] {
            switch operand {
            case .number:
                let unit = field?.inputUnit
                HStack(spacing: 4) {
                    NumberEntryField(title: "value", value: Binding(
                        get: { if case .number(let n) = condition.operands[safe: i] { n / (unit?.perUnit ?? 1) } else { 0 } },
                        set: { if condition.operands.indices.contains(i) { condition.operands[i] = .number($0 * (unit?.perUnit ?? 1)) } }
                    ))
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                    if let unit { Text(unit.label).foregroundStyle(.secondary) }
                }
            case .text where field?.choices != nil:
                let choices = field?.choices ?? []
                Picker("", selection: Binding(
                    get: { if case .text(let s) = condition.operands[safe: i], choices.contains(s) { s } else { choices.first ?? "" } },
                    set: { if condition.operands.indices.contains(i) { condition.operands[i] = .text($0) } }
                )) {
                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Pick one of the values this field can have.")
                .onAppear {
                    // A new condition starts blank; show — and use — the first value rather than matching nothing.
                    if case .text(let s) = condition.operands[safe: i], !choices.contains(s), let first = choices.first { condition.operands[i] = .text(first) }
                }
            case .text:
                TextField("text", text: Binding(
                    get: { if case .text(let s) = condition.operands[safe: i] { s } else { "" } },
                    set: { if condition.operands.indices.contains(i) { condition.operands[i] = .text($0) } }
                ))
                .textFieldStyle(.roundedBorder)
            case .date:
                DatePicker("", selection: Binding(
                    get: { if case .date(let d) = condition.operands[safe: i] { d } else { Date() } },
                    set: { if condition.operands.indices.contains(i) { condition.operands[i] = .date($0) } }
                ), displayedComponents: .date)
                .labelsHidden()
            case .tags:
                EmptyView() // picked in the tag picker below the operator
            case .bool:
                EmptyView()
            }
            }
        }
    }
}

extension Array {
    /// nil instead of a trap when `index` is out of range — for state (a hover position) that can outlive the
    /// array it was measured against.
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}


extension QueryView {
    /// "3 still resolving “A”, “B”" — fields that share a count are named together.
    static func pendingSummary(_ pending: [(field: String, count: Int, resolver: QueryResolverKind?)]) -> String {
        var order: [Int] = []
        var names: [Int: [String]] = [:]
        for item in pending {
            if names[item.count] == nil { order.append(item.count) }
            names[item.count, default: []].append("“\(item.field)”")
        }
        return order.map { "\($0.formatted()) still resolving \(names[$0]!.joined(separator: ", "))" }.joined(separator: " · ")
    }
}


/// Weekday chips (Sun–Sat, none picked = every day) and an optional hour range.
private struct PlayFilterEditor: View {
    @Binding var filter: QueryPlayFilter

    private let days = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { day in
                    let on = filter.weekdays?.contains(day) ?? false
                    Button {
                        var set = Set(filter.weekdays ?? [])
                        if on { set.remove(day) } else { set.insert(day) }
                        filter.weekdays = set.sorted()
                    } label: {
                        Text(days[day])
                            .frame(width: 26, height: 24)
                            .background(on ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .overlay { RoundedRectangle(cornerRadius: 6).stroke(.separator) }
                    }
                    .buttonStyle(.plain)
                    .help(QueryPlayFilter.dayNames[day])
                }
                Text(filter.weekdays?.isEmpty ?? true ? "every day" : "").foregroundStyle(.secondary)
            }
            Toggle("Only certain hours", isOn: Binding(
                get: { filter.fromHour != nil },
                set: { filter.fromHour = $0 ? 5 : nil; filter.toHour = $0 ? 11 : nil }
            ))
            if let from = filter.fromHour, let to = filter.toHour {
                HStack {
                    hourMenu("From", value: from) { filter.fromHour = $0 }
                    Text("through")
                    hourMenu("To", value: to) { filter.toHour = $0 }
                }
                .help("The hours are inclusive: 5 AM through 11 AM covers 5:00 to 11:59. A start after the end wraps past midnight.")
            }
        }
    }

    private func hourMenu(_ title: String, value: Int, set: @escaping (Int) -> Void) -> some View {
        Picker(title, selection: Binding(get: { value }, set: set)) {
            ForEach(0..<24, id: \.self) { Text(QueryPlayFilter.hourLabel($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}


/// A numeric text field that keeps its own text while editing. `TextField(value:format:)` snaps back to the last
/// valid number as soon as the text can't be parsed — so clearing it one character at a time refilled the last digit.
/// Here an empty or partial entry leaves the stored value alone until the field loses focus.
struct NumberEntryField: View {
    let title: String
    @Binding var value: Double
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .focused($focused)
            .onAppear { text = Self.format(value) }
            .onChange(of: text) {
                if let parsed = try? Double(text, format: .number), parsed != value { value = parsed }
            }
            .onChange(of: value) {
                // An outside change (stepper, reset) — not the user's own typing echoing back.
                if !focused || (try? Double(text, format: .number)) != value { text = Self.format(value) }
            }
            .onChange(of: focused) {
                if !focused { text = Self.format(value) }
            }
    }

    private static func format(_ n: Double) -> String { n.formatted(.number.grouping(.never)) }
}
