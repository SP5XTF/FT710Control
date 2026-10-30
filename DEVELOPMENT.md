# FT-710 Control (macOS)

**FT-710 Control** – sterowanie Yaesu FT-710 na macOS: CAT, audio USB, skop RF z radia (FT4222),
dziennik ADIF, CAT Share dla WSJT-X i praca zdalna przez przeglądarkę.

## Pomoc / Help

Wbudowana pomoc: menu **Pomoc → Pomoc FT-710 Control** (⌘?) albo przycisk **?** w pasku stanu.
14 tematów (pierwsze kroki, VFO, filtr, nadawanie i bezpieczeństwo, skop RF, dziennik i QRZ, DX Cluster,
CAT Share, audio, praca zdalna, diagnostyka, skróty, problemy, o programie) z wyszukiwarką, w języku interfejsu.

## Język / Language

Interfejs jest dostępny po polsku i po angielsku. Wybór w pasku stanu (prawy dolny róg okna) działa
od razu, bez restartu i bez rozłączania radia. Domyślnie używany jest język systemu.
Komunikaty statusu wyświetlone przed zmianą języka zmienią się przy najbliższej aktualizacji.

The interface is available in Polish and English – pick the language in the status bar
(bottom-right corner). The switch is immediate, without restarting or disconnecting the radio.

## Zmiana nazwy (dawniej FT710Console)

Projekt nazywa się teraz **FT710Control** (pakiet, katalog i program). Przy pierwszym uruchomieniu
nowa wersja kopiuje ustawienia (pamięci M1–M6, znak, hasło stacji, opisy komunikatów…) i dziennik
spod starej nazwy; stare dane zostają nietknięte jako kopia zapasowa. W Xcode otwórz `Package.swift`
z nowego katalogu `FT710Control`.


Natywna aplikacja SwiftUI do sterowania Yaesu FT-710 przez USB (CAT).
Niezależny projekt hobbystyczny, niezwiązany z Yaesu.

## Uruchomienie

Wymagane: macOS 13+, Xcode lub Command Line Tools (`xcode-select --install`).

```bash
cd FT710Control
swift run
```

albo `open Package.swift` w Xcode i Run (⌘R).

## Przed pierwszym połączeniem

1. Podłącz FT-710 kablem USB. W `/dev` pojawią się zwykle dwa porty
   (`cu.SLAB_USBtoUART…` lub `cu.usbserial-…`). Jeden to Enhanced COM (CAT),
   drugi Standard COM. Jeśli jeden nie odpowiada, wybierz drugi.
2. Ustaw w radiu `CAT RATE` (MENU → OPERATION SETTING → GENERAL) i wybierz tę samą
   wartość w polu „Baud" w aplikacji (domyślnie 38400).
3. Pierwszy test bez nadawania: po „Połącz" status powinien zmienić się na
   „Połączono z FT-710", a częstotliwość i tryb zaczną się odświeżać.

## Bezpieczeństwo nadawania

- PTT działa tylko po zaznaczeniu „Odblokuj nadawanie" i tylko podczas trzymania przycisku.
- Rozłączenie lub wyłączenie odblokowania zawsze wysyła `TX0;` (rozłączenie - bezwarunkowo,
  także gdy odpytywanie radia jeszcze nie zauważyło nadawania).
- Limit czasu nadawania (1/3/5 min, domyślnie 3): po jego upływie aplikacja sama wysyła `TX0;`,
  wycisza mikrofon i blokuje PTT do puszczenia przycisku.
- Zamknięcie aplikacji (⌘Q, zamknięcie okna, Ctrl+C w Terminalu, `kill`) wysyła `TX0;` synchronicznie,
  z czekaniem na fizyczne wysłanie bajtów, zanim port zostanie zamknięty.
  Nie da się tego zagwarantować przy awarii programu, `kill -9` ani odłączeniu kabla.
- Pierwsze testy PTT rób na sztucznym obciążeniu i zgodnie z warunkami swojej licencji.

## Audio USB (etap 2)

