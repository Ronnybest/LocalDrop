import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The main screen: a section per paired Mac with what can be sent to it, then Recent.
struct HomeView: View {
    let model: AppModel
    @State private var addsMac = false
    @State private var showsSettings = false
    @State private var preview: URL?
    @State private var previewItems: [URL] = []

    var body: some View {
        NavigationStack {
            Group {
                if let error = model.phoneError {
                    ContentUnavailableView {
                        Label("Dewlet can’t start", systemImage: "lock.trianglebadge.exclamationmark")
                    } description: {
                        Text(error.message(macName: "Mac"))
                    } actions: {
                        Button("Try Again") { Task { await model.loadPhone() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if model.macs.isEmpty {
                    ContentUnavailableView {
                        Label("Send files to your Mac", systemImage: "laptopcomputer")
                    } description: {
                        Text("Pair your Mac once. After that, send photos and files from here, or share them from any app and pick your Mac.")
                    } actions: {
                        Button("Add a Mac") { addsMac = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.phone == nil)
                    }
                } else {
                    List {
                        ForEach(model.macs) { mac in
                            MacSection(model: model, mac: mac) { addsMac = true }
                        }
                        // Titled: a Mac with nothing paired tells its user to tap “Add a Mac”.
                        Section {
                            Button("Add a Mac", systemImage: "plus") { addsMac = true }
                                .disabled(model.phone == nil)
                        }
                        Section {
                            if model.history.isEmpty {
                                Text("Nothing sent or received yet")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(model.history) { entry in
                                HistoryRow(entry: entry) { urls in
                                    previewItems = urls
                                    preview = urls.first
                                }
                            }
                        } header: {
                            Text("Recent")
                        } footer: {
                            if model.history.isEmpty {
                                Text("To send to this iPhone, use Share › Dewlet on the Mac, or drag files to the right edge of its screen and drop them on this iPhone.")
                            }
                        }
                    }
                    .refreshable {
                        for link in model.links.values { link.poke() }
                    }
                    // Core changes these without a transaction; rows come and go with the system's motion.
                    .animation(.default, value: model.macs.map { model.links[$0.id]?.activity })
                    .animation(.default, value: model.macs.map { model.links[$0.id]?.state })
                }
            }
            .navigationTitle("Dewlet")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showsSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add a Mac", systemImage: "plus") { addsMac = true }
                        .disabled(model.phone == nil)
                }
            }
        }
        .sheet(isPresented: $addsMac) {
            AddMacView(model: model)
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView(model: model)
        }
        // A sheet shows it itself; a preview can't, so it closes for the offer.
        .modifier(IncomingOfferAlert(model: model, isCovered: addsMac || showsSettings))
        .onChange(of: model.offering != nil) { _, offered in
            if offered { preview = nil }
        }
        .quickLookPreview($preview, in: previewItems)
    }
}

/// Accept / Decline for what a Mac wants to send, on every screen that can be in front: an alert
/// can't show from a view under a sheet. One offer at a time; the next Mac's shows once this one
/// is answered.
struct IncomingOfferAlert: ViewModifier {
    let model: AppModel
    /// A sheet is over this view and shows the alert instead.
    var isCovered = false

    func body(content: Content) -> some View {
        let offering = isCovered ? nil : model.offering
        let offer: IncomingOffer? = if case .awaitingDecision(let offer) = offering?.activity { offer } else { nil }
        content
            .alert(Text("Receive from \(offer?.macName ?? "Mac")?"), isPresented: Binding(get: { offer != nil }, set: { _ in }), presenting: offer) { _ in
                Button("Decline", role: .cancel) { offering?.answer(false) }
                Button("Accept") { offering?.answer(true) }
            } message: { offer in
                let what = offer.fileCount == 1 ? offer.firstName : String(localized: "\(offer.fileCount) files")
                Text(verbatim: "\(what) · \(offer.totalSize.formatted(.byteCount(style: .file)))")
            }
            .sensoryFeedback(.warning, trigger: offer) { old, new in old == nil && new != nil }
    }
}

/// One paired Mac: how it is reachable, what runs now, the last result, and the ways to send.
private struct MacSection: View {
    let model: AppModel
    let mac: PairedMac
    let addMac: () -> Void
    @State private var picks: [PhotosPickerItem] = []
    @State private var importsFiles = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        let link = model.links[mac.id]
        let state = link?.state ?? .idle
        let preparation = model.preparing[mac.id]
        let busy = link == nil || link?.activity != nil || preparation != nil
        let needsPairing = state == .notPaired || state == .unreachable(.authenticationFailed)

        Section {
            NavigationLink {
                MacDetailsView(model: model, macId: mac.id)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mac.name)
                            .font(.headline)
                        Text(model.statusText(of: mac))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "laptopcomputer")
                        .foregroundStyle(state == .connected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .symbolEffect(.pulse, isActive: state == .idle || state == .connecting)
                }
            }

            switch state {
            // Not trusted any more, or another key (Dewlet reinstalled on the Mac): pairing again fixes it.
            case .notPaired, .unreachable(.authenticationFailed):
                Button("Add Again", systemImage: "plus.circle") { addMac() }
            case .unreachable(.localNetworkDenied):
                Button("Open Settings", systemImage: "gear") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
            case .unreachable:
                Button("Try Again", systemImage: "arrow.clockwise") { link?.poke() }
            default:
                EmptyView()
            }

            if let link, let activity = link.activity {
                switch activity {
                case .awaitingDecision(let offer):
                    Label("Receive from \(offer.macName)?", systemImage: "arrow.down.circle")
                case .sending(let progress, let summary):
                    transfer(progress, summary: summary, sending: true, link: link)
                case .receiving(let progress, let summary):
                    transfer(progress, summary: summary, sending: false, link: link)
                }
            } else if let preparation {
                HStack(spacing: 12) {
                    ProgressView()
                    Group {
                        if !preparation.queued {
                            Text("Preparing…")
                        } else if state == .connected {
                            Text("Waiting for \(mac.name)…")
                        } else {
                            Text("Connecting to \(mac.name)…")
                        }
                    }
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if !preparation.queued {
                        Button("Cancel", systemImage: "xmark.circle.fill") { model.cancelPreparation(for: mac.id) }
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .buttonStyle(.borderless)
                    }
                }
            }

            if let outcome = model.outcomes[mac.id] {
                let failed = if case .failed = outcome.kind { true } else { false }
                let symbol = switch outcome.kind {
                case .done: "checkmark.circle.fill"
                case .link: "link.circle.fill"
                case .failed: "exclamationmark.triangle.fill"
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol)
                            .font(.title3)
                            .symbolRenderingMode(failed ? .multicolor : .monochrome)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(outcome.title)
                                .font(.subheadline.weight(.medium))
                            if let detail = outcome.detail {
                                Text(detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(failed ? nil : 2)
                            }
                        }
                        Spacer(minLength: 0)
                        switch outcome.kind {
                        case .link(let url):
                            Button("Open") { openURL(url) }
                                .buttonStyle(.bordered)
                        case .failed:
                            Button("Dismiss", systemImage: "xmark") { model.dismissOutcome(mac.id) }
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.secondary)
                                .buttonStyle(.borderless)
                        case .done:
                            EmptyView()
                        }
                    }
                    if outcome.kind == .failed(retry: true) {
                        Button("Try Again") { model.retry(mac.id) }
                            .buttonStyle(.bordered)
                            .disabled(link?.activity != nil || preparation != nil)
                    }
                }
                .sensoryFeedback(trigger: outcome) { _, new in
                    if case .failed = new.kind { .error } else { .success }
                }
            }

            if !needsPairing {
                HStack(spacing: 8) {
                    PhotosPicker(selection: $picks, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
                        Label("Photos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        importsFiles = true
                    } label: {
                        Label("Files", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    // The system's own look (its label can't be restyled); no paste prompt with it.
                    PasteButton(payloadType: PickedItem.self) { items in
                        model.send(pasted: items, to: mac.id)
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(busy)
                .fileImporter(isPresented: $importsFiles, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result, !urls.isEmpty { model.send(files: urls, to: mac.id) }
                }
                .onChange(of: picks) { _, chosen in
                    guard !chosen.isEmpty else { return }
                    model.send(chosen, to: mac.id)
                    picks = []
                }
            }
        }
    }

    /// A transfer under way: what, how far, how fast, and Cancel.
    private func transfer(_ progress: TransferProgress?, summary: String, sending: Bool, link: MacLink) -> some View {
        let name = progress?.fileName ?? summary
        let measured = progress.map { $0.phase == .transferring || $0.phase == .verifying } ?? false
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(sending ? LocalizedStringKey("Sending \(name)") : LocalizedStringKey("Receiving \(name)"))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let progress, progress.fileCount > 1 {
                    Text("\(progress.fileIndex + 1) of \(progress.fileCount)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Button("Cancel", systemImage: "xmark.circle.fill") { link.cancelActivity() }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
            }
            if let progress, measured {
                ProgressView(value: progress.fraction)
                HStack {
                    if progress.phase == .verifying {
                        Text("Verifying…")
                    } else {
                        let done = progress.bytesDone.formatted(.byteCount(style: .file))
                        let total = progress.totalBytes.formatted(.byteCount(style: .file))
                        let speed = Int64(progress.bytesPerSecond).formatted(.byteCount(style: .file))
                        Text(verbatim: String(localized: "\(done) of \(total)") + (progress.bytesPerSecond > 0 ? " · " + String(localized: "\(speed)/s") : ""))
                            .contentTransition(.numericText())
                    }
                    Spacer(minLength: 8)
                    if progress.phase == .transferring,
                       let left = TimeLeft.text(remainingBytes: progress.totalBytes - progress.bytesDone, bytesPerSecond: progress.bytesPerSecond) {
                        Text(left)
                            .contentTransition(.numericText())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress?.phase == .waitingForAcceptance ? LocalizedStringKey("Waiting for \(mac.name) to accept…")
                         : sending ? LocalizedStringKey("Preparing…") : LocalizedStringKey("Waiting for \(mac.name)…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One entry of Recent. A tap previews the kept files, opens Photos for what went there, copies
/// the text again or opens the link; a row with nothing to open (sent files) is no button.
private struct HistoryRow: View {
    let entry: HistoryEntry
    let preview: ([URL]) -> Void
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        let files = entry.files.map { URL.documentsDirectory.appending(path: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        let link = entry.kind == .link ? AppModel.webLink(entry.title) : nil
        let symbol = switch entry.kind {
        case .link: "link"
        case .text: "text.quote"
        case .files where entry.savedToPhotos > 0: "photo.on.rectangle"
        case .files where entry.count > 1: "doc.on.doc"
        case .files:
            switch UTType(filenameExtension: (entry.title as NSString).pathExtension) {
            case let type? where type.conforms(to: .movie): "film"
            case let type? where type.conforms(to: .image): "photo"
            default: "doc"
            }
        }
        var details = [entry.incoming ? String(localized: "From \(entry.macName)") : String(localized: "To \(entry.macName)")]
        if entry.kind == .files {
            details.append(entry.bytes.formatted(.byteCount(style: .file)))
            if entry.savedToPhotos == entry.count {
                details.append(String(localized: "Saved to Photos"))
            } else if !entry.files.isEmpty && files.isEmpty {
                details.append(String(localized: "No longer on this iPhone"))
            }
        }
        details.append(entry.date.formatted(Calendar.current.isDateInToday(entry.date)
                                             ? Date.FormatStyle.dateTime.hour().minute() : Date.FormatStyle.dateTime.day().month().hour().minute()))

        var action: (() -> Void)?
        switch entry.kind {
        case .files where !files.isEmpty: action = { preview(files) }
        case .files where entry.savedToPhotos == entry.count: action = { openURL(URL(string: "photos-redirect://")!) }
        case .files: break
        case .link: if let link { action = { openURL(link) } }
        case .text: action = copy
        }
        let label = Label {
            VStack(alignment: .leading, spacing: 2) {
                // Label colors, not hierarchical styles: inside a Button those resolve to the tint.
                Text(entry.title)
                    .foregroundStyle(Color(.label))
                    .lineLimit(entry.kind == .files ? 1 : 2)
                    .truncationMode(entry.kind == .files ? .middle : .tail)
                Text(verbatim: details.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: copied ? "checkmark" : symbol)
                .contentTransition(.symbolEffect(.replace))
        }

        return Group {
            if let action {
                Button(action: action) { label }
            } else {
                label
            }
        }
        .contextMenu {
            if !files.isEmpty {
                ShareLink(items: files)
            }
            if entry.kind != .files {
                Button("Copy", systemImage: "doc.on.doc") { copy() }
            }
            if let link {
                Button("Open", systemImage: "safari") { openURL(link) }
                ShareLink(item: link)
            }
        }
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
    }

    private func copy() {
        UIPasteboard.general.string = entry.title
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copied = false }
        }
    }
}
