import SwiftUI

/// Zakładka EKRAN: wygląd skopu RF - paleta waterfalla, linia widma, tryb 2D / 3D.
/// Zmiany widać od razu na skopie nad zakładkami i są zapamiętywane.
struct DisplayView: View {
    @ObservedObject var display: DisplaySettings
    @AppStorage("scope.showCluster") private var showClusterOnScope = true
    @AppStorage("scope.showPOTA") private var showPOTAOnScope = true


    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            paletteBox
            spectrumBox
            scopeSpotsBox
            modeBox
            VStack(alignment: .leading, spacing: 8) {
                Button(L("Przywróć domyślne")) { display.resetToDefaults() }
                Text(L("Zmiany widać od razu na skopie i są zapamiętywane."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 170)
        }
    }

    private var paletteBox: some View {
        GroupBox(L("Kolory waterfalla")) {
            VStack(alignment: .leading, spacing: 8) {
                ColumnGrid(WaterfallPalette.allCases, id: \.self, columns: 3, spacing: 8) { palette in
                        Button { display.palette = palette } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(LinearGradient(gradient: palette.swiftUIGradient, startPoint: .leading, endPoint: .trailing))
                                    .frame(height: 22)
                                    .overlay(RoundedRectangle(cornerRadius: 3)
                                        .stroke(display.palette == palette ? Theme.accent : Color.white.opacity(0.15),
                                                lineWidth: display.palette == palette ? 2 : 1))
                                Text(palette.name)
                                    .font(.caption)
                                    .foregroundStyle(display.palette == palette ? Theme.accent : Theme.text)
                            }
                        }
                        .buttonStyle(.plain)
                }
                .frame(width: 3 * 150 + 2 * 8)                // kolumny po 150 pt, jak wcześniej
                Toggle(L("Ta sama paleta dla widma audio"), isOn: $display.audioSamePalette)
                    .font(.caption)
            }
            .padding(6)
        }
        .frame(width: 500)
    }

    private var spectrumBox: some View {
        GroupBox(L("Linia widma")) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Wysokość widma: {1}% skopu", Int((display.spectrumFraction * 100).rounded())))
                        .font(.caption)
                    Slider(value: $display.spectrumFraction, in: 0.15...0.6)
                }
                ColorPicker(L("Kolor linii"), selection: $display.traceColor, supportsOpacity: false)
                Toggle(L("Wypełnienie pod linią"), isOn: $display.traceFill)
                Toggle(L("Wypełnienie kolorami palety"), isOn: $display.fillWithPalette)
                    .disabled(!display.traceFill)
                    .help(L("Wypełnienie pod linią w kolorach palety waterfalla według poziomu (jak w programach SDR)"))
                Toggle(L("Peak hold (szczyty)"), isOn: $display.peakHold)
                    .help(L("Cienka linia szczytów, powoli opadająca - ułatwia wyłapanie krótkich sygnałów"))
            }
            .disabled(display.mode == .threeD)
            .padding(6)
        }
        .frame(width: 230)
    }

    /// Znaczniki stacji nad widmem skopu RF (kolory jak FT8 / kolumna DXCC / alerty).
    private var scopeSpotsBox: some View {
        GroupBox(L("Na skopie")) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(L("Spoty DX Cluster"), isOn: $showClusterOnScope)
                Toggle(L("Aktywacje POTA (zielona kreska)"), isOn: $showPOTAOnScope)
                Toggle(L("Skala dB"), isOn: $display.dbScale)
                    .help(L("Skala z lewej strony widma: 0 dB = góra skali, kreski co 10 dB (względnie - radio nie podaje poziomów w dBm)"))
                Toggle(L("Znaczniki czasu (UTC)"), isOn: $display.timeStamps)
                    .help(L("Godzina na waterfallu co kilka sekund - widać, kiedy ktoś nadawał"))
                Toggle(L("Plan pasma"), isOn: $display.bandPlan)
                    .help(L("Pasek pod waterfallem: CW, cyfrowe, SSB, radiolatarnie, FT8 i radiofonia (IARU Region 1, uproszczony)"))
                Text(L("Tło znaku: obserwowany, nowy kraj, kraj niepotwierdzony - jak w FT8; zwykły - bursztyn."))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
        .frame(width: 230)
    }

    private var modeBox: some View {
        GroupBox(L("Tryb wyświetlania")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $display.mode) {
                    ForEach(WaterfallMode.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Prędkość przesuwu (2D i 3D)")).font(.caption)
                    Picker("", selection: $display.speed) {
                        ForEach(DisplaySettings.speeds.indices, id: \.self) { index in
                            let option = DisplaySettings.speeds[index]
                            Text(L(option.name)).tag(option.value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Group {
                    slider(L("Głębia: {1} linii", Int(display.depth3D)), $display.depth3D, 20...100)
                    slider(L("Wysokość szczytów: {1}%", Int((display.height3D * 100).rounded())), $display.height3D, 0.2...0.8)
                    slider(L("Perspektywa: {1}%", Int((display.tilt3D * 100).rounded())), $display.tilt3D, 0...0.7)
                }
                .disabled(display.mode == .flat)
                Text(L("3D: ostatnie linie widma w perspektywie, kolor według wysokości sygnału. Strojenie kliknięciem działa według przedniej (najnowszej) linii."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
        .frame(width: 300)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption)
            Slider(value: value, in: range)
        }
    }
}
