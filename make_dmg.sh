#!/bin/bash
# Buduje obraz .dmg wersji beta: aplikacja + skrót do folderu Aplikacje + instrukcje dla użytkowników
# (PL i EN: wymagania, instalacja, pierwsze uruchomienie, ustawienia radia, dodatkowe pliki) + licencje.
#
# Użycie:   ./make_dmg.sh                -> dist/FT710Control-<wersja>.dmg (np. FT710Control-0.9.0-beta.dmg)
#           ./make_dmg.sh --universal    -> wersja dla Maców Apple Silicon i Intel (wymaga pełnego Xcode)
#           ./make_dmg.sh --no-build     -> bez ponownej kompilacji (z istniejącego build/FT710Control.app)
# Kontakt w instrukcji:  FT710_CONTACT="SP5XTF, adres@example.com" ./make_dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="FT710Control"
VERSION=$(grep -o 'programVersion = "[^"]*"' Sources/FT710Control/ADIF.swift | cut -d'"' -f2)
CONTACT="${FT710_CONTACT:-SP5XTF (https://www.qrz.com/db/SP5XTF)}"
DATE=$(date +%Y-%m-%d)

BUILD=1
BUILD_ARGS=()
for arg in "$@"; do
    case "${arg}" in
        --no-build) BUILD=0 ;;
        --universal) BUILD_ARGS=(--universal) ;;
        *) echo "Nieznana opcja: ${arg}" >&2; exit 1 ;;
    esac
done

if [[ "${BUILD}" == "1" ]]; then
    bash ./build_app.sh ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}
fi
APP="build/${APP_NAME}.app"
if [[ ! -d "${APP}" ]]; then
    echo "Brak ${APP} - uruchom bez --no-build albo najpierw ./build_app.sh" >&2
    exit 1
fi

# Dla jakich Maców jest ten obraz (wpisywane do instrukcji)
ARCHS=$(lipo -archs "${APP}/Contents/MacOS/${APP_NAME}")
case "${ARCHS}" in
    *arm64*x86_64*|*x86_64*arm64*)
        ARCH="Apple Silicon + Intel"
        ARCH_TEXT="Maców z procesorem Apple (M1, M2, M3, M4…) i z procesorem Intel"
        ARCH_TEXT_EN="Macs with Apple silicon (M1, M2, M3, M4…) and Intel Macs" ;;
    *arm64*)
        ARCH="Apple Silicon"
        ARCH_TEXT="Maców z procesorem Apple (M1, M2, M3, M4…) - NIE działa na Macach z procesorem Intel"
        ARCH_TEXT_EN="Macs with Apple silicon (M1, M2, M3, M4…) - does NOT run on Intel Macs" ;;
    *)
        ARCH="Intel"
        ARCH_TEXT="Maców z procesorem Intel (na Macach z procesorem Apple działa przez Rosettę)"
        ARCH_TEXT_EN="Intel Macs (runs on Apple silicon through Rosetta)" ;;
esac

# Zamiana pól @…@ w instrukcjach (znaki | & \ w wartościach są zabezpieczane dla sed)
escape() { printf '%s' "$1" | sed -e 's/[|&\\]/\\&/g'; }
fill() {
    sed -e "s|@VERSION@|$(escape "${VERSION}")|g" \
        -e "s|@DATE@|$(escape "${DATE}")|g" \
        -e "s|@ARCH@|$(escape "${ARCH}")|g" \
        -e "s|@ARCH_TEXT@|$(escape "${ARCH_TEXT}")|g" \
        -e "s|@ARCH_TEXT_EN@|$(escape "${ARCH_TEXT_EN}")|g" \
        -e "s|@CONTACT@|$(escape "${CONTACT}")|g" "$1"
}

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
STAGE="${WORK}/FT-710 Control ${VERSION}"
mkdir -p "${STAGE}"

echo "==> Zawartość obrazu..."
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Aplikacje - Applications"
fill "Design/dmg/PRZECZYTAJ_MNIE.txt" > "${STAGE}/PRZECZYTAJ MNIE.txt"
fill "Design/dmg/READ_ME.txt" > "${STAGE}/READ ME.txt"
{
    cat THIRD_PARTY_NOTICES.md
    printf '\n\n---\n\nYaesu i FT-710 są znakami towarowymi Yaesu Musen Co., Ltd. FT-710 Control jest niezależnym programem.\n'
    printf 'Yaesu and FT-710 are trademarks of Yaesu Musen Co., Ltd. FT-710 Control is an independent program.\n'
} > "${STAGE}/Licencje.txt"

mkdir -p dist
OUT="dist/${APP_NAME}-${VERSION}.dmg"
rm -f "${OUT}"
echo "==> Tworzenie ${OUT}..."
hdiutil create -volname "FT-710 Control ${VERSION}" -srcfolder "${STAGE}" -fs HFS+ -format UDZO -ov "${OUT}" >/dev/null
hdiutil verify "${OUT}" >/dev/null

echo "OK: ${OUT}"
echo "    wersja ${VERSION}, ${ARCH}, $(du -h "${OUT}" | cut -f1)"
echo "    SHA-256 (do sprawdzenia przez testerów): $(shasum -a 256 "${OUT}" | cut -d' ' -f1)"
