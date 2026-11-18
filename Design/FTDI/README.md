# Licencja FTDI (wymagana przy bibliotekach w aplikacji)

FTDI zgodziło się (e-mail: Kieran Anthony Ward, FTDI, 18.11.2026) na dołączenie bibliotek D2XX
i LibFT4222 do FT-710 Control pod warunkiem dołączenia warunków licencji razem ze sterownikiem.

**Plik `FTDI-Driver-Licence.txt` w tym folderze musi zawierać PEŁNY tekst licencji** ze strony
https://ftdichip.com/driver-licence-terms-details/ (skopiuj całą treść strony do pliku, bez zmian).

- `build_app.sh` bez tego pliku NIE dołącza bibliotek FTDI do aplikacji (ochrona przed wydaniem
  bez wymaganej licencji),
- plik trafia do aplikacji (`Contents/Frameworks/FTDI-Driver-Licence.txt`, obok bibliotek)
  i do obrazu .dmg (`Licencja FTDI - FTDI Licence.txt`).

Aktualizacje: FTDI zaleca najnowsze wersje bibliotek ze swojej strony. Przed wydaniem warto sprawdzić
https://ftdichip.com/drivers/d2xx-drivers/ i stronę LibFT4222 (FT4222H) i w razie nowszej wersji
zainstalować ją w /usr/local/lib - build_app.sh dołącza zawsze tę, którą znajdzie.
