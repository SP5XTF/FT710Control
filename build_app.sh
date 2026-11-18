#!/bin/bash
# Buduje samodzielną aplikację FT710Control.app (działa bez Xcode).
# Do kompilacji potrzebny jest kompilator Swift: Xcode albo same „Command Line Tools”
# (xcode-select --install). Gotowej aplikacji Xcode nie potrzebuje.
#
# Użycie:   ./build_app.sh               -> build/FT710Control.app (procesor tego Maca)
#           ./build_app.sh --universal   -> Apple Silicon + Intel (wymaga pełnego Xcode)
#           ./build_app.sh --install     -> dodatkowo kopiuje do /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="FT710Control"
DISPLAY_NAME="FT-710 Control"
BUNDLE_ID="com.ft710control.app"
VERSION=$(grep -o 'programVersion = "[^"]*"' Sources/FT710Control/ADIF.swift | cut -d'"' -f2)
BUILD_NUMBER=$(date +%Y%m%d%H%M)

INSTALL=0
UNIVERSAL=0
ARCH_FLAGS=()
for arg in "$@"; do
    case "${arg}" in
        --install) INSTALL=1 ;;
        --universal) UNIVERSAL=1; ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
        *) echo "Nieznana opcja: ${arg}" >&2; exit 1 ;;
    esac
done
# bash 3.2 (macOS) z set -u: pusta tablica wymaga zapisu ${TAB[@]+"${TAB[@]}"}

if [[ "${UNIVERSAL}" == "1" ]] && ! xcodebuild -version >/dev/null 2>&1; then
    echo "Wersja uniwersalna (Apple Silicon + Intel) wymaga pełnego Xcode - na tym Macu są tylko" >&2
    echo "narzędzia wiersza poleceń. Uruchom bez --universal (wersja dla Maców z procesorem Apple)." >&2
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "Brak kompilatora Swift. Zainstaluj Xcode albo: xcode-select --install" >&2
    exit 1
fi

echo "==> Kompilacja (Release, wersja ${VERSION})..."
if ! swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}; then
    if ! xcodebuild -version >/dev/null 2>&1; then
        echo "" >&2
        echo "Kompilacja nie powiodła się, a na tym Macu nie ma pełnego Xcode (są tylko narzędzia" >&2
        echo "wiersza poleceń). Na nowych wersjach macOS SwiftUI wymaga do kompilacji pełnego Xcode" >&2
        echo "(błąd: SwiftUIMacros ... not found). Zainstaluj Xcode z App Store albo zbuduj aplikację" >&2
        echo "na Macu z Xcode - gotowa aplikacja i obraz .dmg działają bez Xcode." >&2
    fi
    exit 1
fi
BIN_DIR=$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)

APP="build/${APP_NAME}.app"
echo "==> Składanie ${APP}..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp Design/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>pl</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION%%-*}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>FT-710 Control odczytuje dźwięk z radia (USB) do odsłuchu, widma i dekoderów oraz może nadawać dźwięk z mikrofonu Maca przez USB.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>FT-710 Control udostępnia sterowanie radiem w sieci lokalnej (CAT Share, praca zdalna) i odbiera łączności z WSJT-X.</string>
</dict>
</plist>
PLIST

# Biblioteki FTDI (skop RF przez układ FT4222 w FT-710) wbudowane w aplikację - użytkownik nie instaluje
# niczego sam. Źródło: biblioteki zainstalowane na tym Macu (domyślnie /usr/local/lib; inny katalog:
# FTDI_LIB_DIR=...). Licencja FTDI: tylko do użytku z oryginalnymi układami FTDI (FT-710 ma FT4222) -
# informacja o licencji trafia do DMG (Licencje.txt). Bez bibliotek na tym Macu aplikacja powstaje bez nich.
FTDI_DIR="${FTDI_LIB_DIR:-/usr/local/lib}"
FW="${APP}/Contents/Frameworks"
newest() { ls "${FTDI_DIR}"/"$1".*dylib 2>/dev/null | sort -V | tail -1; }
FT4222_SRC=$(newest libft4222)
FTD2XX_SRC=$(newest libftd2xx)
# warunek zgody FTDI: pełny tekst licencji razem z bibliotekami - bez niego biblioteki NIE są dołączane
FTDI_LICENCE="Design/FTDI/FTDI-Driver-Licence.txt"
if [[ ! -s "${FTDI_LICENCE}" ]]; then
    echo "UWAGA: brak ${FTDI_LICENCE} (pełny tekst licencji FTDI) - biblioteki FTDI NIE zostaną dołączone." >&2
    echo "       Skopiuj treść https://ftdichip.com/driver-licence-terms-details/ do tego pliku." >&2
    FT4222_SRC=""
