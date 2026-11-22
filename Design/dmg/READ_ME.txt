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
a) RF SCOPE (spectrum and waterfall from the radio) - NOTHING TO INSTALL.
   The FTDI libraries (D2XX and LibFT4222) are built into the program. On the radio just set
   MENU -> OPERATION SETTING -> GENERAL -> SCU-LAN10 = ON. FTDI licence: the Licencje.txt file.

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
     Network Server 127.0.0.1:4532 (in FT-710 Control: Configuration (Cmd-,) -> CAT Share).


6. WHAT'S NEW IN THIS VERSION - worth checking
----------------------------------------------
- Configuration (Cmd-,) has new sections: DX Cluster (node, login, filters), FT8/FT4 (sequence
  options, PSKReporter) and CW - keying (port line or the radio's keyer, radio check).
- CAT Share: several programs at once without cutting each other's transmission - the radio stops
  transmitting only when no program holds PTT; a "PTT off" from another program no longer cuts FT8,
  RTTY or the SWR sweep in FT-710 Control either.
- Earlier (0.9.6): RF scope with nothing to install (built-in FTDI libraries), the Configuration
  window, listening filter with notches, fixed tuning from cluster and POTA spots.

7. REPORTING BUGS
-----------------
Send: the program version (@VERSION@), macOS version, Mac model, a description (what you did,
what happened, what you expected) and a screenshot. Easiest: menu Help -> Save diagnostic
report… (one file, no passwords); for radio problems also the Help -> CAT log window.
In-app help: Help menu (Cmd-?).
Bug reports and new versions: https://github.com/sp5xtf/FT710Control (Issues, Releases).
The program checks for new versions itself (menu FT710Control -> Check for updates…).
Contact: @CONTACT@


Yaesu and FT-710 are trademarks of Yaesu Musen Co., Ltd. FT-710 Control is an independent
program, not affiliated with Yaesu. Licences of the components used: "Licencje.txt".