Sekcja „Audio USB" ma cztery wybory urządzeń: dźwięk z radia (RX), głośniki/słuchawki Maca,
mikrofon Maca (TX) i wejście audio USB radia (TX). Urządzenia radia wykrywane są po nazwie
(„USB Audio CODEC"); jeśli wybrało się coś innego, popraw ręcznie.

- **Odsłuch:** „Włącz odsłuch" przekazuje dźwięk z radia na głośniki. Pierwszy raz macOS zapyta
  o zgodę na mikrofon (dla Terminala lub Xcode), bo wejście USB radia jest dla systemu mikrofonem.
- **Nadawanie z Maca:** zaznacz „Nadawaj audio z Maca przez USB", potem „Odblokuj nadawanie".
  Mikrofon jest wtedy gotowy, ale wyciszony, i przepuszczany tylko podczas trzymania PTT.
  Podczas nadawania odsłuch jest wyciszany. Używaj słuchawek, żeby uniknąć sprzężenia.
- W radiu trzeba wskazać USB jako źródło modulacji (w menu źródła modulacji SSB/DATA oraz wybór
  REAR/USB - dokładne nazwy pozycji sprawdź w instrukcji FT-710). Poziomy wejścia i wyjścia
  audio USB ustawia się w menu radia, a suwak TX w aplikacji tylko tłumi sygnał.
- W Konfiguracji Audio MIDI ustaw dla urządzenia radia próbkowanie 48 kHz.
- Ograniczenia: przy długim odsłuchu zegary urządzeń mogą się rozjeżdżać (aplikacja gubi nadmiar
  próbek zamiast narastać opóźnienie); odłączenie urządzenia w trakcie pracy nie jest obsłużone.

## Mierniki (etap 3)

S-metr pokazuje jednostki S i dB ponad S9. Podczas nadawania aktywne są PO (waty), COMP i ALC (procent skali) oraz SWR – w kolejności jak na wyświetlaczu radia.
Mierniki TX są czytane komendą `RM` (COMP=RM3, ALC=RM4, PO=RM5, SWR=RM6 - konwencja jak w Hamlib; jeśli radio
odpowie `?`, w logu pojawi się komunikat i numery trzeba poprawić w `CATClient.swift`).

Tabele przeliczeniowe w `Meters.swift` to wartości startowe typowe dla Yaesu, nie kalibracja Twojego
radia. Obok każdego miernika widać surowy odczyt 0–255. Porównaj go z wyświetlaczem radia i popraw
tabele (`sMeterDB`, `powerWatts`, `swr`).

## Skop RF radia (FT4222)

Panel „Skop RF radia" pokazuje prawdziwy skop FT-710, czyli te same dane co wyświetlacz radia,
czytane przez wbudowany mostek FTDI FT4222. Span (1 kHz – 1 MHz) i tryb CENTER/FIX ustawia się
w radiu; aplikacja odczytuje je z ramek. Najechanie pokazuje częstotliwość, kliknięcie stroi VFO A,
czerwona linia to VFO A.

Protokół (SPI master 375 kHz, ramki 4096 bajtów ze wzorcem FF 01 EE 01, linia widma 850 punktów)
pochodzi z projektu RigControl Web (Apache 2.0) – patrz `THIRD_PARTY_NOTICES.md`.

### Wymagania

1. W radiu: MENU → OPERATION SETTING → GENERAL → **SCU-LAN10 = ON**, potem ponowne podłączenie USB.
   „Diagnostyka USB" musi pokazywać `0403:601C FT4222`.
2. Biblioteka FTDI **LibFT4222 for Mac** (strona FTDI → FT4222H Software Examples → Mac OS).
   Po rozpakowaniu:

   ```bash
   sudo mkdir -p /usr/local/lib
   sudo cp libft4222*.dylib /usr/local/lib/
   cd /usr/local/lib
   ls libft4222*            # sprawdź dokładną nazwę pliku z wersją
   sudo ln -sf <nazwa-pliku-z-wersją>.dylib libft4222.dylib
   sudo xattr -d com.apple.quarantine /usr/local/lib/libft4222*.dylib
   lipo -info /usr/local/lib/libft4222.dylib   # na Apple Silicon musi zawierać arm64
   ```

   Jeśli pakiet zawiera też `libftd2xx*.dylib`, skopiuj go tak samo (z dowiązaniem `libftd2xx.dylib`).
   Inną lokalizację można podać zmienną środowiskową `FT4222_LIB=/pełna/ścieżka.dylib`.
3. Tylko jeden program naraz może czytać skop – zamknij RigControl Web itp.

Gdy coś nie działa, przycisk „Log" w panelu pokazuje, na którym etapie (biblioteka, otwarcie
urządzenia, synchronizacja ramek) wystąpił problem. Poziomy są względne (0–255 radia przeliczane
na skalę ok. −130…−20 dB), nie kalibrowane w dBm.

## Widmo audio i waterfall (etap 4)

Panel „Widmo audio odbiornika" pokazuje linię widma i waterfall liczone z dźwięku USB radia
(FFT 4096 punktów, okno Hanna, ok. 23 klatki/s, rozdzielczość ok. 12 Hz przy 48 kHz).
Działa, gdy włączony jest odsłuch; głośność można skręcić do zera.

- To jest widmo **pasma audio** (do 3/4/6 kHz wokół częstotliwości strojenia), a nie skop RF radia.
- Najechanie kursorem pokazuje częstotliwość audio i - w USB/LSB/DATA/RTTY - odpowiadającą jej
  częstotliwość RF (USB: dial + f, LSB: dial − f). W CW wynik zależy od tonu (pitch), więc RF nie jest liczone.
- „Tło" i „Kontrast" działają od razu na linię widma, a na waterfall dla nowych wierszy.
- „Auto" (domyślnie włączone) ustawia tło na podstawie poziomu szumu, więc obraz nie zależy od
  poziomu wyjścia audio USB ustawionego w radiu. Wyłącz, żeby ustawiać tło ręcznie.
- Aplikacja nie pozwala nadawać, gdy mikrofon (TX) i „Z radia (RX)" to to samo urządzenie
  (odbierany dźwięk trafiałby z powrotem do nadajnika).

## Diagnostyka USB

Przycisk „Diagnostyka USB" sprawdza przez IOKit, co macOS widzi po stronie radia: mostek CAT
Silicon Labs (VID 10C4) i porty szeregowe, mostek FTDI skopu (VID 0403) oraz kodek audio USB.
Raport można skopiować do zgłoszenia błędu. Jeśli mostka FTDI nie widać, w radiu trzeba włączyć
MENU → OPERATION SETTING → GENERAL → SCU-LAN10 = ON i ponownie podłączyć USB.

## CAT Share (WSJT-X, JTDX, programy do logowania)

Sekcja „CAT Share" uruchamia serwer zgodny z rigctld (Hamlib NET rigctl) na `127.0.0.1:4532`,
dostępny tylko z tego Maca. Aplikacja zostaje jedynym właścicielem portu szeregowego radia,
a inne programy sterują FT-710 przez nią.

Ustawienia WSJT-X (Settings → Radio):
- Rig: **Hamlib NET rigctl**, Network Server: **127.0.0.1:4532**
- PTT Method: **CAT**, Mode: **Data/Pkt**, Split Operation: **Fake It** albo **Rig** (split radia przez komendę `ST`)
- Audio (Settings → Audio): wejście i wyjście **USB Audio Device** (kodek radia). WSJT-X korzysta z niego
  bezpośrednio; odsłuch w tej aplikacji może działać równolegle.

Obsługiwane: częstotliwość VFO A (`f`/`F`), tryb (`m`/`M`, DATA-U ↔ PKTUSB), PTT (`t`/`T`),
VFO B jako częstotliwość split (`i`/`I`). Nieznane komendy dostają `RPRT -4` i trafiają do logu
w sekcji CAT Share - jeśli jakiś program się na nich wywraca, ten log pokaże, czego brakuje.

