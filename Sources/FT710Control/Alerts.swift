import SwiftUI
import AppKit
import Combine
import UserNotifications

/// Rodzaj alertu - w kolejności pierwszeństwa (gdy pasuje kilka, alert dostaje pierwszy włączony).
enum AlertKind: String, CaseIterable, Identifiable {
    case callingMe, watched, newDXCC, unconfirmedDXCC, newDXCCBand, unconfirmedDXCCBand, newPark, confirmations

    var id: String { rawValue }

    var name: String {
        switch self {
        case .callingMe: return L("Ktoś mnie woła (FT8)")
        case .watched: return L("Obserwowany znak")
        case .newDXCC: return L("Nowy kraj DXCC")
        case .unconfirmedDXCC: return L("Kraj niepotwierdzony")
        case .newDXCCBand: return L("Nowy kraj DXCC na paśmie")
        case .unconfirmedDXCCBand: return L("Kraj niepotwierdzony na paśmie")
        case .newPark: return L("Nowy park POTA")
        case .confirmations: return L("Nowe potwierdzenia QSL")
        }
    }

    /// Kolory jak kategorie FT8 (WSJT-X).
    var color: Color {
        switch self {
        case .callingMe: return FTHighlight.myCall.color
        case .watched: return FTHighlight.newCall.color
        case .newDXCC: return FTHighlight.newDXCC.color
        case .unconfirmedDXCC: return FTHighlight.unconfirmedDXCC.color
        case .newDXCCBand: return FTHighlight.newDXCCBand.color
        case .unconfirmedDXCCBand: return FTHighlight.unconfirmedDXCCBand.color
        case .newPark: return FTHighlight.newGrid.color
        case .confirmations: return Theme.ok
        }
    }

    /// Kolor jako „#RRGGBB” (panel zdalny w przeglądarce).
    var hex: String {
        switch self {
        case .callingMe: return FTHighlight.myCall.hex
        case .watched: return FTHighlight.newCall.hex
        case .newDXCC: return FTHighlight.newDXCC.hex
        case .unconfirmedDXCC: return FTHighlight.unconfirmedDXCC.hex
        case .newDXCCBand: return FTHighlight.newDXCCBand.hex
        case .unconfirmedDXCCBand: return FTHighlight.unconfirmedDXCCBand.hex
        case .newPark: return FTHighlight.newGrid.hex
        case .confirmations: return "#3FB950"
        }
    }

    /// Domyślnie: wszystko oprócz „niepotwierdzony na paśmie” (na zatłoczonym paśmie bywa go dużo).
    static let defaultEnabled: Set<AlertKind> = [.callingMe, .watched, .newDXCC, .unconfirmedDXCC, .newDXCCBand, .newPark,
                                                 .confirmations]

    static func from(_ status: DXCCStatus) -> [AlertKind] {
        switch status {
        case .newDXCC: return [.newDXCC]
        case .newBand: return [.newDXCCBand]
        case .unconfirmed: return [.unconfirmedDXCC]
        case .unconfirmedNewBand: return [.unconfirmedDXCC, .newDXCCBand]
        case .unconfirmedBand: return [.unconfirmedDXCCBand]
        case .confirmed: return []
        }
    }
}

enum AlertSourceKind: String, CaseIterable, Identifiable {
    case cluster, ft8, pota, qsl
    var id: String { rawValue }
    var name: String {
        switch self {
        case .cluster: return "DX Cluster"
        case .ft8: return "FT8/FT4"
        case .pota: return "POTA"
        case .qsl: return L("Potwierdzenia QSL")
        }
    }
    /// Źródła stacji do włączania w ustawieniach (potwierdzenia sterowane rodzajem alertu).
    static let stationSources: [AlertSourceKind] = [.cluster, .ft8, .pota]
}

/// Zdarzenie, z którego powstał alert - kliknięcie robi to samo, co kliknięcie w źródle.
enum AlertOrigin {
    case cluster(DXSpot)
    case ft8(FTDecode)
    case pota(POTASpot)
    case qsl

    var kind: AlertSourceKind {
        switch self {
        case .cluster: return .cluster
        case .ft8: return .ft8
        case .pota: return .pota
        case .qsl: return .qsl
        }
    }
}

struct AlertItem: Identifiable {
    let id = UUID()
    let time: Date
    let kind: AlertKind
    let origin: AlertOrigin
    let call: String
    let band: String
    let mode: String
    let frequencyHz: Int
    let detail: String          // kraj, park, treść komunikatu FT8
    var read = false
}

