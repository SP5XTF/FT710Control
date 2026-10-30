// FTXW - cienka warstwa nad ft8_lib (MIT, Kārlis Goba YL3JG) dla modułu FT8/FT4 w FT-710 Control.
// Dodaje: dekodowanie wieloprzebiegowe z odejmowaniem zdekodowanych sygnałów, SNR w paśmie 2500 Hz
// jak w WSJT-X, trwałą tablicę skrótów znaków (<...>), kodowanie tekstu i syntezę GFSK do nadawania.
// Wywołania nie są wielowątkowe - Swift używa jednej kolejki.
#ifndef FTXW_H
#define FTXW_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FTXW_PROTOCOL_FT8 0
#define FTXW_PROTOCOL_FT4 1
#define FTXW_SAMPLE_RATE 12000
#define FTXW_MAX_TONES 105

typedef struct {
    char text[64];      // wiadomość, np. "CQ SP5XTF KO02" (komunikat DXpedycji - do 51 znaków)
    float snr;          // dB w paśmie 2500 Hz (skala WSJT-X)
    float dt;           // s względem nominalnego początku nadawania
    float freq;         // Hz, częstotliwość tonu 0
    int score;          // siła synchronizacji (Costas)
    int pass;           // przebieg, w którym zdekodowano (1 = bez odejmowania)
} ftxw_result_t;

/// Dekoduje jeden cykl. samples: mono, 12 kHz, od początku cyklu (UTC). depth: liczba przebiegów 1..4.
/// Zwraca liczbę wyników zapisanych w out.
int ftxw_decode(const float *samples, int num_samples, int protocol,
                int f_min, int f_max, int depth, ftxw_result_t *out, int max_out);

/// Koduje tekst na tony (79 dla FT8, 105 dla FT4). Zwraca liczbę tonów albo kod błędu < 0.
int ftxw_encode(const char *text, int protocol, uint8_t *tones);

/// Jak ftxw_encode, a dodatkowo zapisuje w echo tekst odczytany z zakodowanej wiadomości - dokładnie to,
/// co zobaczy odbiorca (np. raport spoza zakresu zamienia się w inny komunikat, znak złożony w <...>).
int ftxw_encode_echo(const char *text, int protocol, uint8_t *tones, char *echo, int echo_size);

/// Liczba próbek sygnału dla danej liczby tonów przy podanej częstotliwości próbkowania.
int ftxw_synth_length(int num_tones, int protocol, int sample_rate);

/// Synteza GFSK (BT 2,0 dla FT8, 1,0 dla FT4) z łagodnym początkiem i końcem. out: ftxw_synth_length próbek.
void ftxw_synth(const uint8_t *tones, int num_tones, int protocol, float f0, int sample_rate, float *out);

/// Własny znak (i znaki korespondentów) do tablicy skrótów, aby <...> rozwijały się w pełny znak.
void ftxw_remember_call(const char *callsign);

/// Postarzanie tablicy skrótów - wywoływać raz na cykl.
void ftxw_age_hashes(void);

#ifdef __cplusplus
}
#endif

#endif