Bezpieczeństwo:
- PTT z zewnątrz działa tylko po zaznaczeniu „Pozwól na PTT"; bez tego program dostaje `RPRT -9`.
- Rozłączenie programu w trakcie nadawania i wyłączenie zgody wysyłają `TX0;`.
- Limit czasu nadawania obowiązuje także dla PTT z CAT Share.

## Dziennik łączności (ADIF)

**Szybki wpis** (sekcja „Dziennik łączności” w głównym oknie): wpisz znak, uzupełnij RST/imię/QTH/lokator,
Enter lub „Zapisz QSO”. Częstotliwość i pasmo brane są z CAT, tryb dobierany do trybu radia (DATA → FT8,
można zmienić). Początek QSO to chwila wpisania pierwszej litery znaku, koniec - chwila zapisu, oba w UTC.
Pod formularzem pojawia się ostrzeżenie, jeśli stacja jest już w dzienniku.

**Okno dziennika** („Otwórz dziennik”): tabela z wyszukiwaniem, usuwanie zaznaczonych, import i eksport ADIF
(całość albo zaznaczone), ustawienia „Mój znak” i „Mój lokator” (zapisywane jako STATION_CALLSIGN i MY_GRIDSQUARE).

- Eksport: plik `.adi` (ADIF 3.1.4) w ASCII - polskie litery są zamieniane na łacińskie (ł → l, ą → a…),
  bo format ADI nie dopuszcza innych znaków. Tryby zgodne ze specyfikacją (FT4 = MODE MFSK + SUBMODE FT4).
- Import: pola, których dziennik nie wyświetla (np. QSL, DXCC), są zachowywane i wracają przy eksporcie.
  Duplikaty (ten sam znak, pasmo, tryb i początek w odstępie do 2 minut) są pomijane.
- Dane: `~/Library/Application Support/FT710Control/logbook.json`, zapisywany po każdej zmianie,
  z kopią `logbook-kopia.json` robioną przy każdym uruchomieniu. Nieczytelny plik nie jest nadpisywany,
  tylko odkładany na bok.

**WSJT-X / JTDX:** zaznacz „Odbieraj QSO z WSJT-X / JTDX” w oknie dziennika, a w WSJT-X ustaw
Settings → Reporting → UDP Server **127.0.0.1**, port **2237** (ten sam co w aplikacji). Po kliknięciu „OK”
w oknie „Log QSO” łączność trafia do dziennika automatycznie. WSJT-X wysyła UDP tylko pod jeden adres -
jeśli używasz JTAlert lub GridTracker na tym porcie, jeden z programów musi dostać inny port.

## Praca zdalna przez przeglądarkę (Tailscale)

Mac przy radiu jest **stacją**: jedynym właścicielem radia, który sprawdza i wykonuje polecenia.
Operator łączy się zwykłą przeglądarką (iPhone, iPad, dowolny komputer) i ma: częstotliwość, tryby,
pasma, strojenie (przyciski, wpis kHz, dotknięcie skopu), mierniki, skop RF z waterfallem,
odsłuch RX oraz nadawanie fonią z mikrofonu urządzenia (przycisk PTT trzymany palcem lub spacja).

### Uruchomienie

1. **Stacja:** sekcja „Praca zdalna” → ustaw hasło (min. 8 znaków) → włącz „Serwer 127.0.0.1:8710”.
   Serwer słucha **tylko lokalnie** – nic nie jest wystawione do sieci domowej ani internetu.
2. **Tailscale na stacji** (jednorazowo, w Terminalu):

   ```bash
   tailscale serve --bg 8710
   ```

   (Wersja z App Store: `/Applications/Tailscale.app/Contents/MacOS/Tailscale serve --bg 8710`.)
   Tailscale wystawi stronę pod `https://<nazwa-maca>.<tailnet>.ts.net` z prawdziwym certyfikatem,
   dostępną tylko dla Twoich urządzeń w tailnecie. Jeśli poprosi o włączenie HTTPS w panelu
   administracyjnym, zrób to (Settings → DNS → HTTPS Certificates). Wyłączenie: `tailscale serve reset`.
3. **Telefon/tablet:** zainstaluj Tailscale, zaloguj tym samym kontem, otwórz adres z punktu 2,
   podaj hasło, dotknij „Włącz audio” (przeglądarka zapyta o mikrofon).

HTTPS jest konieczne: przeglądarki (zwłaszcza Safari na iPhonie) nie dają dostępu do mikrofonu
stronom otwartym przez zwykłe http. Dlatego dostęp jest przez `tailscale serve`, a nie przez adres IP.

### Dostęp z sieci domowej (opcjonalnie)

Przełącznik „Dostęp z sieci domowej” udostępnia panel także pod `http://<adres-maca>:8710`
(adresy są wyświetlane w sekcji). To połączenie **nie jest szyfrowane**, dlatego:

- działa sterowanie, skop, mierniki i odsłuch (przez zapasowy odtwarzacz, bo bez HTTPS przeglądarki
  wyłączają AudioWorklet), ale **nie ma nadawania** – przeglądarka i tak nie da mikrofonu stronie
  bez HTTPS, a stacja odrzuca PTT z takich połączeń;
- serwer przyjmuje wtedy tylko adresy prywatne (192.168.x.x, 10.x.x.x, 172.16–31.x.x, link-local,
  Tailscale 100.64/10) – nawet przypadkowo przekierowany port na routerze nie wystawi stacji do internetu;
- hasło idzie przez sieć domową jawnym tekstem – używaj innego niż do czegokolwiek ważnego.

Do pracy z nadawaniem w domu używaj adresu Tailscale: w tej samej sieci Tailscale łączy urządzenia
bezpośrednio, więc opóźnienie jest takie samo jak przez http.

### Nadawanie – bezpieczeństwo

- Wymaga zaznaczenia na stacji „Pozwól na nadawanie zdalne”; bez tego przycisk PTT jest nieaktywny.
- PTT działa tylko podczas trzymania przycisku. Przeglądarka wysyła sygnał podtrzymania co 100 ms;
  jeśli przez **0,5 s** nic nie dotrze (zerwane łącze, uśpiony telefon, zamknięta karta), stacja sama
  wysyła TX0. Tak samo przy rozłączeniu, wyłączeniu zgody lub serwera.
