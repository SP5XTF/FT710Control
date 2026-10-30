FT-710 Control - beta @VERSION@ (built @DATE@, @ARCH@)
=============================================================

A Mac program for controlling the Yaesu FT-710: CAT, USB audio, RF scope and waterfall,
FT8/FT4 (receive, transmit, PSKReporter), logbook (QRZ, LoTW, eQSL, Club Log and others)
with QSL confirmation download, awards (DXCC, WAZ, WPX, VUCC, POTA) and a 3D QSO map,
contests (separate log, Cabrillo), DX Cluster, POTA, alerts, SSTV, CW, RTTY, audio filters
(noise reduction, ANF, NB, APF, equaliser), propagation, remote operation from a browser
(iPhone, iPad).

This is a (public) BETA - it may contain bugs. Test transmitting (FT8, CW, RTTY, SSTV) into
a dummy load with low power first.


1. REQUIREMENTS
---------------
- A Mac with macOS 13 Ventura or later. This disk image contains a build for: @ARCH_TEXT_EN@.
- An FT-710 connected to the Mac with a USB cable.
- The CAT port driver is built into macOS - nothing to install. The radio appears as a pair
  of ports /dev/cu.usbserial-...


2. INSTALLATION
---------------
Drag FT710Control onto the "Applications" folder icon in this window.


3. FIRST LAUNCH
---------------
The program is not signed with an Apple certificate, so macOS blocks it the first time.

macOS 15 Sequoia and later:
  1. Open FT710Control in Applications - a warning appears, click "Done".
  2. System Settings -> Privacy & Security -> scroll down to the "Security" section.
  3. Next to the FT710Control message click "Open Anyway" and enter your password.
macOS 13-14:
  Right-click FT710Control -> Open -> Open.
Or in Terminal (any macOS version):
  xattr -dr com.apple.quarantine /Applications/FT710Control.app

On first launch the program asks for:
- MICROPHONE access - this is the radio's USB audio (monitoring, spectrum, decoders). Allow it.
- KEYCHAIN access (QRZ, LoTW passwords...) - choose "Always Allow".
- LOCAL NETWORK access (CAT Share, remote operation) - allow it if you use them.
- NOTIFICATIONS (on the first alert: someone is calling you, new entity, new confirmations) -
  allow them if you want them also when another window is in front.
It also asks for your station details (call, grid) - used by the logbook and propagation.


4. RADIO SETTINGS
-----------------
MENU -> OPERATION SETTING -> GENERAL:
- CAT RATE = 38400
- SCU-LAN10 = ON (RF scope only), then unplug and replug the USB cable.
CW sending from the computer (optional); CW tab -> "Check radio" checks the same:
- "DTR/RTS line" method: CW SETTING -> MODE CW -> PC KEYING = DTR, BK-IN on;
- "Radio keyer (CAT)" method: radio keyer on (KEYER), keyer type other than OFF.
RTTY and digital modes: DATA-L mode (the RTTY tab has a "Set radio: DATA-L" button).
FT8/FT4: the program sets DATA-U and the frequency itself with the band buttons. The MAC CLOCK
must be accurate (System Settings -> General -> Date & Time -> set automatically) - the FT8/FT4
tab shows the offset from a time server; with more than 1 s QSOs fail.


5. EXTRA FILES - only for selected features
-------------------------------------------
a) RF SCOPE (spectrum and waterfall from the radio) - FTDI libraries (free):
   - D2XX driver for macOS:     https://ftdichip.com/drivers/d2xx-drivers/   (libftd2xx...dylib)
   - LibFT4222 library for macOS: ftdichip.com -> Products -> FT4222H -> Software Examples
     -> "LibFT4222 for Mac"   (libft4222...dylib)
   Install in Terminal (in the folder with the unpacked files):
     sudo mkdir -p /usr/local/lib
     sudo cp libftd2xx*.dylib libft4222*.dylib /usr/local/lib/
     sudo xattr -d com.apple.quarantine /usr/local/lib/libft*.dylib
   Without them the program works normally - only the RF scope is missing.

b) LoTW - the TQSL program (ARRL): https://www.arrl.org/tqsl-download
   Install it in Applications (TrustedQSL) and add your LoTW certificate. If the certificate
   has a passphrase, TQSL asks for it in its own window when signing (the program does not
   pass it by default). DOWNLOADING confirmations needs the lotw.arrl.org website login and
   password (Online services -> LoTW) - not the certificate passphrase.

c) QRZ.com - a qrz.com account; full station data needs an XML subscription, and downloading
   confirmations from the QRZ logbook needs a logbook subscription.

   Without a QRZ subscription: HamQTH.com (free) - name, QTH, locator, entity; create an account
   at hamqth.com and enter it in the Station profile (works alone or fills gaps in QRZ data).

d) Club Log - uploading and confirmations need the program's API key (write to the author -
   contact at the end) and an application password from your clublog.org account settings.

e) WSJT-X / JTDX (optional):
   - QSOs to the logbook: WSJT-X -> Settings -> Reporting -> UDP Server 127.0.0.1, port 2237;
   - radio control through this program (CAT Share): in WSJT-X radio "Hamlib NET rigctl",
     Network Server 127.0.0.1:4532 (in FT-710 Control turn on the CAT SHARE tab).


6. WHAT'S NEW IN THIS VERSION - worth checking
----------------------------------------------
- Smoothness: scope and waterfall without stutter, also full screen (the "lag" counter in the
  status bar should show a few tens of ms or less).
- Scope: Turbo (SDR) and Inferno palettes, palette-coloured fill, peak hold, dB scale, time
  stamps on the waterfall, a band plan strip (DISPLAY tab).
- Log: filters (band, mode, period), column sorting, Statistics…, QSO map (3D globe), IOTA/SOTA/
  WWFF/PGA awards, deleting QSOs also in Club Log and QRZ, HamQTH.
- A log in the SSTV, CW and RTTY tabs (column on the right).
- FT8: caller choice (farthest / strongest…), call limit, "next caller after a QSO" - the
  "Options…" button in the transmit panel.
- FT8 Hound: working DXpeditions in Fox/Hound mode (the "Hound" switch in the transmit panel;
  described in Help, FT8 topic).
- Contests: a separate log with editing, "Previous contests…", dupes on the scope, DX Cluster spot.
- Remote operation from a browser: VFO, filters, TX, tuner, memory messages M1-M5, log, CW,
  cluster, alerts, FT8/FT4 (tap a message = call).
- Remote operation over the internet without Tailscale: Cloudflare tunnel (REMOTE tab; on the Mac
  "brew install cloudflared", on the phone just a browser, a QR code with the address).
- Status bar: listening volume with mute.

7. REPORTING BUGS
-----------------
Send: the program version (@VERSION@), macOS version, Mac model, a description (what you did,
what happened, what you expected) and a screenshot. For radio problems include the LOG CAT tab
contents; for the scope - "USB diagnostics" and the scope "Log".
In-app help: Help menu (Cmd-?).
Bug reports and new versions: https://github.com/sp5xtf/FT710Control (Issues, Releases).
The program checks for new versions itself (menu FT710Control -> Check for updates…).
Contact: @CONTACT@


Yaesu and FT-710 are trademarks of Yaesu Musen Co., Ltd. FT-710 Control is an independent
program, not affiliated with Yaesu. Licences of the components used: "Licencje.txt".