/// Centrum alertów: zbiera zdarzenia z DX Cluster, FT8 i POTA, odsiewa powtórki, gra dźwięk, wysyła
/// powiadomienia macOS (tylko w aplikacji spakowanej jako .app) i trzyma listę ostatnich 200 alertów.
@MainActor
final class AlertCenter: ObservableObject {
    static let shared = AlertCenter()

    @Published private(set) var items: [AlertItem] = []
    @Published var enabledKinds: Set<AlertKind> { didSet { save() } }
    @Published var enabledSources: Set<AlertSourceKind> { didSet { save() } }
    /// Obserwowane znaki (oddzielone spacją albo przecinkiem; porównanie po znaku podstawowym).
    @Published var watchList: String { didSet { save() } }
    /// Pasma, na których alerty są aktywne (puste = wszystkie).
    @Published var bands: Set<String> { didSet { save() } }
    @Published var soundEnabled: Bool { didSet { save() } }
    @Published var soundName: String { didSet { save() } }
    @Published var notificationsEnabled: Bool { didSet { save(); if notificationsEnabled { requestAuthorization() } } }
    @Published private(set) var notificationStatus = ""

    var unreadCount: Int { items.filter { !$0.read }.count }

    static let sounds = ["Glass", "Ping", "Hero", "Submarine", "Purr", "Pop", "Funk", "Tink"]
    private static let repeatWindow: TimeInterval = 30 * 60
    private static let callingMeWindow: TimeInterval = 120
    private static let deliveryGap: TimeInterval = 5

    private var lastAlerted: [String: Date] = [:]
    private var lastDelivered = Date.distantPast
    private var seenSpots = Set<UUID>()
    private var clusterBackfillUntil = Date.distantPast
    private var observers: [AnyCancellable] = []
    private let notificationDelegate = AlertNotificationDelegate()

    init() {
        let d = UserDefaults.standard
        enabledKinds = (d.stringArray(forKey: "alerts.kinds")).map { Set($0.compactMap(AlertKind.init(rawValue:))) }
            ?? AlertKind.defaultEnabled
        enabledSources = (d.stringArray(forKey: "alerts.sources")).map { Set($0.compactMap(AlertSourceKind.init(rawValue:))) }
            ?? Set(AlertSourceKind.allCases)
        watchList = d.string(forKey: "alerts.watch") ?? ""
        bands = Set(d.stringArray(forKey: "alerts.bands") ?? [])
        soundEnabled = d.object(forKey: "alerts.sound") as? Bool ?? true
        soundName = d.string(forKey: "alerts.soundName") ?? "Glass"
        notificationsEnabled = d.object(forKey: "alerts.notifications") as? Bool ?? true
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(enabledKinds.map(\.rawValue).sorted(), forKey: "alerts.kinds")
        d.set(enabledSources.map(\.rawValue).sorted(), forKey: "alerts.sources")
        d.set(watchList, forKey: "alerts.watch")
        d.set(bands.sorted(), forKey: "alerts.bands")
        d.set(soundEnabled, forKey: "alerts.sound")
        d.set(soundName, forKey: "alerts.soundName")
        d.set(notificationsEnabled, forKey: "alerts.notifications")
    }

    // MARK: - Źródła

    /// DX Cluster: nowe spoty z listy klienta; spoty przysłane hurtem tuż po połączeniu (sh/dx) nie alarmują.
    func attach(cluster: DXClusterClient) {
        guard observers.isEmpty else { return }
        observers.append(cluster.$state.sink { [weak self] state in
            Task { @MainActor in
                if state == .connected { self?.clusterBackfillUntil = Date().addingTimeInterval(15) }
            }
        })
        observers.append(cluster.$spots.sink { [weak self] spots in
            Task { @MainActor in self?.clusterSpots(spots) }
        })
        setUpNotifications()
    }

    private func clusterSpots(_ spots: [DXSpot]) {
        let fresh = spots.filter { !seenSpots.contains($0.id) }
        for spot in fresh { seenSpots.insert(spot.id) }
        if seenSpots.count > 3000 { seenSpots = Set(spots.map(\.id)) }
        guard Date() > clusterBackfillUntil, enabledSources.contains(.cluster) else { return }
        for spot in fresh.reversed() {
            let match = CTYDatabase.shared.table?.lookup(spot.call)
            var kinds: [AlertKind] = isWatched(spot.call) ? [.watched] : []
            if let match { kinds += countryKinds(match: match, call: spot.call, band: spot.band) }
            raise(kinds, origin: .cluster(spot), call: spot.call, band: spot.band, mode: spot.digiMode ?? spot.mode.rawValue,
                  frequencyHz: spot.frequencyHz, detail: countryName(match))
        }
    }