- Limit czasu nadawania (1/3/5 min) obowiązuje także dla zdalnego PTT.
- Dźwięk z mikrofonu trafia do radia **tylko** podczas zdalnego PTT (nie uruchomi VOX).
- Jeden operator naraz; po 5 błędnych hasłach logowanie jest blokowane na minutę.
- Przyciski „Rozłącz operatora” na stacji i „Rozłącz” w przeglądarce.

### Audio

Format sieciowy: PCM 16 bit, mono, 12 kHz (ok. 24 kB/s w każdą stronę – działa też przez LTE).
RX pochodzi z urządzenia „Z radia (RX)”, mikrofon trafia do „Do radia (TX)”. W radiu źródłem
modulacji dla SSB musi być USB (pozycja źródła modulacji SSB w menu – sprawdź w instrukcji FT-710),
a poziom ustawia się poziomem wejścia audio USB w radiu. **Pierwsze testy na sztucznym obciążeniu**
z podglądem ALC w przeglądarce. Używaj słuchawek – podczas nadawania odsłuch w przeglądarce jest wyciszany.

Źródła strony są w katalogu `web/` (index.html, app.js, worklet.js) i są osadzone w `RemoteWebPage.swift`.

## Układ okna

- **lewa kolumna:** pasma (1.8–70 MHz), 6 trybów (CW i DATA – ponowne kliknięcie przełącza wstęgę U/L),
  RX DSP / filtr (wykres pasma, RX BW, SHIFT, NOTCH, DNF, CONTOUR), AGC,
- **środek:** VFO-A i VFO-B z przyciskami strojenia pod spodem, obok zegarowe mierniki S, PO, SWR,
  COMP, ALC i pole RX/TX; pod nimi skop RF z waterfallem, który wypełnia całą wysokość nad zakładkami,
- **prawa kolumna:** AF, SQL, TX (moc), RF, IPO/AMP1/AMP2, ATT, DNR i NB (suwak: 0 = wyłączone),
  MIC, PROC (0 = wyłączony), AMC; na dole – równo z dołem waterfalla – blok nadawania: zgoda na TX
  i limit czasu, TUNE (ON/OFF, strojenie), PTT, komunikaty z pamięci radia i STOP,
- **dół:** zakładki DZIENNIK, AUDIO, WIDMO AUDIO, CAT SHARE, ZDALNIE, LOG CAT – na stałe pod skopem,
- **pasek stanu:** port, prędkość, Połącz/Rozłącz, język, klatki skopu, aktywne usługi, zegar UTC.

Gdy okno jest niższe, niż potrzeba, boczne kolumny przewijają się wewnątrz (kółkiem myszy),
zamiast wystawać poniżej waterfalla.

### Zmiana częstotliwości na wyświetlaczach VFO

- **Kółko myszy nad cyfrą** zmienia tę cyfrę (nad setkami herców: krok 100 Hz, nad kHz: 1 kHz itd.).
  Kółko w górę zawsze zwiększa częstotliwość, niezależnie od „naturalnego przewijania”;
  na gładziku krok wypada co kilkanaście punktów przesunięcia palców, bezwładność jest pomijana.
- **Kliknięcie cyfry** zaznacza ją (podkreślenie): **↑/↓** zmienia cyfrę, **←/→** przechodzi do sąsiedniej,
  **Esc** albo ponowne kliknięcie kończy zaznaczenie. Strzałki nie działają, gdy piszesz w polu tekstowym.
- **Pole obok trybu** – wpisanie częstotliwości i Enter: `7.074` (MHz), `7074` lub `7074.5` (kHz),
  `7074000` lub `7.074.000` (Hz); można dopisać jednostkę (`21.074MHz`, `7074 kHz`). Zakres 30 kHz – 75 MHz.

To samo działa dla VFO-A i VFO-B.

### SPLIT (pamięci M1–M6 – kod w Memories.swift, obecnie niewyświetlane)

- **M1–M6** (lewa kolumna) to szybkie pamięci aplikacji: częstotliwość i tryb VFO-A, zachowywane między
  uruchomieniami. Kliknięcie zapisanej pamięci ją przywołuje, kliknięcie pustej – zapisuje bieżące ustawienie;
  prawy przycisk: „Zapisz bieżącą” lub „Wyczyść”. Pamięć pasująca do bieżącej częstotliwości jest podświetlona.
  Kanały pamięci radia nie są używane, więc radio nie przechodzi w tryb MEM.
- **SPLIT** (obok A↔B) – komenda `ST0;`/`ST1;`: odbiór na VFO-A, nadawanie na VFO-B. Przy włączonym
  SPLIT VFO-A ma oznaczenie „RX”, VFO-B „TX”/„SPLIT”, a podczas nadawania na czerwono świeci VFO-B.
  CAT Share obsługuje też split dla WSJT-X (Split Operation: Rig).

### Komunikaty (MESSAGE MEMORY radia)

Panel „Komunikaty” (prawa kolumna) odtwarza komunikaty nagrane w pamięci radia: w SSB/AM/FM kanały
głosowe 1–5 (`PB0n;`), w CW kanały CW 1–5 (`KYn;`). Treść nagrywa się w radiu; w aplikacji można nadać
przyciskom własne opisy (prawy przycisk → „Zmień opis…”), osobno dla fonii i CW.

- Odtworzenie **zaklucza nadajnik**, więc przyciski działają tylko przy zaznaczonym „Odblokuj nadawanie”.
- **STOP** jest zawsze dostępny: wysyła `PB00;TX0;` (zatrzymanie komunikatu i koniec nadawania).
- Limit czasu nadawania obejmuje teraz także nadawanie uruchomione przez aplikację bez PTT
  (komunikat, TUNE). Dozór kończy się sam, gdy radio zgłosi koniec nadawania.
