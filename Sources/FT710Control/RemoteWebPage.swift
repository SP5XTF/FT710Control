import Foundation

/// Strona panelu zdalnego, serwowana przez WebSocketServer. Źródła: web/index.html, web/app.js, web/worklet.js.
/// (Plik generowany z katalogu web/ - edytuj tam i wygeneruj ponownie, albo edytuj ostrożnie tutaj.)
enum RemoteWebPage {
    static let indexHTML = ##"""
<!doctype html>
<html lang="pl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="FT-710">
<meta name="theme-color" content="#0d1117">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" href="/icon-180.png">
<link rel="icon" type="image/png" href="/icon-192.png">
<title>FT-710 Control</title>
<style>
:root { --bg:#0d1117; --panel:#161b22; --line:#30363d; --text:#e6edf3; --dim:#8b949e; --acc:#2f81f7; --red:#da3633; --green:#3fb950; --amber:#d29922; }
* { box-sizing: border-box; }
html, body { margin: 0; background: var(--bg); color: var(--text); font: 15px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
body { padding: calc(env(safe-area-inset-top) + 6px) calc(env(safe-area-inset-right) + 10px) calc(env(safe-area-inset-bottom) + 10px) calc(env(safe-area-inset-left) + 10px); max-width: 1500px; margin: 0 auto; -webkit-user-select: none; user-select: none; }
.panel { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 10px; }
h4 { margin: 0 0 6px; font-size: 11px; letter-spacing: 1px; color: var(--amber); }
button { background: #21262d; color: var(--text); border: 1px solid var(--line); border-radius: 8px; padding: 9px 10px; font-size: 14px; touch-action: manipulation; }
button.on { background: var(--acc); border-color: var(--acc); }
button:disabled { opacity: .4; }
input { background: var(--bg); color: var(--text); border: 1px solid var(--line); border-radius: 8px; padding: 9px; font-size: 16px; -webkit-user-select: text; user-select: text; }
input[type=range] { padding: 0; accent-color: var(--acc); }
.row { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.center { justify-content: center; }
.seg { display: inline-flex; gap: 0; }
.seg button { border-radius: 0; margin-left: -1px; padding: 8px 11px; }
.seg button:first-child { border-radius: 8px 0 0 8px; margin-left: 0; }
.seg button:last-child { border-radius: 0 8px 8px 0; }
.ctl { display: grid; grid-template-columns: 62px 1fr; gap: 8px; align-items: center; margin: 6px 0; font-size: 13px; }
.ctl b { color: var(--dim); font-weight: 600; }
.top { display: flex; justify-content: space-between; align-items: center; gap: 8px; font-size: 13px; color: var(--dim); margin-bottom: 8px; }
.dot { display: inline-block; width: 9px; height: 9px; border-radius: 50%; background: var(--red); margin-right: 6px; }
.dot.ok { background: var(--green); }
#freq { font: 600 clamp(32px, 9vw, 60px) ui-monospace, Menlo, monospace; text-align: center; letter-spacing: 1px; }
#modeTx { display: flex; justify-content: center; gap: 8px; margin-top: 2px; }
.badge { padding: 2px 10px; border-radius: 6px; background: #21262d; font-weight: 600; }
.badge.tx { background: var(--red); }
.meter { display: grid; grid-template-columns: 50px 1fr 70px; gap: 8px; align-items: center; font-size: 13px; margin: 5px 0; }
.meter span { text-align: right; font-family: ui-monospace, Menlo, monospace; }
.bar { height: 10px; background: #21262d; border-radius: 5px; overflow: hidden; }
.bar > div { height: 100%; width: 0; background: var(--acc); transition: width .08s linear; }
canvas { width: 100%; display: block; background: #000; image-rendering: pixelated; }
#traceWrap { position: relative; }
#spots { position: absolute; inset: 0; pointer-events: none; overflow: hidden; }
.spot { position: absolute; font: 700 10px -apple-system, sans-serif; color: #000; background: var(--amber); border-radius: 3px; padding: 1px 3px; white-space: nowrap; pointer-events: auto; cursor: pointer; }
.spot.pota { outline: 1.5px solid var(--green); }
.tick { position: absolute; width: 1px; background: rgba(210,153,34,.8); pointer-events: none; }
.tick.pota { background: var(--green); }
#trace { height: 90px; border-radius: 6px 6px 0 0; }
#wf { height: 170px; border-radius: 0 0 6px 6px; }
#axis { display: flex; justify-content: space-between; font: 11px ui-monospace, Menlo, monospace; color: var(--dim); margin-top: 3px; }
.small { font-size: 12px; color: var(--dim); margin-top: 6px; }
details { margin-top: 8px; font-size: 12px; color: var(--dim); }
details summary { cursor: pointer; color: var(--acc); }
details p { margin: 6px 0 0; }
#ptt { width: 100%; height: 88px; margin-top: 8px; font-size: 22px; font-weight: 700; letter-spacing: 2px; border-radius: 14px; touch-action: none; }
#ptt.active { background: var(--red); border-color: var(--red); }
#msg { color: var(--amber); font-size: 13px; min-height: 18px; margin-top: 6px; }
.hidden { display: none !important; }
#login { max-width: 380px; margin: 14vh auto 0; }
/* Układ: telefon - jedna kolumna; iPad poziomo / komputer - skop szeroko po prawej */
#grid { display: grid; gap: 10px; grid-template-columns: 1fr;
  grid-template-areas: "freq" "scope" "meters" "ft8" "log" "bands" "radio" "cw" "cluster" "alerts" "audio"; }
#pFreq { grid-area: freq; } #pScope { grid-area: scope; } #pMeters { grid-area: meters; }
#pBands { grid-area: bands; } #pRadio { grid-area: radio; } #pAudio { grid-area: audio; }
#pLog { grid-area: log; } #pCW { grid-area: cw; } #pCluster { grid-area: cluster; } #pAlerts { grid-area: alerts; }
#pFT8 { grid-area: ft8; }
.ft8row { display: grid; grid-template-columns: 54px 30px 40px 1fr; gap: 6px; padding: 4px; border-bottom: 1px solid var(--line); cursor: pointer; font-family: ui-monospace, Menlo, monospace; font-size: 13px; }
.ft8row:hover { background: #21262d; }
.ft8row.me { background: rgba(255, 77, 77, 0.18); }
.sec { border-top: 1px solid var(--line); margin-top: 8px; padding-top: 6px; }
.sec summary { cursor: pointer; font-size: 11px; letter-spacing: 1px; color: var(--amber); font-weight: 700; }
.tog { padding: 6px 10px; font-size: 13px; }
.list { max-height: 260px; overflow-y: auto; font-size: 13px; }
.item { display: grid; grid-template-columns: 44px 70px 1fr; gap: 6px; padding: 5px 4px; border-bottom: 1px solid var(--line); cursor: pointer; }
.item:hover { background: #21262d; }
.pill { color: #000; border-radius: 4px; padding: 0 5px; font-weight: 700; display: inline-block; }
.mono { font-family: ui-monospace, Menlo, monospace; }
.dim { color: var(--dim); }
.lg { display: grid; grid-template-columns: 1fr 1fr; gap: 6px; }
.lg input { width: 100%; }
@media (min-width: 1000px) {
  #grid { grid-template-columns: 380px 1fr;
    grid-template-areas: "freq scope" "meters scope" "bands ft8" "radio ft8" "radio log" "cw cluster" "audio alerts"; }
  #trace { height: 130px; }
  #wf { height: 340px; }
}
</style>
</head>
<body>
<div id="login" class="panel">
  <div class="row" style="justify-content:space-between">
    <h3 style="margin:0" data-t="FT-710 Control – praca zdalna">FT-710 Control – praca zdalna</h3>
    <button class="langBtn">EN</button>
  </div>
  <div class="row" style="margin-top:10px">
    <input id="pw" type="password" data-tp="Hasło stacji" placeholder="Hasło stacji" autocomplete="current-password" style="flex:1">
    <button id="loginBtn" class="on" data-t="Połącz">Połącz</button>
  </div>
  <div id="loginMsg" style="color:var(--amber);margin-top:8px;font-size:13px"></div>
</div>

<div id="app" class="hidden">
  <div class="top">
    <span><span id="dot" class="dot"></span><span id="conn">…</span></span>
    <span id="rtt"></span>
    <span class="row"><button class="langBtn">EN</button><button id="logout" data-t="Rozłącz">Rozłącz</button></span>
  </div>

  <div id="grid">
    <div id="pFreq" class="panel">
      <div id="freq">–</div>
      <div id="modeTx"><span id="mode" class="badge">–</span><span id="txBadge" class="badge tx hidden">TX</span><span id="splitBadge" class="badge hidden">SPLIT</span></div>
      <div class="row center small" style="margin-top:4px"><span class="mono" id="vfoA">A –</span><span class="mono" id="vfoB">B –</span></div>
      <div class="row center" style="margin-top:6px">
        <button id="vfoAB" class="tog">A=B</button><button id="vfoSwap" class="tog">A↔B</button><button id="ctlSplit" class="tog">SPLIT</button>
      </div>
      <div class="row center" style="margin-top:8px" id="tuneRow"></div>
      <div class="row center" style="margin-top:6px">
        <input id="freqIn" inputmode="decimal" data-tp="kHz, np. 14074" placeholder="kHz, np. 14074" style="width:160px">
        <button id="setFreq" data-t="Ustaw">Ustaw</button>
      </div>
    </div>

    <div id="pScope" class="panel">
      <div id="traceWrap"><canvas id="trace" width="850" height="90"></canvas><div id="spots"></div></div>
      <canvas id="wf" width="850" height="170"></canvas>
      <div id="axis"><span id="ax0"></span><span id="ax1"></span><span id="ax2"></span><span id="ax3"></span><span id="ax4"></span></div>
      <div class="small" id="scopeInfo" data-t="Skop RF: brak danych (włącz go na stacji)">Skop RF: brak danych (włącz go na stacji)</div>
    </div>

    <div id="pMeters" class="panel">
      <div class="meter"><b>S</b><div class="bar"><div id="sBar"></div></div><span id="sTxt">–</span></div>
      <div class="meter"><b>PO</b><div class="bar"><div id="poBar"></div></div><span id="poTxt">–</span></div>
      <div class="meter"><b>COMP</b><div class="bar"><div id="compBar"></div></div><span id="compTxt">–</span></div>
      <div class="meter"><b>ALC</b><div class="bar"><div id="alcBar"></div></div><span id="alcTxt">–</span></div>
      <div class="meter"><b>SWR</b><div class="bar"><div id="swrBar"></div></div><span id="swrTxt">–</span></div>
    </div>

    <div id="pBands" class="panel">
      <h4 data-t="TRYB">TRYB</h4>
      <div class="row" id="modes"></div>
      <h4 style="margin-top:10px" data-t="PASMA">PASMA</h4>
      <div class="row" id="bands"></div>
      <div class="small" data-t="Pasmo pamięta ostatnią częstotliwość i tryb (w tej przeglądarce).">Pasmo pamięta ostatnią częstotliwość i tryb (w tej przeglądarce).</div>
    </div>

    <div id="pRadio" class="panel">
      <h4 data-t="RADIO">RADIO</h4>
      <div class="ctl"><b>ATT</b><div class="seg" id="ctlAtt"></div></div>
      <div class="ctl"><b>IPO</b><div class="seg" id="ctlIpo"></div></div>
      <div class="ctl"><b>AGC</b><div class="seg" id="ctlAgc"></div></div>
      <div class="ctl"><b data-t="Moc">Moc</b><div class="row"><input id="ctlPwr" type="range" min="5" max="100" step="1" style="flex:1"><span id="ctlPwrTxt" style="width:48px;text-align:right">–</span></div></div>
      <div class="ctl" id="ctlKsRow"><b>CW WPM</b><div class="row"><input id="ctlKs" type="range" min="4" max="60" step="1" style="flex:1"><span id="ctlKsTxt" style="width:48px;text-align:right">–</span></div></div>
      <details class="sec"><summary data-t="ODBIÓR">ODBIÓR</summary><div id="secRX"></div></details>
      <details class="sec"><summary data-t="FILTR">FILTR</summary><div id="secFilter"></div></details>
      <details class="sec"><summary data-t="NADAWANIE">NADAWANIE</summary><div id="secTX"></div></details>
      <details class="sec"><summary data-t="TUNER I PAMIĘCI">TUNER I PAMIĘCI</summary>
        <div class="row" style="margin-top:6px"><button id="ctlTuner" class="tog">TUNER</button><button id="atuTune" class="tog" data-t="Strój (TUNE)">Strój (TUNE)</button></div>
        <div class="row" style="margin-top:6px" id="msgRow"></div>
        <div class="small" data-t="Komunikaty z pamięci radia: CW w trybie CW, głosowe w fonii. Nadawanie - te same warunki co PTT.">Komunikaty z pamięci radia: CW w trybie CW, głosowe w fonii. Nadawanie - te same warunki co PTT.</div>
      </details>
    </div>

    <div id="pFT8" class="panel">
      <h4>FT8 / FT4 <span id="ft8State"></span></h4>
      <div class="row">
        <button id="ft8m8" class="tog">FT8</button><button id="ft8m4" class="tog">FT4</button>
        <button id="ft8dec" class="tog" data-t="Dekodowanie">Dekodowanie</button>
        <button id="ft8hound" class="tog">Hound</button>
      </div>
      <div class="row" id="ft8Bands" style="margin-top:6px"></div>
      <div class="small mono" id="ft8Next" style="margin-top:6px"></div>
      <div class="row" style="margin-top:6px">
        <button id="ft8cq" class="tog">CQ</button><button id="ft8tx" class="tog" data-t="Włącz TX">Włącz TX</button><button id="ft8stop" class="tog">STOP</button>
      </div>
      <div class="small" data-t="Dotknięcie komunikatu - wołanie stacji i włączenie TX (jak dwuklik na Macu). Nadawanie - te same warunki co PTT; po rozłączeniu przeglądarki TX FT8 się wyłącza.">Dotknięcie komunikatu - wołanie stacji i włączenie TX (jak dwuklik na Macu). Nadawanie - te same warunki co PTT; po rozłączeniu przeglądarki TX FT8 się wyłącza.</div>
      <div class="list" id="ft8List" style="max-height:340px;margin-top:6px"></div>
    </div>

    <div id="pLog" class="panel">
      <h4 data-t="DZIENNIK">DZIENNIK</h4>
      <div class="row"><input id="logCall" class="mono" data-tp="Znak" placeholder="Znak" autocapitalize="characters" autocomplete="off" style="flex:1;text-transform:uppercase"><button id="logSave" class="on" data-t="Zapisz">Zapisz</button></div>
      <div class="small" id="logInfo"></div>
      <div class="lg" style="margin-top:6px">
        <input id="logRstS" data-tp="RST wysłany" placeholder="RST wysłany"><input id="logRstR" data-tp="RST odebrany" placeholder="RST odebrany">
        <input id="logName" data-tp="Imię" placeholder="Imię"><input id="logQth" data-tp="QTH" placeholder="QTH">
        <input id="logGrid" data-tp="Lokator" placeholder="Lokator"><input id="logComment" data-tp="Uwagi" placeholder="Uwagi">
      </div>
      <div class="small" data-t="Częstotliwość i tryb z radia; zapis jak w programie (wysyłka do serwisów według ustawień).">Częstotliwość i tryb z radia; zapis jak w programie (wysyłka do serwisów według ustawień).</div>
      <h4 style="margin-top:10px" data-t="OSTATNIE QSO">OSTATNIE QSO</h4>
      <div class="list" id="recent"></div>
    </div>

    <div id="pCW" class="panel hidden">
      <h4>CW</h4>
      <div class="row"><input id="cwText" class="mono" data-tp="Tekst do nadania" placeholder="Tekst do nadania" autocapitalize="characters" style="flex:1;text-transform:uppercase"><button id="cwSend" class="on" data-t="Nadaj">Nadaj</button><button id="cwStop">STOP</button></div>
      <div class="row" style="margin-top:6px" id="cwMacros"></div>
    </div>

    <div id="pCluster" class="panel">
      <h4>DX CLUSTER <span class="dim" id="clusterState"></span></h4>
      <div class="list" id="clusterList"></div>
    </div>

    <div id="pAlerts" class="panel">
      <h4 data-t="ALERTY">ALERTY</h4>
      <div class="list" id="alertList"></div>
    </div>

    <div id="pAudio" class="panel">
      <div class="row">
        <button id="audioBtn" class="on" data-t="Włącz audio">Włącz audio</button>
        <span class="small" style="margin:0" data-t="Głośność">Głośność</span>
        <input id="vol" type="range" min="0" max="2" step="0.05" value="1" style="flex:1">
      </div>
      <div class="small" id="audioInfo"></div>
      <div id="msg"></div>
      <button id="ptt" disabled data-t="PTT – przytrzymaj">PTT – przytrzymaj</button>
      <div class="small" id="pttHint"></div>
      <details>
        <summary data-t="Pomoc i test dźwięku">Pomoc i test dźwięku</summary>
        <div class="row" style="margin-top:6px">
          <button id="beepBtn" data-t="Test dźwięku">Test dźwięku</button>
          <span class="small" id="audioDiag" style="margin:0;font-family:ui-monospace,Menlo,monospace"></span>
        </div>
        <p data-t="Brak dźwięku na iPhonie? Sprawdź głośność przyciskami z boku. Strona próbuje grać także w trybie cichym; gdyby to nie działało, wyłącz tryb cichy.">Brak dźwięku na iPhonie? Sprawdź głośność przyciskami z boku. Strona próbuje grać także w trybie cichym; gdyby to nie działało, wyłącz tryb cichy.</p>
        <p data-t="Nadajnik działa tylko podczas trzymania przycisku. Przerwa w łączności dłuższa niż 0,5 s wyłącza nadawanie na stacji. Używaj słuchawek.">Nadajnik działa tylko podczas trzymania przycisku. Przerwa w łączności dłuższa niż 0,5 s wyłącza nadawanie na stacji. Używaj słuchawek.</p>
        <p data-t="Na iPhonie: Udostępnij → Do ekranu początkowego - panel otwiera się wtedy jak aplikacja, na całym ekranie.">Na iPhonie: Udostępnij → Do ekranu początkowego - panel otwiera się wtedy jak aplikacja, na całym ekranie.</p>
      </details>
    </div>
  </div>
</div>
<script src="/app.js"></script>
</body>
</html>
"""##

    static let appJS = ##"""
"use strict";
// FT-710 Control - panel zdalny w przeglądarce.

const $ = (id) => document.getElementById(id);
const MODES = [["LSB", "1"], ["USB", "2"], ["CW-U", "3"], ["CW-L", "7"], ["AM", "5"], ["FM", "4"], ["DATA-L", "8"], ["DATA-U", "C"]];
// pasmo: nazwa, domyślna częstotliwość i tryb (fonia: LSB poniżej 10 MHz, USB powyżej; 30 m - CW), zakres
const BANDS = [["160", 1840000, "1", 1800000, 2000000], ["80", 3700000, "1", 3500000, 4000000],
               ["40", 7100000, "1", 7000000, 7300000], ["30", 10120000, "3", 10100000, 10150000],
               ["20", 14200000, "2", 14000000, 14350000], ["17", 18120000, "2", 18068000, 18168000],
               ["15", 21200000, "2", 21000000, 21450000], ["12", 24940000, "2", 24890000, 24990000],
               ["10", 28400000, "2", 28000000, 29700000], ["6", 50150000, "2", 50000000, 54000000]];
const ATT = [["OFF", 0], ["6 dB", 1], ["12 dB", 2], ["18 dB", 3]];
const IPO = [["IPO", 0], ["AMP1", 1], ["AMP2", 2]];
const AGC = [["FAST", 1], ["MID", 2], ["SLOW", 3], ["AUTO", 4]];

// ---------- język (PL / EN) ----------
// Klucz = tekst polski (jak w programie). Wybór: przycisk PL/EN (zapamiętany), potem język programu, potem przeglądarki.
const EN = {
  "FT-710 Control – praca zdalna": "FT-710 Control – remote", "Hasło stacji": "Station password", "Połącz": "Connect",
  "Rozłącz": "Disconnect", "kHz, np. 14074": "kHz, e.g. 14074", "Ustaw": "Set",
  "Skop RF: brak danych (włącz go na stacji)": "RF scope: no data (turn it on at the station)",
  "TRYB": "MODE", "PASMA": "BANDS", "RADIO": "RADIO", "Moc": "Power",
  "Pasmo pamięta ostatnią częstotliwość i tryb (w tej przeglądarce).": "Each band remembers the last frequency and mode (in this browser).",
  "Włącz audio": "Audio on", "Wyłącz audio": "Audio off", "Głośność": "Volume", "PTT – przytrzymaj": "PTT – hold",
  "Pomoc i test dźwięku": "Help and sound test", "Test dźwięku": "Sound test",
  "Brak dźwięku na iPhonie? Sprawdź głośność przyciskami z boku. Strona próbuje grać także w trybie cichym; gdyby to nie działało, wyłącz tryb cichy.": "No sound on the iPhone? Check the volume with the side buttons. The page tries to play in silent mode too; if that does not work, turn silent mode off.",
  "Nadajnik działa tylko podczas trzymania przycisku. Przerwa w łączności dłuższa niż 0,5 s wyłącza nadawanie na stacji. Używaj słuchawek.": "The transmitter works only while the button is held. A connection gap longer than 0.5 s stops transmitting at the station. Use headphones.",
  "Na iPhonie: Udostępnij → Do ekranu początkowego - panel otwiera się wtedy jak aplikacja, na całym ekranie.": "On iPhone: Share → Add to Home Screen – the panel then opens like an app, full screen.",
  "Podaj hasło": "Enter the password", "Łączenie…": "Connecting…", "Połączenie zamknięte": "Connection closed",
  "Rozłączono": "Disconnected", "Połączono": "Connected", "Błędne hasło": "Wrong password", "opóźnienie": "latency",
  "Nadawanie zakończone przez stację:": "Transmission ended by the station:", "radio rozłączone": "radio disconnected",
  "To połączenie z sieci domowej (http) - tylko odbiór. Do nadawania otwórz adres Tailscale (https).": "This is a home network connection (http) – receive only. To transmit, open the Tailscale address (https).",
  "Nadawanie zdalne jest wyłączone na stacji.": "Remote transmit is turned off at the station.",
  "Stacja nie ma toru audio do radia.": "The station has no audio path to the radio.",
  "Włącz audio, żeby udostępnić mikrofon.": "Turn audio on to share the microphone.",
  "Przytrzymaj przycisk (lub spację) podczas mówienia.": "Hold the button (or the space bar) while talking.",
  "Stacja nie wysyła audio (sprawdź „Z radia (RX)”).": "The station is not sending audio (check “From radio (RX)”).",
  "Skop RF": "RF scope", "dotknij, aby dostroić": "tap to tune",
  "Połączenie bez HTTPS: działa odsłuch, mikrofon i nadawanie są niedostępne.": "Connection without HTTPS: listening works, the microphone and transmitting are unavailable.",
  "Mikrofon niedostępny - otwórz stronę przez https (tailscale serve), nie przez http.": "Microphone unavailable – open the page over https (tailscale serve), not http.",
  "wyłączone": "off", "Audio:": "Audio:",
  "Mikrofon zablokowany - w Safari: „aA” → Ustawienia witryny → Mikrofon → Pozwalaj (aplikacja z ekranu początkowego: Ustawienia → Safari → Mikrofon); w Chrome: Ustawienia iPhone’a → Aplikacje → Chrome → Mikrofon. Potem Wyłącz i Włącz audio.": "Microphone blocked – in Safari: “aA” → Website Settings → Microphone → Allow (home-screen app: Settings → Safari → Microphone); in Chrome: iPhone Settings → Apps → Chrome → Microphone. Then Audio off and Audio on.",
  "ODBIÓR": "RECEIVE", "FILTR": "FILTER", "NADAWANIE": "TRANSMIT", "TUNER I PAMIĘCI": "TUNER AND MEMORIES",
  "Strój (TUNE)": "Tune (TUNE)", "Komunikaty z pamięci radia: CW w trybie CW, głosowe w fonii. Nadawanie - te same warunki co PTT.": "Radio memory messages: CW in CW mode, voice in phone. Transmitting – the same conditions as PTT.",
  "DZIENNIK": "LOG", "Znak": "Call", "Zapisz": "Save", "RST wysłany": "RST sent", "RST odebrany": "RST received",
  "Imię": "Name", "QTH": "QTH", "Lokator": "Locator", "Uwagi": "Comment",
  "Częstotliwość i tryb z radia; zapis jak w programie (wysyłka do serwisów według ustawień).": "Frequency and mode from the radio; saved as in the program (upload to services per settings).",
  "OSTATNIE QSO": "RECENT QSOS", "Tekst do nadania": "Text to send", "Nadaj": "Send", "ALERTY": "ALERTS",
  "Zapisano": "Logged", "było": "worked", "nowa stacja": "new station", "brak połączenia": "not connected",
  "Brak spotów.": "No spots.", "Brak alertów.": "No alerts.", "Brak łączności.": "No QSOs.",
  "Dekodowanie": "Decoding", "Włącz TX": "Enable TX", "Wyłącz TX": "Disable TX", "NADAJE": "TRANSMITTING", "TX włączony": "TX enabled",
  "Brak komunikatów.": "No messages.", "Następny": "Next", "QSO z": "QSO with",
  "Dotknięcie komunikatu - wołanie stacji i włączenie TX (jak dwuklik na Macu). Nadawanie - te same warunki co PTT; po rozłączeniu przeglądarki TX FT8 się wyłącza.": "Tap a message – call the station and enable TX (like a double-click on the Mac). Transmitting – the same conditions as PTT; when the browser disconnects, FT8 TX is turned off.",
  "AF": "AF", "RF": "RF", "SQL": "SQL", "Poziom NB": "NB level", "Poziom NR": "NR level", "Szerokość": "Width",
  "Przesunięcie": "Shift", "Notch": "Notch", "Contour": "Contour", "MIC": "MIC", "Poziom PROC": "PROC level", "AMC": "AMC"
};
let LANG = localStorage.getItem("ft710.lang") || ((navigator.language || "").startsWith("pl") ? "pl" : "en");
function T(pl) { return LANG === "en" ? (EN[pl] || pl) : pl; }
function applyLang() {
  document.documentElement.lang = LANG;
  document.querySelectorAll("[data-t]").forEach((el) => { el.textContent = T(el.dataset.t); });
  document.querySelectorAll("[data-tp]").forEach((el) => { el.placeholder = T(el.dataset.tp); });
  document.querySelectorAll(".langBtn").forEach((b) => { b.textContent = LANG === "pl" ? "EN" : "PL"; });
  if (st && st.f !== undefined) render();
}
document.querySelectorAll(".langBtn").forEach((b) => b.addEventListener("click", () => {
  LANG = LANG === "pl" ? "en" : "pl";
  localStorage.setItem("ft710.lang", LANG);
  applyLang();
}));
const STEPS = [-1000, -100, -10, 10, 100, 1000];
const RANGE = 140;          // zakres skali skopu w jednostkach radia (0-255 ≈ 110 dB)

let ws = null;
let st = {};
let pttOn = false;
let hbTimer = null;
let pingTimer = null;
let actx = null;
let rxPush = null;          // funkcja przyjmująca Float32Array (12 kHz)
let rxGain = null;
// Diagnostyka audio
let rxPackets = 0;
let rxPeak = 0;
let fallbackLevel = null;   // funkcja zwracająca zapas bufora (ms) w trybie zapasowym
// Strona przez zwykłe http w sieci domowej: przeglądarka nie da mikrofonu ani AudioWorklet.
const secure = window.isSecureContext;
let micNode = null;
let micReady = false;
let micStream = null;
let micSource = null;
let audioOn = false;        // odsłuch i mikrofon włączone przyciskiem
let scope = { lo: 0, hi: 0, floor: null, width: 0 };
let palette = null;

// ---------- pomocnicze ----------

function fmtFreq(hz) {
  if (!hz) return "–";
  const mhz = Math.floor(hz / 1e6);
  const k = Math.floor(hz / 1000) % 1000;
  const h = hz % 1000;
  return `${mhz}.${String(k).padStart(3, "0")}.${String(h).padStart(3, "0")}`;
}

function send(obj) {
  if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj));
}

function msg(text) {
  $("msg").textContent = text || "";
}

function makeButton(label, onClick, parent) {
  const b = document.createElement("button");
  b.textContent = label;
  b.addEventListener("click", onClick);
  parent.appendChild(b);
  return b;
}

STEPS.forEach((d) => {
  const abs = Math.abs(d);
  const label = (d > 0 ? "+" : "−") + (abs >= 1000 ? abs / 1000 + " kHz" : abs + " Hz");
  makeButton(label, () => send({ t: "tune", d }), $("tuneRow"));
});
MODES.forEach(([label, code]) => {
  const b = makeButton(label, () => send({ t: "mode", code }), $("modes"));
  b.dataset.code = code;
});
// Pasma: zapamiętana częstotliwość i tryb na każdym paśmie (localStorage), domyślnie fonia / CW na 30 m.
function bandOf(hz) { const b = BANDS.find((x) => hz >= x[3] && hz <= x[4]); return b ? b[0] : null; }
function bandMemory() { try { return JSON.parse(localStorage.getItem("ft710.bands") || "{}"); } catch (e) { return {}; } }
BANDS.forEach(([label, hz, mc]) => {
  const b = makeButton(label + " m", () => {
    const mem = bandMemory();
    const current = bandOf(st.f);
    if (current) { mem[current] = { hz: st.f, mc: st.mc }; }        // zapamiętaj, gdzie byłeś
    localStorage.setItem("ft710.bands", JSON.stringify(mem));
    const target = mem[label] || { hz, mc };
    send({ t: "band", hz: target.hz, mc: target.mc });
  }, $("bands"));
  b.dataset.band = label;
});

// Panel radia: ATT, IPO, AGC (przyciski), moc i prędkość klucza CW (suwaki - wysyłka po puszczeniu)
function segment(id, items, name) {
  items.forEach(([label, v]) => {
    const b = makeButton(label, () => send({ t: "ctl", c: name, v }), $(id));
    b.dataset.v = v;
  });
}
segment("ctlAtt", ATT, "att");
segment("ctlIpo", IPO, "ipo");
segment("ctlAgc", AGC, "agc");
function slider(id, name, unit) {
  const el = $(id);
  el.addEventListener("input", () => { $(id + "Txt").textContent = el.value + unit; el.dataset.busy = "1"; });
  el.addEventListener("change", () => { send({ t: "ctl", c: name, v: parseInt(el.value, 10) }); delete el.dataset.busy; });
}
slider("ctlPwr", "pwr", " W");
slider("ctlKs", "ks", "");

// ---------- Pozostałe ustawienia radia (zakresy przychodzą przy logowaniu) ----------
let RANGES = {};
let MYCALL = "";
const SLIDERS = [];
function addSlider(parent, name, label, lo, hi, fmt) {
  const row = document.createElement("div"); row.className = "ctl";
  const b = document.createElement("b"); b.dataset.t = label; b.textContent = T(label); row.appendChild(b);
  const box = document.createElement("div"); box.className = "row";
  const el = document.createElement("input");
  el.type = "range"; el.min = lo; el.max = hi; el.step = 1; el.style.flex = "1";
  const txt = document.createElement("span"); txt.className = "mono"; txt.style.width = "70px"; txt.style.textAlign = "right"; txt.textContent = "–";
  el.addEventListener("input", () => { txt.textContent = fmt(+el.value); el.dataset.busy = "1"; });
  el.addEventListener("change", () => { send({ t: "ctl", c: name, v: parseInt(el.value, 10) }); delete el.dataset.busy; });
  box.appendChild(el); box.appendChild(txt); row.appendChild(box); parent.appendChild(row);
  SLIDERS.push({ name, el, txt, fmt });
}
function addToggles(parent, items) {
  const row = document.createElement("div"); row.className = "row"; row.style.margin = "6px 0";
  items.forEach(([name, label]) => {
    const b = makeButton(label, () => send({ t: "ctl", c: name, v: (st.ctl && st.ctl[name]) ? 0 : 1 }), row);
    b.classList.add("tog"); b.dataset.ctl = name;
  });
  parent.appendChild(row);
}
const pct = (v) => v + "";
addSlider($("secRX"), "af", "AF", 0, 255, pct);
addSlider($("secRX"), "rf", "RF", 0, 255, pct);
addSlider($("secRX"), "sql", "SQL", 0, 100, pct);
addToggles($("secRX"), [["nb", "NB"], ["nr", "NR"], ["dnf", "DNF"]]);
addSlider($("secRX"), "nbl", "Poziom NB", 0, 10, pct);
addSlider($("secRX"), "nrl", "Poziom NR", 1, 15, pct);
addSlider($("secFilter"), "width", "Szerokość", 0, 23, (v) => "#" + v);
addSlider($("secFilter"), "shift", "Przesunięcie", -1200, 1200, (v) => v + " Hz");
addToggles($("secFilter"), [["notch", "NOTCH"], ["cont", "CONTOUR"]]);
addSlider($("secFilter"), "notchf", "Notch", 1, 320, (v) => v * 10 + " Hz");
addSlider($("secFilter"), "contf", "Contour", 10, 3200, (v) => v + " Hz");
addSlider($("secTX"), "mic", "MIC", 0, 100, pct);
addToggles($("secTX"), [["proc", "PROC"]]);
addSlider($("secTX"), "procl", "Poziom PROC", 0, 100, pct);
addSlider($("secTX"), "amc", "AMC", 1, 100, pct);
function applyRanges() {
  SLIDERS.forEach((s) => { const r = RANGES[s.name]; if (r) { s.el.min = r[0]; s.el.max = r[1]; } });
}

// VFO, split, tuner, komunikaty z pamięci
$("vfoAB").addEventListener("click", () => send({ t: "vfo", op: "ab" }));
$("vfoSwap").addEventListener("click", () => send({ t: "vfo", op: "swap" }));
$("ctlSplit").addEventListener("click", () => send({ t: "ctl", c: "split", v: (st.ctl && st.ctl.split) ? 0 : 1 }));
$("ctlTuner").addEventListener("click", () => send({ t: "ctl", c: "tuner", v: (st.ctl && st.ctl.tuner) ? 0 : 1 }));
$("atuTune").addEventListener("click", () => send({ t: "atu" }));
[1, 2, 3, 4, 5].forEach((ch) => makeButton("M" + ch, () => send({ t: "msg", ch }), $("msgRow")).classList.add("tog"));
makeButton("STOP", () => send({ t: "msgstop" }), $("msgRow")).classList.add("tog");

// ---------- Dziennik ----------
let lookupTimer = null;
function setLogCall(call) {
  $("logCall").value = call;
  ["logName", "logQth", "logGrid"].forEach((id) => { $(id).value = ""; });
  $("logInfo").textContent = "";
  if (call.length >= 3) send({ t: "lookup", call });
}
$("logCall").addEventListener("input", () => {
  $("logCall").value = $("logCall").value.toUpperCase().replace(/\s/g, "");
  clearTimeout(lookupTimer);
  const call = $("logCall").value;
  if (call.length >= 3) lookupTimer = setTimeout(() => send({ t: "lookup", call }), 700);
  else $("logInfo").textContent = "";
});
function saveLog() {
  const call = $("logCall").value.trim();
  if (call.length < 3) return;
  send({ t: "log", call, rsts: $("logRstS").value || defaultRST(), rstr: $("logRstR").value || defaultRST(), name: $("logName").value,
         qth: $("logQth").value, grid: $("logGrid").value, comment: $("logComment").value });
}
$("logSave").addEventListener("click", saveLog);
$("logCall").addEventListener("keydown", (e) => { if (e.key === "Enter") saveLog(); });
function defaultRST() { return (st.mc === "3" || st.mc === "7" || st.mc === "6" || st.mc === "9") ? "599" : (st.mc === "8" || st.mc === "C") ? "" : "59"; }

// ---------- CW ----------
const MACROS = [["CQ", "CQ CQ DE {MY} {MY} K"], ["5NN", "{CALL} 5NN TU"], ["TU", "TU 73 DE {MY} EE"], ["?", "?"], ["AGN", "AGN"], ["MY", "{MY}"]];
function expandCW(text) { return text.replace(/\{MY\}/g, MYCALL).replace(/\{CALL\}/g, $("logCall").value || ""); }
MACROS.forEach(([label, text]) => makeButton(label, () => send({ t: "cw", text: expandCW(text) }), $("cwMacros")).classList.add("tog"));
$("cwSend").addEventListener("click", () => {
  const text = $("cwText").value.trim().toUpperCase();
  if (text) { send({ t: "cw", text: expandCW(text) }); $("cwText").value = ""; }
});
$("cwText").addEventListener("keydown", (e) => { if (e.key === "Enter") $("cwSend").click(); });
$("cwStop").addEventListener("click", () => send({ t: "cwstop" }));

// ---------- FT8 / FT4 ----------
let ft8s = {};
const ft8 = (op, extra) => send(Object.assign({ t: "ft8", op }, extra || {}));
$("ft8m8").addEventListener("click", () => ft8("mode", { m: "FT8" }));
$("ft8m4").addEventListener("click", () => ft8("mode", { m: "FT4" }));
$("ft8dec").addEventListener("click", () => ft8("decode", { on: !ft8s.on }));
$("ft8hound").addEventListener("click", () => ft8("hound", { on: !ft8s.hound }));
$("ft8cq").addEventListener("click", () => ft8("cq"));
$("ft8tx").addEventListener("click", () => ft8("tx", { on: !ft8s.tx }));
$("ft8stop").addEventListener("click", () => ft8("stop"));
function bandName(hz) {
  const m = hz / 1e6;
  return m < 2.5 ? "160" : m < 4.5 ? "80" : m < 6 ? "60" : m < 8 ? "40" : m < 11 ? "30" : m < 15 ? "20" :
         m < 19 ? "17" : m < 22 ? "15" : m < 25 ? "12" : m < 30 ? "10" : "6";
}
function showFT8State(m) {
  ft8s = m;
  $("ft8m8").classList.toggle("on", m.m === "FT8");
  $("ft8m4").classList.toggle("on", m.m === "FT4");
  $("ft8dec").classList.toggle("on", !!m.on);
  $("ft8hound").classList.toggle("on", !!m.hound);
  $("ft8tx").classList.toggle("on", !!m.tx);
  $("ft8tx").textContent = T(m.tx ? "Wyłącz TX" : "Włącz TX");
  const state = $("ft8State");
  state.textContent = m.txing ? T("NADAJE") : m.tx ? T("TX włączony") : "";
  state.style.color = m.txing ? "#ff5555" : "#d29922";
  const parts = [];
  if (m.next) parts.push(T("Następny") + ": " + m.next);
  if (m.dxc) parts.push(T("QSO z") + " " + m.dxc);
  parts.push("TX " + m.txf + " Hz · RX " + m.rxf + " Hz");
  if (m.st) parts.push(m.st);
  $("ft8Next").textContent = parts.join(" · ");
  const box = $("ft8Bands"); box.innerHTML = "";
  (m.bands || []).forEach((hz) => {
    const b = makeButton(bandName(hz) + " m", () => ft8("band", { hz }), box);
    b.classList.add("tog");
    if (bandName(hz) === bandName(m.dial || 0)) b.classList.add("on");
  });
}
function showFT8List(list) {
  const box = $("ft8List"); box.innerHTML = "";
  if (!list.length) { const e = document.createElement("div"); e.className = "small"; e.textContent = T("Brak komunikatów."); box.appendChild(e); return; }
  list.forEach((d) => {
    const r = document.createElement("div"); r.className = "ft8row" + (d.me ? " me" : "");
    const time = d.t.slice(0, 2) + ":" + d.t.slice(2, 4) + ":" + d.t.slice(4, 6);
    [time, (d.snr > 0 ? "+" : "") + d.snr, d.f].forEach((v) => { const c = document.createElement("span"); c.className = "dim"; c.textContent = v; r.appendChild(c); });
    const text = document.createElement("span"); text.textContent = d.txt;
    if (d.col) { text.style.color = d.col; text.style.fontWeight = "700"; }
    r.appendChild(text);
    r.title = d.dx || "";
    r.addEventListener("click", () => ft8("call", { id: d.id, tx: true }));
    box.appendChild(r);
  });
}

// ---------- Listy: ostatnie QSO, DX Cluster, alerty ----------
function row(parent, cells, onClick) {
  const r = document.createElement("div"); r.className = "item";
  cells.forEach((c) => r.appendChild(c));
  if (onClick) r.addEventListener("click", onClick);
  parent.appendChild(r);
}
function span(text, cls, bg) {
  const e = document.createElement("span"); e.textContent = text;
  if (cls) e.className = cls;
  if (bg) { e.classList.add("pill"); e.style.background = bg; }
  return e;
}
function empty(parent, text) { const e = document.createElement("div"); e.className = "small"; e.textContent = T(text); parent.appendChild(e); }
function showRecent(list) {
  const box = $("recent"); box.innerHTML = "";
  if (!list.length) return empty(box, "Brak łączności.");
  list.forEach((q) => row(box, [span(q.time, "mono dim"), span(q.band + " " + q.mode, "dim"), span(q.call + (q.rst ? "  " + q.rst : ""), "mono")]));
}
function showCluster(m) {
  $("clusterState").textContent = m.conn ? "" : "· " + T("brak połączenia");
  const box = $("clusterList"); box.innerHTML = "";
  if (!m.list.length) return empty(box, "Brak spotów.");
  m.list.forEach((s) => {
    const right = document.createElement("span");
    right.appendChild(span(s.c, "mono", s.col || "#d29922"));
    right.appendChild(span(" " + s.m + " · " + s.dx + (s.cm ? " · " + s.cm : ""), "dim"));
    row(box, [span(s.time, "mono dim"), span(s.khz, "mono"), right], () => { send({ t: "freq", hz: s.hz }); setLogCall(s.c); });
  });
}
function showAlerts(list) {
  const box = $("alertList"); box.innerHTML = "";
  if (!list.length) return empty(box, "Brak alertów.");
  list.forEach((a) => {
    const right = document.createElement("span");
    right.appendChild(span(a.kind, "", a.col));
    right.appendChild(span(" " + a.c + " " + a.band + " " + a.m + (a.d ? " · " + a.d : ""), "mono"));
    row(box, [span(a.time, "mono dim"), span(a.hz ? (a.hz / 1000).toFixed(1) : "", "mono dim"), right], () => {
      if (a.hz) send({ t: "freq", hz: a.hz });
      if (/^[A-Z0-9\/]{3,}$/.test(a.c)) setLogCall(a.c);
    });
  });
}

// Znaki stacji nad skopem (DX Cluster i POTA) - kolory jak w programie
let spots = [];
function drawSpots() {
  const box = $("spots");
  box.innerHTML = "";
  if (!(scope.hi > scope.lo)) return;
  const width = box.clientWidth, height = box.clientHeight;
  const rowEnds = [-1e9, -1e9, -1e9];
  spots.filter((s) => s.hz >= scope.lo && s.hz <= scope.hi)
       .map((s) => ({ s, x: ((s.hz - scope.lo) / (scope.hi - scope.lo)) * width }))
       .sort((a, b) => a.x - b.x)
       .forEach(({ s, x }) => {
         const w = s.c.length * 6.4 + 8;
         const left = Math.min(Math.max(x - w / 2, 0), Math.max(width - w, 0));
         let row = rowEnds.findIndex((end) => end + 3 <= left);
         if (row < 0) row = rowEnds.indexOf(Math.min(...rowEnds));
         rowEnds[row] = left + w;
         const top = 2 + row * 15;
         const label = document.createElement("span");
         label.className = "spot" + (s.p ? " pota" : "");
         label.textContent = s.c;
         label.title = s.c + " " + (s.tip || "");
         label.style.left = left + "px";
         label.style.top = top + "px";
         if (s.col) label.style.background = s.col;
         label.addEventListener("click", () => send({ t: "freq", hz: s.hz }));
         box.appendChild(label);
         const tick = document.createElement("div");
         tick.className = "tick" + (s.p ? " pota" : "");
         tick.style.left = x + "px";
         tick.style.top = top + 13 + "px";
         tick.style.height = Math.max(0, height - top - 13) + "px";
         box.appendChild(tick);
       });
}
window.addEventListener("resize", drawSpots);
applyLang();

function setFreqFromInput() {
  const v = parseFloat($("freqIn").value.replace(",", "."));
  if (v > 0) {
    send({ t: "freq", hz: Math.round(v * 1000) });
    $("freqIn").value = "";
    $("freqIn").blur();
  }
}
$("setFreq").addEventListener("click", setFreqFromInput);
$("freqIn").addEventListener("keydown", (e) => { if (e.key === "Enter") setFreqFromInput(); });

// ---------- połączenie ----------

function connect() {
  const pw = $("pw").value;
  if (!pw) {
    $("loginMsg").textContent = T("Podaj hasło");
    return;
  }
  $("loginMsg").textContent = T("Łączenie…");
  const proto = location.protocol === "https:" ? "wss://" : "ws://";
  ws = new WebSocket(proto + location.host + "/ws");
  ws.binaryType = "arraybuffer";
  ws.onopen = () => send({ t: "auth", pw });
  ws.onmessage = (e) => {
    if (typeof e.data === "string") onJSON(JSON.parse(e.data));
    else onBinary(e.data);
  };
  ws.onclose = () => {
    stopPTT();
    if (audioOn) stopAudio();           // po rozłączeniu zwolnij mikrofon
    clearInterval(pingTimer);
    $("app").classList.add("hidden");
    $("login").classList.remove("hidden");
    $("dot").classList.remove("ok");
    if ($("loginMsg").textContent === T("Łączenie…") || !$("loginMsg").textContent) {
      $("loginMsg").textContent = T("Połączenie zamknięte");
    }
  };
}
$("loginBtn").addEventListener("click", connect);
$("pw").addEventListener("keydown", (e) => { if (e.key === "Enter") connect(); });
$("logout").addEventListener("click", () => {
  stopPTT();
  $("loginMsg").textContent = T("Rozłączono");
  if (ws) ws.close();
});

function onJSON(m) {
  switch (m.t) {
    case "auth_ok":
      if (m.lang && !localStorage.getItem("ft710.lang")) { LANG = m.lang; applyLang(); }
      RANGES = m.ranges || {};
      MYCALL = m.mycall || "";
      applyRanges();
      $("loginMsg").textContent = "";
      $("login").classList.add("hidden");
      $("app").classList.remove("hidden");
      $("dot").classList.add("ok");
      $("conn").textContent = T("Połączono") + (m.station ? " · " + m.station : "");
      pingTimer = setInterval(() => send({ t: "ping", ts: performance.now() }), 2000);
      break;
    case "auth_fail":
      $("loginMsg").textContent = m.msg || T("Błędne hasło");
      break;
    case "state":
      st = m;
      render();
      break;
    case "spots":
      spots = m.list || [];
      drawSpots();
      break;
    case "notice":
      msg(m.msg);
      break;
    case "lookup":
      if (m.call === $("logCall").value) {
        const parts = [m.name, m.qth, m.grid, m.country].filter((x) => x);
        parts.push(m.worked > 0 ? T("było") + ": " + m.worked + " QSO (" + m.bands + ")" : T("nowa stacja"));
        $("logInfo").textContent = parts.join(" · ");
        if (m.name && !$("logName").value) $("logName").value = m.name;
        if (m.qth && !$("logQth").value) $("logQth").value = m.qth;
        if (m.grid && !$("logGrid").value) $("logGrid").value = m.grid;
      }
      break;
    case "logged":
      msg(T("Zapisano") + " " + m.call + " " + m.time + " UTC");
      ["logCall", "logName", "logQth", "logGrid", "logComment", "logRstS", "logRstR"].forEach((id) => { $(id).value = ""; });
      $("logInfo").textContent = "";
      break;
    case "recent":
      showRecent(m.list || []);
      break;
    case "cluster":
      showCluster(m);
      break;
    case "alerts":
      showAlerts(m.list || []);
      break;
    case "ft8":
      showFT8List(m.list || []);
      break;
    case "ft8s":
      showFT8State(m);
      break;
    case "pong":
      $("rtt").textContent = T("opóźnienie") + " " + Math.round(performance.now() - m.ts) + " ms";
      break;
    case "ptt_off":
      stopPTT(true);
      if (m.reason) msg(T("Nadawanie zakończone przez stację:") + " " + m.reason);
      break;
  }
}

// ---------- widok ----------

function setBar(id, raw) {
  $(id).style.width = Math.max(0, Math.min(100, (raw / 255) * 100)) + "%";
}

function render() {
  $("freq").textContent = st.conn ? fmtFreq(st.f) : T("radio rozłączone");
  $("mode").textContent = st.m || "–";
  $("txBadge").classList.toggle("hidden", !st.tx);
  document.querySelectorAll("#modes button").forEach((b) => b.classList.toggle("on", b.dataset.code === st.mc));
  const band = bandOf(st.f);
  document.querySelectorAll("#bands button").forEach((b) => b.classList.toggle("on", b.dataset.band === band));
  const c = st.ctl || {};
  const mark = (id, v) => document.querySelectorAll("#" + id + " button").forEach((b) => b.classList.toggle("on", v !== undefined && +b.dataset.v === v));
  mark("ctlAtt", c.att);
  mark("ctlIpo", c.ipo);
  mark("ctlAgc", c.agc === undefined ? undefined : Math.min(c.agc, 4));   // AUTO-FAST/MID/SLOW = AUTO
  if (c.pwr !== undefined && !$("ctlPwr").dataset.busy) { $("ctlPwr").value = c.pwr; $("ctlPwrTxt").textContent = c.pwr + " W"; }
  if (c.ks !== undefined && !$("ctlKs").dataset.busy) { $("ctlKs").value = c.ks; $("ctlKsTxt").textContent = c.ks; }
  $("ctlKsRow").classList.toggle("hidden", !(st.mc === "3" || st.mc === "7"));
  $("pCW").classList.toggle("hidden", !(st.mc === "3" || st.mc === "7"));
  $("vfoA").textContent = "";
  $("vfoB").textContent = "B " + fmtFreq(st.fb);
  $("splitBadge").classList.toggle("hidden", !c.split);
  $("ctlSplit").classList.toggle("on", !!c.split);
  $("ctlTuner").classList.toggle("on", !!c.tuner);
  document.querySelectorAll("[data-ctl]").forEach((b) => b.classList.toggle("on", !!c[b.dataset.ctl]));
  SLIDERS.forEach((s) => {
    const v = c[s.name];
    if (v !== undefined && !s.el.dataset.busy) { s.el.value = v; s.txt.textContent = s.fmt(v); }
  });
  const rst = defaultRST();
  ["logRstS", "logRstR"].forEach((id) => { const el = $(id); if (document.activeElement !== el) el.placeholder = rst || T(id === "logRstS" ? "RST wysłany" : "RST odebrany"); });
  setBar("sBar", st.tx ? 0 : st.s);
  $("sTxt").textContent = st.tx ? "–" : st.sTxt;
  // Kolejność jak w radiu: PO, COMP, ALC, SWR (aktywne tylko podczas nadawania).
  setBar("poBar", st.tx ? st.po : 0);
  $("poTxt").textContent = st.tx ? st.poTxt : "–";
  setBar("compBar", st.tx ? st.comp || 0 : 0);
  $("compTxt").textContent = st.tx && st.compTxt ? st.compTxt : "–";
  setBar("alcBar", st.tx ? st.alc : 0);
  $("alcTxt").textContent = st.tx ? st.alcTxt : "–";
  setBar("swrBar", st.tx ? st.swr : 0);
  $("swrTxt").textContent = st.tx ? st.swrTxt : "–";
  // SWR jak w aplikacji na stacji: od ok. 2:1 pomarańczowy, od ok. 4:1 czerwony.
  const swrRaw = st.tx ? st.swr : 0;
  $("swrBar").style.background = swrRaw >= 126 ? "var(--red)" : swrRaw >= 52 ? "var(--amber)" : "var(--acc)";

  const canTX = st.allowTX && st.audioTX && st.txHere && micReady && st.conn;
  $("ptt").disabled = !canTX;
  if (!st.txHere || !secure) $("pttHint").textContent = T("To połączenie z sieci domowej (http) - tylko odbiór. Do nadawania otwórz adres Tailscale (https).");
  else if (!st.allowTX) $("pttHint").textContent = T("Nadawanie zdalne jest wyłączone na stacji.");
  else if (!st.audioTX) $("pttHint").textContent = T("Stacja nie ma toru audio do radia.");
  else if (!micReady) $("pttHint").textContent = T("Włącz audio, żeby udostępnić mikrofon.");
  else $("pttHint").textContent = T("Przytrzymaj przycisk (lub spację) podczas mówienia.");
  if (!st.audioRX) $("audioInfo").textContent = T("Stacja nie wysyła audio (sprawdź „Z radia (RX)”).");
  else $("audioInfo").textContent = "";
}

// ---------- dane binarne ----------

function onBinary(buf) {
  const type = new Uint8Array(buf, 0, 1)[0];
  if (type === 1 && rxPush && audioOn) {
    const pcm = new Int16Array(buf, 4);
    const f = new Float32Array(pcm.length);
    for (let i = 0; i < pcm.length; i++) {
      f[i] = pcm[i] / 32768;
      const a = Math.abs(f[i]);
      if (a > rxPeak) rxPeak = a;
    }
    rxPackets++;
    rxPush(f);
  } else if (type === 1) {
    rxPackets++;
  } else if (type === 2) {
    const dv = new DataView(buf);
    scope.lo = dv.getUint32(4, true);
    scope.hi = dv.getUint32(8, true);
    drawScope(new Uint8Array(buf, 12));
  }
}

// ---------- skop ----------

function buildPalette() {
  const stops = [[0, 0, 0, 0], [0.25, 0, 0, 0.55], [0.45, 0, 0.6, 0.9], [0.65, 0.1, 0.85, 0.2],
                 [0.8, 1, 0.9, 0], [0.92, 1, 0.25, 0], [1, 1, 1, 1]];
  const p = new Uint8ClampedArray(256 * 3);
  for (let i = 0; i < 256; i++) {
    const t = i / 255;
    let k = 1;
    while (k < stops.length - 1 && stops[k][0] < t) k++;
    const a = stops[k - 1];
    const b = stops[k];
    const f = Math.max(0, Math.min(1, (t - a[0]) / (b[0] - a[0])));
    for (let c = 0; c < 3; c++) p[i * 3 + c] = 255 * (a[c + 1] + (b[c + 1] - a[c + 1]) * f);
  }
  return p;
}

function drawScope(a) {
  const n = a.length;
  const trace = $("trace");
  const wf = $("wf");
  if (scope.width !== n) {
    scope.width = n;
    trace.width = n;
    wf.width = n;
    palette = palette || buildPalette();
  }

  // automatyczne tło: 40. percentyl, szum na ok. 25% skali
  const sorted = Array.from(a).sort((x, y) => x - y);
  const target = sorted[Math.floor(n * 0.4)] - 0.25 * RANGE;
  scope.floor = scope.floor === null ? target : scope.floor + 0.1 * (target - scope.floor);
  const norm = (v) => Math.max(0, Math.min(1, (v - scope.floor) / RANGE));

  // linia widma
  const tc = trace.getContext("2d");
  const th = trace.height;
  tc.clearRect(0, 0, n, th);
  tc.beginPath();
  for (let i = 0; i < n; i++) {
    const y = th - norm(a[i]) * (th - 3);
    if (i === 0) tc.moveTo(i, y);
    else tc.lineTo(i, y);
  }
  tc.strokeStyle = "#3fb950";
  tc.lineWidth = 1.2;
  tc.stroke();

  // znacznik VFO A
  if (st.f && scope.hi > scope.lo && st.f >= scope.lo && st.f <= scope.hi) {
    const x = ((st.f - scope.lo) / (scope.hi - scope.lo)) * n;
    tc.fillStyle = "rgba(218,54,51,0.9)";
    tc.fillRect(x - 0.75, 0, 1.5, th);
  }

  // waterfall: przesuń w dół o 1 piksel i dopisz nowy wiersz u góry
  const wc = wf.getContext("2d");
  const wh = wf.height;
  wc.drawImage(wf, 0, 0, n, wh - 1, 0, 1, n, wh - 1);
  const row = wc.createImageData(n, 1);
  for (let i = 0; i < n; i++) {
    const idx = Math.round(norm(a[i]) * 255) * 3;
    row.data[i * 4] = palette[idx];
    row.data[i * 4 + 1] = palette[idx + 1];
    row.data[i * 4 + 2] = palette[idx + 2];
    row.data[i * 4 + 3] = 255;
  }
  wc.putImageData(row, 0, 0);

  // oś
  const span = scope.hi - scope.lo;
  const decimals = span < 10000 ? 4 : 3;
  for (let i = 0; i <= 4; i++) {
    $("ax" + i).textContent = ((scope.lo + (span * i) / 4) / 1e6).toFixed(decimals);
  }
  $("scopeInfo").textContent = T("Skop RF") + " · span " + (span >= 1e6 ? span / 1e6 + " MHz" : span / 1000 + " kHz") +
    " · " + T("dotknij, aby dostroić");
  drawSpots();
}

function tuneFromScope(e) {
  if (!(scope.hi > scope.lo)) return;
  const rect = e.currentTarget.getBoundingClientRect();
  const t = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
  const step = scope.hi - scope.lo >= 20000 ? 100 : 10;
  const hz = Math.round((scope.lo + (scope.hi - scope.lo) * t) / step) * step;
  send({ t: "freq", hz });
}
$("trace").addEventListener("click", tuneFromScope);
$("wf").addEventListener("click", tuneFromScope);

// ---------- audio ----------

// Zapasowy odtwarzacz RX dla stron bez HTTPS (ScriptProcessorNode działa wszędzie).
// Ta sama logika bufora co w worklet.js, z nieco większym zapasem (działa w wątku strony).
function createFallbackRx(ctx) {
  const RATE = 12000;
  const size = RATE * 4;
  const buf = new Float32Array(size);
  const target = Math.round(RATE * 0.25);
  const max = Math.round(RATE * 0.7);
  let r = 0, w = 0, count = 0, pos = 0, primed = false;
  const node = ctx.createScriptProcessor(2048, 1, 2);
  node.onaudioprocess = (e) => {
    const out = e.outputBuffer.getChannelData(0);
    const step = RATE / ctx.sampleRate;
    let i = 0;
    if (!primed && count >= target) primed = true;
    if (primed) {
      for (; i < out.length; i++) {
        if (count < 2) { primed = false; break; }
        const a = buf[r];
        const b = buf[(r + 1) % size];
        out[i] = a + (b - a) * pos;
        pos += step;
        while (pos >= 1) { pos -= 1; r = (r + 1) % size; count--; }
      }
    }
    out.fill(0, i);
    for (let c = 1; c < e.outputBuffer.numberOfChannels; c++) e.outputBuffer.getChannelData(c).set(out);
  };
  // Część przeglądarek przetwarza ScriptProcessor tylko z podłączonym wejściem.
  const silence = ctx.createGain();
  silence.gain.value = 0;
  const osc = ctx.createOscillator();
  osc.connect(silence).connect(node);
  osc.start();
  const push = (samples) => {
    for (let k = 0; k < samples.length; k++) {
      buf[w] = samples[k];
      w = (w + 1) % size;
      if (count < size) count++; else r = (r + 1) % size;
    }
    if (count > max) {
      const drop = count - target;
      r = (r + drop) % size;
      count -= drop;
    }
  };
  return { node, push, bufferedMs: () => Math.round((count / RATE) * 1000) };
}

// iPhone/iPad: domyślnie Safari traktuje dźwięk strony jak „efekty” i wycisza go przełącznikiem
// trybu cichego. Typ sesji „playback” (Safari 16.4+) sprawia, że gra jak odtwarzacz muzyki.
// Z mikrofonem potrzebny jest „play-and-record”.
function setAudioSession(type) {
  try {
    if (navigator.audioSession) navigator.audioSession.type = type;
  } catch (err) { /* starsze przeglądarki - bez znaczenia */ }
  // navigator.audioSession działa tylko przez HTTPS (i od iOS 16.4). W pozostałych przypadkach
  // odtwarzanie cichego elementu <audio> przełącza iOS w tryb odtwarzacza, który ignoruje
  // przełącznik trybu cichego - wtedy Web Audio też staje się słyszalne.
  if (type === "playback" && !navigator.audioSession) playSilentElement();
}

let silentElement = null;

// 0,5 s ciszy jako plik WAV (8 kHz, 8 bit, mono) tworzony w pamięci.
function silentWavURL() {
  const samples = 4000;
  const bytes = new Uint8Array(44 + samples);
  const view = new DataView(bytes.buffer);
  const text = (offset, value) => { for (let i = 0; i < value.length; i++) bytes[offset + i] = value.charCodeAt(i); };
  text(0, "RIFF"); view.setUint32(4, 36 + samples, true); text(8, "WAVE");
  text(12, "fmt "); view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
  view.setUint32(24, 8000, true); view.setUint32(28, 8000, true); view.setUint16(32, 1, true); view.setUint16(34, 8, true);
  text(36, "data"); view.setUint32(40, samples, true);
  bytes.fill(128, 44);                 // 8-bitowe PCM: 128 = cisza
  return URL.createObjectURL(new Blob([bytes], { type: "audio/wav" }));
}

function playSilentElement() {
  if (!silentElement) {
    silentElement = document.createElement("audio");
    silentElement.src = silentWavURL();
    silentElement.loop = true;
    silentElement.setAttribute("playsinline", "");
    silentElement.setAttribute("x-webkit-airplay", "deny");
  }
  const attempt = silentElement.play();      // musi być wywołane z kliknięcia użytkownika
  if (attempt && attempt.catch) attempt.catch(() => { /* bez tego i tak spróbujemy grać */ });
}

function stopSilentElement() {
  if (silentElement) silentElement.pause();
}

async function startAudio() {
  setAudioSession(secure && navigator.mediaDevices ? "play-and-record" : "playback");
  // Safari (iPhone): o mikrofon trzeba poprosić od razu w dotknięciu, zanim cokolwiek zacznie czekać
  // (pobieranie modułu dźwięku, resume) - inaczej odmawia z NotAllowedError.
  let micRequest = null;
  if (secure && !micReady && navigator.mediaDevices && navigator.mediaDevices.getUserMedia) {
    micRequest = navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true, noiseSuppression: false, autoGainControl: true, channelCount: 1 }
    });
    micRequest.catch(() => {});        // odmowa obsłużona niżej - bez ostrzeżenia o nieobsłużonym błędzie
  }
  try {
    if (!actx) {
      const Ctx = window.AudioContext || window.webkitAudioContext;
      actx = new Ctx({ latencyHint: "interactive" });
      rxGain = actx.createGain();
      rxGain.gain.value = parseFloat($("vol").value);
      rxGain.connect(actx.destination);
      if (secure && actx.audioWorklet) {
        await actx.audioWorklet.addModule("/worklet.js");
        const node = new AudioWorkletNode(actx, "rx-player", { numberOfInputs: 0, outputChannelCount: [2] });
        node.connect(rxGain);
        rxPush = (f) => node.port.postMessage(f, [f.buffer]);
      } else {
        const fallback = createFallbackRx(actx);
        fallback.node.connect(rxGain);
        rxPush = fallback.push;
        fallbackLevel = fallback.bufferedMs;
      }
    }
    await actx.resume();
    audioOn = true;
    $("audioBtn").textContent = T("Wyłącz audio");
    $("audioBtn").classList.remove("on");
    if (micRequest) {
      try {
        startMic(await micRequest);
      } catch (err) {
        msg(T("Mikrofon zablokowany - w Safari: „aA” → Ustawienia witryny → Mikrofon → Pozwalaj (aplikacja z ekranu początkowego: Ustawienia → Safari → Mikrofon); w Chrome: Ustawienia iPhone’a → Aplikacje → Chrome → Mikrofon. Potem Wyłącz i Włącz audio.") + " (" + err.name + ")");
      }
    } else if (secure && !micReady) {
      msg(T("Mikrofon niedostępny - otwórz stronę przez https (tailscale serve), nie przez http."));
    }
    if (!secure) msg(T("Połączenie bez HTTPS: działa odsłuch, mikrofon i nadawanie są niedostępne."));
    render();
  } catch (err) {
    msg(T("Audio:") + " " + err.message);
  }
}

/// Podłączenie strumienia mikrofonu (pozwolenie uzyskane już w dotknięciu „Włącz audio”).
function startMic(stream) {
  micStream = stream;
  micSource = actx.createMediaStreamSource(stream);
  micNode = new AudioWorkletNode(actx, "mic-capture");
  const silent = actx.createGain();
  silent.gain.value = 0;               // węzeł musi być w grafie, żeby był przetwarzany
  micSource.connect(micNode).connect(silent).connect(actx.destination);
  micNode.port.onmessage = (e) => {
    if (!pttOn || !ws || ws.readyState !== 1) return;
    const pcm = e.data;
    const packet = new Uint8Array(4 + pcm.byteLength);
    packet[0] = 3;
    packet.set(new Uint8Array(pcm.buffer, pcm.byteOffset, pcm.byteLength), 4);
    ws.send(packet.buffer);
  };
  micReady = true;
}

// Wyłączenie: koniec nadawania, zwolnienie mikrofonu (gaśnie wskaźnik mikrofonu w telefonie),
// zatrzymanie odtwarzania. Kontekst audio zostaje uśpiony i wraca przy ponownym włączeniu.
async function stopAudio() {
  stopPTT(false);
  audioOn = false;
  if (micStream) micStream.getTracks().forEach((track) => track.stop());
  if (micSource) micSource.disconnect();
  if (micNode) micNode.disconnect();
  micStream = null;
  micSource = null;
  micNode = null;
  micReady = false;
  stopSilentElement();
  if (actx && actx.state === "running") {
    try { await actx.suspend(); } catch (err) { /* ignoruj */ }
  }
  $("audioBtn").textContent = T("Włącz audio");
  $("audioBtn").classList.add("on");
  msg("");
  render();
}

$("audioBtn").addEventListener("click", () => (audioOn ? stopAudio() : startAudio()));

// Krótki ton 600 Hz wygenerowany w telefonie - sprawdza, czy przeglądarka w ogóle wydaje dźwięk.
$("beepBtn").addEventListener("click", async () => {
  if (!micReady) setAudioSession("playback");
  const Ctx = window.AudioContext || window.webkitAudioContext;
  const ctx = actx || new Ctx();
  await ctx.resume();
  const osc = ctx.createOscillator();
  const g = ctx.createGain();
  osc.frequency.value = 600;
  g.gain.value = 0.2;
  osc.connect(g).connect(ctx.destination);
  osc.start();
  osc.stop(ctx.currentTime + 0.4);
});

// Co sekundę: stan kontekstu audio, pakiety RX, poziom szczytowy, bufor.
setInterval(() => {
  if ($("app").classList.contains("hidden")) return;
  const parts = [];
  parts.push("audio " + (actx ? actx.state + " " + actx.sampleRate + " Hz" : "wyłączone"));
  parts.push("pakiety RX " + rxPackets + "/s");
  parts.push("poziom " + (rxPeak > 0 ? Math.round(20 * Math.log10(rxPeak)) + " dBFS" : "cisza"));
  if (fallbackLevel) parts.push("bufor " + fallbackLevel() + " ms");
  $("audioDiag").textContent = parts.join(" · ");
  rxPackets = 0;
  rxPeak = 0;
}, 1000);
$("vol").addEventListener("input", () => {
  if (rxGain && !pttOn) rxGain.gain.value = parseFloat($("vol").value);
});

// ---------- PTT ----------

function startPTT() {
  if (pttOn || $("ptt").disabled) return;
  pttOn = true;
  msg("");
  micNode.port.postMessage({ active: true });
  if (rxGain) rxGain.gain.value = 0;      // bez odsłuchu podczas nadawania (sprzężenie)
  send({ t: "ptt", on: true });
  hbTimer = setInterval(() => send({ t: "hb" }), 100);
  $("ptt").classList.add("active");
}

function stopPTT(fromStation) {
  if (!pttOn) return;
  pttOn = false;
  clearInterval(hbTimer);
  hbTimer = null;
  if (micNode) micNode.port.postMessage({ active: false });
  if (rxGain) rxGain.gain.value = parseFloat($("vol").value);
  if (!fromStation) send({ t: "ptt", on: false });
  $("ptt").classList.remove("active");
}

const pttButton = $("ptt");
pttButton.addEventListener("pointerdown", (e) => {
  e.preventDefault();
  pttButton.setPointerCapture(e.pointerId);
  startPTT();
});
["pointerup", "pointercancel", "lostpointercapture"].forEach((name) =>
  pttButton.addEventListener(name, () => stopPTT(false)));
pttButton.addEventListener("contextmenu", (e) => e.preventDefault());
document.addEventListener("visibilitychange", () => { if (document.hidden) stopPTT(false); });
window.addEventListener("blur", () => stopPTT(false));
window.addEventListener("pagehide", () => stopPTT(false));
document.addEventListener("keydown", (e) => {
  if (e.code === "Space" && !e.repeat && document.activeElement.tagName !== "INPUT") {
    e.preventDefault();
    startPTT();
  }
});
document.addEventListener("keyup", (e) => { if (e.code === "Space") stopPTT(false); });
"""##

    static let workletJS = ##"""
// FT-710 Control - procesory audio przeglądarki (AudioWorklet).
// Sieć: PCM 16 bit mono 12 kHz w obie strony.

const NET_RATE = 12000;

// Odtwarzanie RX z buforem przeciw drganiom (jitter): start po 150 ms danych,
// powyżej 500 ms zaległości odrzucamy nadmiar, żeby opóźnienie nie rosło.
class RxPlayer extends AudioWorkletProcessor {
  constructor() {
    super();
    this.size = NET_RATE * 4;
    this.buf = new Float32Array(this.size);
    this.r = 0;
    this.w = 0;
    this.count = 0;
    this.pos = 0;
    this.primed = false;
    this.target = Math.round(NET_RATE * 0.15);
    this.max = Math.round(NET_RATE * 0.5);
    this.port.onmessage = (e) => this.push(e.data);
  }

  push(samples) {
    for (let i = 0; i < samples.length; i++) {
      this.buf[this.w] = samples[i];
      this.w = (this.w + 1) % this.size;
      if (this.count < this.size) {
        this.count++;
      } else {
        this.r = (this.r + 1) % this.size;
      }
    }
    if (this.count > this.max) {
      const drop = this.count - this.target;
      this.r = (this.r + drop) % this.size;
      this.count -= drop;
    }
  }

  process(inputs, outputs) {
    const channels = outputs[0];
    const out = channels[0];
    const step = NET_RATE / sampleRate;
    if (!this.primed) {
      if (this.count >= this.target) {
        this.primed = true;
      } else {
        for (const ch of channels) ch.fill(0);
        return true;
      }
    }
    for (let i = 0; i < out.length; i++) {
      if (this.count < 2) {
        this.primed = false;
        out.fill(0, i);
        break;
      }
      const a = this.buf[this.r];
      const b = this.buf[(this.r + 1) % this.size];
      out[i] = a + (b - a) * this.pos;
      this.pos += step;
      while (this.pos >= 1) {
        this.pos -= 1;
        this.r = (this.r + 1) % this.size;
        this.count--;
      }
    }
    for (let c = 1; c < channels.length; c++) channels[c].set(out);
    return true;
  }
}
registerProcessor("rx-player", RxPlayer);

// Mikrofon: dwa filtry dolnoprzepustowe (~4,5 kHz) przed decymacją do 12 kHz,
// paczki po 240 próbek (20 ms) jako Int16. Działa tylko, gdy włączone (podczas PTT).
class MicCapture extends AudioWorkletProcessor {
  constructor() {
    super();
    this.ratio = sampleRate / NET_RATE;
    this.alpha = 1 - Math.exp((-2 * Math.PI * 4500) / sampleRate);
    this.lp1 = 0;
    this.lp2 = 0;
    this.pos = 0;
    this.out = new Int16Array(240);
    this.n = 0;
    this.active = false;
    this.port.onmessage = (e) => {
      this.active = !!e.data.active;
      if (!this.active) this.n = 0;
    };
  }

  process(inputs) {
    const input = inputs[0] && inputs[0][0];
    if (!input || !this.active) return true;
    for (let i = 0; i < input.length; i++) {
      this.lp1 += this.alpha * (input[i] - this.lp1);
      this.lp2 += this.alpha * (this.lp1 - this.lp2);
      this.pos += 1;
      if (this.pos >= this.ratio) {
        this.pos -= this.ratio;
        const v = Math.max(-1, Math.min(1, this.lp2));
        this.out[this.n++] = Math.round(v * 32767);
        if (this.n === this.out.length) {
          this.port.postMessage(this.out.slice());
          this.n = 0;
        }
      }
    }
    return true;
  }
}
registerProcessor("mic-capture", MicCapture);
"""##

    static let manifest = """
    {"name": "FT-710 Control", "short_name": "FT-710", "start_url": "/", "display": "standalone",
     "background_color": "#0d1117", "theme_color": "#0d1117",
     "icons": [{"src": "/icon-192.png", "sizes": "192x192", "type": "image/png"},
               {"src": "/icon-180.png", "sizes": "180x180", "type": "image/png"}]}
    """

    static var files: [String: WebSocketServer.StaticFile] {
        func file(_ type: String, _ body: String) -> WebSocketServer.StaticFile {
            WebSocketServer.StaticFile(contentType: type, body: Data(body.utf8))
        }
        return [
            "/": file("text/html; charset=utf-8", indexHTML),
            "/index.html": file("text/html; charset=utf-8", indexHTML),
            "/app.js": file("text/javascript; charset=utf-8", appJS),
            "/worklet.js": file("text/javascript; charset=utf-8", workletJS),
            // „Do ekranu początkowego”: ikona i manifest - panel otwiera się jak aplikacja, na całym ekranie
            "/manifest.webmanifest": file("application/manifest+json", manifest),
            "/icon-180.png": WebSocketServer.StaticFile(contentType: "image/png", body: RemoteWebIcons.icon180),
            "/icon-192.png": WebSocketServer.StaticFile(contentType: "image/png", body: RemoteWebIcons.icon192)
        ]
    }
}
