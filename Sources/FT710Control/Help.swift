import SwiftUI

/// Temat pomocy w dwóch językach. Treść: Markdown w wierszu (pogrubienie, `kod`, linki), nowe linie zachowane.
struct HelpTopic: Identifiable {
    let id: String
    let icon: String
    let titlePL: String
    let titleEN: String
    let bodyPL: String
    let bodyEN: String

    var title: String { AppLanguage.current == .en ? titleEN : titlePL }
    var body: String { AppLanguage.current == .en ? bodyEN : bodyPL }
}

/// Okno pomocy: tematy z wyszukiwarką po lewej, treść po prawej, w języku interfejsu.
struct HelpView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.current.rawValue
    @State private var selection: String? = HelpContent.topics.first?.id
    @State private var search = ""

    private var filtered: [HelpTopic] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return HelpContent.topics }
        return HelpContent.topics.filter { $0.title.lowercased().contains(query) || $0.body.lowercased().contains(query) }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection) { topic in
                Label(topic.title, systemImage: topic.icon).tag(topic.id)
            }
            .searchable(text: $search, placement: .sidebar, prompt: L("Szukaj w pomocy"))
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            if let topic = HelpContent.topics.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(topic.title, systemImage: topic.icon)
                            .font(.title2.bold())
                        Text(Self.render(topic.body))
                            .font(.body)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: 720, alignment: .leading)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(L("Wybierz temat z listy.")).foregroundStyle(.secondary)
            }
        }
        .id(languageCode)                              // zmiana języka przebudowuje treść
        .navigationTitle(L("Pomoc FT-710 Control"))
        .frame(minWidth: 820, minHeight: 560)
    }

    private static func render(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

/// Menu Pomoc: „Pomoc FT-710 Control” (⌘?) otwiera okno pomocy.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(L("Pomoc FT-710 Control")) { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}

enum HelpContent {
    static let topics: [HelpTopic] = [
        HelpTopic(id: "start", icon: "play.circle", titlePL: "Pierwsze kroki", titleEN: "Getting started",
                  bodyPL: """
**Połączenie z radiem**
1. Połącz FT-710 kablem USB (gniazdo USB z tyłu radia) i włącz radio.
2. W radiu ustaw prędkość CAT: MENU → OPERATION SETTING → GENERAL → **CAT RATE = 38400**.
3. W pasku stanu (dół okna) wybierz port. Radio tworzy dwa porty o podobnych nazwach (np. `…C0` i `…C1`) – CAT działa na **pierwszym** z pary.
4. Wybierz prędkość **38400** i kliknij **Połącz** (albo Enter).

Po połączeniu w środku okna pojawi się częstotliwość, a obok przycisków strojenia napis „Połączono z FT-710”. Jeśli widać „Brak odpowiedzi”, wybierz drugi port z pary albo sprawdź CAT RATE.

**Zapamiętywanie:** po udanym połączeniu program zapamiętuje port i prędkość. Przy zaznaczonym **Auto** (pasek stanu) łączy się sam przy starcie; gdy radio jest wyłączone, czeka i łączy się, gdy port się pojawi. Ręczne „Rozłącz” zatrzymuje te próby. Waterfall (skop RF) startuje domyślnie – jeśli go wyłączysz, program to zapamięta.

**Język**
Polski / English wybierasz w pasku stanu. Zmiana działa od razu, bez rozłączania radia.

**Okna**
• Główne okno – panel radia i zakładki narzędzi.
• Dziennik łączności – pełna lista QSO, import/eksport ADIF, ustawienia stacji i QRZ.
• Pomoc – to okno (⌘?).
""",
                  bodyEN: """
**Connecting to the radio**
1. Connect the FT-710 with a USB cable (USB socket on the back of the radio) and turn the radio on.
2. On the radio set the CAT speed: MENU → OPERATION SETTING → GENERAL → **CAT RATE = 38400**.
3. In the status bar (bottom of the window) choose the port. The radio creates two ports with similar names (e.g. `…C0` and `…C1`) – CAT works on the **first** one.
4. Choose **38400** and click **Connect** (or press Enter).

Once connected, the frequency appears in the middle of the window and “Connected to FT-710” next to the tuning buttons. If you see “No response”, pick the other port of the pair or check CAT RATE.

**Remembering:** after a successful connection the program remembers the port and speed. With **Auto** checked (status bar) it connects by itself at start-up; if the radio is off, it waits and connects when the port appears. A manual “Disconnect” stops these attempts. The waterfall (RF scope) starts by default – if you turn it off, the program remembers that.

**Language**
Polski / English is selected in the status bar. The change is immediate and does not disconnect the radio.

**Windows**
• Main window – radio panel and tool tabs.
• Logbook – full QSO list, ADIF import/export, station and QRZ settings.
• Help – this window (⌘?).
"""),

        HelpTopic(id: "profile", icon: "person.crop.circle", titlePL: "Profil stacji", titleEN: "Station profile",
                  bodyPL: """
Okno **Profil stacji** otwiera się przy pierwszym uruchomieniu, a później z menu **FT710Control → Profil stacji…** (⇧⌘,).

• **Język** programu – Polski / English.
• **Twoja stacja:** znak, imię i nazwisko, QTH, lokator, kraj, DXCC / CQ / ITU.
• **Pobierz z QRZ** – po wpisaniu znaku wypełnia pozostałe pola danymi z QRZ.com. Jeśli konto QRZ nie jest jeszcze zapisane, można je podać w tym samym oknie (hasło trafia do pęku kluczy macOS).
• **HamQTH.com** (bezpłatnie) – darmowa baza znaków: imię, QTH, lokator, kraj i strefy. Działa sama (bez konta QRZ) albo razem z QRZ: gdy QRZ nie zna znaku albo bez subskrypcji XML nie podaje lokatora i adresu, braki uzupełnia HamQTH. Konto zakłada się na hamqth.com; hasło trafia do pęku kluczy. Z wyszukiwania korzysta cały program: dziennik, karta stacji, „Uzupełnij z QRZ”, zawody, panel zdalny.
• Mapka pokazuje położenie według lokatora – szybka kontrola, czy lokator jest poprawny.

**Gdzie program używa tych danych**
• Dziennik: „Mój znak” i „Mój lokator” – odległości, azymuty, mapa trasy.
• Każda zapisana łączność (także z WSJT-X): pola ADIF `MY_NAME`, `MY_CITY`, `MY_COUNTRY`, `MY_DXCC`, `MY_CQ_ZONE`, `MY_ITU_ZONE` – trafiają do eksportu i usług online.
• DX Cluster: logowanie Twoim znakiem (gdy pole „Znak” w zakładce klastra jest puste).
• Usługi online: znak dla eQSL, HRDLog.net i Club Log, jeśli nie był jeszcze ustawiony.
""",
                  bodyEN: """
The **Station profile** window opens on first launch, and later from the **FT710Control → Station profile…** menu (⇧⌘,).

• Program **language** – Polski / English.
• **Your station:** call sign, name, QTH, grid, country, DXCC / CQ / ITU.
• **Fetch from QRZ** – after entering your call, fills the other fields from QRZ.com. If no QRZ account is saved yet, it can be entered in the same window (the password goes to the macOS Keychain).
• **HamQTH.com** (free) – a free callbook: name, QTH, locator, country and zones. Works on its own (no QRZ account) or together with QRZ: when QRZ does not know a call or (without an XML subscription) gives no locator and address, HamQTH fills the gaps. Create an account at hamqth.com; the password goes to the keychain. The whole program uses the lookup: the log, the station card, “Fill from QRZ”, contests, the remote panel.
• The map shows the location from your grid – a quick check that the grid is correct.

**Where the program uses this data**
• Logbook: “My call” and “My grid” – distances, bearings, path map.
• Every logged QSO (also from WSJT-X): ADIF fields `MY_NAME`, `MY_CITY`, `MY_COUNTRY`, `MY_DXCC`, `MY_CQ_ZONE`, `MY_ITU_ZONE` – included in exports and online services.
• DX Cluster: login with your call sign (when the “Call” field in the cluster tab is empty).
• Online services: call sign for eQSL, HRDLog.net and Club Log, if not set yet.
"""),

        HelpTopic(id: "vfo", icon: "dial.medium", titlePL: "VFO i strojenie", titleEN: "VFO and tuning",
                  bodyPL: """
**Wyświetlacze VFO-A i VFO-B**
• **Kółko myszy nad cyfrą** zmienia tę cyfrę (nad setkami herców – o 100 Hz, nad kHz – o 1 kHz itd.). Kółko w górę zawsze zwiększa częstotliwość.
• **Kliknięcie cyfry** zaznacza ją: **↑ / ↓** zmienia cyfrę, **← / →** przechodzi do sąsiedniej, **Esc** kończy.
• **Pole obok trybu** – wpisanie częstotliwości i Enter: `7.074` (MHz), `7074` lub `7074.5` (kHz), `7074000` lub `7.074.000` (Hz); można dopisać jednostkę, np. `21.074MHz`.

**Informacje pod częstotliwością**
• VFO-A: tryb, **RX BW** (szerokość filtra), **TX BW** (pasmo nadawania SSB z menu radia), **AGC**, **STEP** (krok strojenia przycisków −/+), a także włączone funkcje: AMP1/AMP2, ATT, NB, DNR, NOTCH, DNF, CONT (wyróżnione kolorem).
• Drugie VFO (po prawej): jego tryb (odczytywany co ok. 3 s; „–”, jeśli radio go nie podaje), STEP i SPLIT przy pracy z rozstawem.

**Zmiana pasma** – przycisk pasma ustawia częstotliwość i **tryb SSB z właściwą wstęgą**: LSB poniżej 10 MHz (160/80/40 m), USB od 10 MHz w górę oraz na 60 m. Prawy przycisk na panelu „Pasmo” zmienia to zachowanie: „tylko popraw wstęgę, gdy jest SSB” (CW i DATA zostają) albo „nie zmieniaj trybu”.

**Przyciski pod VFO**
• **− / +** – strojenie o wybrany **KROK** (10 Hz … 10 kHz).
• **A/B** – przełącza, na którym VFO pracuje radio (jak przycisk A/B w radiu); częstotliwości A i B zostają na miejscu. **Aktywne VFO jest zawsze wyświetlane po lewej jako główne** – po A/B okna zamieniają się miejscami – i to jego częstotliwość oraz tryb trafiają do dziennika, skopu, spotów, pamięci, CAT Share i pracy zdalnej; przyciski trybu (LSB, USB, CW…) zmieniają tryb aktywnego VFO. Każde VFO ma własny tryb, który wędruje razem z jego częstotliwością. Program odczytuje aktywne VFO z radia; gdyby radio nie odpowiadało na ten odczyt, śledzi tylko własny przycisk A/B (przełączenia z panelu radia nie byłyby wtedy widoczne).
• **A=B** – kopiowanie VFO-A do VFO-B (VFO-A bez zmian), np. przed ustawieniem SPLIT.
• **SPLIT** – odbiór na VFO-A, nadawanie na VFO-B. Przy SPLIT VFO-A ma oznaczenie RX, VFO-B – TX; podczas nadawania na czerwono świeci VFO-B.

**Pasma i tryby (lewa kolumna)**
• Przycisk pasma ustawia typową częstotliwość pasma.
• **CW** i **DATA** – ponowne kliknięcie przełącza wstęgę (CW-U ↔ CW-L, DATA-U ↔ DATA-L).
""",
                  bodyEN: """
**VFO-A and VFO-B displays**
• **Mouse wheel over a digit** changes that digit (over the hundreds of hertz – by 100 Hz, over kHz – by 1 kHz, etc.). Wheel up always increases the frequency.
• **Click a digit** to select it: **↑ / ↓** change it, **← / →** move to the neighbouring digit, **Esc** ends.
• **Field next to the mode** – type a frequency and press Enter: `7.074` (MHz), `7074` or `7074.5` (kHz), `7074000` or `7.074.000` (Hz); a unit may be added, e.g. `21.074MHz`.

**Information below the frequency**
• VFO-A: mode, **RX BW** (filter width), **TX BW** (SSB transmit band from the radio menu), **AGC**, **STEP** (tuning step of the −/+ buttons), plus enabled functions: AMP1/AMP2, ATT, NB, DNR, NOTCH, DNF, CONT (highlighted).
• The second VFO (on the right): its mode (read about every 3 s; “–” if the radio does not report it), STEP and SPLIT when working split.

**Band change** – a band button sets the frequency and **SSB with the correct sideband**: LSB below 10 MHz (160/80/40 m), USB from 10 MHz up and on 60 m. Right-click the “Band” panel to change this: “only correct the sideband when in SSB” (CW and DATA stay) or “do not change the mode”.

**Buttons below the VFOs**
• **− / +** – tune by the selected **STEP** (10 Hz … 10 kHz).
• **A/B** – switches which VFO the radio operates on (like the radio's A/B button); the A and B frequencies stay put. **The active VFO is always shown on the left as the main one** – after A/B the displays swap places – and its frequency and mode go to the log, scope, spots, memories, CAT Share and remote operation; the mode buttons (LSB, USB, CW…) change the active VFO's mode. Each VFO has its own mode, which travels with its frequency. The program reads the active VFO from the radio; if the radio did not answer that read, it only tracks its own A/B button (switches made on the radio panel would then not be visible).
• **A=B** – copy VFO-A to VFO-B (VFO-A unchanged), e.g. before setting SPLIT.
• **SPLIT** – receive on VFO-A, transmit on VFO-B. With SPLIT on, VFO-A is marked RX and VFO-B TX; while transmitting, VFO-B is lit red.

**Bands and modes (left column)**
• A band button sets a typical frequency of that band.
• **CW** and **DATA** – clicking again switches the sideband (CW-U ↔ CW-L, DATA-U ↔ DATA-L).
"""),

        HelpTopic(id: "dsp", icon: "waveform.path", titlePL: "Filtr, AGC i redukcja szumów", titleEN: "Filter, AGC and noise reduction",
                  bodyPL: """
**RX DSP / Filtr** (lewa kolumna)
• Wykres pokazuje pasmo przepustowe w zakresie audio 0–4 kHz: trapez = szerokość i SHIFT, czerwone wcięcie = NOTCH, bursztynowe przegięcie = CONTOUR, znacznik DNF.
• **RX BW** – szerokość filtra (obok opisu indeks zgłoszony przez radio). W AM/FM szerokość jest stała.
• **SHIFT** – przesunięcie pasma (krok 20 Hz), przycisk **0** zeruje.
• **NOTCH** (ręczny) z częstotliwością, **DNF** (automatyczny notch), **CONTOUR** z częstotliwością.
• **AGC**: FAST / MID / SLOW / AUTO.

**Prawa kolumna**
• **AF, SQL, RF** – głośność, blokada szumów, wzmocnienie w.cz.; **TX** – moc nadajnika.
• **IPO / AMP1 / AMP2** – przedwzmacniacz, **ATT** – tłumik.
• **DNR, NB, PROC** – suwak z wyłączaniem: **0 = OFF**, powyżej zera – włączone z tym poziomem.
• **MIC, AMC** – poziom mikrofonu i automatycznej kontroli mocy.

Ustawienia są odczytywane z radia po połączeniu i co ok. 3 s, więc zmiany gałkami na radiu też są widoczne. Kontrolka wyszarzona = radio nie odpowiedziało na jej komendę (lista w zakładce LOG CAT).
""",
                  bodyEN: """
**RX DSP / Filter** (left column)
• The graph shows the passband in the 0–4 kHz audio range: trapezoid = width and SHIFT, red notch = NOTCH, amber dip = CONTOUR, DNF marker.
• **RX BW** – filter width (the index reported by the radio is shown next to it). In AM/FM the width is fixed.
• **SHIFT** – passband shift (20 Hz steps), the **0** button resets it.
• **NOTCH** (manual) with frequency, **DNF** (automatic notch), **CONTOUR** with frequency.
• **AGC**: FAST / MID / SLOW / AUTO.

**Right column**
• **AF, SQL, RF** – volume, squelch, RF gain; **TX** – transmitter power.
• **IPO / AMP1 / AMP2** – preamplifier, **ATT** – attenuator.
• **DNR, NB, PROC** – slider with off position: **0 = OFF**, above zero – on at that level.
• **MIC, AMC** – microphone gain and automatic power control.

Settings are read from the radio after connecting and about every 3 s, so changes made with the radio's knobs show up too. A greyed-out control = the radio did not answer its command (listed in the CAT LOG tab).
"""),

        HelpTopic(id: "tx", icon: "antenna.radiowaves.left.and.right", titlePL: "Nadawanie i bezpieczeństwo", titleEN: "Transmitting and safety",
                  bodyPL: """
Nadawanie z aplikacji jest celowo zabezpieczone – wszystkie elementy w bloku na dole prawej kolumny.

• **Odblokuj TX** – bez tej zgody PTT, TUNE i komunikaty są nieaktywne. Wyłączenie zgody zawsze kończy nadawanie.
• **Limit czasu** (1 / 3 / 5 min) – po upływie aplikacja sama wysyła TX0 i blokuje PTT do puszczenia przycisku. Obejmuje PTT z aplikacji, komunikaty z pamięci radia i TUNE (ręczny mikrofon przy radiu – nie).
• **PTT** – nadawanie tylko podczas trzymania przycisku myszą.
• **TUNE** – ON/OFF włącza tuner, przycisk TUNE uruchamia strojenie (radio nadaje nośną).
• **Komunikaty** (CQ, Call, …) – odtwarzają komunikaty nagrane w pamięci radia (fonia w SSB/AM/FM, CW w CW). Opis przycisku: prawy przycisk → „Zmień opis…”. **STOP** zatrzymuje komunikat i kończy nadawanie.

**Zawsze wysyłane jest TX0:** przy rozłączeniu, zamknięciu okna lub programu (także Ctrl+C w Terminalu), wyłączeniu zgody, upływie limitu.

**SSTV, CW i RTTY:** długość obrazu SSTV oraz tekstu CW i RTTY jest sprawdzana z limitem **przed** nadaniem; SSTV i RTTY kończą nadawanie, gdy radio przestanie nadawać, a cofnięcie zgody albo rozłączenie radia zatrzymuje je niezależnie od otwartej zakładki. CW kluczowane jest linią DTR/RTS drugiego portu radia – z pominięciem strażnika czasu CAT – dlatego STOP, cofnięcie zgody na TX albo rozłączenie radia natychmiast zwalnia klucz, niezależnie od otwartej zakładki.

Pierwsze próby nadawania rób na sztucznym obciążeniu, przy małej mocy, obserwując ALC i SWR.
""",
                  bodyEN: """
Transmitting from the app is deliberately protected – all controls are in the block at the bottom of the right column.

• **Enable TX** – without this consent PTT, TUNE and messages are inactive. Turning it off always ends transmission.
• **Time limit** (1 / 3 / 5 min) – when it expires the app sends TX0 itself and locks PTT until the button is released. It covers PTT from the app, radio memory messages and TUNE (not the hand microphone at the radio).
• **PTT** – transmits only while the button is held with the mouse.
• **TUNE** – ON/OFF switches the tuner, the TUNE button starts tuning (the radio transmits a carrier).
• **Messages** (CQ, Call, …) – play messages recorded in the radio's memory (voice in SSB/AM/FM, CW in CW). Button label: right-click → “Edit label…”. **STOP** stops the message and ends transmission.

**TX0 is always sent:** on disconnect, when closing the window or the program (also Ctrl+C in Terminal), when consent is turned off, when the limit expires.

**SSTV, CW and RTTY:** the length of an SSTV image and of CW and RTTY text is checked against the limit **before** sending; SSTV and RTTY stop when the radio stops transmitting, and withdrawing consent or disconnecting the radio stops them whichever tab is open. CW is keyed with the DTR/RTS line of the radio's second port – bypassing the CAT time watchdog – so STOP, withdrawing TX consent or disconnecting the radio releases the key immediately, whichever tab is open.

Make your first transmit tests into a dummy load at low power, watching ALC and SWR.
"""),

        HelpTopic(id: "scope", icon: "waveform", titlePL: "Skop RF i waterfall", titleEN: "RF scope and waterfall",
                  bodyPL: """
Skop pokazuje te same dane co wyświetlacz radia, odczytywane przez wbudowany mostek FTDI FT4222.

**Wymagania (jednorazowo)**
1. W radiu: MENU → OPERATION SETTING → GENERAL → **SCU-LAN10 = ON**, potem odłącz i podłącz kabel USB. „Diagnostyka USB” musi pokazywać `0403:601C FT4222`.
2. Biblioteki FTDI w `/usr/local/lib`: **libft4222** (pakiet „LibFT4222 for Mac”) i **libftd2xx** (pakiet D2XX dla macOS) – szczegóły w README.
3. Skop może czytać tylko jeden program naraz.

**Obsługa**
• **Włączony** – start/stop odczytu. Span i tryb CENTER/FIX ustawia się w radiu.
• Czerwona linia = VFO-A; najechanie pokazuje częstotliwość, **kliknięcie stroi VFO-A**.
• **Auto** dobiera tło do poziomu szumu; **Kontrast** i szybkość waterfalla – w pasku skopu.
• Znaki nad linią widma to **spoty z DX Cluster** i **aktywacje POTA** (rzędy dobierane tak, żeby się nie zasłaniały). **Tło znaku** jak kolory w FT8, kolumna DXCC i alerty: turkus – obserwowany znak, magenta – nowy kraj, jasnoróżowe – nowy kraj na paśmie, fiolet – kraj niepotwierdzony, jasny fiolet – niepotwierdzony na paśmie, **bursztyn** – nic z tych rzeczy. **POTA** ma zieloną kreskę i zieloną obwódkę (podpowiedź: park i jego nazwa; ten sam znak w klastrze i POTA – pokazany jako POTA). **Kliknięcie w znak albo jego kreskę** stroi radio dokładnie na stację, wpisuje znak (przy POTA także park) do formularza dziennika i otwiera zakładkę DZIENNIK; kliknięcie kolejnej stacji podmienia znak. Wyłączanie: zakładka EKRAN → **Stacje na skopie**.
• **Przewijanie:** przeciągnij widmo myszą w lewo/prawo, przesuń dwoma palcami w bok na gładziku albo użyj Shift + kółko myszy. **Zwykłe kółko** nad skopem stroi radio krokiem STEP (jak gałka VFO). W trybie CENTER radio trzyma VFO w środku skopu, więc przewinięcie przestraja VFO, a obraz jedzie za nim; w trybie FIX zakres skopu stoi, a zmienia się tylko VFO.
• **Zapisz ramki** zapisuje surowe ramki na Biurko (do diagnozy), **Log** – przebieg połączenia z FT4222.
""",
                  bodyEN: """
The scope shows the same data as the radio's display, read through the built-in FTDI FT4222 bridge.

**Requirements (once)**
1. On the radio: MENU → OPERATION SETTING → GENERAL → **SCU-LAN10 = ON**, then unplug and replug the USB cable. “USB diagnostics” must show `0403:601C FT4222`.
2. FTDI libraries in `/usr/local/lib`: **libft4222** (“LibFT4222 for Mac” package) and **libftd2xx** (D2XX for macOS) – details in the README.
3. Only one program at a time can read the scope.

**Using it**
• **On** – start/stop reading. Span and CENTER/FIX mode are set on the radio.
• Red line = VFO-A; hovering shows the frequency, **clicking tunes VFO-A**.
• **Auto** sets the floor to the noise level; **Contrast** and waterfall speed are in the scope bar.
• Call signs above the spectrum line are **DX Cluster spots** and **POTA activations** (rows chosen so they do not overlap). **Label background** as the FT8 colours, the DXCC column and alerts: cyan – watched call, magenta – new entity, light pink – new entity on band, purple – unconfirmed entity, light purple – unconfirmed on band, **amber** – none of these. **POTA** has a green line and a green outline (tooltip: park and its name; the same call in the cluster and POTA is shown as POTA). **Clicking a call or its line** tunes the radio exactly to the station, puts the call (for POTA also the park) in the logbook form and opens the LOG tab; clicking another station replaces the call. Turning off: DISPLAY tab → **Stations on the scope**.
• **Scrolling:** drag the spectrum left/right with the mouse, swipe sideways with two fingers on a trackpad, or use Shift + mouse wheel. The **plain wheel** over the scope tunes the radio by the STEP (like the VFO knob). In CENTER mode the radio keeps the VFO in the middle of the scope, so scrolling retunes the VFO and the picture follows; in FIX mode the scope range stays put and only the VFO changes.
• **Save frames** saves raw frames to the Desktop (for diagnosis), **Log** – the FT4222 connection log.
"""),

        HelpTopic(id: "display", icon: "paintpalette", titlePL: "Ekran – kolory i tryb 3D", titleEN: "Display – colours and 3D mode",
                  bodyPL: """
Zakładka **EKRAN** zmienia wygląd skopu RF. Zmiany widać od razu na skopie i są zapamiętywane.

**Kolory waterfalla:** Klasyczna, **Turbo (SDR)** (granatowy szum, sygnały od zieleni do czerwieni – jak w nowoczesnych programach SDR), **Inferno** (fiolet → pomarańcz → biel), Ogień, Morska, Zielony fosfor, Tęcza, Skala szarości – kliknij podgląd palety. Zmiana przemalowuje od razu całą historię waterfalla. „Ta sama paleta dla widma audio” stosuje ją też w zakładce WIDMO AUDIO.
**Nowoczesny skop:** **Wypełnienie kolorami palety** (ramka Linia widma) – pod linią widma kolory palety waterfalla według poziomu, jak w programach SDR. **Peak hold** – cienka, jasna linia szczytów, powoli opadająca (ok. 6 s), od nowa po strojeniu i zmianie zakresu. W ramce **Na skopie**: **Skala dB** z lewej strony widma (0 dB = góra skali, kreski co 10 dB – względnie, bo radio nie podaje poziomów w dBm), **Znaczniki czasu (UTC)** na waterfallu co kilka sekund (odstęp dobierany do prędkości przesuwu) i **Plan pasma** – pasek pod waterfallem z odcinkami IARU Region 1: CW, cyfrowe, SSB, radiolatarnie, FT8 (+3 kHz od częstotliwości wybierania) oraz pasma radiofonii. Waterfall skopu RF ma pełną rozdzielczość radia (850 punktów) i dłuższą historię. Widok całego zakresu 0–64 MHz, jak w odbiornikach SDR, nie jest możliwy – FT-710 podaje tylko dane swojego skopu.

**Linia widma:** wysokość widma jako część skopu (reszta to waterfall), kolor linii, wypełnienie pod linią.

**Tryb wyświetlania**
• **2D – waterfall** – linia widma i waterfall (jak dotąd).
• **Prędkość przesuwu** (szybko / średnio / wolno / bardzo wolno) – wspólna dla waterfalla 2D i widoku 3D, ta sama co przełącznik „Waterfall” w pasku skopu. Przy wolnym przesuwie każda linia jest maksimum z pominiętych ramek, więc krótkie sygnały (np. CW) nie znikają.
• **3D – perspektywa** – ostatnie linie widma ułożone w głąb, kolor według wysokości sygnału; widać, jak sygnały pojawiają się i znikają w czasie. Ustawienia: **głębia** (liczba linii), **wysokość szczytów**, **perspektywa** (zwężenie w głąb).
• W 3D strojenie kliknięciem i kursor częstotliwości działają według przedniej (najnowszej) linii; znaki spotów DX Cluster są u góry.
• Widok 3D jest rysowany w tle, najwyżej ok. 15 razy na sekundę – nie spowalnia programu. Przy słabszym komputerze zmniejsz głębię.

**Na skopie** – znaki nad widmem skopu RF: przełączniki **Spoty DX Cluster** i **Aktywacje POTA (zielona kreska)**. Tło znaku jak kolory w FT8 i alertach (obserwowany, nowy kraj, kraj niepotwierdzony), zwykły – bursztyn; stacja już zrobiona na tym paśmie – bez fioletu. Szczegóły: temat „Skop RF i waterfall”.

**Przywróć domyślne** – paleta klasyczna, tryb 2D, widmo 30% wysokości.
""",
                  bodyEN: """
The **DISPLAY** tab changes how the RF scope looks. Changes appear on the scope immediately and are remembered.

**Waterfall colours:** Classic, **Turbo (SDR)** (navy noise, signals from green to red – as in modern SDR programs), **Inferno** (purple → orange → white), Fire, Ocean, Green phosphor, Rainbow, Grayscale – click a palette preview. The change recolours the whole waterfall history at once. “Same palette for the audio spectrum” also applies it in the AUDIO SPECTRUM tab.
**Modern scope:** **Fill with palette colours** (Spectrum trace box) – under the trace, the waterfall palette colours by level, as in SDR programs. **Peak hold** – a thin, bright line of peaks, slowly decaying (about 6 s), restarted after tuning and a range change. In the **On the scope** box: a **dB scale** on the left of the spectrum (0 dB = top of the scale, marks every 10 dB – relative, as the radio gives no dBm levels), **Time stamps (UTC)** on the waterfall every few seconds (the interval follows the scroll speed) and a **Band plan** – a strip under the waterfall with IARU Region 1 segments: CW, digital, SSB, beacons, FT8 (+3 kHz from the dial frequency) and broadcast bands. The RF scope waterfall has the radio's full resolution (850 points) and a longer history. A view of the whole 0–64 MHz range, as in SDR receivers, is not possible – the FT-710 only provides its own scope data.

**Spectrum line:** spectrum height as a share of the scope (the rest is the waterfall), line colour, fill under the line.

**Display mode**
• **2D – waterfall** – spectrum line and waterfall (as before).
• **Scroll speed** (fast / medium / slow / very slow) – shared by the 2D waterfall and the 3D view, the same as the “Waterfall” switch in the scope bar. At slow speeds each line is the maximum of the skipped frames, so short signals (e.g. CW) do not disappear.
• **3D – perspective** – the latest spectrum lines arranged in depth, coloured by signal height; you can see signals appear and disappear over time. Settings: **depth** (number of lines), **peak height**, **perspective** (narrowing into the distance).
• In 3D, click tuning and the frequency cursor follow the front (newest) line; DX Cluster spot calls are at the top.
• The 3D view is drawn in the background, at most about 15 times per second – it does not slow the program down. On a slower computer reduce the depth.

**On the scope** – call signs above the RF scope spectrum: the **DX Cluster spots** and **POTA activations (green line)** switches. The label background as the FT8 colours and alerts (watched, new entity, unconfirmed entity), ordinary – amber; a station already worked on this band – no purple. Details: the “RF scope and waterfall” topic.

**Restore defaults** – classic palette, 2D mode, spectrum 30% of the height.
"""),

        HelpTopic(id: "log", icon: "book", titlePL: "Dziennik, QRZ.com i mapa", titleEN: "Logbook, QRZ.com and map",
                  bodyPL: """
**Zapis łączności** (zakładka LOG)
• Wpisz znak – po chwili dane z QRZ uzupełnią puste pola (imię, QTH, lokator). Tryb dobiera się do trybu radia, RST do trybu.
• Enter lub **Zapisz QSO**. Częstotliwość i pasmo pochodzą z radia, czas w UTC (początek = wpisanie pierwszej litery znaku).
• Pod formularzem od razu widać, czy stacja już była: **NOWA STACJA**, **NOWE PASMO**, **NOWY TRYB** albo **ZROBIONE** (to pasmo i tryb), oraz ostatnie łączności z nią (data, pasmo, tryb, raporty). Znaki z dodatkami (`SP5XX/P`) są łączone ze znakiem podstawowym.
• **Wpisywane QSO nie ginie**: znak i pozostałe pola zostają po przejściu na inną zakładkę i powrocie. Gdy ta sama stacja zostanie zalogowana inną drogą (FT8 po RR73/73, łączność z WSJT-X, ZAWODY), formularz czyści się sam i pokazuje „Zapisano … o … UTC”; inny, właśnie wpisywany znak zostaje nietknięty.

**Karta stacji** (po prawej): miejsce, odległość (km/mi), azymut z kierunkiem świata i drogą długą (LP), mapa z trasą po kole wielkim (przybliżanie: przyciski + / − / ⟲, kółko myszy, szczypanie na gładziku), dane DXCC/CQ/ITU. Kliknięcie QSO w tabeli pokazuje jego stację. Znak w tabeli to link do QRZ.com.

**Okno dziennika** (przycisk „Otwórz dziennik”)
• **Mój znak** i **Mój lokator** – potrzebne do odległości i do pól ADIF.
• **QRZ.com** – użytkownik i hasło (hasło w pęku kluczy macOS). Pełne dane wymagają subskrypcji „XML Logbook Data”.
• **Edycja łączności:** podwójne kliknięcie QSO, przycisk **Edytuj…** albo prawy przycisk → „Edytuj…” (także w tabeli w zakładce LOG). Można zmienić znak, czas UTC, częstotliwość (zawsze w MHz, np. 144.176; można dopisać kHz albo GHz – dziennik obsługuje wszystkie pasma od 2200 m do 3 cm, także łączności z innych radiotelefonów), tryb, raporty, imię, QTH, lokator, kraj i uwagi; „Uzupełnij z QRZ” wypełnia puste pola. Pozostałe pola ADIF (np. potwierdzenia QSL z importu) zostają bez zmian.
• **Prawy przycisk na łączności** (okno dziennika i tabela w zakładce DZIENNIK):
   – **Uzupełnij z QRZ.com** – dla jednej lub wielu zaznaczonych łączności wypełnia tylko puste pola (imię, QTH, lokator, kraj, DXCC, strefy CQ/ITU) i przelicza odległość; niczego nie nadpisuje. **Stacja spoza swojego kraju** (np. P4/WE9V z Aruby, FM/VE3DZ z Martyniki): QRZ opisuje jej dom, więc z QRZ brane jest tylko imię, a kraj, strefy i kontynent – z prefiksu przed ukośnikiem (cty.dat), tak jak w Club Log i LoTW; QTH, lokator i odległość z domowego adresu nie są wpisywane, a numer DXCC uzupełni potwierdzenie z LoTW. To samo dotyczy formularza wpisu i edycji QSO. /P, /M i zmiana okręgu (W1AW/4) to ten sam kraj.
   – **Wyślij SPOT…** – przygotowuje komendę klastra, np. `DX 14025.0 DL1ABC CW 599 tnx QSO`, przełącza na zakładkę DX CLUSTER i wpisuje ją w pole komendy. Spot nie jest wysyłany automatycznie – popraw komentarz i kliknij „Wyślij”.
• **Usuń cały dziennik…** – wymaga wpisania słowa USUŃ; przed usunięciem program zapisuje kopię (`logbook-przed-usunieciem-….json` w katalogu danych).
• **Potwierdzenia QSL…** (okno dziennika) – pobiera potwierdzenia i oznacza nimi łączności:
  – **LoTW** – login i hasło do **strony** lotw.arrl.org (nie hasło certyfikatu TQSL) w „Usługi online…” → LoTW. Pobierane są tylko nowe potwierdzenia od ostatniego razu, razem z danymi stacji potwierdzającej (kraj DXCC, strefy, lokator – uzupełniają puste pola).
  – **eQSL** – skrzynka odbiorcza (eQSL od korespondentów); te same dane co do wysyłki. Gdy masz kilka QTH w eQSL, QTH Nickname musi się zgadzać.
  – **QRZ Logbook** – łączności potwierdzone w QRZ (klucz API; pobieranie wymaga subskrypcji QRZ).
  – **Club Log** – dopasowania dzienników: łączność jest potwierdzona, gdy korespondent też wysłał ją do Club Log (±15 min; te same dane co do wysyłki – hasło aplikacji i klucz API). Uznawane w dyplomach IOTA, **nie** w DXCC ARRL, więc nie wchodzą do statystyk. Przy okazji numer DXCC z mapowania Club Log uzupełnia puste pole łączności.
  – **Import z pliku ADIF** – np. eksport z HRDLog.net (ten serwis nie ma interfejsu pobierania potwierdzeń), raport LoTW albo plik z innego programu; brane są pola LOTW_QSL_RCVD, EQSL_QSL_RCVD, APP_QRZLOG_STATUS.
  – **Od początku** – wszystkie potwierdzenia, nie tylko nowe (pierwszy raz; LoTW przy dużym dzienniku nawet kilka minut).
  – **Automatycznie raz dziennie** (domyślnie włączone): 2 minuty po starcie programu i potem co godzinę program pobiera nowe potwierdzenia z serwisów, z których ostatnie pobranie było ponad dobę temu, i daje znać alertem, np. „5 nowych potwierdzeń – LoTW · nowy potwierdzony kraj: Malawi” (kliknięcie otwiera okno dziennika). Przy każdym serwisie widać godzinę następnego pobrania.
  Dopasowanie jak zaleca ARRL: znak (także z /P), pasmo i czas ±30 min; tryb rozstrzyga tylko przy kilku pasujących łącznościach. Potwierdzenia bez łączności w dzienniku są pokazane w osobnej liście.
• Kolumna **QSL** w tabeli: **L** – LoTW, **E** – eQSL, **Q** – QRZ, **C** – Club Log. Filtr **Wszystkie / Potwierdzone / Niepotwierdzone** obok wyszukiwania. Do dyplomu DXCC ARRL liczy się tylko LoTW – eQSL i QRZ można dołączyć do statystyk w oknie potwierdzeń („licz też…”). Potwierdzenia zaimportowane wcześniej z innego programu (te same pola ADIF) są rozpoznawane od razu.
• **Mapa łączności…** (okno dziennika) – Twoje łączności na **kuli ziemskiej 3D** (obraz satelitarny z rzeźbą terenu; po oddaleniu globus – na Macach z procesorem Apple, na Intel płaska mapa). Obracanie myszą lub gładzikiem, przybliżanie kółkiem, szczypaniem albo przyciskami + / − / ⟲. **Kolory**: pasmo (jak na mapie propagacji), emisja (CW, fonia, FT8, FT4, RTTY, inne cyfrowe) albo potwierdzenie (LoTW, opcjonalnie eQSL/QRZ). **Filtry**: pasmo, emisja, okres (cały okres, 24 godziny, 30 dni, 12 miesięcy, ten rok), kontynent, tylko potwierdzone. **Linie po kole wielkim** od Twojej stacji (przy wielu punktach warto zawęzić filtry). Położenie z lokatora, a bez niego – środek kraju z cty.dat (**punkty przybliżone**, półprzezroczyste; można je ukryć). Punkty są rysowane jedną warstwą, więc mapa działa płynnie także przy tysiącach łączności; gęste obszary rozdzielają się po przybliżeniu. Legenda z liczbami, na dole statystyka (QSO, kraje, kontynenty, najdalsza łączność); **kliknięcie punktu** (przy dowolnym przybliżeniu) – żółty znacznik z dymkiem, szczegóły na dole i **Edytuj…**.
• **Dyplomy…** (okno dziennika) – zakładki **DXCC**, **WAZ**, **WPX**, **VUCC**, **POTA**, wszystkie w tym samym układzie: podsumowanie u góry, tabela z kolumną dla każdego pasma (✓ – potwierdzone na paśmie, W – zrobione bez potwierdzenia; pozycja na pomarańczowo – bez żadnego potwierdzenia), wiersz „Razem”, filtr „Bez potwierdzenia”, wyszukiwanie, sortowanie (kolejność, nazwa, pierwsze QSO), **Eksport CSV**. Potwierdzenie: LoTW, a eQSL i QRZ – jeśli zaznaczysz „licz też…”.
  – **DXCC** (ARRL) – kraje w kategoriach **mieszane**, **fonia** (SSB, AM, FM, SSTV), **CW**, **cyfrowe**; zrobione z wszystkich aktualnych jednostek, potwierdzone z najbliższym progiem (100, 150… Honor Roll), suma kraj-pasmo do **DXCC Challenge** (160–6 m). Kraj z cty.dat (także znaki przenośne; kraje WAE, np. IT9, liczone jak DXCC – Włochy).
  – **WAZ** (CQ) – 40 stref CQ: zrobione i potwierdzone z 40, **lista brakujących stref** i stref bez potwierdzenia. Strefa z pola CQZ łączności, a gdy go brak – z cty.dat.
  – **WPX** (CQ) – prefiksy znaków wg zasad WPX: SP5XTF → SP5, 3Z9X → 3Z9, S50A → S50, RAEM → RA0, W1AW/4 → W4, DL/SP5XTF → DL0; przyrostki /P /M /MM /QRP pomijane.
  – **VUCC** (ARRL) – kwadraty lokatora (4 znaki) na pasmach od 6 m; przy każdym paśmie potwierdzone kwadraty i próg dyplomu (6 m i 2 m – 100, 1,25 m i 70 cm – 50, wyżej – 25).
  – **POTA** – upolowane parki z dziennika (POTA_REF / SIG_INFO), z datą pierwszej łączności, stacją i pasmami; POTA nie wymaga potwierdzeń QSL.
  – **IOTA** (RSGB) – wyspy z pola IOTA (np. EU-005), z potwierdzeniami; **SOTA** – szczyty (SOTA_REF), **WWFF** – obszary przyrodnicze (WWFF_REF) – liczone z dziennika; numery także z pól SIG/SIG_INFO zapisanych przez inne programy.
  – **PGA** – polskie gminy: łączności z SP z kodem gminy w polu CNTY (wpisywanym w oknie edycji QSO → **Referencje dyplomów**).
• **Plik i kopie** (menu po prawej nad tabelą) – import i eksport ADIF, kopia w iCloud (włączenie, „Zrób kopię teraz”, „Pokaż w Finderze”), przywracanie z kopii i usuwanie całego dziennika. Nad tabelą zostają: wyszukiwanie i filtry (pierwszy wiersz) oraz Edytuj…, Usuń…, Statystyki…, Mapa łączności…, Dyplomy…, Potwierdzenia QSL… i Usługi online… (drugi wiersz).
• **Kopia w iCloud** (domyślnie włączona) – dodatkowa kopia poza Makiem, w iCloud Drive, folder **FT-710 Control/Kopie dziennika**: plik `dziennik-RRRR-MM-DD.json` z każdego dnia (30 ostatnich dni) i `dziennik-najnowszy.adi` z całym dziennikiem w formacie ADIF – otworzy go każdy program do logowania, także na innym komputerze. Kopia jest aktualizowana najwyżej co 10 minut po zmianach i przy zamykaniu programu; pusty dziennik nigdy nie nadpisuje kopii. Menu **iCloud**: stan ostatniej kopii, **Zrób kopię teraz**, **Pokaż w Finderze**. Wymaga włączonego iCloud Drive (Ustawienia systemowe → Apple ID → iCloud); przy pierwszej kopii macOS może zapytać o dostęp do iCloud Drive.
• **Przywróć z kopii…** – lista kopii (stan z ostatniego uruchomienia, sprzed usunięcia, sprzed przywrócenia, kopie dnia z iCloud Drive) z datą i liczbą QSO albo dowolny plik kopii. **Dołącz do dziennika** dodaje brakujące łączności (duplikaty są pomijane), **Zastąp dziennik…** podmienia cały dziennik po potwierdzeniu – wcześniej zapisując kopię bieżącego stanu.
• **Import ADIF** najpierw sprawdza plik i pokazuje podgląd: ile łączności jest nowych, ile to **duplikaty** (lista z łącznością, z którą się pokrywają) i ile rekordów jest błędnych. Zapisywane są tylko nowe, po kliknięciu „Importuj nowe”. Duplikat = ten sam znak, pasmo, tryb (SSB/USB/LSB traktowane jako SSB) i czas w odstępie do 10 minut; wykrywane są też rekordy powtórzone w samym pliku. Te same zasady obowiązują przy QSO z WSJT-X i przy dołączaniu kopii.
• **Usuwanie łączności:** zaznacz jedną albo kilka (⌘/⇧ + kliknięcie) i naciśnij **Delete**, przycisk **Usuń…** albo prawy przycisk → „Usuń…” – z potwierdzeniem; pojedynczą łączność można też usunąć w oknie edycji (**Usuń łączność…**). **Usuwanie w serwisach:** jeśli łączność była wysłana do **Club Log** albo **QRZ Logbook**, okno potwierdzenia ma zaznaczone „Usuń także w serwisach” – program usuwa ją tam od razu (Club Log: najwyżej 10 łączności naraz, więcej – ręcznie w Club Log; QRZ: numer łączności zapamiętany przy wysyłce, a dla starszych wyszukany w QRZ po znaku, paśmie i czasie). **LoTW** z zasady nie pozwala usuwać wysłanych łączności, a w **eQSL** i pozostałych serwisach trzeba je usunąć ręcznie na stronie – okno o tym przypomina. Odznaczenie pól usuwa łączność tylko z dziennika w programie. (Log zawodów ma osobne usuwanie – zakładka ZAWODY.)
• **Wyszukiwanie i filtry** nad tabelą: szukanie po znaku, kraju i imieniu; pasmo, emisja (CW, fonia, FT8, FT4, RTTY, inne cyfrowe), okres (24 godziny, 30 dni, 12 miesięcy, ten rok) i potwierdzenia – łączą się ze sobą. **Sortowanie** – kliknięcie nagłówka kolumny (data, znak, pasmo, częstotliwość, QSL, kraj, lokator, uwagi).
• **Statystyki…** – podsumowanie (łączności, różne stacje, kraje DXCC, dni z łącznościami, najlepszy dzień) i wykresy: łączności w latach, pasma, emisje, kontynenty, godziny UTC; wybór okresu.
• **Referencje dyplomów** w oknie edycji QSO: gmina (CNTY), IOTA, SOTA, WWFF, POTA – standardowe pola ADIF.
• **Import i eksport ADIF** (ADIF 3.1.4, z polami COUNTRY, DXCC, CQZ, ITUZ, DISTANCE).
• **Odbieraj QSO z WSJT-X / JTDX** – w WSJT-X: Settings → Reporting → UDP Server `127.0.0.1`, port `2237`.

Dane: `~/Library/Application Support/FT710Control/logbook.json` (kopia przy każdym uruchomieniu).
""",
                  bodyEN: """
**Logging a QSO** (LOG tab)
• Type the call sign – after a moment QRZ data fills empty fields (name, QTH, grid). The mode follows the radio, RST follows the mode.
• Press Enter or **Log QSO**. Frequency and band come from the radio, time is UTC (start = typing the first letter of the call).
• Below the form you immediately see whether the station was worked before: **NEW STATION**, **NEW BAND**, **NEW MODE** or **WORKED** (this band and mode), plus the latest QSOs with it (date, band, mode, reports). Calls with suffixes (`SP5XX/P`) are matched to the base call.
• **The QSO being entered is kept**: the call and other fields stay when you switch to another tab and back. When the same station is logged another way (FT8 after RR73/73, a QSO from WSJT-X, CONTEST), the form clears itself and shows “Logged … at … UTC”; a different call you are typing is left untouched.

**Station card** (right): location, distance (km/mi), bearing with compass direction and long path (LP), map with the great-circle path (zoom: + / − / ⟲ buttons, mouse wheel, pinch on the trackpad), DXCC/CQ/ITU data. Clicking a QSO in the table shows its station. The call sign in the table links to QRZ.com.

**Logbook window** (“Open logbook” button)
• **My call** and **My grid** – needed for distance and ADIF fields.
• **QRZ.com** – username and password (the password is stored in the macOS Keychain). Full data requires the “XML Logbook Data” subscription.
• **Editing a QSO:** double-click it, use **Edit…** or right-click → “Edit…” (also in the table in the LOG tab). Call sign, UTC time, frequency (always in MHz, e.g. 144.176; kHz or GHz may be added – the log supports all bands from 2200 m to 3 cm, including QSOs made with other radios), mode, reports, name, QTH, grid, country and notes can be changed; “Fill from QRZ” fills empty fields. Other ADIF fields (e.g. QSL confirmations from an import) stay unchanged.
• **Right-click a QSO** (logbook window and the table in the LOG tab):
   – **Fill from QRZ.com** – for one or more selected QSOs fills only empty fields (name, QTH, grid, country, DXCC, CQ/ITU zones) and recalculates the distance; nothing is overwritten. **A station operating away from its country** (e.g. P4/WE9V from Aruba, FM/VE3DZ from Martinique): QRZ describes its home, so only the name is taken from QRZ, and the country, zones and continent come from the prefix before the slash (cty.dat), as in Club Log and LoTW; the QTH, grid and distance from the home address are not filled in, and the DXCC number is filled in by the LoTW confirmation. The same applies to the entry form and QSO editing. /P, /M and a district change (W1AW/4) are the same country.
   – **Send SPOT…** – prepares a cluster command, e.g. `DX 14025.0 DL1ABC CW 599 tnx QSO`, switches to the DX CLUSTER tab and puts it in the command field. The spot is not sent automatically – adjust the comment and click “Send”.
• **Delete entire logbook…** – requires typing the word DELETE; before deleting, the program saves a backup (`logbook-przed-usunieciem-….json` in the data folder).
• **QSL confirmations…** (logbook window) – downloads confirmations and marks the QSOs:
  – **LoTW** – login and password for the lotw.arrl.org **website** (not the TQSL certificate password) in “Online services…” → LoTW. Only confirmations new since the last time are downloaded, with the confirming station's data (DXCC entity, zones, locator – they fill empty fields).
  – **eQSL** – the inbox (eQSLs from your contacts); the same credentials as for uploading. With several QTHs in eQSL the QTH Nickname must match.
  – **QRZ Logbook** – QSOs confirmed in QRZ (API key; downloading requires a QRZ subscription).
  – **Club Log** – log matches: a QSO is confirmed when the other station has also uploaded it to Club Log (±15 min; the same credentials as for uploading – application password and API key). Accepted for IOTA awards, **not** for ARRL DXCC, so they are not counted in the statistics. The DXCC number from Club Log's mapping also fills an empty field of the QSO.
  – **Import from an ADIF file** – e.g. an export from HRDLog.net (this service has no confirmation download interface), a LoTW report or a file from another program; the fields LOTW_QSL_RCVD, EQSL_QSL_RCVD, APP_QRZLOG_STATUS are used.
  – **From the start** – all confirmations, not only new ones (the first time; LoTW can take several minutes for a large log).
  – **Automatically once a day** (on by default): 2 minutes after the program starts and then every hour the program downloads new confirmations from services last downloaded more than a day ago and lets you know with an alert, e.g. “5 new confirmations – LoTW · newly confirmed entity: Malawi” (clicking it opens the logbook window). Each service shows the time of the next download.
  Matching as recommended by ARRL: call (also with /P), band and time ±30 min; the mode only decides between several matching QSOs. Confirmations without a QSO in the log are shown in a separate list.
• The **QSL** column in the table: **L** – LoTW, **E** – eQSL, **Q** – QRZ, **C** – Club Log. The **All / Confirmed / Unconfirmed** filter next to the search. Only LoTW counts for the ARRL DXCC award – eQSL and QRZ can be added to the statistics in the confirmations window (“also count…”). Confirmations imported earlier from another program (the same ADIF fields) are recognised immediately.
• **QSO map…** (logbook window) – your QSOs on a **3D globe** (satellite imagery with terrain; zoomed out a globe – on Apple silicon Macs, on Intel a flat map). Rotate with the mouse or trackpad, zoom with the wheel, a pinch or the + / − / ⟲ buttons. **Colours**: band (as on the propagation map), mode (CW, phone, FT8, FT4, RTTY, other digital) or confirmation (LoTW, optionally eQSL/QRZ). **Filters**: band, mode, period (whole period, 24 hours, 30 days, 12 months, this year), continent, confirmed only. **Great-circle lines** from your station (with many points it is worth narrowing the filters). Location from the locator, otherwise the middle of the country from cty.dat (**approximate points**, semi-transparent; they can be hidden). Points are drawn as a single layer, so the map stays smooth even with thousands of QSOs; dense areas separate when zoomed in. A legend with counts, statistics at the bottom (QSOs, entities, continents, farthest QSO); **clicking a point** (at any zoom) – a yellow marker with a callout, details at the bottom and **Edit…**.
• **Awards…** (logbook window) – the **DXCC**, **WAZ**, **WPX**, **VUCC**, **POTA** tabs, all with the same layout: a summary at the top, a table with a column for each band (✓ – confirmed on the band, W – worked but not confirmed; an item in orange – no confirmation at all), the “Total” row, the “Not confirmed” filter, search, sorting (order, name, first QSO), **Export CSV**. Confirmation: LoTW, plus eQSL and QRZ if “also count…” is ticked.
  – **DXCC** (ARRL) – entities in the **mixed**, **phone** (SSB, AM, FM, SSTV), **CW**, **digital** categories; worked out of all current entities, confirmed with the next threshold (100, 150… Honor Roll), the entity-band total for the **DXCC Challenge** (160–6 m). Entity from cty.dat (including portable calls; WAE entities such as IT9 count as their DXCC entity – Italy).
  – **WAZ** (CQ) – 40 CQ zones: worked and confirmed out of 40, the **list of missing zones** and of zones without confirmation. Zone from the QSO's CQZ field, or from cty.dat if it is missing.
  – **WPX** (CQ) – call sign prefixes by the WPX rules: SP5XTF → SP5, 3Z9X → 3Z9, S50A → S50, RAEM → RA0, W1AW/4 → W4, DL/SP5XTF → DL0; the suffixes /P /M /MM /QRP are ignored.
  – **VUCC** (ARRL) – grid squares (4 characters) on bands from 6 m up; for each band the confirmed grids and the award threshold (6 m and 2 m – 100, 1.25 m and 70 cm – 50, higher – 25).
  – **POTA** – parks hunted from the log (POTA_REF / SIG_INFO), with the date of the first QSO, the station and the bands; POTA does not need QSL confirmations.
  – **IOTA** (RSGB) – islands from the IOTA field (e.g. EU-005), with confirmations; **SOTA** – summits (SOTA_REF), **WWFF** – nature areas (WWFF_REF) – counted from the log; references also from SIG/SIG_INFO saved by other programs.
  – **PGA** – Polish gminas: QSOs with SP stations with a gmina code in the CNTY field (entered in the QSO edit window → **Award references**).
• **File and backups** (the menu on the right above the table) – ADIF import and export, the iCloud backup (switch, “Back up now”, “Show in Finder”), restoring from a backup and deleting the whole logbook. Above the table remain: search and filters (first row) and Edit…, Delete…, Statistics…, QSO map…, Awards…, QSL confirmations… and Online services… (second row).
• **iCloud backup** (on by default) – an extra copy off the Mac, in iCloud Drive, folder **FT-710 Control/Kopie dziennika**: a `dziennik-YYYY-MM-DD.json` file for each day (last 30 days) and `dziennik-najnowszy.adi` with the whole log in ADIF format – any logging program can open it, also on another computer. The backup is updated at most every 10 minutes after changes and when the program quits; an empty log never overwrites the backup. The **iCloud** menu: status of the last backup, **Back up now**, **Show in Finder**. Requires iCloud Drive to be on (System Settings → Apple ID → iCloud); on the first backup macOS may ask for access to iCloud Drive.
• **Restore from backup…** – list of backups (state at the last start, before deleting, before restoring, daily backups from iCloud Drive) with date and QSO count, or any backup file. **Add to logbook** adds missing QSOs (duplicates are skipped), **Replace logbook…** replaces the whole logbook after confirmation – backing up the current state first.
• **ADIF import** checks the file first and shows a preview: how many QSOs are new, how many are **duplicates** (listed with the QSO they match) and how many records are invalid. Only new QSOs are saved, after clicking “Import new”. Duplicate = same call, band, mode (SSB/USB/LSB count as SSB) and time within 10 minutes; records repeated within the file itself are detected too. The same rules apply to QSOs from WSJT-X and when adding a backup.
• **Deleting QSOs:** select one or several (⌘/⇧ + click) and press **Delete**, the **Delete…** button or right-click → “Delete…” – with confirmation; a single QSO can also be deleted in the edit window (**Delete QSO…**). **Deleting in services:** if the QSO was uploaded to **Club Log** or **QRZ Logbook**, the confirmation window has “Also delete in services” ticked – the program deletes it there at once (Club Log: at most 10 QSOs at a time, more – manually in Club Log; QRZ: the QSO number remembered at upload, for older ones looked up in QRZ by call, band and time). **LoTW** by design does not allow deleting uploaded QSOs, and in **eQSL** and the other services they have to be deleted manually on the website – the window reminds you. Unticking the boxes deletes the QSO only from the program’s logbook. (The contest log has its own deletion – CONTEST tab.)
• **Search and filters** above the table: search by call, entity and name; band, mode (CW, phone, FT8, FT4, RTTY, other digital), period (24 hours, 30 days, 12 months, this year) and confirmations – they combine. **Sorting** – click a column header (date, call, band, frequency, QSL, entity, locator, comment).
• **Statistics…** – a summary (QSOs, unique stations, DXCC entities, days with QSOs, best day) and charts: QSOs by year, bands, modes, continents, UTC hours; period selection.
• **Award references** in the QSO edit window: gmina (CNTY), IOTA, SOTA, WWFF, POTA – standard ADIF fields.
• **ADIF import and export** (ADIF 3.1.4, with COUNTRY, DXCC, CQZ, ITUZ, DISTANCE).
• **Receive QSOs from WSJT-X / JTDX** – in WSJT-X: Settings → Reporting → UDP Server `127.0.0.1`, port `2237`.

Data: `~/Library/Application Support/FT710Control/logbook.json` (backed up at every start).
"""),

        HelpTopic(id: "services", icon: "icloud.and.arrow.up", titlePL: "Usługi online (LoTW, QRZ, eQSL, WRL…)", titleEN: "Online services (LoTW, QRZ, eQSL, WRL…)",
                  bodyPL: """
Okno dziennika → **Usługi online…**. Po lewej lista usług ze stanem (brak danych logowania / wysyłka automatyczna / ostatnia wysyłka), po prawej ustawienia wybranej usługi.

**Obsługiwane usługi**
• **LoTW** – podpis i wysyłka programem **TQSL** (ARRL). Potrzebny zainstalowany TQSL z certyfikatem i lokalizacją stacji; w ustawieniach podaj ścieżkę do TQSL (domyślnie `/Applications/TrustedQSL/…`) i nazwę lokalizacji stacji. **Hasło certyfikatu**: domyślnie program go nie przekazuje – jeśli certyfikat ma hasło, TQSL sam o nie zapyta w swoim okienku przy podpisywaniu (hasło nie przechodzi przez program). Przełącznik „Przekazuj hasło certyfikatu do TQSL automatycznie” jest wygodniejszy przy automatycznej wysyłce, ale TQSL przyjmuje hasło tylko w linii poleceń, więc na czas podpisywania widzą je inne programy na tym Macu. Do **pobierania potwierdzeń** potrzebne są też login i hasło do **strony** lotw.arrl.org (nie hasło certyfikatu) – pola pod ustawieniami TQSL; pobieranie: okno dziennika → **Potwierdzenia QSL…**.
• **QRZ Logbook** – klucz API z QRZ: Logbook → Settings → API. Wysyłka wymaga subskrypcji QRZ.
• **eQSL** – użytkownik i hasło jak na eqsl.cc, opcjonalnie QTH Nickname.
• **Club Log** – e-mail, znak, hasło aplikacji oraz klucz API. Klucz identyfikuje program, nie użytkownika – prosi się o niego raz, po zalogowaniu na clublog.org/requestapikey.php. Pojedyncze QSO idą od razu po zapisie (realtime.php); **Wyślij zaległe** wysyła zaległe jednym plikiem ADIF (putlogs.php) – Club Log zabrania seryjnej wysyłki przez realtime.php. Po każdym błędzie (kod HTTP inny niż 200, złe hasło, odrzucony klucz) automatyczna wysyłka do Club Log zostaje **wstrzymana** – kolejne QSO nie ponawiają prób, żeby nie zablokować konta; po poprawieniu ustawień kliknij **Wyślij zaległe**.
• **HRDLog.net** – znak i kod wysyłania (Upload Code) z profilu na hrdlog.net.
• **Cloudlog / Wavelog** – adres własnego serwera, ID profilu stacji i klucz API z prawem zapisu.
• **World Radio League** – klucz API z WRL (Integrations → Developer API). ID dziennika jest opcjonalne: bez niego łączności trafiają do dziennika domyślnego; **Test** pokaże listę dzienników z ID, jeśli domyślnego nie ma. WRL przyjmuje najwyżej 60 łączności na minutę – „Wyślij zaległe” wysyła je co sekundę.

**Wysyłka**
• **Wysyłaj automatycznie po zapisaniu QSO** – nowa łączność (zapis ręczny albo z WSJT-X) od razu trafia do włączonych usług. Wynik widać pod formularzem w zakładce LOG, np. „SP5XX: LoTW ✓ · QRZ Logbook ✓”.
• **Import pliku ADIF niczego nie wysyła** – żeby nie wysłać ponownie starego dziennika.
• **Wyślij zaległe (N)** – wysyła łączności jeszcze niewysłane do tej usługi (np. po błędzie albo braku internetu).
• **Oznacz wszystkie jako wysłane…** – gdy dziennik był już wysłany innym programem.
• Duplikat zgłoszony przez usługę jest traktowany jak „już wysłane”, nie jak błąd.
• **Test** sprawdza dane logowania (Club Log i HRDLog.net nie mają testu – sprawdzenie następuje przy pierwszej wysyłce).

Stan wysyłki każdej łączności jest zapisywany w standardowych polach ADIF (np. `LOTW_QSL_SENT`, `QRZCOM_QSO_UPLOAD_STATUS`, `EQSL_QSL_SENT`), więc przechodzi do eksportu; widać go też w edycji łączności. Hasła i klucze API są w pęku kluczy macOS.

Poprawka łączności po wysłaniu jest automatycznie przesyłana tylko do **World Radio League** (jedyny serwis z interfejsem do poprawek). W pozostałych usługach popraw ją na stronie usługi.
""",
                  bodyEN: """
Logbook window → **Online services…**. On the left, the list of services with their state (no credentials / auto-upload / last upload), on the right the settings of the selected service.

**Supported services**
• **LoTW** – signing and upload with **TQSL** (ARRL). TQSL must be installed with a certificate and a station location; in the settings give the path to TQSL (default `/Applications/TrustedQSL/…`) and the station location name. **Certificate passphrase**: by default the program does not pass it – if the certificate has a passphrase, TQSL asks for it in its own window when signing (the passphrase does not pass through the program). The “Pass the certificate passphrase to TQSL automatically” switch is more convenient for automatic uploads, but TQSL accepts the passphrase only on the command line, so other programs on this Mac can see it while signing. **Downloading confirmations** also needs the login and password for the lotw.arrl.org **website** (not the certificate password) – the fields below the TQSL settings; downloading: logbook window → **QSL confirmations…**.
• **QRZ Logbook** – API key from QRZ: Logbook → Settings → API. Uploading requires a QRZ subscription.
• **eQSL** – user and password as on eqsl.cc, optionally the QTH Nickname.
• **Club Log** – e-mail, call sign, application password and an API key. The key identifies the program, not the user – request it once after logging in at clublog.org/requestapikey.php. Single QSOs go right after logging (realtime.php); **Upload pending** sends the backlog as one ADIF file (putlogs.php) – Club Log forbids serial uploads through realtime.php. After any error (HTTP code other than 200, wrong password, rejected key) automatic uploads to Club Log are **paused** – new QSOs do not retry, so the account is not locked; after fixing the settings click **Upload pending**.
• **HRDLog.net** – call sign and Upload Code from your hrdlog.net profile.
• **Cloudlog / Wavelog** – your server address, station profile ID and a read/write API key.
• **World Radio League** – API key from WRL (Integrations → Developer API). The logbook ID is optional: without it QSOs go to the default logbook; **Test** lists your logbooks with IDs if there is no default. WRL accepts at most 60 QSOs per minute – “Upload pending” sends one per second.

**Uploading**
• **Upload automatically after logging a QSO** – a new QSO (logged manually or from WSJT-X) is sent to the enabled services right away. The result is shown under the form in the LOG tab, e.g. “SP5XX: LoTW ✓ · QRZ Logbook ✓”.
• **Importing an ADIF file uploads nothing** – so an old log is not sent again.
• **Upload pending (N)** – uploads QSOs not yet sent to that service (e.g. after an error or no internet).
• **Mark all as sent…** – when the log was already uploaded by another program.
• A duplicate reported by a service counts as “already sent”, not as an error.
• **Test** checks the credentials (Club Log and HRDLog.net have no test – they are checked on the first upload).

Each QSO's upload state is stored in standard ADIF fields (e.g. `LOTW_QSL_SENT`, `QRZCOM_QSO_UPLOAD_STATUS`, `EQSL_QSL_SENT`), so it carries over to exports; it is also shown in the QSO editor. Passwords and API keys are kept in the macOS Keychain.

Edits made after uploading are sent automatically only to **World Radio League** (the only service with an update interface). In the other services, correct the QSO on the service's website.
"""),

        HelpTopic(id: "cluster", icon: "dot.radiowaves.up.forward", titlePL: "DX Cluster", titleEN: "DX Cluster",
                  bodyPL: """
• Menu **Węzły** – polski węzeł **dxcluster.pl:7300** (domyślny) i przykładowe węzły zagraniczne (CC Cluster, DXSpider, AR-Cluster, Reverse Beacon Network); można wpisać dowolny adres i port.
• **Znak** – pusty = „Mój znak” z okna dziennika. Logowanie odbywa się automatycznie.
• **Łącz automatycznie** – połączenie przy starcie i ponawianie co 30 s po zerwaniu.
• **Hasło** – tylko dla węzłów, które go wymagają (Enter zapisuje je w pęku kluczy). Program wysyła je po monicie „password:”.
• **Ostatnie spoty po połączeniu** – po zalogowaniu program wysyła `sh/dx 30`, więc tabela od razu się zapełnia.
• Licznik „X z Y spotów” pokazuje, ile spotów jest widocznych po filtrach, a ile odebrano – przy filtrze „moje pasmo” spoty z innych pasm są ukryte.

**Spoty**
• Kolumna **Dziennik**: **nowy** (brak w logu), **inne pasmo**, **✓ pasmo** (już zrobiony na tym paśmie).
• Kolumna **DXCC**: kraj spotu na tle w kolorze jak w FT8 – **magenta** nowy kraj, **jasnoróżowy** nowy na paśmie, **fiolet** kraj niepotwierdzony, **jasny fiolet** niepotwierdzony na tym paśmie; bez tła – potwierdzony na tym paśmie (podpowiedź po najechaniu kursorem). Kraj z bazy cty.dat.
• **Kliknięcie** spotu wpisuje znak do formularza dziennika (bez zmiany zakładki), **podwójne kliknięcie** stroi radio (opcjonalnie ustawia tryb). Przy FT8/FT4 radio trafia na standardową częstotliwość, np. 14.074.
• Filtry: pasmo (wszystkie / moje / wybrane), **tryb**: CW, SSB, cyfrowe – wszystkie, FT8, FT4, RTTY, PSK, JS8, Q65, inne cyfrowe (emisja z komentarza spotu albo z częstotliwości FT8), „Ukryj zrobione na tym paśmie”.
• Prawy przycisk: Dostrój / Otwórz w QRZ.com.
• Konsola węzła przyjmuje komendy, np. `sh/dx 20`, `set/filter`.

Spoty z ostatnich 30 minut pojawiają się też na skopie RF.
""",
                  bodyEN: """
• **Nodes** menu – the Polish node **dxcluster.pl:7300** (default) and sample foreign nodes (CC Cluster, DXSpider, AR-Cluster, Reverse Beacon Network); any address and port can be entered.
• **Call** – empty = “My call” from the logbook window. Login is automatic.
• **Connect automatically** – connects at start-up and retries every 30 s after a dropped connection.
• **Password** – only for nodes that require one (Enter saves it in the Keychain). The program sends it after the “password:” prompt.
• **Recent spots after connecting** – after login the program sends `sh/dx 30`, so the table fills right away.
• The “X of Y spots” counter shows how many spots are visible after filters and how many were received – with the “my band” filter, spots from other bands are hidden.

**Spots**
• **Log** column: **new** (not in the log), **other band**, **✓ band** (already worked on this band).
• **DXCC** column: the spot's entity on a background coloured as in FT8 – **magenta** new entity, **light pink** new on band, **purple** unconfirmed entity, **light purple** unconfirmed on this band; no background – confirmed on this band (tooltip on hover). Entity from cty.dat.
• **Clicking** a spot puts the call in the logbook form (without switching tabs), **double-click** tunes the radio (optionally sets the mode). For FT8/FT4 the radio goes to the standard frequency, e.g. 14.074.
• Filters: band (all / mine / selected), **mode**: CW, SSB, digital – all, FT8, FT4, RTTY, PSK, JS8, Q65, other digital (mode from the spot comment or the FT8 frequency), “Hide worked on this band”.
• Right-click: Tune / Open on QRZ.com.
• The node console accepts commands, e.g. `sh/dx 20`, `set/filter`.

Spots from the last 30 minutes also appear on the RF scope.
"""),

        HelpTopic(id: "sstv", icon: "photo.on.rectangle", titlePL: "SSTV – obrazy", titleEN: "SSTV – images",
                  bodyPL: """
Zakładka **SSTV**: odbiór i nadawanie obrazów. Dekoder i nadajnik są częścią programu (własny kod, bez zewnętrznych programów).

**Przyciski pasm** (panel strojenia, 80–6 m): typowe częstotliwości wywoławcze SSTV (3,733, 7,165, 14,230, 18,160, 21,340, 24,975, 28,680, 50,680 MHz); poniżej 10 MHz **DATA-L**, powyżej **DATA-U** – jak fonia. Program pamięta ostatnią częstotliwość SSTV na każdym paśmie; prawy przycisk – powrót do domyślnej. Zmiana pasma przerywa nadawanie.

**Tryby:** Martin M1 i M2, Scottie S1 i S2, Robot 36, PD 90, PD 120, PD 180. Tryb rozpoznawany jest automatycznie po nagłówku **VIS**.

**Odbiór**
1. Radio w **USB** (albo DATA-U), typowe częstotliwości: 14,230 / 21,340 / 28,680 MHz.
2. Włącz **odsłuch** (zakładka AUDIO albo przycisk w części STROJENIE) – dekoder korzysta z dźwięku z radia.
3. Obraz rysuje się linia po linii; po zakończeniu trafia do **galerii** (`Obrazy/FT710Control SSTV`, nazwa z datą UTC, trybem i częstotliwością).
• Dekoder sam koryguje **rozstrojenie** do ok. ±200 Hz i **pochylenie** obrazu (różnice zegarów kart dźwiękowych).
• Gdy nadawanie urwie się w połowie, zostaje zapisana odebrana część obrazu.
• **Strojenie:** widmo audio ze znacznikami SYNC (1200 Hz), 1500, VIS (1900 Hz) i 2300 Hz oraz wskaźnik bieżącego tonu – nagłówek VIS powinien wypadać na 1900 Hz.

**Dziennik** (kolumna po prawej)
• Znak z wyszukiwaniem w QRZ/HamQTH (imię, QTH i lokator uzupełniają się same; dla stacji spoza swojego kraju tylko imię), kraj i informacja „nowa stacja” albo „było: N QSO”.
• **RSV** wysłany i odebrany (domyślnie 595): czytelność 1–5, siła 1–9, jakość obrazu 1–5.
• Tryb odebranego obrazka (np. „SSTV Martin 1”) trafia sam do uwag.
• **Zapisz QSO** (albo ⌘↩) – tryb SSTV, częstotliwość z radia, zapis jak w dzienniku programu (kraj, strefy, odległość, wysyłka do serwisów). Do DXCC SSTV liczy się jako Phone (zasady ARRL).

**Nadawanie**
• Obraz z pliku (**Obraz…**), **plansza testowa** albo odebrany obraz (**Odeślij**). Obraz jest skalowany do rozdzielczości trybu (z przycięciem), z nakładką: Twój znak u góry i własny tekst u dołu (np. „UR 595 TNX”).
• **NADAJ** wymaga połączenia z radiem, zaznaczenia **Odblokuj TX** i wybranego urządzenia „Do radia (TX)” w zakładce AUDIO. PTT włącza się i wyłącza samo.
• Czas obrazu jest sprawdzany z **limitem nadawania** – PD 180 (ok. 188 s) wymaga limitu 5 min.
• **STOP** albo cofnięcie zgody na TX natychmiast kończy nadawanie; nadawanie kończy się też, gdy radio przestanie nadawać (np. po limicie czasu).
• SSTV to **ciągła nośna przez 1–3 minuty** – zmniejsz moc (np. 25–50 W) i ustaw poziom tak, żeby ALC ledwie się ruszało.
""",
                  bodyEN: """
**SSTV** tab: receiving and sending images. The decoder and transmitter are part of the program (own code, no external programs).

**Band buttons** (tuning panel, 80–6 m): typical SSTV calling frequencies (3.733, 7.165, 14.230, 18.160, 21.340, 24.975, 28.680, 50.680 MHz); below 10 MHz **DATA-L**, above **DATA-U** – like phone. The program remembers the last SSTV frequency on each band; right-click – back to the default. Changing band stops transmitting.

**Modes:** Martin M1 and M2, Scottie S1 and S2, Robot 36, PD 90, PD 120, PD 180. The mode is detected automatically from the **VIS** header.

**Receiving**
1. Radio in **USB** (or DATA-U), typical frequencies: 14.230 / 21.340 / 28.680 MHz.
2. Turn **monitoring** on (AUDIO tab or the button in the TUNING part) – the decoder uses the radio's audio.
3. The image is drawn line by line; when finished it goes to the **gallery** (`Pictures/FT710Control SSTV`, named with UTC date, mode and frequency).
• The decoder corrects **mistuning** up to about ±200 Hz and image **slant** (sound card clock differences) by itself.
• If a transmission stops halfway, the received part of the image is saved.
• **Tuning:** audio spectrum with markers SYNC (1200 Hz), 1500, VIS (1900 Hz) and 2300 Hz, plus a current tone indicator – the VIS header should fall at 1900 Hz.

**Log** (column on the right)
• Call with a QRZ/HamQTH lookup (name, QTH and locator fill in themselves; for a station away from home only the name), entity and “new station” or “worked: N QSOs”.
• **RSV** sent and received (595 by default): readability 1–5, strength 1–9, picture quality 1–5.
• The mode of the received picture (e.g. “SSTV Martin 1”) goes to the comment by itself.
• **Log QSO** (or ⌘↩) – SSTV mode, frequency from the radio, saved as in the program's log (entity, zones, distance, upload to services). For DXCC, SSTV counts as Phone (ARRL rules).

**Sending**
• An image from a file (**Image…**), the **test pattern** or the received image (**Reply**). The image is scaled to the mode's resolution (cropped), with an overlay: your call at the top and your own text at the bottom (e.g. “UR 595 TNX”).
• **SEND** requires a radio connection, **Enable TX** and the “To radio (TX)” device chosen in the AUDIO tab. PTT is keyed and released automatically.
• The image duration is checked against the **transmit limit** – PD 180 (about 188 s) needs the 5 min limit.
• **STOP** or withdrawing TX consent ends transmission immediately; it also ends if the radio stops transmitting (e.g. after the time limit).
• SSTV is a **continuous carrier for 1–3 minutes** – reduce power (e.g. 25–50 W) and set the level so ALC barely moves.
"""),

        HelpTopic(id: "cw", icon: "waveform.badge.mic", titlePL: "CW – dekoder i nadawanie", titleEN: "CW – decoder and sending",
                  bodyPL: """
Zakładka **CW**: dekoder telegrafii z dźwięku radia i nadawanie tekstu kluczem z komputera.

**Przyciski pasm** (panel strojenia, 160–6 m): radio w **CW-U** na początku odcinka CW (np. 14,030, 7,025, 3,530 MHz). Program pamięta ostatnią częstotliwość CW na każdym paśmie – po przestrojeniu i zmianie pasma przycisk wraca w to samo miejsce; prawy przycisk – powrót do domyślnej. Zmiana pasma przerywa nadawanie.

**Dekoder**
• Wymaga włączonego **odsłuchu** (dźwięk z radia). Ton CW znajdowany jest automatycznie (dokładność ~1 Hz); kliknięcie w widmo wskazuje stację ręcznie, **Auto** wraca do automatu.
• Tempo (WPM) i próg dopasowują się same – także do nierównej ręki i zaników (QSB).
• Dekoder pisze tylko wtedy, gdy na tonie jest **wąski sygnał CW** – przy fonii SSB czy samym szumie milczy (bez „śmieci”). Gdy CW się pojawi, dekoder odtwarza ostatnie 3 s, więc początek transmisji nie ginie.
• Wyłączony dekoder w ogóle nie analizuje dźwięku; widmo w zakładce liczone jest tylko, gdy zakładka jest otwarta.
• **APF dla dekodera (100 Hz)** – wąski filtr tylko na torze odczytu znaków (wyszukiwanie stacji dalej widzi całe pasmo). Pomaga przy bardzo słabych sygnałach (pomiar przy SNR 0 dB: błędy 22,5 → 18,4 %), przy silnych nic nie zmienia. Dla dekodera jest zawsze 100 Hz – węższy filtr zamieniałby szum w „ton” i dekoder pisałby śmieci. **APF (słuchawki)** w tej zakładce to ustawienie z zakładki AUDIO; pasmo filtra jest zaznaczone na widmie.
• **AI – model językowy:** gdy znak jest niejednoznaczny (kropka czy kreska, przerwa w znaku czy między znakami), dekoder rozważa wiele wersji i wybiera tę, która najlepiej pasuje do typowego języka QSO (CQ, DE, 5NN, TU, 73…) oraz do Twojego znaku i znaków z dziennika. Bieżące słowo jest pokazane od razu (kolor bursztynowy), po jego zakończeniu – poprawione przez model.
• Pomiar na nagraniach testowych: czysty sygnał 18–35 WPM ≈ 0–1 % błędów, SNR 3 dB ≈ 3 %, nierówna ręka 2,8 % z modelem (7,8 % bez), bardzo słaby sygnał (SNR 0 dB) ≈ 24 %; fonia SSB – dekoder milczy.

**Nadawanie** – dwie metody do wyboru (pole „Nadawanie przez”):
• **Linia DTR/RTS (port CAT-2)** – dokładne tempo z komputera; wymaga w radiu PC KEYING = DTR/RTS i drugiego portu radia. Jeśli linia nie zmienia stanu, program przerywa nadawanie i mówi dlaczego.
• **Klucz radia (CAT)** – tekst trafia do pamięci 5 klucza FT-710 (po 50 znaków) i nadaje go wbudowany klucz radia; pamięć 5, prędkość i stan klucza są potem przywracane. Nie wymaga drugiego portu ani PC KEYING. Wymaga **włączonego klucza radia (KEYER)** i ustawionego **typu klucza** (nie OFF) – program włącza klucz sam, a po pierwszym kawałku tekstu sprawdza w radiu, czy faktycznie nadaje; jeśli nie – podaje przyczynę.
• **Sprawdź radio** odczytuje przez CAT PC KEYING, BK-IN i tryb; **Popraw ustawienia** ustawia je jednym kliknięciem. Przy metodzie „Klucz radia” PC KEYING jest tylko informacją (ⓘ) – ta metoda go nie potrzebuje.

Szczegóły metody liniowej
• W radiu: tryb **CW**, **BK-IN** włączony, menu **PC KEYING = DTR** (albo RTS – zgodnie z wyborem w programie).
• **Port klucza** to drugi port radia (Standard COM / CAT-2) – program podpowiada go sam (np. …C1 przy porcie CAT …C0).
• Tekst albo **makra** (ołówek – edycja; {CALL} = Twój znak), tempo 5–40 WPM.
• Wymaga zaznaczenia **Odblokuj TX**; czas tekstu jest sprawdzany z limitem nadawania. **STOP**, cofnięcie zgody na TX albo rozłączenie radia natychmiast zwalnia klucz.

**Dziennik** (kolumna po prawej)
• Znak z wyszukiwaniem w QRZ/HamQTH (imię, QTH i lokator uzupełniają się same; dla stacji spoza swojego kraju tylko imię), kraj i informacja „nowa stacja” albo „było: N QSO”.
• **RST** wysłany i odebrany – puste pola zapisują się jako 599.
• **Zapisz QSO** (albo ⌘↩) – tryb CW, częstotliwość z radia, zapis jak w dzienniku programu (kraj, strefy, odległość, wysyłka do serwisów).
""",
                  bodyEN: """
**CW** tab: a telegraphy decoder for the radio's audio and sending text with a computer-driven key.

**Band buttons** (tuning panel, 160–6 m): the radio in **CW-U** at the start of the CW segment (e.g. 14.030, 7.025, 3.530 MHz). The program remembers the last CW frequency on each band – after retuning and changing band the button returns to the same spot; right-click – back to the default. Changing band stops transmitting.

**Decoder**
• Needs **monitoring** on (audio from the radio). The CW tone is found automatically (~1 Hz accuracy); clicking the spectrum picks a station manually, **Auto** returns to automatic.
• Speed (WPM) and threshold adapt by themselves – also to an uneven fist and fading (QSB).
• The decoder prints only when there is a **narrow CW signal** on the tone – with SSB voice or plain noise it stays silent (no “garbage”). When CW appears, the decoder replays the last 3 s, so the start of a transmission is not lost.
• A disabled decoder does not analyse audio at all; the spectrum in the tab is computed only while the tab is open.
• **APF for the decoder (100 Hz)** – a narrow filter on the character-reading path only (station search still sees the whole band). It helps with very weak signals (measured at SNR 0 dB: errors 22.5 → 18.4 %) and changes nothing with strong ones. For the decoder it is always 100 Hz – a narrower filter would turn noise into a “tone” and the decoder would print garbage. **APF (headphones)** in this tab is the AUDIO tab setting; the filter band is marked on the spectrum.
• **AI – language model:** when a character is ambiguous (dot or dash, a gap inside a character or between characters), the decoder weighs several versions and picks the one that best fits typical QSO language (CQ, DE, 5NN, TU, 73…) and your own and logbook call signs. The current word is shown at once (amber), and corrected by the model when it ends.
• Measured on test recordings: clean signal 18–35 WPM ≈ 0–1 % errors, SNR 3 dB ≈ 3 %, uneven fist 2.8 % with the model (7.8 % without), very weak signal (SNR 0 dB) ≈ 24 %; SSB voice – the decoder stays silent.

**Sending** – two methods (the “Send via” field):
• **DTR/RTS line (CAT-2 port)** – precise timing from the computer; needs PC KEYING = DTR/RTS on the radio and the radio's second port. If the line does not change state, the program stops sending and says why.
• **Radio keyer (CAT)** – the text goes into FT-710 keyer memory 5 (50 characters at a time) and the radio's built-in keyer sends it; memory 5, speed and keyer state are restored afterwards. Needs neither a second port nor PC KEYING. Requires the **radio keyer (KEYER) on** and a **keyer type** set (not OFF) – the program turns the keyer on itself and, after the first piece of text, checks on the radio that it is really transmitting; if not, it gives the reason.
• **Check radio** reads PC KEYING, BK-IN and mode over CAT; **Fix settings** sets them with one click. With the “Radio keyer” method PC KEYING is shown for information only (ⓘ) – that method does not need it.

Line method details
• On the radio: **CW** mode, **BK-IN** on, **PC KEYING = DTR** menu (or RTS – matching the choice in the program).
• The **key port** is the radio's second port (Standard COM / CAT-2) – the program suggests it (e.g. …C1 for CAT port …C0).
• Text or **macros** (pencil – edit; {CALL} = your call), speed 5–40 WPM.
• Requires **Enable TX**; the text duration is checked against the transmit limit. **STOP**, withdrawing TX consent or disconnecting the radio releases the key immediately.

**Log** (column on the right)
• Call with a QRZ/HamQTH lookup (name, QTH and locator fill in themselves; for a station away from home only the name), entity and “new station” or “worked: N QSOs”.
• **RST** sent and received – empty fields are saved as 599.
• **Log QSO** (or ⌘↩) – CW mode, frequency from the radio, saved as in the program's log (entity, zones, distance, upload to services).
"""),

        HelpTopic(id: "propagation", icon: "globe.europe.africa", titlePL: "Propagacja", titleEN: "Propagation",
                  bodyPL: """
Zakładka **PROPAGACJA** zbiera w jednym miejscu dane o warunkach na pasmach. Odświeża się sama co kilka minut, gdy jest otwarta (przycisk **Odśwież** – od razu).

**Słońce i geomagnetyka** (HamQSL, N0NBH): SFI, plamy, wskaźniki A i K, rozbłyski rentgenowskie, wiatr słoneczny, Bz, protony, stan pola, szum, MUF, foF2. Kolor: zielony – dobrze, pomarańczowy – uwaga, czerwony – źle; po najechaniu – objaśnienie.
• Ogólnie: wysokie SFI i plamy = lepsze wyższe pasma (15–10 m); niskie K i A = spokojna jonosfera; rozbłyski M/X = możliwe zaniki KF po stronie dziennej.

**Indeks Kp** (NOAA) – wykres z ostatnich dni; 5 i więcej to burza geomagnetyczna (gorsze KF, szansa na zorzę na VHF).

**Warunki KF** – prognoza dla grup pasm, osobno w dzień i w nocy.

**Warunki VHF/UKF** – zorza i Es dla Europy (2 / 4 / 6 m) oraz **spoty 6 m – 70 cm z Twojego DX Cluster z ostatniej godziny** – czyli rzeczywiste otwarcia.

**Aktywność pasm** – ile spotów pojawiło się na każdym paśmie w ostatnich 30 minutach (wymaga połączenia z DX Cluster).

**Twoje QTH** – wszystko liczone jest dla **lokatora z Profilu stacji**: wschód i zachód Słońca u Ciebie (UTC) i informacja, kiedy jesteś na linii szarości (±30 min – najlepszy czas na DX na 160–40 m).

**Mapa i „Otwarte pasma z Twojego miejsca”** (PSK Reporter, ostatnia godzina) – trzy zakresy:
• **Mój kwadrat** (np. KO02) – gdzie słychać **wszystkie stacje nadające z Twojego kwadratu** – realna propagacja z Twojego miejsca, także gdy sam nie nadajesz (np. pracujesz SSB/CW).
• **Moje pole** (np. KO) – to samo dla większego obszaru, gdy w kwadracie jest mało stacji.
• **Mój znak** – gdzie słychać Ciebie (gdy nadajesz emisjami cyfrowymi, np. FT8).
Gdy otwarta jest zakładka PROPAGACJA, **mapa zajmuje miejsce skopu RF** (środkowa kolumna okna) – duża, z wyborem zakresu raportów i pasma, przybliżaniem i statystyką pasm; po przejściu na inną zakładkę skop wraca. Na mapie: **linia szarości** (strefa nocy, odświeżana co minutę), Twoja stacja i odbiorcy w kolorach pasm. Obok – ranking pasm wg liczby odbiorów z największą odległością. PSK Reporter jest odpytywany najwyżej co 5 minut (także po zmianie zakresu).

**Mapy NOAA** – D-RAP (pochłanianie na KF, np. po rozbłyskach) i owal zorzy; kliknięcie otwiera podgląd z przybliżaniem (kółko myszy, szczypanie, przyciski +/−, „Cały obraz”) i przyciskiem „Otwórz w przeglądarce”.
**Przybliżanie map** – na mapie stacji (karta stacji w dzienniku) i na mapie propagacji: przyciski **+ / − / ⟲** (widok startowy) w prawym górnym rogu, **kółko myszy** (przybliża wokół kursora), na gładziku szczypanie; przesuwanie – przeciąganie albo dwa palce.

Źródła: N0NBH (hamqsl.com), NOAA SWPC, PSK Reporter (pskreporter.info). PSK Reporter jest odpytywany najwyżej co 5 minut, zgodnie z prośbą serwisu.
""",
                  bodyEN: """
The **PROPAGATION** tab gathers band-condition data in one place. It refreshes itself every few minutes while open (the **Refresh** button – immediately).

**Sun and geomagnetics** (HamQSL, N0NBH): SFI, sunspots, A and K indices, X-ray flares, solar wind, Bz, protons, field state, noise, MUF, foF2. Colour: green – good, orange – caution, red – bad; hover for an explanation.
• In general: high SFI and sunspots = better upper bands (15–10 m); low K and A = a calm ionosphere; M/X flares = possible HF blackouts on the daylight side.

**Kp index** (NOAA) – a chart of recent days; 5 or more is a geomagnetic storm (worse HF, a chance of VHF aurora).

**HF conditions** – a forecast for band groups, separately for day and night.

**VHF/UHF conditions** – aurora and Es for Europe (2 / 4 / 6 m) plus **6 m – 70 cm spots from your DX Cluster in the last hour** – i.e. real openings.

**Band activity** – how many spots appeared on each band in the last 30 minutes (needs a DX Cluster connection).

**Your QTH** – everything is calculated for the **grid from the Station profile**: sunrise and sunset at your location (UTC) and when you are on the greyline (±30 min – the best time for DX on 160–40 m).

**Map and “Open bands from your location”** (PSK Reporter, last hour) – three scopes:
• **My square** (e.g. KO02) – where **all stations transmitting from your square** are heard – real propagation from your location, even when you are not transmitting (e.g. working SSB/CW).
• **My field** (e.g. KO) – the same for a larger area when your square has few stations.
• **My call** – where you are heard (when you transmit digital modes, e.g. FT8).
While the PROPAGATION tab is open, **the map takes the place of the RF scope** (the middle column of the window) – large, with report scope and band selection, zoom and band statistics; the scope returns when you switch to another tab. On the map: the **greyline** (night zone, refreshed every minute), your station and receivers in band colours. Next to it – a band ranking by number of receptions with the longest distance. PSK Reporter is queried at most every 5 minutes (also after a scope change).

**NOAA maps** – D-RAP (HF absorption, e.g. after flares) and the auroral oval; clicking opens a viewer with zoom (mouse wheel, pinch, +/− buttons, “Whole image”) and an “Open in browser” button.
**Zooming maps** – on the station map (station card in the logbook) and on the propagation map: **+ / − / ⟲** (initial view) buttons in the top right corner, the **mouse wheel** (zooms around the cursor), pinch on the trackpad; panning – drag or two fingers.

Sources: N0NBH (hamqsl.com), NOAA SWPC, PSK Reporter (pskreporter.info). PSK Reporter is queried at most every 5 minutes, as the service asks.
"""),

        HelpTopic(id: "rtty", icon: "keyboard", titlePL: "RTTY – dekoder i nadawanie", titleEN: "RTTY – decoder and sending",
                  bodyPL: """
Zakładka **RTTY**: dalekopis (Baudot ITA2, standard 45,45 bodu, przesuw 170 Hz).

**Przyciski pasm** (panel strojenia, 160–10 m): radio w **DATA-L**, ustawione o 2,125 kHz powyżej środka aktywności RTTY (np. 14,085, 7,040, 3,590 MHz), więc sygnały wypadają na tonie mark 2125 Hz. Program pamięta ostatnią częstotliwość RTTY na każdym paśmie; prawy przycisk – powrót do domyślnej. Zmiana pasma przerywa nadawanie.

**Odbiór**
• Wymaga włączonego **odsłuchu**. Radio może być w **DATA-L** albo **RTTY-L** (mark 2125 Hz).
• **AFC** sam znajduje parę tonów i dostraja się z dokładnością ułamka herca; można też kliknąć w widmo na ton **mark** stacji. Na widmie: **M** – mark, **S** – space.
• Dekoder pisze tylko, gdy w widmie jest para tonów RTTY – przy fonii i szumie milczy; początek transmisji nie ginie (ostatnie 1,5 s są odtwarzane).
• **Odwrócenie wg trybu radia**: w DATA-L/RTTY-L mark to niższy ton, w DATA-U/USB – wyższy; program ustawia to sam (można wyłączyć i użyć **REV**).
• **USOS** – po spacji powrót do liter (standard).
• Pomiar na nagraniach testowych: SNR 10 dB – 0 % błędów, 5 dB – 2 %, odstrojenie 40 Hz – 3 %, sam szum – brak fałszywych znaków.

**Nadawanie (AFSK)**
• Radio w **DATA-L** (przycisk **Ustaw radio: DATA-L**), dźwięk przez USB – urządzenie „Do radia (TX)” w zakładce AUDIO.
• Program nadaje na tonach, na których odbiera – po dostrojeniu do stacji odpowiadasz na jej częstotliwości.
• Makra ({CALL} = Twój znak), tekst, **Poziom** – ustaw tak, żeby ALC ledwie się ruszało. RTTY to ciągła nośna: zmniejsz moc.
• Wymaga **Odblokuj TX**; czas tekstu jest sprawdzany z limitem nadawania; STOP, cofnięcie zgody albo rozłączenie radia kończy nadawanie.

**Dziennik** (kolumna po prawej)
• Znak z wyszukiwaniem w QRZ/HamQTH (imię, QTH i lokator uzupełniają się same; dla stacji spoza swojego kraju tylko imię), kraj i informacja „nowa stacja” albo „było: N QSO”.
• **RST** wysłany i odebrany – puste pola zapisują się jako 599.
• **Zapisz QSO** (albo ⌘↩) – tryb RTTY, częstotliwość z radia, zapis jak w dzienniku programu (kraj, strefy, odległość, wysyłka do serwisów).
""",
                  bodyEN: """
The **RTTY** tab: radioteletype (Baudot ITA2, standard 45.45 baud, 170 Hz shift).

**Band buttons** (tuning panel, 160–10 m): the radio in **DATA-L**, set 2.125 kHz above the centre of RTTY activity (e.g. 14.085, 7.040, 3.590 MHz), so signals land on the 2125 Hz mark tone. The program remembers the last RTTY frequency on each band; right-click – back to the default. Changing band stops transmitting.

**Receive**
• Needs **monitoring** on. The radio can be in **DATA-L** or **RTTY-L** (mark 2125 Hz).
• **AFC** finds the tone pair and tunes to a fraction of a hertz; you can also click the station's **mark** tone in the spectrum. On the spectrum: **M** – mark, **S** – space.
• The decoder prints only when an RTTY tone pair is in the spectrum – silent on voice and noise; the start of a transmission is not lost (the last 1.5 s are replayed).
• **Reverse by radio mode**: in DATA-L/RTTY-L the mark is the lower tone, in DATA-U/USB the higher one; the program sets this itself (you can turn it off and use **REV**).
• **USOS** – back to letters after a space (standard).
• Measured on test recordings: SNR 10 dB – 0 % errors, 5 dB – 2 %, 40 Hz off-tune – 3 %, noise only – no false characters.

**Transmit (AFSK)**
• Radio in **DATA-L** (the **Set radio: DATA-L** button), audio over USB – the “To radio (TX)” device in the AUDIO tab.
• The program transmits on the tones it receives – once tuned to a station you reply on its frequency.
• Macros ({CALL} = your call), text, **Level** – set so that ALC barely moves. RTTY is a continuous carrier: reduce power.
• Requires **Enable TX**; the text duration is checked against the transmit limit; STOP, withdrawing consent or disconnecting the radio ends transmission.

**Log** (column on the right)
• Call with a QRZ/HamQTH lookup (name, QTH and locator fill in themselves; for a station away from home only the name), entity and “new station” or “worked: N QSOs”.
• **RST** sent and received – empty fields are saved as 599.
• **Log QSO** (or ⌘↩) – RTTY mode, frequency from the radio, saved as in the program's log (entity, zones, distance, upload to services).
"""),

        HelpTopic(id: "ft8", icon: "waveform.path.ecg", titlePL: "FT8 i FT4", titleEN: "FT8 and FT4",
                  bodyPL: """
Zakładka **FT8/FT4**: odbiór i nadawanie emisji FT8 (cykl 15 s) i FT4 (cykl 7,5 s) przez dźwięk USB – wodospad i listy stacji jak w WSJT-X, automatyczna sekwencja QSO i zapis do dziennika.

**Przygotowanie**
• Włącz **odsłuch** (dźwięk z radia przez USB). Dekoder dostaje dźwięk **przed** filtrami odsłuchu – NB, ANF, AI czy „Głos DX” w słuchawkach nie wpływają na dekodowanie.
• Przyciski pasm (160m…6m) ustawiają standardową częstotliwość i tryb **DATA-U**. Filtr radia: co najmniej 3000 Hz.
• **Zegar Maca** musi zgadzać się z UTC (FT8 toleruje ok. ±1 s, FT4 mniej). Program sprawdza zegar przez NTP (time.apple.com) przy starcie i przyciskiem **Sprawdź zegar**. Gdy większość stacji ma DT powyżej ±0,5 s, pojawia się ostrzeżenie. Włącz w Ustawieniach systemowych → Ogólne → Data i czas **Ustaw czas automatycznie**.

**Wodospad**
• Gdy otwarta jest zakładka FT8/FT4, wodospad zajmuje **miejsce skopu RF** (ok. 72 s, prawie 5 cykli) – listy stacji mają wtedy cały panel zakładki. Po przejściu do innej zakładki skop wraca.
• Najnowszy wiersz u góry; szara linia z czasem UTC to początek cyklu. Skala 0–3200 Hz.
• **Lewy przycisk** – częstotliwość odbioru (zielony znacznik), **prawy przycisk** albo **Shift+kliknięcie** – nadawania (czerwony, przerywany; na skali klamra TX jest nad klamrą RX). Znaczniki można **przeciągać**. W panelu NADAWANIE: pole **TX** z krokiem 10 Hz oraz **TX = RX** i **RX = TX**. Zmiana w trakcie nadawania obowiązuje od następnego cyklu.
• Gdzie nadawać: przy wołaniu CQ wybierz w wodospadzie wolne miejsce (bez sygnałów przez kilka cykli); przy odpowiadaniu na CQ możesz nadawać na częstotliwości stacji (domyślnie – dwuklik przenosi tam TX) albo z boku (**Trzymaj TX**).
• Suwaki jasności i kontrastu pod wodospadem.

**Listy**
• **Aktywność pasma** – wszystkie komunikaty z cyklu (UTC, dB, DT, Hz, komunikat, kraj). **Częstotliwość odbioru** – komunikaty przy zielonym znaczniku i wszystkie skierowane do Ciebie.
• Kolory – patrz **Kolory na listach stacji** poniżej. Po najechaniu kursorem na komunikat podpowiedź wymienia pasujące kategorie i kraj (np. „Nowy kraj DXCC · CQ w komunikacie · Malawi”).

**Kolory na listach stacji**
Kolory i kategorie są takie same jak „Decode Highlighting” w WSJT-X (te same barwy, ta sama kolejność). Przycisk **Kolory…** nad listą otwiera listę kategorii z polami wyboru: kolor wiersza wyznacza **pierwsza zaznaczona kategoria od góry**, która pasuje do komunikatu. Na kolorowym tle tekst jest czarny. Domyślnie zaznaczone: mój znak, nowy kraj DXCC, kraj niepotwierdzony, nowy kraj DXCC na paśmie, kraj niepotwierdzony na paśmie, CQ, komunikat nadany – pozostałe włączasz według potrzeby (**Domyślne** / **Wszystkie**).
• 🟥 **Mój znak w komunikacie** – ktoś woła **Ciebie** (odpowiedź na CQ, raport, RR73, 73). Te komunikaty widać też zawsze w oknie **Częstotliwość odbioru**.
• **Nowy kontynent** / **na paśmie** – kontynent, którego nie masz w dzienniku (albo nie na tym paśmie).
• **Nowa strefa CQ** / **na paśmie**, **Nowa strefa ITU** / **na paśmie** – jak wyżej, dla stref (do WAZ i podobnych dyplomów).
• 🟪 **Nowy kraj DXCC** (magenta) – kraju nie ma w dzienniku na żadnym paśmie; **na paśmie** (jasnoróżowy) – kraj jest, ale nie na tym paśmie.
• **Kraj niepotwierdzony** (fiolet) – kraj jest w dzienniku, ale żadna łączność z nim nie jest potwierdzona; **na paśmie** (jasny fiolet) – na tym paśmie zrobiony, ale niepotwierdzony (potwierdzenie jest z innego pasma). Potwierdzenie: LoTW, a eQSL i QRZ – jeśli w oknie potwierdzeń zaznaczysz „licz też…”; zmiana tych przełączników od razu przelicza kolory. Na liście nad „Nowy kraj DXCC na paśmie”, bo niepotwierdzony kraj liczy się do DXCC bardziej niż nowe pasmo.
• 🟧 **Nowy kwadrat lokatora** / **na paśmie** – 4-znakowy lokator z CQ (np. JO31), którego nie masz (do VUCC, dyplomów lokatorowych).
• 🟦 **Nowy znak** (turkus) – z tą stacją nie było jeszcze łączności; **na paśmie** (jasny turkus) – była, ale nie na tym paśmie.
• 🟩 **CQ w komunikacie** – zwykłe CQ od stacji, z którą nie masz jeszcze łączności na tym paśmie, gdy żadna wyżej zaznaczona kategoria nie pasuje.
• **Szary tekst bez tła** – stacja **już zrobiona na tym paśmie** (w dowolnym trybie): jej CQ nie jest zielone ani fioletowe – także gdy jej kraj nie jest jeszcze potwierdzony, bo kolejne QSO z tą samą stacją zwykle nic nie zmienia (potwierdzenie przyjdzie, gdy ona wyśle log); fiolet zostaje dla innych stacji z tego kraju. W tym program różni się od WSJT-X, a działa jak JTDX. Szare są też jej komunikaty w łącznościach z innymi. Ta sama zasada dotyczy alertów „kraj niepotwierdzony” i znaków na skopie.
• 🟨 **Komunikat nadany** – Twój komunikat (w cyklu, w którym nadawałeś).
• Bez koloru – łączności innych stacji (nie CQ i nie do Ciebie), tekst dowolny, znaki ukryte w skrócie `<…>`.

Jak to jest liczone:
• Kategorie „nowy …” dotyczą tylko **CQ** – jak w WSJT-X. W każdej parze pasuje najwyżej jedna: „nowy” (brak w dzienniku w ogóle) albo „nowy na paśmie”.
• **Kraj, kontynent, strefy** – według bazy **cty.dat** (z uwzględnieniem znaków przenośnych, np. DL/SP5XTF, SP5XTF/MM); dla łączności w dzienniku – z pól CONT, CQZ, ITUZ, a gdy ich brak, także z cty.dat. Bez pobranej bazy (zakładka ZAWODY → **Aktualizuj bazę krajów**) kolumna „Kraj” jest pusta, a kategorie krajów, kontynentów i stref się nie pojawiają.
• **Znak** – znak podstawowy: SP5XTF i SP5XTF/P to ta sama stacja. **Lokator** – tylko gdy jest w komunikacie (CQ z lokatorem).
• Wszystko w **dowolnym trybie**; **pasmo** – pasmo, na którym jest radio (dial z CAT); bez CAT działają tylko kategorie ogólne.
• Dziennik jest sprawdzany na bieżąco: po zapisaniu QSO kolory **całej listy** są przeliczane od razu – widoczne już wiersze tej stacji szarzeją, bez czekania na następny cykl.
• Po najechaniu kursorem na komunikat podpowiedź wymienia **wszystkie** pasujące kategorie (także niezaznaczone) i kraj.
• **Tylko CQ i do mnie** (nad listą) ukrywa komunikaty innych łączności – zostają CQ, wywołania do Ciebie i Twoje komunikaty.
• Nie ma kategorii WSJT-X „New US State” i „LoTW User” – program nie ma tych danych.
• Kliknięcie komunikatu ustawia odbiór na tej stacji i wpisuje jej znak do pola dziennika. **Podwójne kliknięcie** – wołanie tej stacji (patrz niżej). Nadane komunikaty mają żółte tło.

**Nadawanie i QSO**
• Wymaga **Odblokuj TX**, radia w **DATA-U** i urządzenia „Do radia (TX)” w zakładce AUDIO. **Poziom TX** (górny rząd, obok przycisków pasm, razem z jasnością i kontrastem wodospadu) ustaw tak, żeby ALC ledwie się ruszało; FT8 to ciągła nośna przez 12,6 s – zwykle wystarcza 20–50 W.
• Komunikaty **Tx1–Tx6** jak w WSJT-X: Tx1 – znak i lokator, Tx2 – raport, Tx3 – R+raport, Tx4 – RR73, Tx5 – 73, Tx6 – CQ. Kropka przy komunikacie = nadawany w następnym cyklu (można kliknąć inny). ✓ – koder potwierdził komunikat; ⚠ – odbiorca zobaczyłby co innego (podpowiedź pokazuje co) i taki komunikat nie zostanie nadany. Komunikaty można edytować; **Generuj** odtwarza standardowe.
• **Wołanie stacji:** podwójne kliknięcie jej CQ – program wpisuje znak, lokator i raport (SNR, z jakim ją słyszysz), wybiera przeciwny cykl i włącza TX. **Pomiń Tx1** – zaczyna od raportu (Tx2) zamiast lokatora; QSO jest krótsze o jeden cykl, a lokator z CQ i tak trafia do dziennika. **CQ** – wołanie CQ (Tx6).
• **Auto-sekwencja:** po każdym cyklu program sam wybiera następny komunikat: lokator → raport (Tx2), raport → R+raport (Tx3), R+raport → RR73 (Tx4), RRR/RR73 → 73 (Tx5). Gdy na Twoje CQ odpowiada kilka stacji naraz, wybór ustawiasz w **Kilku wołających**: najsilniejszy (najwyższy SNR), najsłabszy, **najdalej** albo najbliżej. Odległość liczona od Twojego lokatora: z lokatora w komunikacie stacji, z lokatora, który podała wcześniej (CQ, Tx1) w tej sesji, a bez niego – z położenia kraju (cty.dat). Przy równej albo nieznanej odległości rozstrzyga wyższy SNR. W trakcie QSO pozostali wołający są pomijani (świecą na czerwono). Opcje sekwencji są pod przyciskiem **Opcje…** w panelu nadawania (pod nim podsumowanie aktualnych ustawień). **Limit wywołań** (3, 5, 9 albo bez limitu; domyślnie 5): tyle razy z rzędu program woła stację, która nie odpowiada (wywołanie i R-raport), potem wyłącza nadawanie z komunikatem „… nie odpowiada po N wywołaniach”; każda odpowiedź tej stacji liczy od nowa, CQ nie ma limitu (pilnuje go watchdog – 6 min). **Po QSO odpowiadaj następnemu wołającemu** (domyślnie włączone): po QSO zaczętym od Twojego CQ nadawanie się nie wyłącza – w następnym cyklu program odpowiada kolejnej wołającej stacji (wg „Kilku wołających”), a gdy nikt nie woła, wraca do CQ; „73” od stacji z właśnie zapisanego QSO nie przeszkadza. Po QSO z Twojego wołania (S&P) działa „Wyłącz TX po 73”.
• **Dziennik:** po nadaniu RR73 albo 73 QSO jest zapisywane (raz na stację): FT8, albo MFSK/FT4; częstotliwość = dial + ton nadawania; raporty, lokator, kraj, strefy, odległość. Potem TX się wyłącza (**Wyłącz TX po 73**) – gdy stacja nie usłyszała RR73 i powtarza raport, kliknij **Włącz TX**, a RR73 pójdzie jeszcze raz (bez drugiego wpisu).
• **Cykl:** 1. = :00 i :30, 2. = :15 i :45 (FT4: co 7,5 s). PTT włącza się na początku cyklu, dźwięk zaczyna się 0,5 s później – jak w WSJT-X (DT = 0). Włączenie TX do 2 s po początku cyklu nadaje jeszcze w nim (początek obcięty).
• **Trzymaj TX** – dwuklik nie przenosi częstotliwości nadawania (split, Shift+kliknięcie w wodospad). Bez niego nadajesz na częstotliwości wołanej stacji.
• **Bezpieczeństwo:** **Zatrzymaj** przerywa natychmiast; **Włącz TX** wyłączone pozwala dokończyć bieżący komunikat. Cofnięcie „Odblokuj TX”, rozłączenie radia, zmiana pasma albo trybu – natychmiastowe zatrzymanie. **Watchdog** wyłącza TX po 6 min bez Twojej reakcji (każde kliknięcie albo postęp QSO liczy się od nowa). Działa też limit czasu nadawania radia.

**PSKReporter**
• Przełącznik **PSKReporter** (pod wodospadem, domyślnie włączony) zgłasza odebrane stacje do pskreporter.info – dzięki temu nadający widzą na mapie, gdzie ich słychać. To samo robi „Enable PSK Reporter Spotting” w WSJT-X; jeśli WSJT-X działa równolegle na tym samym dźwięku, włącz zgłaszanie tylko w jednym programie.
• Zgodnie z zasadami serwisu: pakiet najwyżej co 5 minut (z losowym przesunięciem), każda stacja najwyżej raz na godzinę na danym paśmie i w danym trybie, jedno gniazdo UDP, częstotliwość = dial + ton. Zgłaszane są tylko znaki odczytane wprost – nie te rozwinięte ze skrótu `<…>`, ani Twoje własne komunikaty.
• Wymaga znaku i lokatora w profilu stacji oraz połączenia z radiem (częstotliwość). Pole **antena** – opcjonalny opis anteny. Liczba obok to stacje zgłoszone od uruchomienia; podpowiedź pokazuje czas ostatniej wysyłki.

**Dekoder**
• Biblioteka **ft8_lib** (Kārlis Goba YL3JG, MIT) z dodanym odejmowaniem zdekodowanych sygnałów (**Głębokość**: Szybka = 1 przebieg, Normalna = 2, Głęboka = 3) i pomiarem SNR jak w WSJT-X.
• Pomiar: na nagraniach z pasma ok. 75 % komunikatów, które dekoduje WSJT-X (plus kilka procent takich, których WSJT-X nie podał). Próg: FT8 – pewne dekodowanie do −17 dB, połowa przy −18,7 dB (WSJT-X ok. −21 dB); FT4 – do −13 dB, połowa przy −14,5 dB. Najsłabsze stacje częściej umkną niż w WSJT-X.
• SNR zgodny z rzeczywistym w granicach ±1 dB (pomiar na sygnale w szumie białym); DT zgodne z WSJT-X.
• Porównanie na żywo: WSJT-X może działać równolegle na tym samym wejściu dźwięku (bez CAT – albo przez CAT Share).
• **Zmiana FT8 ↔ FT4** przestraja radio na częstotliwość nowego trybu na tym samym paśmie (np. 40 m: 7,074 ↔ 7,0475 MHz). Gdy nowy tryb nie ma częstotliwości na paśmie (FT4 na 160 i 60 m), częstotliwość zostaje bez zmian.
• Kolumna **km** w obu listach: odległość od Twojego lokatora – z lokatora stacji (z komunikatu albo z jej wcześniejszych komunikatów w tej sesji); „~” – bez lokatora, przybliżona ze środka kraju (cty.dat). Okno „Częstotliwość odbioru” jest szersze – mieści cały komunikat z odległością.

**Hound – DXpedycje (Fox/Hound)**
• Gdy DXpedycja ogłasza tryb Fox/Hound (zwykle na własnej, nietypowej częstotliwości), zaznacz **Hound** w panelu nadawania. TX przechodzi powyżej 1000 Hz (Fox nie odpowiada wołającym niżej), nadawanie w 2. cyklu (1. należy do Foxa). Podsumowanie pod przyciskami świeci na pomarańczowo.
• **Dwuklik** na komunikacie Foxa (np. jego CQ) – wołanie **Tx1** (znak Foxa, Twój znak, lokator). Częstotliwość TX się nie zmienia; „Pomiń Tx1” w trybie Hound nie działa. Wołanie bez limitu wywołań (pilnuje watchdog).
• Gdy Fox odpowie raportem, program sam wysyła **Tx3 „R+raport” na częstotliwości Foxa** (powtórzenia o 300 Hz wyżej) – wymaga „Odblokuj TX”. Po **RR73** od Foxa QSO trafia do dziennika, nadawanie się wyłącza (Hound nie wysyła 73), a TX wraca na częstotliwość wołania. Bez RR73 po 5 × R+raport nadawanie się zatrzymuje – QSO sprawdź w logu online DXpedycji.
• Program dekoduje też **komunikaty łączone Foxa** („K1ABC RR73; SP5XTF <KH1/KH7Z> -12” – RR73 dla jednej stacji i raport dla drugiej); komunikat do Ciebie jest podświetlony. Tryb SuperFox (podpisany protokół) nie jest obsługiwany.
• Zwykłych stacji nie wołaj w trybie Hound – po pracy z DXpedycją odznacz Hound.
""",
                  bodyEN: """
The **FT8/FT4** tab: receiving and transmitting FT8 (15 s cycle) and FT4 (7.5 s cycle) over USB audio – WSJT-X-style waterfall and station lists, automatic QSO sequence and logging.

**Setup**
• Turn **monitoring** on (radio audio over USB). The decoder gets the audio **before** the monitoring filters – NB, ANF, AI or “DX voice” in the headphones do not affect decoding.
• The band buttons (160m…6m) set the standard frequency and **DATA-U** mode. Radio filter: at least 3000 Hz.
• The **Mac clock** must match UTC (FT8 tolerates about ±1 s, FT4 less). The program checks the clock over NTP (time.apple.com) at start-up and with **Check clock**. When most stations show DT beyond ±0.5 s, a warning appears. In System Settings → General → Date & Time turn on **Set time automatically**.

**Waterfall**
• While the FT8/FT4 tab is open, the waterfall takes the **place of the RF scope** (about 72 s, almost 5 cycles) – the station lists get the whole tab panel. The scope returns when you switch to another tab.
• Newest line at the top; the grey line with a UTC time marks the start of a cycle. Scale 0–3200 Hz.
• **Left button** – receive frequency (green marker), **right button** or **Shift+click** – transmit frequency (red, dashed; on the scale the TX bracket sits above the RX bracket). Markers can be **dragged**. In the TRANSMIT panel: the **TX** field with 10 Hz steps, plus **TX = RX** and **RX = TX**. A change during transmission applies from the next period.
• Where to transmit: when calling CQ pick a clear spot in the waterfall (no signals for a few periods); when answering a CQ you can transmit on the station's frequency (default – double-click moves TX there) or off to the side (**Hold TX**).
• Brightness and contrast sliders below the waterfall.

**Lists**
• **Band activity** – all messages of each cycle (UTC, dB, DT, Hz, message, country). **RX frequency** – messages near the green marker and all messages addressed to you.
• Colours – see **Colours in the station lists** below. Hovering over a message lists the matching categories and the country (e.g. “New DXCC · CQ in message · Malawi”).

**Colours in the station lists**
The colours and categories are the same as WSJT-X “Decode Highlighting” (same colours, same order). The **Colours…** button above the list opens the category list with checkboxes: a row's colour is set by the **first ticked category from the top** that matches the message. Text on a coloured background is black. Ticked by default: my call, new DXCC, unconfirmed DXCC, new DXCC on band, unconfirmed DXCC on band, CQ, transmitted message – enable the others as you need (**Default** / **All**).
• 🟥 **My call in message** – someone is calling **you** (a reply to your CQ, a report, RR73, 73). These always also appear in the **RX frequency** window.
• **New continent** / **on band** – a continent not in your log (or not on this band).
• **New CQ zone** / **on band**, **New ITU zone** / **on band** – the same for zones (for WAZ and similar awards).
• 🟪 **New DXCC** (magenta) – the country is not in your log on any band; **on band** (light pink) – the country is there, but not on this band.
• **Unconfirmed DXCC** (purple) – the country is in your log, but no QSO with it is confirmed; **on band** (light purple) – worked on this band but not confirmed there (confirmed on another band). Confirmation: LoTW, plus eQSL and QRZ if “also count…” is ticked in the confirmations window; changing these switches recalculates the colours immediately. Listed above “New DXCC on band”, because an unconfirmed entity matters more for DXCC than a new band.
• 🟧 **New grid** / **on band** – a 4-character locator from the CQ (e.g. JO31) you do not have (for VUCC and grid awards).
• 🟦 **New call** (cyan) – no QSO with this station yet; **on band** (light cyan) – worked, but not on this band.
• 🟩 **CQ in message** – a normal CQ from a station you have not worked on this band yet, when none of the ticked categories above match.
• **Grey text, no background** – a station **already worked on this band** (in any mode): its CQ is neither green nor purple – even when its entity is not confirmed yet, because another QSO with the same station usually changes nothing (the confirmation comes when that station uploads its log); purple stays for other stations from that entity. Here the program differs from WSJT-X and works like JTDX. Its messages in QSOs with others are grey too. The same rule applies to “unconfirmed DXCC” alerts and to calls on the scope.
• 🟨 **Transmitted message** – your own message (in the period you transmitted).
• No colour – QSOs between other stations (not a CQ and not to you), free text, calls hidden in a `<…>` hash.

How it is determined:
• “New …” categories apply to **CQ** messages only – as in WSJT-X. In each pair at most one matches: “new” (not in the log at all) or “new on band”.
• **Country, continent, zones** – from the **cty.dat** database (including portable calls, e.g. DL/SP5XTF, SP5XTF/MM); for logged QSOs – from the CONT, CQZ, ITUZ fields, falling back to cty.dat. Without the database (CONTEST tab → **Update country database**) the “Country” column is empty and the country, continent and zone categories do not appear.
• **Call** – the base call: SP5XTF and SP5XTF/P are the same station. **Grid** – only when it is in the message (a CQ with a locator).
• Everything in **any mode**; **band** – the band the radio is on (dial from CAT); without CAT only the general categories work.
• The logbook is checked live: after a QSO is logged the colours of the **whole list** are recalculated immediately – rows of that station already on screen turn grey, without waiting for the next period.
• Hovering over a message lists **all** matching categories (including unticked ones) and the country.
• **Only CQ and to me** (above the list) hides messages from other QSOs – CQs, calls to you and your own messages remain.
• The WSJT-X categories “New US State” and “LoTW User” are not available – the program does not have this data.
• Clicking a message sets the receive frequency to that station and puts its call into the log entry field. **Double-click** – call that station (see below). Transmitted messages have a yellow background.

**Transmitting and QSOs**
• Requires **Enable TX**, the radio in **DATA-U** and the “To radio (TX)” device in the AUDIO tab. Set **TX level** (top row, next to the band buttons, together with the waterfall brightness and contrast) so that ALC barely moves; FT8 is a continuous carrier for 12.6 s – 20–50 W is usually enough.
• Messages **Tx1–Tx6** as in WSJT-X: Tx1 – call and locator, Tx2 – report, Tx3 – R+report, Tx4 – RR73, Tx5 – 73, Tx6 – CQ. The dot marks the message sent in the next period (click another to change). ✓ – the encoder confirmed the message; ⚠ – the receiver would see something else (the tooltip shows what) and such a message will not be sent. Messages can be edited; **Generate** restores the standard ones.
• **Calling a station:** double-click its CQ – the program fills in the call, locator and report (the SNR you hear it with), picks the opposite period and starts TX. **Skip Tx1** – starts with the report (Tx2) instead of the locator; the QSO is one period shorter and the locator from the CQ still goes into the log. **CQ** – call CQ (Tx6).
• **Auto sequence:** after each period the program picks the next message: locator → report (Tx2), report → R+report (Tx3), R+report → RR73 (Tx4), RRR/RR73 → 73 (Tx5). When several stations answer your CQ at once, the choice is set in **Several callers**: strongest (highest SNR), weakest, **farthest** or nearest. Distance is measured from your locator: from the locator in the station's message, from the locator it sent earlier (CQ, Tx1) in this session, or otherwise from the country's position (cty.dat). With equal or unknown distance the higher SNR wins. During a QSO other callers are skipped (they show in red). The sequence options are under the **Options…** button in the transmit panel (a summary of the current settings below it). **Call limit** (3, 5, 9 or no limit; 5 by default): the program calls a station that does not answer this many times in a row (call and R-report), then stops transmitting with the message “… did not answer after N calls”; each answer from that station starts the count again, CQ has no limit (the watchdog takes care of it – 6 min). **After a QSO, answer the next caller** (on by default): after a QSO started from your CQ, transmitting does not stop – in the next period the program answers the next calling station (per “Several callers”), and if nobody calls it returns to CQ; a “73” from the station of the QSO just logged does not get in the way. After a QSO from your own call (S&P), “Disable TX after 73” applies.
• **Logbook:** after RR73 or 73 is sent the QSO is logged (once per station): FT8, or MFSK/FT4; frequency = dial + transmit tone; reports, locator, country, zones, distance. Then TX turns off (**Disable TX after 73**) – if the station missed your RR73 and repeats the report, click **Start TX** and RR73 goes out again (without a second log entry).
• **Period:** 1st = :00 and :30, 2nd = :15 and :45 (FT4: every 7.5 s). PTT is keyed at the start of the period and audio starts 0.5 s later – as in WSJT-X (DT = 0). Starting TX up to 2 s into a period still transmits in it (with the beginning cut).
• **Hold TX** – double-click does not move the transmit frequency (split, Shift+click the waterfall). Without it you transmit on the called station's frequency.
• **Safety:** **Halt** stops immediately; turning **Start TX** off lets the current message finish. Withdrawing “Enable TX”, disconnecting the radio, changing band or mode – immediate stop. The **watchdog** turns TX off after 6 min without your action (every click or QSO progress restarts it). The radio's transmit time limit also applies.

**PSKReporter**
• The **PSKReporter** switch (below the waterfall, on by default) reports received stations to pskreporter.info – so transmitting stations can see on the map where they are heard. This is what “Enable PSK Reporter Spotting” does in WSJT-X; if WSJT-X runs in parallel on the same audio, enable reporting in only one program.
• Following the service rules: a packet at most every 5 minutes (with a random offset), each station at most once per hour per band and mode, a single UDP socket, frequency = dial + tone. Only calls decoded directly are reported – not those expanded from a `<…>` hash, nor your own messages.
• Requires your call and locator in the station profile and a radio connection (frequency). The **antenna** field – an optional antenna description. The number next to it is stations reported since start-up; the tooltip shows the time of the last upload.

**Decoder**
• The **ft8_lib** library (Kārlis Goba YL3JG, MIT) with added subtraction of decoded signals (**Depth**: Fast = 1 pass, Normal = 2, Deep = 3) and WSJT-X-style SNR.
• Measured: on band recordings about 75 % of the messages WSJT-X decodes (plus a few percent WSJT-X did not report). Threshold: FT8 – reliable down to −17 dB, half at −18.7 dB (WSJT-X about −21 dB); FT4 – down to −13 dB, half at −14.5 dB. The weakest stations are missed more often than in WSJT-X.
• SNR matches the true value within ±1 dB (measured on signals in white noise); DT matches WSJT-X.
• Live comparison: WSJT-X can run in parallel on the same audio input (without CAT – or through CAT Share).
• **Switching FT8 ↔ FT4** retunes the radio to the new mode's frequency on the same band (e.g. 40 m: 7.074 ↔ 7.0475 MHz). When the new mode has no frequency on the band (FT4 on 160 and 60 m), the frequency stays unchanged.
• The **km** column in both lists: distance from your locator – from the station's locator (from the message or its earlier messages in this session); “~” – no locator, approximated from the middle of the country (cty.dat). The “Rx frequency” window is wider – it fits the whole message with the distance.

**Hound – DXpeditions (Fox/Hound)**
• When a DXpedition announces Fox/Hound (usually on its own, unusual frequency), tick **Hound** in the transmit panel. TX moves above 1000 Hz (the Fox does not answer callers lower down), transmitting in the 2nd period (the 1st belongs to the Fox). The summary under the buttons turns orange.
• **Double-click** a Fox message (e.g. its CQ) – calling with **Tx1** (Fox call, your call, locator). The TX frequency does not change; “Skip Tx1” does not apply in Hound mode. Calling without a call limit (the watchdog keeps watch).
• When the Fox answers with a report, the program itself sends **Tx3 “R+report” on the Fox's frequency** (repeats 300 Hz higher) – “Enable TX” is required. After **RR73** from the Fox the QSO goes to the log, transmitting stops (a Hound does not send 73) and TX returns to the calling frequency. Without RR73 after 5 × R+report transmitting stops – check the QSO in the DXpedition's online log.
• The program also decodes the Fox's **combined messages** (“K1ABC RR73; SP5XTF <KH1/KH7Z> -12” – RR73 for one station and a report for another); a message to you is highlighted. SuperFox mode (signed protocol) is not supported.
• Do not call ordinary stations in Hound mode – untick Hound after working the DXpedition.
"""),

        HelpTopic(id: "pota", icon: "leaf", titlePL: "POTA – Parki w eterze", titleEN: "POTA – Parks on the Air",
                  bodyPL: """
Zakładka **POTA**: spoty aktywatorów z parków (Parks on the Air), statystyki użytkownika i polowanie na parki jednym kliknięciem.

**Statystyki**
• Pole znaku jest **edytowalne** – domyślnie (puste) używany jest znak z profilu stacji; można wpisać dowolny znak i kliknąć **Pobierz**.
• Pokazywane: aktywacje (i próby), parki i QSO jako aktywator, parki i QSO jako łowca, liczba dyplomów i wyróżnień. **Profil na pota.app** otwiera pełny profil w przeglądarce.
• Dane są publiczne – nie trzeba logować się na pota.app ani podawać hasła.

**Spoty**
• Lista bieżących aktywacji (jedna pozycja na aktywatora i park), odświeżana **co 60 s** – API POTA utrzymują wolontariusze, więc program nie pyta częściej.
• **Zakończone aktywacje** (filtr „QRT / zakończone”) – aktywacje, które zniknęły z listy albo zgłosiły QRT, są pokazywane jeszcze przez godzinę (wyszarzone, „koniec”). Program zna tylko te, które widział, gdy był uruchomiony.
• **Filtry jak na pota.app** (zapamiętywane): **Pasmo**, **Emisja** (CW / fonia / cyfrowe), **Program** (kraj programu z numeru parku, np. US, SP, DL) – przy każdej opcji liczba spotów; **Wiek** (5–60 min albo wszystkie – według ostatniego spotu aktywacji); **QRT / zakończone** – pokaż / ukryj; **Ukryte** – aktywacje ukryte ręcznie (menu prawego przycisku → **Ukryj tę aktywację**, wracają po 24 h); **Upolowane** – pokaż / ukryj parki, które już masz w dzienniku; **Wyróżnianie** – w jakiej emisji liczyć „nowy park” (mieszane / fonia / CW / cyfrowe: np. przy CW park zrobiony tylko fonią nadal jest nowy). **Sortowanie** – lista wyboru albo kliknięcie nagłówka kolumny; pasma od 160 m w górę. **⏸** – wstrzymanie odświeżania, obok odliczanie do następnego.
• **Kolory**: park **fioletowy i pogrubiony** – nowy, nie ma go w Twoim dzienniku; wiersz **szary** – aktywacja zakończona albo ten aktywator z tym parkiem już zrobiony dziś na tym paśmie.

**Kliknięcie spotu**
• Radio przestraja się na częstotliwość aktywatora z trybem: CW, LSB poniżej 10 MHz / USB powyżej, AM, FM, DATA-U dla FT8/FT4 i innych cyfrowych.
• Znak aktywatora trafia do formularza **DZIENNIK**, a numer parku pokazuje się pod nim („POTA: US-0062 – …”). Przy zapisie QSO dostaje pola ADIF **SIG=POTA**, **SIG_INFO** i **POTA_REF** (oraz uwagę „POTA US-0062”, jeśli pole uwag jest puste) – POTA liczy je po wysłaniu dziennika. Numer parku obowiązuje tylko dla znaku tego aktywatora; ✕ go usuwa.
• **Dwuklik** – to samo i przejście do zakładki DZIENNIK. Menu prawego przycisku: park na pota.app, aktywator na QRZ.com.
• Parki „upolowane” program odczytuje z dziennika (POTA_REF albo SIG_INFO przy SIG=POTA), także z łączności zaimportowanych z innych programów.

API POTA jest nieoficjalne i może się zmienić bez zapowiedzi – jeśli spoty przestaną się pojawiać, komunikat błędu jest w prawym górnym rogu zakładki.
""",
                  bodyEN: """
The **POTA** tab: activator spots from parks (Parks on the Air), user statistics and one-click park hunting.

**Statistics**
• The call field is **editable** – when empty, the call from the station profile is used; you can type any call and click **Download**.
• Shown: activations (and attempts), parks and QSOs as an activator, parks and QSOs as a hunter, number of awards and endorsements. **Profile on pota.app** opens the full profile in the browser.
• The data is public – no pota.app login or password is needed.

**Spots**
• The list of current activations (one row per activator and park), refreshed **every 60 s** – the POTA API is run by volunteers, so the program does not ask more often.
• **Ended activations** (the “QRT / ended” filter) – activations that dropped off the list or reported QRT stay visible for an hour (greyed, “ended”). The program only knows those it saw while it was running.
• **Filters as on pota.app** (remembered): **Band**, **Mode** (CW / phone / digital), **Program** (the program country from the park reference, e.g. US, SP, DL) – each option shows its number of spots; **Age** (5–60 min or all – by the activation’s latest spot); **QRT / ended** – show / hide; **Hidden** – activations hidden manually (right-click menu → **Hide this activation**, they come back after 24 h); **Hunted** – show / hide parks already in your log; **Highlight** – in which mode a “new park” is counted (mixed / phone / CW / digital: e.g. with CW a park worked only on phone is still new). **Sorting** – the picker or a click on a column header; bands from 160 m upwards. **⏸** – pause refreshing, next to it the countdown to the next refresh.
• **Colours**: park in **bold purple** – new, not in your log; **grey** row – the activation has ended or you already worked this activator in this park today on this band.

**Clicking a spot**
• The radio tunes to the activator's frequency and mode: CW, LSB below 10 MHz / USB above, AM, FM, DATA-U for FT8/FT4 and other digital modes.
• The activator's call goes into the **LOG** form and the park reference is shown below it (“POTA: US-0062 – …”). When saved, the QSO gets the ADIF fields **SIG=POTA**, **SIG_INFO** and **POTA_REF** (and the comment “POTA US-0062” if the comment is empty) – POTA counts them once the log is uploaded. The park reference applies only to that activator's call; ✕ removes it.
• **Double-click** – the same and switch to the LOG tab. Right-click menu: park on pota.app, activator on QRZ.com.
• Hunted parks are read from the logbook (POTA_REF, or SIG_INFO with SIG=POTA), including QSOs imported from other programs.

The POTA API is unofficial and may change without notice – if spots stop appearing, the error message is in the top right corner of the tab.
"""),

        HelpTopic(id: "alerts", icon: "bell", titlePL: "Alerty", titleEN: "Alerts",
                  bodyPL: """
**Alerty** dają znać o ciekawych stacjach, także gdy patrzysz na inną zakładkę albo nie siedzisz przy komputerze. Dzwonek w pasku zakładek (obok „Diagnostyka USB”) pokazuje liczbę nieprzeczytanych; kliknięcie otwiera listę.

**Rodzaje** (w kolejności ważności – gdy pasuje kilka, alert dostaje pierwszy zaznaczony):
• **Ktoś mnie woła (FT8)** – komunikat FT8/FT4 z Twoim znakiem jako adresatem.
• **Obserwowany znak** – znak z Twojej listy (np. DXpedycje), z dowolnego źródła.
• **Nowy kraj DXCC**, **Kraj niepotwierdzony**, **Nowy kraj DXCC na paśmie**, **Kraj niepotwierdzony na paśmie** – jak kolory w FT8 i kolumna DXCC w klastrze (potwierdzenia: LoTW, opcjonalnie eQSL i QRZ).
• **Nowy park POTA** – aktywacja z parku, którego nie masz w dzienniku.
• **Nowe potwierdzenia QSL** – automatyczne pobieranie (raz dziennie) przyniosło nowe potwierdzenia; w treści liczba, serwisy i kraje, które stały się potwierdzone. Kliknięcie otwiera okno dziennika.
Domyślnie włączone wszystkie oprócz „niepotwierdzony na paśmie” (na zatłoczonym paśmie bywa go dużo).

**Źródła**: DX Cluster (nowe spoty), FT8/FT4 (komunikaty z każdego cyklu, tylko CQ dla kategorii krajów), POTA (nowe aktywacje). Każde można wyłączyć; opcjonalnie tylko wybrane **pasma**.

**Dostarczanie**
• **Dźwięk** (do wyboru, przycisk „Odtwórz”) i **powiadomienie macOS** – kliknięcie powiadomienia otwiera program i działa jak kliknięcie alertu. Powiadomienia działają w zbudowanej aplikacji (build_app.sh / DMG); przy pierwszym alercie macOS zapyta o zgodę (Ustawienia systemowe → Powiadomienia → FT-710 Control).
• **Bez zalewu**: ten sam znak, rodzaj i pasmo – najwyżej raz na 30 minut (wywołanie w FT8 – co 2 minuty); dźwięk i powiadomienie najwyżej co 5 s – przy serii reszta trafia tylko na listę; spoty przysłane hurtem tuż po połączeniu z klastrem i pierwsza lista POTA po starcie nie alarmują.

**Lista alertów**: czas UTC, rodzaj (kolor), znak, częstotliwość, pasmo, tryb, źródło, kraj / park / treść komunikatu; kropka – nieprzeczytany. **Kliknięcie** robi to samo, co kliknięcie w źródle: DX Cluster – strojenie i znak do dziennika; POTA – strojenie, znak i park; FT8 – przejście do zakładki FT8/FT4, odbiór na tej stacji i znak do dziennika. **Przeczytane**, **Wyczyść**, ⚙ – ustawienia. Lista trzyma 200 ostatnich alertów (do zamknięcia programu).
""",
                  bodyEN: """
**Alerts** tell you about interesting stations, also when you are looking at another tab or away from the computer. The bell in the tab bar (next to “USB diagnostics”) shows the number of unread alerts; clicking it opens the list.

**Kinds** (in order of importance – when several match, the alert gets the first ticked one):
• **Calling me (FT8)** – an FT8/FT4 message with your call as the addressee.
• **Watched call** – a call from your list (e.g. DXpeditions), from any source.
• **New DXCC**, **Unconfirmed DXCC**, **New DXCC on band**, **Unconfirmed DXCC on band** – like the FT8 colours and the DXCC column in the cluster (confirmations: LoTW, optionally eQSL and QRZ).
• **New POTA park** – an activation from a park not in your log.
• **New QSL confirmations** – the automatic (daily) download brought new confirmations; the text shows the number, the services and the entities that became confirmed. Clicking it opens the logbook window.
All are on by default except “unconfirmed on band” (there can be many on a busy band).

**Sources**: DX Cluster (new spots), FT8/FT4 (messages from every period, only CQs for the entity kinds), POTA (new activations). Each can be turned off; optionally only selected **bands**.

**Delivery**
• **Sound** (selectable, “Play” button) and a **macOS notification** – clicking the notification opens the program and works like clicking the alert. Notifications work in the built app (build_app.sh / DMG); on the first alert macOS asks for permission (System Settings → Notifications → FT-710 Control).
• **No flooding**: the same call, kind and band – at most once per 30 minutes (an FT8 call to you – every 2 minutes); sound and notification at most every 5 s – during a burst the rest only goes to the list; spots sent in bulk right after connecting to the cluster and the first POTA list after start-up do not alert.

**Alert list**: UTC time, kind (colour), call, frequency, band, mode, source, entity / park / message text; a dot – unread. **Clicking** does the same as clicking in the source: DX Cluster – tune and call to the log; POTA – tune, call and park; FT8 – switch to the FT8/FT4 tab, receive on that station and call to the log. **Mark read**, **Clear**, ⚙ – settings. The list keeps the last 200 alerts (until the program quits).
"""),

        HelpTopic(id: "contest", icon: "trophy", titlePL: "Zawody – punktacja i Cabrillo", titleEN: "Contests – scoring and Cabrillo",
                  bodyPL: """
Zakładka **ZAWODY**: szybkie wpisywanie łączności, punktacja i mnożniki na żywo, eksport Cabrillo.

**Baza zawodów:** CQ World Wide DX, CQ WPX, IARU HF Championship, SP DX Contest, ARRL International DX oraz zawody ogólne (RST + numer). Przy każdych: termin, wymiana, punktacja i link do regulaminu. W SP DX Contest i ARRL DX program sam rozpoznaje, czy jesteś stacją SP / W/VE, czy zagraniczną.

**Baza krajów (cty.dat):** do punktów potrzebny jest plik cty.dat (AD1C, country-files.com) – przycisk **Aktualizuj bazę krajów**. Aktualizuj go przed dużymi zawodami (nowe prefiksy, stacje specjalne).

**Praca:**
• **Nowe zawody…** – wybór zawodów i emisji; numeracja od 001, wynik od zera.
• Wpisz znak – od razu widać kraj, kontynent i strefy, **DUBEL** (czerwony), punkty i **NOWY** mnożnik (zielony). Strefa CQ / ITU podpowiada się z bazy krajów.
• **Enter** zapisuje, **Esc** czyści. Dubel zapisuje się dopiero po drugim Enter (0 punktów).
• **Moja wymiana** – strefa, litera województwa (SP DX Contest), moc albo stan; przy numerze program liczy go sam.
• **Wynik:** QSO, punkty i mnożniki na każdym paśmie, wynik całkowity, tempo (QSO/h).

**Log zawodów:** każde zawody mają **osobny log** (plik na sesję) – łączności nie trafiają do głównego dziennika ani do automatycznej wysyłki do serwisów. Tabela **LOG ZAWODÓW** pokazuje wszystkie łączności (najnowsze u góry): **dwuklik** albo przycisk **Edytuj…** – zmiana znaku, czasu UTC, pasma, trybu, RST i wymian; przycisk **Usuń…**, klawisz **Delete**, prawy przycisk → **Usuń z logu zawodów…** albo **Usuń łączność…** w oknie edycji – usunięcie (wynik i Cabrillo przeliczają się od razu; główny dziennik bez zmian). **Dodaj do dziennika…** – kopiuje łączności zawodów do głównego dziennika ze standardowymi polami ADIF zawodów (CONTEST_ID, STX/SRX, wymiany); te, które już tam są (ten sam znak, pasmo, czas ±2 min), są pomijane; wysyłka do serwisów potem świadomie: Usługi online → Wyślij zaległe. Łączności zawodów zapisane przez wcześniejsze wersje (w dzienniku) program przy pierwszym uruchomieniu kopiuje do logu zawodów.
**Poprzednie zawody…** – lista wszystkich logów zawodów (nazwa, liczba QSO, daty) z przyciskiem **Otwórz**; zawody ze starszych wersji zapisane tylko w dzienniku są oznaczone „w dzienniku” i po otwarciu dostają własny log. „Nowe zawody…” niczego nie usuwa – poprzednie zawsze można otworzyć. Logi i ustawienia zawodów są w folderze `~/Library/Application Support/FT710Control/Contests`; program uruchomiony z Xcode i zainstalowany z DMG korzystają z tych samych logów, ale mają osobne ustawienia – jeśli któryś nie zna bieżących zawodów, otwiera ostatnio używany log.
**QRZ:** po wpisaniu znaku pod polem pojawiają się imię, QTH i lokator z QRZ.com; zapisują się w łączności (dla stacji spoza swojego kraju, np. P4/WE9V – tylko imię).
**Skop:** w zakładce ZAWODY kliknięcie stacji (DX Cluster, POTA) na skopie stroi radio i wpisuje znak do pola zawodów – bez przechodzenia do DZIENNIKA. **Zrobione w zawodach na skopie:** stacje już zrobione w tych zawodach na danym paśmie (wg reguł dubli zawodów – w CQ WW znak i pasmo, w zawodach liczonych na emisje także emisja spotu) są **czerwone** (domyślnie), **ukryte** albo bez zmian – przy otwartej zakładce ZAWODY.
**Spot na DX Cluster:** przycisk **Spot** przy polu zawodów spotuje ostatnio zapisaną stację, a **Wyślij spot na DX Cluster…** w menu łączności w logu zawodów – wybraną. Okno pokazuje gotowe polecenie („DX 14025.0 DL1ABC CQ WW DX”), które można poprawić przed wysłaniem; wymaga połączenia z klastrem.
**Cabrillo:** **Nagłówek Cabrillo…** – kategorie (moc FT-710: LOW), klub, adres, soapbox; **Eksport Cabrillo…** zapisuje plik .log do wysłania organizatorowi.

Reguły zostały sprawdzone z regulaminami (CQ WPX 2025, SP DX Contest 2023–2024, IARU HF, ARRL DX, CQ WW), ale organizatorzy czasem je zmieniają – przed zawodami zajrzyj do regulaminu. Wynik w programie to wynik zgłaszany; organizator po sprawdzeniu logów może go skorygować.
""",
                  bodyEN: """
The **CONTEST** tab: fast QSO entry, live scoring and multipliers, Cabrillo export.

**Contest database:** CQ World Wide DX, CQ WPX, IARU HF Championship, SP DX Contest, ARRL International DX and a general contest (RST + serial). Each shows the dates, exchange, scoring and a link to the rules. In the SP DX Contest and ARRL DX the program detects by itself whether you are an SP / W/VE station or a foreign one.

**Country database (cty.dat):** scoring needs the cty.dat file (AD1C, country-files.com) – the **Update country database** button. Update it before major contests (new prefixes, special stations).

**Operating:**
• **New contest…** – choose the contest and mode; serials start at 001, the score at zero.
• Type a call – you immediately see the country, continent and zones, **DUPE** (red), points and **NEW** multiplier (green). The CQ / ITU zone is suggested from the country database.
• **Enter** logs, **Esc** clears. A dupe is logged only after a second Enter (0 points).
• **My exchange** – zone, province letter (SP DX Contest), power or state; serials are counted by the program.
• **Score:** QSOs, points and multipliers per band, total score, rate (QSO/h).

**Contest log:** every contest has a **separate log** (a file per session) – QSOs do not go to the main logbook or to automatic uploads to services. The **CONTEST LOG** table shows all QSOs (newest at the top): **double-click** or the **Edit…** button – change the call, UTC time, band, mode, RST and exchanges; the **Delete…** button, the **Delete** key, right-click → **Remove from the contest log…** or **Delete QSO…** in the edit window – removal (score and Cabrillo are recalculated at once; the main logbook is unchanged). **Add to logbook…** – copies the contest QSOs to the main logbook with the standard ADIF contest fields (CONTEST_ID, STX/SRX, exchanges); those already there (same call, band, time ±2 min) are skipped; uploading to services afterwards, deliberately: Online services → Upload pending. Contest QSOs saved by earlier versions (in the logbook) are copied to the contest log on the first start.
**Previous contests…** – a list of all contest logs (name, QSO count, dates) with an **Open** button; contests from older versions saved only in the logbook are marked “in the logbook” and get their own log when opened. “New contest…” removes nothing – earlier ones can always be opened. Contest logs and settings are in the `~/Library/Application Support/FT710Control/Contests` folder; the program run from Xcode and the one installed from the DMG share the same logs but have separate settings – if one does not know the current contest, it opens the most recently used log.
**QRZ:** after entering a call, the name, QTH and locator from QRZ.com appear below the field; they are saved with the QSO (for a station operating away from home, e.g. P4/WE9V – only the name).
**Scope:** in the CONTEST tab, clicking a station (DX Cluster, POTA) on the scope tunes the radio and puts the call into the contest field – without switching to the LOG. **Worked in contest on the scope:** stations already worked in this contest on the band (per the contest’s dupe rules – in CQ WW call and band, in contests counted per mode also the spot’s mode) are **red** (default), **hidden** or unchanged – while the CONTEST tab is open.
**DX Cluster spot:** the **Spot** button next to the contest field spots the last logged station, and **Send a DX Cluster spot…** in a QSO’s menu in the contest log – the selected one. The window shows a ready command (“DX 14025.0 DL1ABC CQ WW DX”) that can be edited before sending; it needs a cluster connection.
**Cabrillo:** **Cabrillo header…** – categories (FT-710 power: LOW), club, address, soapbox; **Export Cabrillo…** saves the .log file to send to the organiser.

The rules were checked against the official rules (CQ WPX 2025, SP DX Contest 2023–2024, IARU HF, ARRL DX, CQ WW), but organisers sometimes change them – check the rules before a contest. The score shown is the claimed score; the organiser may adjust it after log checking.
"""),

        HelpTopic(id: "catshare", icon: "point.3.connected.trianglepath.dotted", titlePL: "CAT Share (WSJT-X, JTDX)", titleEN: "CAT Share (WSJT-X, JTDX)",
                  bodyPL: """
CAT Share pozwala innym programom sterować radiem przez tę aplikację (jedyny właściciel portu szeregowego).

1. Zakładka **CAT SHARE** → włącz serwer rigctl `127.0.0.1:4532`. Stan przełączników (serwer, „Pozwól na PTT”) jest zapamiętywany – po ponownym uruchomieniu programu serwer włącza się sam.
2. W WSJT-X: Settings → Radio:
   • Rig: **Hamlib NET rigctl**, Network Server: **127.0.0.1:4532**
   • PTT Method: **CAT**, Mode: **Data/Pkt**, Split Operation: **Fake It** albo **Rig**
3. Audio w WSJT-X: wejście i wyjście **USB Audio Device** (kodek radia).
4. PTT z zewnętrznych programów wymaga zaznaczenia **Pozwól na PTT**.

Rozłączenie programu w trakcie nadawania zawsze wysyła TX0. Limit czasu nadawania obowiązuje także tutaj.
• **Inne programy (RUMlogNG, loggery):** w ustawieniach radia wybierz model **„Hamlib NET rigctl”**, host 127.0.0.1, port 4532 – **nie** „Yaesu FT-710” (ten model wysyła natywne komendy CAT radia, których serwer nie rozumie; log CAT Share pokaże wtedy wskazówkę). Odpytywanie co ok. 500 ms wystarczy.
• Obsługiwany jest też **rozszerzony format rigctld** (polecenia z przedrostkiem `+`, `;`, `|` albo `,`, np. `+f`), którego używają nowsze loggery Hamlib – odpowiedzi z nazwami pól jak w oryginalnym rigctld.
""",
                  bodyEN: """
CAT Share lets other programs control the radio through this app (the only owner of the serial port).

1. **CAT SHARE** tab → turn on the rigctl server `127.0.0.1:4532`. The switch states (server, “Allow PTT”) are remembered – after restarting the program the server turns on by itself.
2. In WSJT-X: Settings → Radio:
   • Rig: **Hamlib NET rigctl**, Network Server: **127.0.0.1:4532**
   • PTT Method: **CAT**, Mode: **Data/Pkt**, Split Operation: **Fake It** or **Rig**
3. WSJT-X audio: input and output **USB Audio Device** (the radio's codec).
4. PTT from external programs requires **Allow PTT**.

A program disconnecting while transmitting always triggers TX0. The transmit time limit applies here too.
• **Other programs (RUMlogNG, loggers):** in the rig settings choose the model **“Hamlib NET rigctl”**, host 127.0.0.1, port 4532 – **not** “Yaesu FT-710” (that model sends the radio's native CAT commands, which the server does not understand; the CAT Share log will then show a hint). Polling about every 500 ms is enough.
• The **extended rigctld format** is supported too (commands prefixed with `+`, `;`, `|` or `,`, e.g. `+f`), used by newer Hamlib loggers – replies with field names as in the original rigctld.
"""),

        HelpTopic(id: "audio", icon: "speaker.wave.2", titlePL: "Audio USB", titleEN: "USB audio",
                  bodyPL: """
Zakładka **AUDIO**:
• **Z radia (RX)** – kodek USB radia (zwykle „USB Audio Device”), **Głośniki / słuchawki** – gdzie słuchać.
• **Włącz odsłuch** – dźwięk odbiornika na Macu; potrzebny też do zakładki WIDMO AUDIO.
• **Mikrofon (TX)** i **Do radia (TX)** – nadawanie fonią z mikrofonu Maca przez USB („Nadawaj audio z Maca przez USB”).

Mikrofon (TX) nie może być wejściem z radia – aplikacja odmówi nadawania, bo odbierany dźwięk trafiłby do nadajnika. W radiu źródło modulacji SSB musi być ustawione na USB.

macOS pyta o dostęp do mikrofonu przy pierwszym użyciu – zgoda jest potrzebna także do odczytu dźwięku z radia.

**Redukcja szumu (DSP na Macu)** – filtr między wyjściem audio radia a słuchawkami: oddziela mowę od szumu. Poziomy: **Lekki** i **Średni** (najlepsza zrozumiałość mowy), **Mocny** i **Maks.** (najwięcej ciszy między relacjami, mowa lekko przycięta). Program sam uczy się widma szumu w ok. 1 s.
• **Głos DX** – algorytm OM-LSA z dokładnym śledzeniem szumu (MCRA): dla każdego pasma ocenia prawdopodobieństwo obecności mowy – mowę zostawia, tło ścisza łagodnie, bez „ćwierkania”. **Najlepszy wybór dla słabych stacji DX**: w pomiarach stosunek mowy do tła lepszy o 2–3 dB niż poziom Średni we wszystkich próbach (także dla stacji pod szumem, SNR −6 dB).
• **AI** – sieć neuronowa RNNoise (Xiph): przy stacjach **dobrze słyszalnych** w hałaśliwym paśmie wycisza tło lepiej niż pozostałe poziomy (działa przy 48 kHz). **Słabe stacje DX** – na poziomie szumu albo pod nim – sieć uznaje za szum i wycina; pomiar: przy SNR −6 dB AI traci ok. 7 dB mowy, a poziom Średni daje lepszy stosunek mowy do tła. Dla słabych stacji wybierz **Głos DX**. Suwak **Siła AI** (30–100 %, domyślnie 70 %) miesza wynik sieci z oryginałem – mniejsza siła zostawia słabe sygnały słyszalne.
• **ANF – gwizdy** – automatycznie wycina gwizdy i nośne (np. stację strojącą obok, heterodyny); na czystej mowie lekko ją zmienia, więc włączaj przy gwizdach.
• **NB – trzaski** – wygasza trzaski i impulsy (wyładowania atmosferyczne, iskrzenie); mowy nie rusza.
• **APF (CW)** – wąski filtr szczytowy w słuchawkach (50 / 100 / 200 Hz); jego środek **podąża za tonem dekodera CW**, więc słyszysz tę stację, którą dekoder czyta. To samo ustawienie jest w zakładce CW. Przy CW nie włączaj ANF – wycina stałe tony, a więc także sygnał CW.
• **Korektor (EQ)** – 8 pasm dla odsłuchu SSB (200 Hz … 3,2 kHz) z wykresem charakterystyki. Gotowe ustawienia: **Płasko**, **DX – mowa** (mniej basu, wyraźniejsze 1,3–2,4 kHz, mniej syku – słaba stacja w szumie), **Wyraźność (zawody)** (mocniej to samo), **Ciepło (rozmowa)** (łagodniej przy długim QSO), **Mniej szumu** (tłumi syk powyżej pasma mowy). Ruszenie suwaka zmienia ustawienie na „Własne”; podwójne kliknięcie suwaka zeruje pasmo, kółko myszy zmienia o 0,5 dB. Całość jest ściszana o największe podbicie, więc korektor nie przesterowuje.
• Kolejność w łańcuchu: NB → ANF → redukcja szumu (AI albo Lekki…Maks.) → APF → pasmo głosu → korektor → wyrównanie głośności.
• **Pasmo głosu 250–2900 Hz** – wycina szum poza pasmem mowy.
• **Wyrównanie głośności** – redukcja szumu ścisza całość; to ją wyrównuje.
• Szybki wybór: panel **NR Mac** w lewej kolumnie – poziom (OFF / 1–4 / DX / AI) oraz ANF, NB i APF (działa przy włączonym odsłuchu).
• Filtr działa tylko na odsłuch; widmo, dekodery SSTV, CW i RTTY oraz praca zdalna dostają dźwięk bez zmian. Opóźnienie ok. 21 ms. Ustawienia zapisuje „Zapisz ustawienia”.
• To filtr na Macu, niezależny od DNR w radiu – można używać obu, ale zwykle wystarczy jeden.

**Zapisz ustawienia** zapamiętuje urządzenia (po stałym identyfikatorze), głośności, nadawanie przez USB i stan odsłuchu – program startuje z nimi do następnego zapisu. Napis „Zmiany niezapisane” oznacza, że bieżące ustawienia różnią się od zapisanych.
• **Pasek stanu** (na dole okna): ikona głośnika wycisza i odcisza odsłuch (poziom zostaje zapamiętany), suwak to ta sama głośność co w zakładce AUDIO; głośność jest zapamiętywana między uruchomieniami.
• **Korektor nadawania (TX)** – 12 pasm (60, 100, 160, 250, 400, 630 Hz, 1; 1,4; 1,8; 2,3; 2,8; 3,3 kHz), ±12 dB, dla mikrofonu Maca i mikrofonu panelu zdalnego (dźwięk przez USB do radia). Gotowe ustawienia: **Płasko**, **DX – przebicie** (obcięte niskie, podbite 1,4–2,8 kHz – czytelność w szumie i pile-upie), **Rozmowa – pełny głos**, **Zawody**; ruszenie suwaka – „Własne”. Korektor zmienia barwę, nie głośność (całość ściszana o największe podbicie – nie przesteruje toru); poziom ustaw MIC GAIN w radiu. FT-710 ma własny korektor mikrofonu – na początek ustaw go płasko, żeby oba się nie sumowały. Sprawdzaj ALC i najlepiej odsłuch na drugim odbiorniku albo WebSDR.
""",
                  bodyEN: """
**AUDIO** tab:
• **From radio (RX)** – the radio's USB codec (usually “USB Audio Device”), **Speakers / headphones** – where to listen.
• **Start monitoring** – receiver audio on the Mac; also needed for the AUDIO SPECTRUM tab.
• **Microphone (TX)** and **To radio (TX)** – voice transmit from the Mac microphone over USB (“Send Mac audio to the radio over USB”).

The microphone (TX) must not be the radio's input – the app refuses to transmit, because received audio would go back into the transmitter. On the radio the SSB modulation source must be set to USB.

macOS asks for microphone access on first use – permission is also needed to read audio from the radio.

**Noise reduction (DSP on the Mac)** – a filter between the radio's audio output and your headphones: it separates speech from noise. Levels: **Light** and **Medium** (best speech intelligibility), **Strong** and **Max** (most silence between transmissions, speech slightly trimmed). The program learns the noise spectrum by itself in about 1 s.
• **DX voice** – the OM-LSA algorithm with accurate noise tracking (MCRA): for every band it estimates the probability that speech is present – speech is kept, the background is lowered gently, without “chirping”. **The best choice for weak DX stations**: in measurements the speech-to-background ratio was 2–3 dB better than Medium in every trial (also for stations below the noise, SNR −6 dB).
• **AI** – the RNNoise neural network (Xiph): for **clearly audible** stations in a noisy band it quietens the background better than the other levels (works at 48 kHz). **Weak DX stations** – at or below the noise level – are treated as noise and removed; measured: at SNR −6 dB AI loses about 7 dB of speech, while Medium gives a better speech-to-background ratio. For weak stations choose **DX voice**. The **AI strength** slider (30–100 %, default 70 %) mixes the network output with the original – a lower strength keeps weak signals audible.
• **ANF – whistles** – automatically removes whistles and carriers (e.g. a station tuning up nearby, heterodynes); it slightly alters clean speech, so turn it on when there are whistles.
• **NB – crackles** – blanks crackles and impulses (atmospheric static, sparking); speech is left alone.
• **APF (CW)** – a narrow peak filter in the headphones (50 / 100 / 200 Hz); its centre **follows the CW decoder tone**, so you hear the station the decoder is reading. The same setting is in the CW tab. Do not use ANF with CW – it removes steady tones, including the CW signal.
• **Equaliser (EQ)** – 8 bands for SSB listening (200 Hz … 3.2 kHz) with a response graph. Presets: **Flat**, **DX – voice** (less bass, clearer 1.3–2.4 kHz, less hiss – a weak station in noise), **Clarity (contest)** (more of the same), **Warm (ragchew)** (gentler for long QSOs), **Less hiss** (cuts hiss above the speech band). Moving a slider switches to “Custom”; double-clicking a slider resets the band, the mouse wheel changes it by 0.5 dB. The overall level is lowered by the largest boost, so the equaliser does not clip.
• Order in the chain: NB → ANF → noise reduction (AI or Light…Max) → APF → voice band → equaliser → level equalisation.
• **Voice band 250–2900 Hz** – removes noise outside the speech band.
• **Level equalisation** – noise reduction makes everything quieter; this evens it out.
• Quick choice: the **NR Mac** panel in the left column – level (OFF / 1–4 / DX / AI) plus ANF, NB and APF (works while monitoring is on).
• The filter only affects listening; the spectrum, the SSTV, CW and RTTY decoders and remote operation get the audio unchanged. Delay about 21 ms. Settings are stored with “Save settings”.
• This is a Mac filter, independent of the radio's DNR – both can be used, but usually one is enough.

**Save settings** stores the devices (by a permanent identifier), volumes, USB transmit and the monitoring state – the program starts with them until you save again. “Unsaved changes” means the current settings differ from the saved ones.
• **Status bar** (at the bottom of the window): the speaker icon mutes and unmutes listening (the level is remembered), the slider is the same volume as in the AUDIO tab; the volume is remembered between launches.
• **Transmit equalizer (TX)** – 12 bands (60, 100, 160, 250, 400, 630 Hz, 1, 1.4, 1.8, 2.3, 2.8, 3.3 kHz), ±12 dB, for the Mac microphone and the remote panel microphone (audio over USB to the radio). Presets: **Flat**, **DX – punch** (lows cut, 1.4–2.8 kHz boosted – readability in noise and pile-ups), **Ragchew – full voice**, **Contest**; moving a slider – “Custom”. The equalizer changes the tone, not the loudness (the whole is lowered by the largest boost – it does not overdrive the path); set the level with MIC GAIN in the radio. The FT-710 has its own microphone equalizer – start with it flat so the two do not add up. Watch ALC and preferably listen on a second receiver or a WebSDR.
"""),

        HelpTopic(id: "remote", icon: "iphone.radiowaves.left.and.right", titlePL: "Praca zdalna", titleEN: "Remote operation",
                  bodyPL: """
Sterowanie radiem z przeglądarki (iPhone, iPad, dowolny komputer).

**Panel w przeglądarce**
• **Układ**: na telefonie jedna kolumna; na iPadzie w poziomie i na komputerze skop szeroko po prawej, sterowanie po lewej.
• **Język PL / EN** – przycisk w rogu (zapamiętany w przeglądarce); domyślnie język programu.
• **Skop** ze strojeniem dotknięciem i **znakami stacji** z DX Cluster i POTA – te same kolory co na skopie w programie (obserwowany, nowy kraj, niepotwierdzony; POTA z zieloną obwódką); dotknięcie znaku stroi radio. Wyświetlanie zależy od przełączników „Stacje na skopie” w zakładce EKRAN.
• **Pasma** pamiętają ostatnią częstotliwość i tryb (w tej przeglądarce); domyślnie fonia (LSB poniżej 10 MHz, USB powyżej), 30 m – CW.
• **Radio**: ATT, IPO, AGC, moc (suwak), w CW prędkość klucza radia (KS); zwijane sekcje **Odbiór** (AF, RF, SQL, NB i NR z poziomami, DNF), **Filtr** (szerokość, przesunięcie IF, notch i contour z częstotliwością), **Nadawanie** (MIC, PROC z poziomem, AMC), **Tuner i pamięci** (tuner, strojenie TUNE, komunikaty z pamięci radia M1–M5). Przy częstotliwości: VFO B, **A=B**, **A↔B**, **SPLIT**.
• **Dziennik**: znak (dane z QRZ i „było: N QSO” jak w programie), RST (puste – domyślne dla trybu), imię, QTH, lokator, uwagi; częstotliwość i tryb z radia; zapis tą samą funkcją co w programie (wysyłka do serwisów według ustawień); lista ostatnich QSO.
• **FT8 / FT4**: tryb, dekodowanie, przyciski pasm (częstotliwości bieżącego trybu), Hound; lista ostatnich 40 komunikatów w kolorach jak na Macu („do mnie” wyróżnione). **Dotknięcie komunikatu** – wołanie stacji i włączenie TX (jak dwuklik na Macu); **CQ**, **Włącz/Wyłącz TX**, **STOP**; widać następny komunikat, stację QSO, TX/RX Hz i status. Dekodowanie i sygnał – na Macu (odsłuch w zakładce AUDIO musi działać). Nadawanie – te same warunki co PTT (zgoda zdalna zastępuje „Odblokuj TX”); po rozłączeniu przeglądarki TX FT8 się wyłącza.
• **CW** (w trybie CW): tekst z klawiatury i makra (CQ, 5NN, TU…; {MY} – Twój znak, {CALL} – znak z dziennika), STOP.
• **DX Cluster** i **Alerty**: listy z kolorami jak w programie; dotknięcie stroi radio i wpisuje znak do dziennika.
• **Nadawanie z przeglądarki** (PTT, CW, komunikaty z pamięci, TUNE) – te same warunki: „Pozwól na nadawanie zdalne” i połączenie szyfrowane (Tailscale/HTTPS); po rozłączeniu przeglądarki nadawanie CW i komunikatu jest przerywane.
• **Jak aplikacja**: na iPhonie Udostępnij → Do ekranu początkowego – ikona FT-710 i panel na całym ekranie.
• **Mikrofon (PTT)**: przeglądarka pyta o zgodę po dotknięciu „Włącz audio”. W Chrome na iPhonie potrzebna jest też zgoda systemowa: Ustawienia → Aplikacje → Chrome → Mikrofon; w Safari zgoda dla strony: „aA” → Ustawienia witryny → Mikrofon.
• Podpowiedzi i test dźwięku – zwinięte pod „Pomoc i test dźwięku”.

**Przez Tailscale (z nadawaniem)**
1. Zakładka **ZDALNIE**: ustaw hasło (min. 8 znaków) i włącz serwer. Stan przełączników (serwer, nadawanie zdalne, sieć domowa) jest zapamiętywany – po ponownym uruchomieniu serwer włącza się sam; jeśli zostawisz „Pozwól na nadawanie zdalne”, operator z hasłem może nadawać od razu po starcie programu.
2. Jednorazowo w Terminalu: `tailscale serve --bg 8710`. Jeśli Terminal odpowiada „command not found: tailscale”, aplikacja Tailscale nie dodała polecenia do ścieżki – użyj pełnej ścieżki: `/Applications/Tailscale.app/Contents/MacOS/Tailscale serve --bg 8710`, albo (wersja Standalone) zainstaluj polecenie w ustawieniach aplikacji Tailscale (integracja z wierszem poleceń), albo dodaj do `~/.zshrc` alias: `alias tailscale="/Applications/Tailscale.app/Contents/MacOS/Tailscale"`.
3. Na telefonie z Tailscale otwórz `https://<nazwa-maca>.<tailnet>.ts.net`, podaj hasło, dotknij „Włącz audio”.
4. Nadawanie wymaga na stacji zaznaczenia **Pozwól na nadawanie zdalne**.

**Przez internet bez Tailscale – tunel Cloudflare** (zakładka ZDALNIE)
• Telefon potrzebuje tylko przeglądarki (Safari) – bez aplikacji i konta. Na Macu jednorazowo w Terminalu: `brew install cloudflared` (bezpłatny program Cloudflare).
• Hasło pracy zdalnej musi mieć co najmniej **12 znaków** (adres jest publiczny). **Uruchom tunel** – po chwili pojawia się adres `https://….trycloudflare.com` z **kodem QR** (zeskanuj aparatem iPhone'a), **Kopiuj** i **Otwórz**. Opcja „Uruchamiaj razem z pracą zdalną”.
• Połączenie jest szyfrowane (HTTPS): działa mikrofon, PTT i nadawanie – na tych samych warunkach co przez Tailscale. Po 5 błędnych hasłach logowanie jest blokowane na 1 min, przy kolejnych seriach na 5 min, 15 min i 1 h.
• Adres zmienia się przy każdym uruchomieniu tunelu; **Zatrzymaj tunel**, wyłączenie pracy zdalnej albo zamknięcie programu kończy dostęp. Ruch przechodzi przez serwery Cloudflare, a tunel testowy nie ma gwarancji dostępności – do stałej, codziennej pracy wygodniejszy jest Tailscale. Obie drogi mogą działać jednocześnie.

**W sieci domowej (bez nadawania)**
Przełącznik **Dostęp z sieci domowej** – adres `http://<adres-maca>:8710`: sterowanie, skop i odsłuch. Bez HTTPS przeglądarka nie udostępnia mikrofonu, a stacja odrzuca PTT.

**Bezpieczeństwo:** PTT działa tylko podczas trzymania przycisku; brak sygnału od przeglądarki przez 0,5 s wyłącza nadawanie na stacji. Jeden operator naraz; 5 błędnych haseł blokuje logowanie na minutę.

iPhone: jeśli nic nie słychać, sprawdź głośność; strona próbuje grać także w trybie cichym.
""",
                  bodyEN: """
Control the radio from a browser (iPhone, iPad, any computer).

**The browser panel**
• **Layout**: one column on a phone; on an iPad in landscape and on a computer the scope is wide on the right and the controls on the left.
• **Language PL / EN** – a button in the corner (remembered in the browser); by default the program's language.
• **Scope** with tap-to-tune and **station calls** from DX Cluster and POTA – the same colours as on the program's scope (watched, new entity, unconfirmed; POTA with a green outline); tapping a call tunes the radio. Display depends on the “Stations on the scope” switches in the DISPLAY tab.
• **Bands** remember the last frequency and mode (in this browser); by default phone (LSB below 10 MHz, USB above), 30 m – CW.
• **Radio**: ATT, IPO, AGC, power (slider), in CW the radio's key speed (KS); collapsible sections **Receive** (AF, RF, SQL, NB and NR with levels, DNF), **Filter** (width, IF shift, notch and contour with frequency), **Transmit** (MIC, PROC with level, AMC), **Tuner and memories** (tuner, TUNE, radio memory messages M1–M5). Next to the frequency: VFO B, **A=B**, **A↔B**, **SPLIT**.
• **Log**: call (QRZ data and “worked: N QSOs” as in the program), RST (empty – the mode default), name, QTH, locator, comment; frequency and mode from the radio; saved by the same function as in the program (upload to services per settings); a list of recent QSOs.
• **FT8 / FT4**: mode, decoding, band buttons (frequencies of the current mode), Hound; a list of the last 40 messages in the Mac's colours (“to me” highlighted). **Tapping a message** – call the station and enable TX (like a double-click on the Mac); **CQ**, **Enable/Disable TX**, **STOP**; the next message, the QSO station, TX/RX Hz and the status are shown. Decoding and the signal – on the Mac (listening in the AUDIO tab must run). Transmitting – the same conditions as PTT (remote permission replaces “Enable TX”); when the browser disconnects, FT8 TX is turned off.
• **CW** (in CW mode): typed text and macros (CQ, 5NN, TU…; {MY} – your call, {CALL} – the call from the log), STOP.
• **DX Cluster** and **Alerts**: lists with the program's colours; tapping tunes the radio and puts the call into the log.
• **Transmitting from the browser** (PTT, CW, memory messages, TUNE) – the same conditions: “Allow remote transmit” and an encrypted connection (Tailscale/HTTPS); when the browser disconnects, CW and message transmission is stopped.
• **Like an app**: on iPhone Share → Add to Home Screen – the FT-710 icon and the panel full screen.
• **Microphone (PTT)**: the browser asks for permission after tapping “Audio on”. Chrome on iPhone also needs system permission: Settings → Apps → Chrome → Microphone; in Safari the website permission: “aA” → Website Settings → Microphone.
• Hints and the sound test – collapsed under “Help and sound test”.

**Via Tailscale (with transmit)**
1. **REMOTE** tab: set a password (min. 8 characters) and turn the server on. The switch states (server, remote transmit, home network) are remembered – after restarting the program the server turns on by itself; if you leave “Allow remote transmit” on, an operator with the password can transmit right after the program starts.
2. Once in Terminal: `tailscale serve --bg 8710`. If Terminal answers “command not found: tailscale”, the Tailscale app did not add the command to the path – use the full path: `/Applications/Tailscale.app/Contents/MacOS/Tailscale serve --bg 8710`, or (Standalone version) install the command in the Tailscale app settings (command-line integration), or add an alias to `~/.zshrc`: `alias tailscale="/Applications/Tailscale.app/Contents/MacOS/Tailscale"`.
3. On a phone with Tailscale open `https://<mac-name>.<tailnet>.ts.net`, enter the password, tap “Włącz audio” (the browser page is currently in Polish only).
4. Transmit requires **Allow remote transmit** at the station.

**Over the internet without Tailscale – Cloudflare tunnel** (REMOTE tab)
• The phone only needs a browser (Safari) – no app and no account. On the Mac, once in Terminal: `brew install cloudflared` (a free Cloudflare program).
• The remote password must have at least **12 characters** (the address is public). **Start the tunnel** – after a moment the `https://….trycloudflare.com` address appears with a **QR code** (scan it with the iPhone camera), **Copy** and **Open**. Option “Start together with remote operation”.
• The connection is encrypted (HTTPS): the microphone, PTT and transmitting work – on the same conditions as via Tailscale. After 5 wrong passwords login is blocked for 1 min, for further series 5 min, 15 min and 1 h.
• The address changes every time the tunnel starts; **Stop the tunnel**, turning off remote operation or quitting the program ends access. Traffic passes through Cloudflare's servers and the test tunnel has no availability guarantee – for permanent, everyday use Tailscale is more convenient. Both ways can run at the same time.

**On the home network (no transmit)**
**Home network access** switch – address `http://<mac-address>:8710`: control, scope and listening. Without HTTPS the browser does not provide the microphone and the station rejects PTT.

**Safety:** PTT works only while the button is held; no signal from the browser for 0.5 s ends transmission at the station. One operator at a time; 5 wrong passwords block login for a minute.

iPhone: if you hear nothing, check the volume; the page also tries to play in silent mode.
"""),

        HelpTopic(id: "diag", icon: "stethoscope", titlePL: "Diagnostyka", titleEN: "Diagnostics",
                  bodyPL: """
• **Diagnostyka USB** (przycisk przy zakładkach) – co macOS widzi po stronie radia: mostek CAT (Silicon Labs), mostek skopu FT4222, kodek audio. „Zapamiętaj stan” + odłączenie kabla pokazuje, które urządzenia należą do radia. „Kopiuj raport” – do zgłoszenia problemu.
• **LOG CAT** – komunikacja z radiem; tu pojawia się lista komend, na które radio nie odpowiedziało (wyszarzone kontrolki), i odrzucone komendy („?”).
• **Pasek stanu** – liczniki płynności: ile razy na sekundę odświeża się okno, panel skopu, linia widma i waterfall, ile ramek przychodzi z radia oraz opóźnienie głównego wątku. Płynnie: „trace” i „wf” równe „frames”, opóźnienie poniżej ok. 30 ms.
""",
                  bodyEN: """
• **USB diagnostics** (button next to the tabs) – what macOS sees of the radio: CAT bridge (Silicon Labs), FT4222 scope bridge, audio codec. “Save state” + unplugging the cable shows which devices belong to the radio. “Copy report” – for problem reports.
• **CAT LOG** – communication with the radio; this lists commands the radio did not answer (greyed-out controls) and rejected commands (“?”).
• **Status bar** – smoothness counters: how many times per second the window, scope panel, spectrum line and waterfall refresh, how many frames arrive from the radio, and the main-thread delay. Smooth: “trace” and “wf” equal “frames”, delay below about 30 ms.
"""),

        HelpTopic(id: "keys", icon: "keyboard", titlePL: "Skróty", titleEN: "Shortcuts",
                  bodyPL: """
• **⌘?** – pomoc
• **Enter** (pasek stanu) – Połącz / Rozłącz
• **Kółko myszy nad cyfrą VFO** – zmiana cyfry
• **Kliknięcie cyfry**, potem **↑ / ↓** – zmiana, **← / →** – sąsiednia cyfra, **Esc** – koniec
• **Kliknięcie w skop** – strojenie VFO-A, **kliknięcie znaku spotu** – strojenie do spotu
• **Podwójne kliknięcie spotu** w DX Cluster – strojenie
• **Enter** w polu znaku dziennika – zapis QSO
• Przeglądarka (praca zdalna): **spacja** – PTT (przytrzymaj)
""",
                  bodyEN: """
• **⌘?** – help
• **Enter** (status bar) – Connect / Disconnect
• **Mouse wheel over a VFO digit** – change the digit
• **Click a digit**, then **↑ / ↓** – change, **← / →** – neighbouring digit, **Esc** – done
• **Click on the scope** – tune VFO-A, **click a spot call sign** – tune to the spot
• **Double-click a spot** in DX Cluster – tune
• **Enter** in the log call field – log the QSO
• Browser (remote operation): **space** – PTT (hold)
"""),

        HelpTopic(id: "trouble", icon: "wrench.and.screwdriver", titlePL: "Rozwiązywanie problemów", titleEN: "Troubleshooting",
                  bodyPL: """
**„Brak odpowiedzi” po połączeniu** – wybierz drugi port z pary, sprawdź CAT RATE = 38400 w radiu i prędkość w pasku stanu.

**Skop: „Nie znaleziono libft4222.dylib”** – zainstaluj obie biblioteki FTDI (libft4222 i libftd2xx) w `/usr/local/lib` i zdejmij kwarantannę (`xattr`). **„Nie można otworzyć FT4222”** – SCU-LAN10 = ON, ponowne podłączenie USB, żaden inny program nie używa skopu.

**macOS pyta o hasło do pęku kluczy (QRZ)** – kliknij „Zawsze pozwalaj”. Po każdej nowej kompilacji programu macOS pyta ponownie (traktuje ją jak nowy program).

**Kontrolka wyszarzona** – radio nie odpowiedziało na jej komendę; szczegóły w LOG CAT.

**Brak dźwięku z radia** – zgoda na mikrofon dla programu (Ustawienia systemowe → Prywatność i ochrona → Mikrofon), właściwe urządzenie „Z radia (RX)”.

**Waterfall się zacina** – sprawdź liczniki w pasku stanu (temat „Diagnostyka”) i prześlij je przy zgłoszeniu.

**DX Cluster nie łączy** – spróbuj innego węzła z menu; komunikaty węzła widać w konsoli.

**Klucz CW nie nadaje** – sprawdź w radiu: tryb CW, BK-IN włączony, PC KEYING = DTR (albo RTS, zgodnie z wyborem w programie); w programie port klucza = drugi port radia (nie port CAT). „Nie można otworzyć portu klucza” – port zajęty przez inny program (np. WSJT-X ustawiony na PTT przez ten port).

**Dekoder CW pisze śmieci** – sprawdź SNR (pasek w zakładce CW) i wskaż stację kliknięciem w widmo; przy kilku stacjach blisko siebie zawęź filtr radia (RX BW).

**Odzyskanie dziennika** – w oknie dziennika kliknij **Przywróć z kopii…** i wybierz kopię. Ręcznie: kopie są w `~/Library/Application Support/FT710Control/` (`logbook-kopia.json`, `logbook-przed-….json`) – zamknij program, zmień nazwę wybranej kopii na `logbook.json` i uruchom program ponownie. Gdy dysk Maca uległ awarii: kopie dnia są w iCloud Drive (folder **FT-710 Control/Kopie dziennika**) – na nowym komputerze przywróć je przez **Przywróć z kopii…**, a plik `dziennik-najnowszy.adi` zaimportujesz do dowolnego programu.
""",
                  bodyEN: """
**“No response” after connecting** – choose the other port of the pair, check CAT RATE = 38400 on the radio and the speed in the status bar.

**Scope: “libft4222.dylib not found”** – install both FTDI libraries (libft4222 and libftd2xx) in `/usr/local/lib` and remove the quarantine flag (`xattr`). **“Cannot open the FT4222”** – SCU-LAN10 = ON, replug USB, no other program is using the scope.

**macOS asks for the Keychain password (QRZ)** – click “Always Allow”. After every new build macOS asks again (it treats it as a new program).

**Greyed-out control** – the radio did not answer its command; details in CAT LOG.

**No audio from the radio** – microphone permission for the program (System Settings → Privacy & Security → Microphone), the correct “From radio (RX)” device.

**Waterfall stutters** – check the counters in the status bar (“Diagnostics” topic) and include them in your report.

**DX Cluster does not connect** – try another node from the menu; node messages are shown in the console.

**The CW key does not transmit** – check on the radio: CW mode, BK-IN on, PC KEYING = DTR (or RTS, matching the program); in the program the key port = the radio's second port (not the CAT port). “Cannot open the key port” – the port is used by another program (e.g. WSJT-X set to PTT on that port).

**The CW decoder prints garbage** – check the SNR (bar in the CW tab) and pick the station by clicking the spectrum; with several stations close together, narrow the radio filter (RX BW).

**Restoring the logbook** – in the logbook window click **Restore from backup…** and choose a backup. Manually: backups are in `~/Library/Application Support/FT710Control/` (`logbook-kopia.json`, `logbook-przed-….json`) – quit the program, rename the chosen backup to `logbook.json` and start the program again. If the Mac's disk failed: daily backups are in iCloud Drive (folder **FT-710 Control/Kopie dziennika**) – on a new computer restore them with **Restore from backup…**, and `dziennik-najnowszy.adi` can be imported into any program.
"""),

        HelpTopic(id: "about", icon: "info.circle", titlePL: "O programie", titleEN: "About",
                  bodyPL: """
**FT-710 Control** – sterowanie Yaesu FT-710 na macOS.

Odczyt skopu FT-710 przez FT4222 opiera się na protokole z projektu **RigControl Web** (Jason Weisberger NT0Y, licencja Apache 2.0) – szczegóły w pliku `THIRD_PARTY_NOTICES.md`. Biblioteki FTDI (LibFT4222, D2XX) nie są dołączone i podlegają licencji FTDI.

Dekoder FT8/FT4: **ft8_lib** (Kārlis Goba YL3JG, licencja MIT; zawiera KISS FFT, Mark Borgerding, BSD). Protokoły FT8 i FT4: K1JT, K9AN, G4WJS (WSJT-X).

Mapy: Apple MapKit. Dane stacji: QRZ.com (interfejs XML, wymaga konta).

**Wersja beta, aktualizacje, licencja**
• Program jest w publicznej wersji beta: https://github.com/sp5xtf/FT710Control – tam nowe wersje (Releases) i zgłaszanie błędów (Issues).
• **Aktualizacje:** program sprawdza nowe wersje na GitHub przy starcie i raz na dobę; gdy jest nowsza, na pasku stanu pojawia się pomarańczowy przycisk „Nowa wersja …”. Ręcznie: menu FT710Control → **Sprawdź aktualizacje…**.
• **Licencja:** GNU GPL v3.0 – program wolny i otwarty; składniki zewnętrzne i ich licencje – plik THIRD_PARTY_NOTICES.md.
""",
                  bodyEN: """
**FT-710 Control** – Yaesu FT-710 control for macOS.

Reading the FT-710 scope through the FT4222 is based on the protocol from the **RigControl Web** project (Jason Weisberger NT0Y, Apache 2.0 licence) – see `THIRD_PARTY_NOTICES.md`. The FTDI libraries (LibFT4222, D2XX) are not included and are subject to the FTDI licence.

FT8/FT4 decoder: **ft8_lib** (Kārlis Goba YL3JG, MIT licence; includes KISS FFT, Mark Borgerding, BSD). FT8 and FT4 protocols: K1JT, K9AN, G4WJS (WSJT-X).

Maps: Apple MapKit. Station data: QRZ.com (XML interface, account required).

**Beta, updates, licence**
• The program is in public beta: https://github.com/sp5xtf/FT710Control – new versions (Releases) and bug reports (Issues).
• **Updates:** the program checks GitHub for new versions at start-up and once a day; when there is a newer one, an orange “New version …” button appears in the status bar. Manually: menu FT710Control → **Check for updates…**.
• **Licence:** GNU GPL v3.0 – free and open software; third-party components and their licences – the THIRD_PARTY_NOTICES.md file.
""")
    ]
}