- Rozłączenie CAT wysyła `PB00;TX0;`.
- Składnia `KYn;` dla CW w FT-710 jest do potwierdzenia – jeśli radio ją odrzuci, w LOG CAT pojawi się „?”.

### Ustawienia radia (komendy CAT)

| Kontrolka | CAT | Kontrolka | CAT |
|---|---|---|---|
| AF | `AG0nnn` | Preamp | `PA0n` (0 IPO, 1 AMP1, 2 AMP2) |
| RF | `RG0nnn` | ATT | `RA0n` (0 off, 1 6 dB, 2 12 dB, 3 18 dB) |
| SQL | `SQ0nnn` | AGC | `GT0n` (0 off … 4 auto) |
| Moc TX | `PCnnn` | NB / poziom | `NB0n` / `NL0nnn` |
| AMC | `AOnnn` | | |
| MIC | `MGnnn` | DNR / poziom | `NR0n` / `RL0nn` |
| PROC / poziom | `PR0n` / `PLnnn` | DNF | `BC0n` |
| Tuner | `AC00n` (0 off, 1 on, 2 strojenie) | RX BW | `SH0;` odczyt, `SH00nn` (indeks szerokości) |
| SHIFT | `IS0;` odczyt, `IS00±nnnn` (Hz, krok 20) | NOTCH | `BP00n` wł./wył., `BP01nnn` (×10 Hz) |
| CONTOUR | `CO000n` wł./wył., `CO01nnnn` (Hz) | | |

**Panel „RX DSP / Filtr”** pokazuje pasmo przepustowe w dziedzinie audio (0–4 kHz): szerokość i SHIFT
przesuwają trapez, ręczny NOTCH to czerwone wcięcie, CONTOUR – bursztynowe przegięcie, DNF – znacznik.
Środek pasma przyjęty jest jako ok. 1500 Hz (SSB/DATA) lub 700 Hz (CW, ton nie jest odczytywany z radia),
a opisy szerokości pochodzą z tabel Yaesu FTDX10/FTDX101 – obok zawsze jest wartość zgłoszona przez radio.
W AM/FM szerokość jest stała.

Składnia pochodzi z rodziny Yaesu FTDX10/FT-710. Po połączeniu aplikacja odpytuje każde ustawienie;
kontrolka, na którą radio nie odpowie w 3 s, jest wyłączona, a w zakładce LOG CAT pojawia się lista
takich komend. Co ok. 3 s ustawienia są odczytywane ponownie, więc zmiany gałkami na radiu są widoczne.
Przy przesuwaniu suwaka komendy idą najwyżej co 60 ms.

**TUNE** (strojenie tunera) nadaje nośną, dlatego działa tylko przy zaznaczonym „Odblokuj nadawanie”.

## QRZ.com, mapa, odległość i azymut

**Konto:** okno dziennika → wiersz „QRZ.com” → użytkownik i hasło → „Zapisz”. Hasło trafia do pęku kluczy
macOS (Keychain), nazwa użytkownika do ustawień. Status logowania jest widoczny obok. Do pełnych danych
QRZ wymaga subskrypcji „XML Logbook Data”; bez niej QRZ zwraca tylko część pól (aplikacja to sygnalizuje).

**W zakładce DZIENNIK:**
- po wpisaniu znaku (ok. 0,7 s przerwy) aplikacja pobiera dane z QRZ i **uzupełnia puste pola** imię, QTH,
  lokator – wpisanego ręcznie nic nie nadpisuje; znaki z dodatkami (`SP5XX/P`, `DL/SP5XX`) są szukane
  jako znak podstawowy,
- **karta stacji** (po prawej): znak i miejsce, odległość w km i mi, azymut z kierunkiem świata i azymut
  drogi długiej (LP), **mapa z trasą po kole wielkim** (MapKit), dane: imię, QTH, kraj, lokator, współrzędne,
  DXCC/CQ/ITU, przyciski „Szukaj w QRZ” i „QRZ.com” (strona znaku w przeglądarce),
- kliknięcie łączności w tabeli pokazuje jej stację na karcie (bez danych QRZ – z lokatora z dziennika),
- tabela ma kolumny Kraj, Odległość i Azymut.

Odległość i azymut liczone są od „Mój lokator” (okno dziennika) do współrzędnych z QRZ albo środka
lokatora korespondenta. Przy zapisie QSO do pól ADIF trafiają COUNTRY, DXCC, CQZ, ITUZ i DISTANCE (km),
więc eksport zawiera te dane. Wyniki QRZ są zapamiętywane do końca działania programu (bez zbędnych zapytań),
sesja QRZ odnawia się sama po wygaśnięciu.

## Usługi online (LoTW, QRZ Logbook, eQSL, Club Log, HRDLog.net, Cloudlog, World Radio League)

Okno dziennika → **Usługi online…**: ustawienia każdej usługi (hasła i klucze w pęku kluczy macOS),
test połączenia, wysyłka automatyczna po zapisaniu QSO (ręcznie lub z WSJT-X), „Wyślij zaległe”
i „Oznacz wszystkie jako wysłane”. Import ADIF nie wysyła niczego. LoTW przez program TQSL (ARRL).
World Radio League przez API v1 (`api.worldradioleague.com`): klucz z Integrations → Developer API,
opcjonalne ID dziennika; poprawki łączności są wysyłane do WRL (PATCH).
Stan wysyłki w standardowych polach ADIF (`LOTW_QSL_SENT`, `QRZCOM_QSO_UPLOAD_STATUS`, `EQSL_QSL_SENT`,
`CLUBLOG_QSO_UPLOAD_STATUS`, `HRDLOG_QSO_UPLOAD_STATUS` i daty). Szczegóły w pomocy programu.

## Redukcja szumu w odsłuchu (DSP)