    /// FT8/FT4: komunikaty z cyklu - wywołanie do mnie, obserwowany znak, kategorie krajów z wyróżniania.
    func ft8(_ decodes: [FTDecode], band: String, dial: Int) {
        guard enabledSources.contains(.ft8) else { return }
        for d in decodes where !d.isTX && !d.isSeparator {
            guard let call = d.info.from, FTMessageInfo.isCallsign(call) else { continue }
            var kinds: [AlertKind] = []
            if d.toMe { kinds.append(.callingMe) }
            if isWatched(call) { kinds.append(.watched) }
            if d.info.isCQ {
                for h in d.highlights {
                    switch h {
                    case .newDXCC: kinds.append(.newDXCC)
                    case .unconfirmedDXCC: kinds.append(.unconfirmedDXCC)
                    case .newDXCCBand: kinds.append(.newDXCCBand)
                    case .unconfirmedDXCCBand: kinds.append(.unconfirmedDXCCBand)
                    default: break
                    }
                }
            }
            raise(kinds, origin: .ft8(d), call: call, band: band, mode: d.mode.rawValue,
                  frequencyHz: dial > 0 ? dial + d.freq : 0, detail: d.text + (d.country.isEmpty ? "" : " · " + d.country))
        }
    }

    /// POTA: nowe aktywacje (pierwsza lista po starcie nie alarmuje - robi to POTAManager).
    func pota(_ spots: [POTASpot], isNewPark: (POTASpot) -> Bool) {
        guard enabledSources.contains(.pota) else { return }
        for spot in spots {
            let match = CTYDatabase.shared.table?.lookup(spot.activator)
            var kinds: [AlertKind] = isWatched(spot.activator) ? [.watched] : []
            if let match { kinds += countryKinds(match: match, call: spot.activator, band: spot.band) }
            if isNewPark(spot) { kinds.append(.newPark) }
            raise(kinds, origin: .pota(spot), call: spot.activator, band: spot.band, mode: spot.mode,
                  frequencyHz: spot.frequencyHz, detail: spot.reference + " " + spot.parkName)
        }
    }

    // MARK: - Ocena i dostarczenie

    /// Rodzaje krajowe dla stacji; „niepotwierdzony” pomijany, gdy ta stacja jest już zrobiona na tym paśmie.
    private func countryKinds(match: CTYMatch, call: String, band: String) -> [AlertKind] {
        let index = WorkedIndexStore.shared.index
        var kinds = AlertKind.from(index.dxccStatus(match: match, band: band))
        if index.workedOnBand(call, band: band) { kinds.removeAll { $0 == .unconfirmedDXCC || $0 == .unconfirmedDXCCBand } }
        return kinds
    }

    private func isWatched(_ call: String) -> Bool {
        let base = QRZClient.baseCall(call.uppercased())
        return watchList.uppercased().split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" || $0 == "\n" })
            .contains { QRZClient.baseCall(String($0)) == base }
    }

    private func countryName(_ match: CTYMatch?) -> String {
        guard let match else { return "" }
        return CTYDatabase.shared.table?.dxccName(CTYTable.dxccKey(match)) ?? match.entity.name
    }

    private func raise(_ kinds: [AlertKind], origin: AlertOrigin, call: String, band: String, mode: String,
                       frequencyHz: Int, detail: String) {
        // pierwszy włączony rodzaj w kolejności pierwszeństwa
        guard let kind = AlertKind.allCases.first(where: { kinds.contains($0) && enabledKinds.contains($0) }) else { return }
        if !bands.isEmpty, !bands.contains(band) { return }
        let key = kind.rawValue + "|" + QRZClient.baseCall(call) + "|" + band
        let now = Date()
        let window = kind == .callingMe ? Self.callingMeWindow : Self.repeatWindow
        if let last = lastAlerted[key], now.timeIntervalSince(last) < window { return }
        lastAlerted[key] = now
        if lastAlerted.count > 2000 { lastAlerted = lastAlerted.filter { now.timeIntervalSince($0.value) < Self.repeatWindow } }

        let item = AlertItem(time: now, kind: kind, origin: origin, call: call, band: band, mode: mode,
                             frequencyHz: frequencyHz, detail: detail)
        items.insert(item, at: 0)
        if items.count > 200 { items.removeLast(items.count - 200) }
        deliver(item)
    }