fi
if [[ -n "${FT4222_SRC}" && -n "${FTD2XX_SRC}" ]]; then
    echo "==> Biblioteki FTDI do aplikacji: $(basename "$(readlink -f "${FT4222_SRC}")"), $(basename "$(readlink -f "${FTD2XX_SRC}")")"
    mkdir -p "${FW}"
    cp -L "${FT4222_SRC}" "${FW}/libft4222.dylib"
    cp -L "${FTD2XX_SRC}" "${FW}/libftd2xx.dylib"
    chmod u+w "${FW}/libft4222.dylib" "${FW}/libftd2xx.dylib"
    install_name_tool -id @rpath/libft4222.dylib "${FW}/libft4222.dylib" 2>/dev/null
    install_name_tool -id @rpath/libftd2xx.dylib "${FW}/libftd2xx.dylib" 2>/dev/null
    # libft4222 wskazuje libftd2xx pełną ścieżką (np. /usr/local/lib/...) - na kopię obok siebie w aplikacji
    OLD_D2XX=$(otool -L "${FW}/libft4222.dylib" | awk '/libftd2xx/ {print $1; exit}')
    if [[ -n "${OLD_D2XX}" ]]; then
        install_name_tool -change "${OLD_D2XX}" @loader_path/libftd2xx.dylib "${FW}/libft4222.dylib" 2>/dev/null
    fi
    cp "${FTDI_LICENCE}" "${FW}/FTDI-Driver-Licence.txt"          # licencja obok sterownika (warunek FTDI)
    xattr -cr "${FW}"
    codesign --force --sign - "${FW}/libftd2xx.dylib" "${FW}/libft4222.dylib"
    echo "    zależność libft4222 -> $(otool -L "${FW}/libft4222.dylib" | awk '/libftd2xx/ {print $1; exit}')"
else
    echo "UWAGA: brak bibliotek FTDI w ${FTDI_DIR} - aplikacja BEZ nich (skop wymaga instalacji przez użytkownika)" >&2
fi

# Podpis ad-hoc (wymagany na Apple Silicon; pieczętuje Info.plist i zasoby)
echo "==> Podpisywanie (ad-hoc)..."
codesign --force --deep --sign - "${APP}"
codesign --verify --deep --strict "${APP}"

# Ustawienia z uruchomień przez Xcode / swift run (domena „FT710Control”) -> domena aplikacji - jednorazowo
if defaults read "${APP_NAME}" >/dev/null 2>&1 && ! defaults read "${BUNDLE_ID}" >/dev/null 2>&1; then
    echo "==> Przenoszenie ustawień (port CAT, audio, filtry, makra...) do aplikacji..."
    defaults export "${APP_NAME}" - | defaults import "${BUNDLE_ID}" -
fi

echo "==> Architektury: $(lipo -archs "${APP}/Contents/MacOS/${APP_NAME}")"

# Minimalna wersja macOS zapisana w programie - musi być 13.0, inaczej starsze Maci go nie uruchomią
if command -v vtool >/dev/null 2>&1; then
    MINOS=$(vtool -show-build "${APP}/Contents/MacOS/${APP_NAME}" 2>/dev/null | awk '/minos/ {print $2; exit}')
    echo "==> Minimalna wersja macOS w programie: ${MINOS:-?}"
    if [[ -n "${MINOS}" && "${MINOS%%.*}" -gt 13 ]]; then
        echo "UWAGA: program wymaga macOS ${MINOS} - na starszych systemach się nie uruchomi." >&2
        echo "       Prześlij ten komunikat - trzeba wymusić minimum 13.0." >&2
    fi
fi

if [[ "${INSTALL}" == "1" ]]; then
    echo "==> Instalacja w /Applications..."
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP}" "/Applications/${APP_NAME}.app"
    echo "OK: Gotowe: /Applications/${APP_NAME}.app"
else
    echo "OK: Gotowe: ${APP}   (instalacja w /Applications: ./build_app.sh --install)"
fi