`AudioDenoiser` w ścieżce radio → słuchawki: STFT 1024/256 (okno sqrt-Hann), szum z minimum
wygładzonej mocy (~1 s), filtr Wienera „decision-directed”, podłoga tłumienia, wygładzanie
wzmocnień, pasmo głosu 250–2900 Hz, wyrównanie głośności. Poziomy Lekki/Średni/Mocny/Maks.
Pomiar na mowie z szumem (SNR 5 dB): szum −8…−18 dB, segSNR mowy +4,4…+1,9 dB. Opóźnienie 21 ms.

## Filtry audio odsłuchu (łańcuch)

NB (wygaszacz impulsów: próg 8× obwiedni ~2 ms, trzaski −17 dB, mowa nietknięta) → ANF (wzmacniacz linii
NLMS, 256 wsp., opóźnienie 1,3 ms, nośne −12…−16 dB) → AI (RNNoise v0.1.1, Xiph, BSD – tło −13…−16 dB przy
silnym szumie) albo filtr Wienera (Lekki…Maks.) albo Głos DX (OM-LSA + MCRA wg Cohen & Berdugo 2001/2002, dostrojone do słabej mowy SSB: +1,9…+2,7 dB mowa/tło względem „Średni”, 15/15 prób) → pasmo głosu → wyrównanie głośności. Inspiracja: zestaw filtrów
Thetis/WDSP (GPL) – zaimplementowane od zera z literatury, bez kodu Thetis.

## Ekran (waterfall)

Zakładka **EKRAN**: 6 palet waterfalla (zmiana przemalowuje całą historię – bufor przechowuje poziomy,
kolory nadaje tablica palety), wysokość widma, kolor i wypełnienie linii, tryb **3D** (perspektywa:
ostatnie linie widma w głąb, gradient palety według wysokości, rysowane w tle ≤ 15 kl./s).
Ustawienia zapamiętywane (`DisplaySettings`).

## CW – dekoder i nadawanie

Zakładka **CW**. Dekoder (`CWDecoder`): 8 kHz, automatyczny ton (FFT + interpolacja), obwiednia
(mieszanie, filtry ~15 % kropki), próg z histerezą i eliminacją zakłóceń, tempo z globalnego dopasowania
(kropki 1×, kreski 3×), przeszukiwanie wiązkowe słowa z trigramowym modelem języka QSO (+ znaki z dziennika).
Pomiar: czysty 18–35 WPM ≈ 0 %, SNR 3 dB ≈ 4 %, nierówna ręka 2,8 % (bez modelu 7,8 %).
Nadawanie (`CWKeyer`): DTR/RTS portu Standard COM (CAT-2), w radiu PC KEYING = DTR/RTS i BK-IN,
wątek o najwyższym priorytecie z `mach_wait_until`, makra, kontrola limitu, STOP.

## SSTV

Zakładka **SSTV** – dekoder i nadajnik na własnym kodzie (Accelerate, bez zewnętrznych bibliotek):
Martin M1/M2, Scottie S1/S2, Robot 36, PD 90/120/180. Odbiór: automatyczne rozpoznanie trybu po VIS,
korekcja rozstrojenia (±200 Hz) i pochylenia (dopasowanie prostej do impulsów synchronizacji), zapis do
`~/Pictures/FT710Control SSTV`. Nadawanie: obraz z pliku / plansza testowa / odebrany obraz, nakładka ze znakiem
i tekstem, PTT automatyczne, kontrola limitu nadawania. Algorytm sprawdzony prototypem (szum, +80 Hz, +150 ppm):
błąd 1,4–3 % skali, pochylenie ≤ 1 piksel we wszystkich trybach.

## DX Cluster

Zakładka **DX CLUSTER**: połączenie telnet z węzłem klastra (DXSpider, AR-Cluster, CC Cluster,
Reverse Beacon Network). Menu „Węzły” ma kilka przykładowych publicznych węzłów (adresy węzłów się
zmieniają – można wpisać dowolny). Logowanie następuje automatycznie znakiem z pola „Znak”
(pusty = „Mój znak” z okna dziennika) po wykryciu monitu `login:` / `Please enter your call:`.

- **Spoty** w tabeli: czas UTC, częstotliwość, znak (link do QRZ.com), pasmo, tryb (z komentarza,
  np. FT8, albo odgadnięty z planu pasm IARU R1), status w dzienniku: **nowy** / **inne pasmo** / **✓ pasmo**,
  komentarz, spotter. Ten sam znak na tej samej częstotliwości w ciągu 10 minut nie dubluje się.
- **Podwójne kliknięcie** spotu stroi radio (VFO-A); opcjonalnie ustawia też tryb. W trybach cyfrowych
  radio jest ustawiane na częstotliwość „dial” (standard FT8/FT4 albo sygnał − 1500 Hz). Spoty spoza
  pasm FT-710 (np. 2 m) są wyszarzone i nie przestrajają radia. Prawy przycisk: Dostrój / QRZ.com.
- **Filtry:** pasmo (wszystkie / moje pasmo / wybrane), tryb (CW / SSB / DIGI), ukrywanie stacji zrobionych
  na tym paśmie.
- **Konsola węzła** z polem komend (np. `sh/dx 20`, `set/filter`); negocjacja telnet jest obsługiwana.
- **Na skopie RF** nad linią widma pojawiają się znaki stacji ze spotów z ostatnich 30 minut w widocznym
  zakresie; kliknięcie znaku stroi radio.
- „Łącz automatycznie”: połączenie przy starcie i ponowna próba co 30 s po zerwaniu.

## Pomysły odłożone na później

- **FT2** - jedyny otwarty opis pochodzi z WSJT-X Improved (GPL): przed pracą decyzja licencyjna.
- **Natywna aplikacja zdalna** (iOS/iPadOS w SwiftUI) - po wydaniu programu; najpierw dokument protokołu
  serwera zdalnego (WebSocket: JSON + binarne audio/skop) dla nowego czatu.