    /// Dźwięk i powiadomienie najwyżej co 5 s - przy serii alertów reszta trafia tylko na listę.
    private func deliver(_ item: AlertItem) {
        let now = Date()
        guard now.timeIntervalSince(lastDelivered) >= Self.deliveryGap else { return }
        lastDelivered = now
        if soundEnabled { NSSound(named: NSSound.Name(soundName))?.play() }
        guard notificationsEnabled, Self.canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = item.kind == .confirmations ? item.call : item.kind.name + ": " + item.call
        var parts: [String] = []
        if item.frequencyHz > 0 { parts.append(String(format: "%.3f MHz", Double(item.frequencyHz) / 1_000_000)) }
        if !item.band.isEmpty { parts.append(item.band) }
        if !item.mode.isEmpty { parts.append(item.mode) }
        content.body = parts.joined(separator: " · ") + (item.detail.isEmpty ? "" : "\n" + item.detail)
        content.subtitle = item.origin.kind.name
        content.userInfo = ["alert": item.id.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil))
    }

    func playTest() { NSSound(named: NSSound.Name(soundName))?.play() }

    /// Automatyczne pobranie potwierdzeń przyniosło nowe: „5 nowych potwierdzeń, w tym nowy kraj: …”.
    func confirmationsArrived(count: Int, entities: [String], sources: [String]) {
        guard enabledKinds.contains(.confirmations), count > 0 else { return }
        var detail = sources.joined(separator: ", ")
        if !entities.isEmpty {
            let shown = entities.prefix(5).joined(separator: ", ")
            let more = entities.count > 5 ? " " + L("i {1} innych", entities.count - 5) : ""
            detail += " · " + (entities.count == 1 ? L("nowy potwierdzony kraj: {1}", shown)
                                                   : L("nowe potwierdzone kraje ({1}): {2}", entities.count, shown + more))
        }
        let item = AlertItem(time: Date(), kind: .confirmations, origin: .qsl,
                             call: L("{1} nowych potwierdzeń", count), band: "", mode: "", frequencyHz: 0, detail: detail)
        items.insert(item, at: 0)
        if items.count > 200 { items.removeLast(items.count - 200) }
        deliver(item)
    }

    // MARK: - Lista

    func markAllRead() {
        for i in items.indices { items[i].read = true }
    }

    func clear() { items.removeAll() }

    func item(_ id: UUID) -> AlertItem? { items.first { $0.id == id } }

    /// Kliknięcie alertu (lista albo powiadomienie): oznaczenie jako przeczytany i prośba do okna o działanie.
    func activate(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].read = true
        NotificationCenter.default.post(name: .alertActivated, object: nil, userInfo: ["id": id])
    }

    // MARK: - Powiadomienia macOS

    /// Powiadomienia wymagają aplikacji spakowanej jako .app z identyfikatorem (build_app.sh / make_dmg.sh);
    /// przy uruchomieniu bez paczki zostają dźwięk i lista w oknie.
    static var canNotify: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private func setUpNotifications() {
        guard Self.canNotify else {
            notificationStatus = L("Powiadomienia macOS działają w zbudowanej aplikacji (.app); teraz - dźwięk i lista.")
            return
        }
        UNUserNotificationCenter.current().delegate = notificationDelegate
        if notificationsEnabled { requestAuthorization() }
    }

    private func requestAuthorization() {
        guard Self.canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                AlertCenter.shared.notificationStatus = granted ? ""
                    : L("macOS nie zezwala na powiadomienia - Ustawienia systemowe → Powiadomienia → FT-710 Control.")
            }
        }
    }
}

/// Kliknięcie powiadomienia macOS → ten sam efekt co kliknięcie alertu na liście; przy aktywnym oknie
/// powiadomienie też jest pokazywane (baner).
final class AlertNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let idText = response.notification.request.content.userInfo["alert"] as? String
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let idText, let id = UUID(uuidString: idText) { AlertCenter.shared.activate(id) }
        }
        completionHandler()
    }
}

extension Notification.Name {
    /// Kliknięto alert (userInfo["id"]: UUID) - okno główne stroi radio i wpisuje znak.
    static let alertActivated = Notification.Name("ft710.alertActivated")
}
