# FT-710 Control

**A native macOS station program for the Yaesu FT-710** – rig control, RF scope and waterfall, FT8/FT4,
logbook with QSL confirmations and awards, DX Cluster, POTA, contests, CW/RTTY/SSTV and remote operation
from an iPhone or iPad browser.

> **Public beta.** The program is in active development and may contain bugs. Test transmitting into a
> dummy load with low power first, and please report problems in
> [Issues](https://github.com/sp5xtf/FT710Control/issues). The program checks for new versions itself
> (menu **FT710Control → Check for updates…**).

Documentation: **[Wiki](https://github.com/sp5xtf/FT710Control/wiki)** (the in-app help, English and Polish).
Polish version below – [wersja polska](#po-polsku).

## Features

- **Rig control (CAT over USB)**: VFO A/B, split, modes, filters (width, shift, notch, contour), NB/NR/DNF,
  AGC, ATT/IPO, power, MIC/PROC/AMC, tuner, radio memory messages, S/PO/SWR/COMP/ALC meters.
- **RF scope and waterfall** (FT4222 USB link): click to tune, DX Cluster and POTA call signs on the scope,
  Turbo/Inferno and other palettes, palette-coloured fill, peak hold, dB scale, time stamps, IARU R1 band
  plan strip, 3D view.
- **FT8/FT4**: decoding and transmitting, auto-sequencing, caller choice (strongest / farthest…), call
  limit, **Fox/Hound (DXpedition) mode** including combined Fox messages, PSKReporter.
- **Logbook**: filters and sorting, statistics, 3D QSO map, **manual QSO entry** (e.g. a second radio on 2 m / 70 cm /
  23 cm, with propagation mode and satellite), QRZ.com / **HamQTH** lookups, uploads to LoTW,
  eQSL, QRZ Logbook, Club Log, HRDLog, Cloudlog, confirmation downloads, ADIF import/export, iCloud backup.
- **Awards**: DXCC, WAZ, WPX, VUCC, POTA, IOTA, SOTA, WWFF, PGA.
- **DX Cluster, POTA spots, alerts** (someone calling you, new DXCC…), propagation maps.
- **Contests** with a separate log, scoring, dupes on the scope and Cabrillo export (CQ WW, CQ WPX, SP DX
  and others).
- **CW, RTTY, SSTV and PSK31/PSK63** decoders and transmitters, each with a logging panel.
- **Antenna SWR sweep** across a band (low-power carriers, SWR curve, saved and compared measurements) and a
  **"Who hears me" map** from PSKReporter with the night side and the day/night line (grayline).
- **Audio**: noise reduction (incl. AI), ANF, NB, APF, 8-band receive equalizer, **12-band transmit
  equalizer** for the Mac microphone.
- **Remote operation from a browser** (iPhone, iPad, any computer): audio both ways, PTT, scope, VFO,
  filters, CW, **FT8**, log, cluster – over **Tailscale** or a **Cloudflare tunnel** (no app on the phone).
- **CAT Share** (rigctld) for WSJT-X, JTDX, JS8Call and other programs. **Settings backup/restore** and a
  one-click **diagnostic report**. Polish and English interface.

## Requirements

- A Mac with **macOS 13 Ventura or later** (Apple Silicon; an Intel build can be made from source).
- A **Yaesu FT-710** connected with a USB cable. The CAT port driver is built into macOS.
- Optional: FTDI FT4222 libraries for the RF scope, TQSL for LoTW uploads, `cloudflared` for the
  Cloudflare tunnel (`brew install cloudflared`). Details are in the in-app help (**Help → FT-710 Control
  Help**, ⌘?).

## Installation

1. Download the latest `FT710Control-….dmg` from [Releases](https://github.com/sp5xtf/FT710Control/releases).
2. Open it and drag **FT710Control** to **Applications**.
3. **First launch** – the beta is not yet signed with an Apple Developer ID, so macOS blocks it once:
   - **macOS 15 Sequoia and later:** open the program, click *Done*, then **System Settings → Privacy &
     Security**, scroll to *Security* and click **Open Anyway** next to FT710Control.
   - **macOS 13–14:** right-click FT710Control → **Open** → **Open**.
   - Or in Terminal: `xattr -dr com.apple.quarantine /Applications/FT710Control.app`
4. Allow microphone access (this is the radio's USB audio), keychain access and – if you use remote
   operation or CAT Share – local network access. Enter your call and locator.

## Building from source

Xcode 15 or later (Swift 5.9):

```sh
git clone https://github.com/sp5xtf/FT710Control.git
cd FT710Control
swift build                 # or open Package.swift in Xcode; tests: swift test / ⌘U
./build_app.sh              # build/FT710Control.app  (--install copies it to /Applications)
./make_dmg.sh               # dist/FT710Control-<version>.dmg  (--universal: Apple Silicon + Intel)
```

Developer notes (in Polish): [DEVELOPMENT.md](DEVELOPMENT.md).

## Reporting bugs

Open an [Issue](https://github.com/sp5xtf/FT710Control/issues) with the program version, macOS version, Mac
model, what you did, what happened and a screenshot. For radio problems add the contents of the **Help → CAT log**
window; for the scope – **USB diagnostics** and the scope **Log**. Easiest: **Help → Save diagnostic report…** – one file with all of this, without passwords. If the program quits, attach the crash
report (**Console → Crash Reports → FT710Control-….ips**).

## License

FT-710 Control is free software under the **GNU General Public License v3.0** – see [LICENSE](LICENSE).
Third-party components and their licences: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Yaesu and FT-710 are trademarks of Yaesu Musen Co., Ltd. FT-710 Control is an independent program, not
affiliated with Yaesu.

73 de **SP5XTF**

---

## Po polsku

**FT-710 Control** – program stacyjny dla Yaesu FT-710 na macOS: sterowanie radiem, skop RF i waterfall,
FT8/FT4 (z trybem Fox/Hound), dziennik z potwierdzeniami QSL i dyplomami, DX Cluster, POTA, zawody,
CW/RTTY/SSTV/PSK31, pomiar SWR anteny, mapa „kto mnie słyszy” oraz praca zdalna z przeglądarki iPhone'a lub iPada (Tailscale albo tunel Cloudflare).
Interfejs po polsku i angielsku.

**Wersja beta** – nadawanie najpierw na sztuczne obciążenie i z małą mocą; błędy proszę zgłaszać w
[Issues](https://github.com/sp5xtf/FT710Control/issues). Program sam sprawdza nowe wersje.

**Instalacja:** pobierz `FT710Control-….dmg` z [Releases](https://github.com/sp5xtf/FT710Control/releases),
przeciągnij program do Aplikacji. Przy pierwszym uruchomieniu macOS zablokuje program (brak podpisu Apple):
w macOS 15 – Ustawienia systemowe → Prywatność i ochrona → „Otwórz mimo to”; w macOS 13–14 – prawy przycisk
→ Otwórz → Otwórz; albo w Terminalu `xattr -dr com.apple.quarantine /Applications/FT710Control.app`.
Pełna pomoc w programie: menu Pomoc (⌘?), a także w [Wiki](https://github.com/sp5xtf/FT710Control/wiki).

Licencja: GNU GPL v3.0.