- **Winlink** (analiza 10.2026):
  - VARA HF/FM - zamknięty modem (EA5HVK), płatna licencja, protokół nieopublikowany, tylko Windows x86:
    własnej implementacji nie będzie; na Macu M działa przez CrossOver (Wine). VARA FM - VHF/UHF, dla FT-710
    praktycznie bez zastosowania (FM tylko 10 i 6 m).
  - ARDOP - otwarty protokół Winlink; implementacja ardopcf (C, licencja MIT, github.com/pflarue/ardop)
    może być modułem jak ft8_lib; bramek ARDOP mniej niż VARA.
  - Klient poczty: Pat (otwarty, wersja na macOS, obsługuje VARA i ARDOP).
  - Drogi: A) Pat + VARA/ardopcf zewnętrznie, nasz program daje CAT (CAT Share) i dźwięk - mały nakład,
    rekomendowany start; B) ardopcf wbudowany + Pat do poczty; C) ARDOP + własny klient Winlink.

## Kod tymczasowy

Brak. Jednorazowe migracje z wersji roboczych (naprawa krajów stacji spoza swojego kraju, kolory „kraj
niepotwierdzony” w FT8, alert „Nowe potwierdzenia QSL”, kopiowanie zawodów z dziennika) usunięte w wersji 0.9 -
nowy użytkownik nie ma takich danych; zawody zapisane w dzienniku przez stare wersje otwiera „Poprzednie zawody…”.

## Testy automatyczne

W katalogu projektu: **`swift test`** (albo w Xcode: Product → Test, ⌘U). Plik `Tests/FT710ControlTests/CoreLogicTests.swift`,
16 testów logiki, która wcześniej była sprawdzana jednorazowymi prototypami:

- ADIF w obie strony (czysty ASCII, pola potwierdzeń w `extra`),
- FT8: rozbiór komunikatów, zakres raportów (−31 → „73”!), echo kodera, kodowanie → synteza → dekodowanie FT8 i FT4
  (moduł C `FTX`), przepróbkowanie 48 → 12 kHz,
- potwierdzenia QSL: dopasowanie do dziennika (znak z /P, pasmo, ±30 min, tryb rozstrzyga), trzy warianty odpowiedzi QRZ,
  litery L/E/Q i zasada „do DXCC tylko LoTW”,
- kodowanie formularzy (`+` jako `%2B`, litery spoza ASCII) i pakiet IPFIX PSKReportera (nagłówek, zestawy, rekord nadawcy),
- stan kraju DXCC (nowy / na paśmie / niepotwierdzony, Sycylia jako Włochy) i statystyka DXCC w kategoriach,
- ponowne tłumaczenie zapamiętanych tekstów (`Lr`) i zgodność pól `{n}` we wszystkich hasłach słownika,
- POTA: spoty (nazwa parku w `name`, QRT, tryb radia) i numery parków z `SIG_INFO`/`POTA_REF`.

Testy uruchamiać po każdej większej zmianie - kompilator na Macu sprawdza też to, czego nie wyłapią prototypy.

## FT8 / FT4 (odbiór i nadawanie)

Zakładka **FT8/FT4**: dekodowanie po każdym cyklu (15 s / 7,5 s), wodospad w stylu WSJT-X (najnowszy wiersz
u góry, linia i czas UTC na początku cyklu, znaczniki RX/TX, kliknięcie / Shift+kliknięcie), listy
„Aktywność pasma” i „Częstotliwość odbioru” z kolorami (do mnie, nowy kraj, nowy na paśmie, CQ, zaliczony),
przyciski standardowych częstotliwości (DATA-U), kontrola zegara przez NTP i ostrzeżenie o przesunięciu DT.

- Silnik: moduł C `Sources/FTX` – **ft8_lib** (Kārlis Goba YL3JG, MIT) bez zmian + warstwa `ftxw.c`:
  odejmowanie zdekodowanych sygnałów (2–3 przebiegi), SNR w skali WSJT-X (±1 dB na sygnale syntetycznym),
  DT skorygowane o jeden symbol, trwała tablica skrótów znaków `<...>`, kodowanie tekstu i synteza GFSK.
- Pomiar: 75,4 % dekodów WSJT-X na nagraniach testowych ft8_lib (1298 komunikatów); próg FT8 −17 dB
  (100 %) / −18,7 dB (50 %), FT4 −13 dB / −14,5 dB. Kodowanie → synteza → dekodowanie: 14/14 wiadomości.
- Swift: `FT8Receiver.swift` (przepróbkowanie do 12 kHz – sprawdzone prototypem: 100 % dekodów po 12→48→12 kHz,
  zegar cykli UTC, bufor 40 s, wodospad 2,93 Hz/bin), `FT8Manager.swift` (rozbiór komunikatów, kraj z cty.dat,
  status w dzienniku, SNTP), `FT8View.swift`.
- Dźwięk do dekodera pochodzi sprzed filtrów odsłuchu (NB/ANF/AI nie szkodzą dekodowaniu).
- **Etap 2 – nadawanie** (`FT8Transmit.swift`): Tx1–Tx6 jak w WSJT-X, dwuklik = wołanie stacji, CQ,
  auto-sekwencja (sprawdzona symulacją 5 scenariuszy: S&P, CQ z kilkoma odpowiedziami, powtórzony R-raport,
  pominięty Tx1, DX pracujący z kimś innym), zapis QSO po RR73/73 (raz na stację; FT8 albo MFSK+FT4).
  Każdy komunikat przed nadaniem jest kodowany i odczytywany z powrotem (`ftxw_encode_echo`) – raport −31
  zakodowałby się jako „73”, więc raporty są ograniczone do −30…+30, a komunikat z innym echem nie jest nadawany;
  teksty nie będące komunikatem standardowym idą jako tekst dowolny (do 13 znaków).
  Harmonogram: PTT na początku cyklu, dźwięk 0,5 s później (`AVAudioPlayerNode.play(at:)` z czasem hosta),
  przygotowanie 0,45 s przed cyklem – po dekodowaniu poprzedniego; spóźniony start do 2 s (FT4 0,8 s) z obcięciem
  początku. Zabezpieczenia: Odblokuj TX, Zatrzymaj, watchdog 6 min, zmiana pasma/trybu, rozłączenie, limit radia,
  sprawdzanie DATA-U i urządzenia „Do radia”.
