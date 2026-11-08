import SwiftUI

/// Dzwonek w pasku zakładek: liczba nieprzeczytanych alertów; kliknięcie otwiera listę.
struct AlertBellButton: View {
    @ObservedObject var center = AlertCenter.shared
    @State private var showList = false

    var body: some View {
        Button { showList.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: center.unreadCount > 0 ? "bell.badge.fill" : "bell")
                Text(center.unreadCount > 0 ? "\(center.unreadCount)" : L("Alerty"))
                    .monospacedDigit()
            }
            .padding(.horizontal, 6)
        }
        .buttonStyle(RigButtonStyle(selected: center.unreadCount > 0, height: 22, fontSize: 11))
        .fixedSize()
        .help(L("Alerty: ktoś mnie woła, obserwowane znaki, nowe i niepotwierdzone kraje, nowe parki POTA"))
        .popover(isPresented: $showList, arrowEdge: .bottom) { AlertListView(center: center) }
    }
}

/// Lista alertów (najnowsze u góry); kliknięcie - strojenie i znak do dziennika, jak w źródle.
struct AlertListView: View {
    @ObservedObject var center: AlertCenter
    @State private var showSettings = false

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Alerty")).font(.headline)
                Spacer()
                Button(L("Przeczytane")) { center.markAllRead() }.disabled(center.unreadCount == 0)
                Button(L("Wyczyść")) { center.clear() }.disabled(center.items.isEmpty)
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .help(L("Ustawienia alertów"))
            }
            .controlSize(.small)
            if center.items.isEmpty {
                Text(L("Brak alertów. Pojawią się, gdy w DX Cluster, FT8 albo POTA trafi się coś, co zaznaczyłeś w ustawieniach."))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(center.items) { item in row(item) }
                    }
                }
                .frame(height: 360)
            }
            if !center.notificationStatus.isEmpty {
                Text(Lr(center.notificationStatus)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 520)
        .sheet(isPresented: $showSettings) { AlertSettingsView(center: center) }
    }

    private func row(_ item: AlertItem) -> some View {
        Button { center.activate(item.id) } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(Self.time.string(from: item.time)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
                Text(item.kind.name)
                    .font(.caption2.bold()).foregroundStyle(.black)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(item.kind.color, in: RoundedRectangle(cornerRadius: 3))
                    .frame(width: 150, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.call).bold()
                        if item.frequencyHz > 0 {
                            Text(String(format: "%.3f", Double(item.frequencyHz) / 1_000_000)).monospacedDigit()
                        }
                        Text(item.band + " " + item.mode).foregroundStyle(.secondary)
                        Text(item.origin.kind.name).font(.caption2).foregroundStyle(.secondary)
                    }
                    if !item.detail.isEmpty {
                        Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if !item.read { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
            }
            .font(.system(size: 12))
            .padding(.vertical, 3).padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(item.read ? Color.clear : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
        .help(item.kind == .confirmations ? L("Kliknij: okno dziennika")
                                          : L("Kliknij: radio na tę częstotliwość, znak do dziennika"))
    }
}

/// Ustawienia alertów: rodzaje (w kolejności pierwszeństwa), źródła, obserwowane znaki, pasma, dźwięk, powiadomienia.
struct AlertSettingsView: View {
    @ObservedObject var center: AlertCenter
    @Environment(\.dismiss) private var dismiss

    private static let allBands = ["160m", "80m", "60m", "40m", "30m", "20m", "17m", "15m", "12m", "10m", "6m", "4m", "2m", "70cm"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Ustawienia alertów")).font(.title3.bold())
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Rodzaje (od najważniejszego)")).font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(AlertKind.allCases) { kind in
                        Toggle(isOn: binding(kind)) {
                            Text(kind.name).foregroundStyle(.black)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(kind.color, in: RoundedRectangle(cornerRadius: 3))
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Źródła")).font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(AlertSourceKind.stationSources) { source in
                        Toggle(source.name, isOn: Binding(
                            get: { center.enabledSources.contains(source) },
                            set: { on in if on { center.enabledSources.insert(source) } else { center.enabledSources.remove(source) } }))
                        .toggleStyle(.checkbox)
                    }
                    Divider().padding(.vertical, 4)
                    Toggle(L("Dźwięk"), isOn: $center.soundEnabled).toggleStyle(.checkbox)
                        .help(L("Dźwięk przy alercie (wybór dźwięku obok)"))
                    HStack {
                        Picker("", selection: $center.soundName) {
                            ForEach(AlertCenter.sounds, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        Button(L("Odtwórz")) { center.playTest() }
                    }
                    .disabled(!center.soundEnabled)
                    Toggle(L("Powiadomienia macOS"), isOn: $center.notificationsEnabled).toggleStyle(.checkbox)
                    if !center.notificationStatus.isEmpty {
                        Text(Lr(center.notificationStatus)).font(.caption2).foregroundStyle(.secondary)
                            .frame(width: 260, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Obserwowane znaki (oddzielone spacją lub przecinkiem)")).font(.caption.bold()).foregroundStyle(.secondary)
                TextField(L("np. 3Y0K VP8PJ FT8WW"), text: $center.watchList)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Pasma (nic nie zaznaczone = wszystkie)")).font(.caption.bold()).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(Self.allBands, id: \.self) { band in
                        Button(band) {
                            if center.bands.contains(band) { center.bands.remove(band) } else { center.bands.insert(band) }
                        }
                        .buttonStyle(RigButtonStyle(selected: center.bands.contains(band), height: 20, fontSize: 10))
                        .fixedSize()
                    }
                }
            }
            Text(L("Ten sam znak, rodzaj alertu i pasmo - najwyżej raz na 30 minut (wywołanie w FT8 - co 2 minuty). Dźwięk i powiadomienie najwyżej co 5 s; spoty przysłane hurtem po połączeniu z klastrem i pierwsza lista POTA nie alarmują."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("Domyślne")) { center.enabledKinds = AlertKind.defaultEnabled }
                Spacer()
                Button(L("Zamknij")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 640)
    }

    private func binding(_ kind: AlertKind) -> Binding<Bool> {
        Binding(get: { center.enabledKinds.contains(kind) },
                set: { on in if on { center.enabledKinds.insert(kind) } else { center.enabledKinds.remove(kind) } })
    }
}