- **PSKReporter** (`PSKReporter.swift`): IPFIX wg pskreporter.info/pskdev.html (enterprise 30351, szablony
  0x50E2 odbiornik / 0x50E3 nadawcy), report.pskreporter.info:4739, jedno gniazdo UDP, pakiet co 5 min + 0–30 s
  losowo, szablony w pierwszych 3 pakietach i co godzinę, każda stacja raz na godzinę na paśmie, pakiety < 1400 B.
  Format sprawdzony niezależnym parserem IPFIX (RFC 5101): szablony, rekordy, wyrównanie, długości, pakiet bez szablonów.
- Następne: FT2.

## Co jest zrobione / co dalej

Zrobione: połączenie, odczyt i ustawianie VFO A, tryb, S-metr (surowy), pasma, kroki,
kopiowanie/zamiana VFO, PTT, podgląd komunikacji.
Do sprawdzenia z instrukcją CAT FT-710: kody trybów (MD), komendy AB/SV, skala S-metra.
Kolejne etapy: do ustalenia.

## Uwaga o sandboxie

Uruchamianie przez `swift run` nie wymaga uprawnień. Jeśli zrobisz z tego aplikację .app
z włączonym App Sandbox, dodaj uprawnienia dostępu do urządzeń USB/szeregowych.

## Propagacja

Zakładka **PROPAGACJA**: dane słoneczne i warunki KF/VHF z HamQSL (N0NBH, XML), indeks Kp z NOAA SWPC (JSON),
aktywność pasm i otwarcia 6 m–70 cm z własnego DX Cluster, mapa MapKit z linią szarości (położenie Słońca liczone
w programie - zgodność z efemerydami ~0,01°) i raportami odbioru z PSK Reporter (najwyżej co 5 min), mapy NOAA
(D-RAP, owal zorzy). Źródła podane w zakładce.

## Wydajność

- **Kompilacja Debug z optymalizacją** (`Package.swift`: `-O` dla Swift, `-O2` dla RNNoise i FTX) - DSP (FFT,
  waterfall, dekodery SSTV/CW, filtry audio, sieć RNNoise) działa płynnie także przy uruchamianiu z Xcode.
  Kosztem jest mniej dokładny debuger (zmienne „optimized away”); do szukania błędów można te linie
  tymczasowo usunąć.
- **Dziennik:** indeks według znaku (budowany raz po zmianie) dla „czy już była” i kolumny „Dziennik”
  w DX Cluster; zapis w tle (zwięzły JSON, seria zmian = jeden zapis, natychmiastowy zapis przy zamykaniu).
- **Okno:** tabela ostatnich QSO nie przerysowuje się przy strojeniu radia; widmo audio liczone tylko,
  gdy jest widoczne; waterfall - kolory przeliczane tylko dla nowej linii; dane zmieniające się co ramkę
  (widmo, mierniki, poziomy, spoty) w osobnych obiektach - nie przerysowują całego okna.

## Ikona

Oryginalna ikona (gałka VFO na tle waterfallu) - bez logo i wzornictwa producenta radia.
`Design/AppIcon.svg` (źródło), `Design/make_icon.py` (generator), `Design/AppIcon.iconset` i `Design/AppIcon.icns`
(dla pakietu .app: `CFBundleIconFile = AppIcon`). Przy uruchamianiu z Xcode ikonę w Docku ustawia program
(`Sources/FT710Control/Resources/AppIcon.png`).

## Samodzielna aplikacja (bez Xcode)

```bash
cd FT710Control
./build_app.sh             # → build/FT710Control.app
./build_app.sh --install   # → dodatkowo /Applications/FT710Control.app
```

Do **kompilacji** potrzebny jest kompilator Swift: Xcode albo same „Command Line Tools”
(`xcode-select --install`). **Gotowa aplikacja działa bez Xcode** - z Findera, Launchpada, Docka.

Skrypt: kompilacja Release, pakiet `.app` z ikoną i `Info.plist` (m.in. opis dostępu do mikrofonu),
podpis ad-hoc, jednorazowe przeniesienie ustawień z uruchomień przez Xcode. Dziennik, obrazy SSTV
i hasła (pęk kluczy) są wspólne dla obu sposobów uruchamiania.

Przy pierwszym uruchomieniu aplikacji macOS zapyta o **mikrofon** (dźwięk z radia przez USB) i o dostęp
do **pęku kluczy** (hasła QRZ, LoTW…) - wybierz „Zawsze pozwalaj”. Po każdej ponownej kompilacji pytanie
o pęk kluczy może się powtórzyć (nowy podpis ad-hoc). Skop RF nadal wymaga biblioteki FTDI FT4222
w `/usr/local/lib`. Aplikacja przeniesiona na inny Mac: pierwsze uruchomienie przez prawy przycisk →
„Otwórz” (program nie jest podpisany certyfikatem Apple).

## Wersja testowa (.dmg dla testerów)

```bash
./make_dmg.sh                    # dist/FT710Control-<wersja>-test-<data>.dmg (procesor tego Maca)
./make_dmg.sh --universal        # Apple Silicon + Intel (wymaga pełnego Xcode; na macOS 27+ Apple wycofuje Intel - zwykle zbędne)
FT710_CONTACT="SP5XTF, adres@example.com" ./make_dmg.sh   # kontakt wpisany do instrukcji
```

Obraz zawiera: aplikację, skrót do folderu Aplikacje, `PRZECZYTAJ MNIE.txt` / `READ ME.txt`
(wymagania, instalacja, pierwsze uruchomienie na macOS 13-14 i 15+, ustawienia radia, dodatkowe pliki:
biblioteki FTDI dla skopu, TQSL dla LoTW, QRZ, WSJT-X; zgłaszanie błędów) oraz `Licencje.txt`
(wymagana licencja BSD RNNoise, znaki towarowe). Szablony instrukcji: `Design/dmg/`.
Skrypt wypisuje sumę SHA-256 obrazu - testerzy mogą sprawdzić, że plik dotarł nieuszkodzony.

