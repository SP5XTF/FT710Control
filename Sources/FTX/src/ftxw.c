// FTXW - warstwa nad ft8_lib dla FT-710 Control (opis w include/ftxw.h).
#include "ftxw.h"

#include <ft8/decode.h>
#include <ft8/encode.h>
#include <ft8/message.h>
#include <ft8/constants.h>
#include <common/monitor.h>

#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>
#include <stdio.h>

// Parametry dobrane na nagraniach testowych ft8_lib (porównanie z WSJT-X); można nadpisać przez -D.
#ifndef FTXW_MIN_SCORE
#define FTXW_MIN_SCORE 10          // minimalna siła synchronizacji kandydata
#endif
#ifndef FTXW_LDPC_ITERATIONS
#define FTXW_LDPC_ITERATIONS 30
#endif
#ifndef FTXW_SUB_SPREAD
#define FTXW_SUB_SPREAD 1          // ile podziałów częstotliwości obok tonu wygaszać przy odejmowaniu
#endif
#ifndef FTXW_NOISE_HZ
#define FTXW_NOISE_HZ 250.0f       // połowa szerokości okna, w którym mierzony jest szum wokół sygnału
#endif
#ifndef FTXW_NOISE_PCT
#define FTXW_NOISE_PCT 0.25        // percentyl komórek przyjmowany jako szum
#endif
#ifndef FTXW_TIME_OSR
#define FTXW_TIME_OSR 2            // podziały symbolu w czasie
#endif
#ifndef FTXW_FREQ_OSR
#define FTXW_FREQ_OSR 2            // podziały odstępu tonów w częstotliwości
#endif
#ifndef FTXW_SNR_SCALE
#define FTXW_SNR_SCALE 1.0f
#endif
#ifndef FTXW_SNR_OFFSET
#define FTXW_SNR_OFFSET 0.8f       // zmierzone przesunięcie na sygnale syntetycznym
#endif

// ---------------------------------------------------------------- tablica skrótów znaków (<...>)

#define HASH_SIZE 1024
#define HASH_MAX_AGE 40   // cykli bez odświeżenia (FT8: 10 minut)

static struct {
    char callsign[12];
    uint32_t hash;   // 8 bitów wieku + 22 bity skrótu
} hashes[HASH_SIZE];

static void hash_save(const char *callsign, uint32_t n22)
{
    uint16_t h10 = (n22 >> 12) & 0x3FFu;
    int idx = (h10 * 23) % HASH_SIZE;
    for (int probe = 0; probe < HASH_SIZE && hashes[idx].callsign[0]; ++probe) {
        if ((hashes[idx].hash & 0x3FFFFFu) == n22 && strcmp(hashes[idx].callsign, callsign) == 0) {
            hashes[idx].hash &= 0x3FFFFFu;                 // odśwież wiek
            return;
        }
        idx = (idx + 1) % HASH_SIZE;
    }
    if (hashes[idx].callsign[0]) return;                   // tablica pełna
    strncpy(hashes[idx].callsign, callsign, 11);
    hashes[idx].callsign[11] = 0;
    hashes[idx].hash = n22;
}

static bool hash_lookup(ftx_callsign_hash_type_t type, uint32_t hash, char *callsign)
{
    uint8_t shift = (type == FTX_CALLSIGN_HASH_10_BITS) ? 12 : (type == FTX_CALLSIGN_HASH_12_BITS ? 10 : 0);
    uint16_t h10 = (hash >> (12 - shift)) & 0x3FFu;
    int idx = (h10 * 23) % HASH_SIZE;
    for (int probe = 0; probe < HASH_SIZE && hashes[idx].callsign[0]; ++probe) {
        if (((hashes[idx].hash & 0x3FFFFFu) >> shift) == hash) {
            strcpy(callsign, hashes[idx].callsign);
            return true;
        }
        idx = (idx + 1) % HASH_SIZE;
    }
    callsign[0] = 0;
    return false;
}

static ftx_callsign_hash_interface_t hash_if = { .lookup_hash = hash_lookup, .save_hash = hash_save };

void ftxw_age_hashes(void)
{
    // Usuwanie z otwartym adresowaniem psułoby łańcuchy - przebudowujemy tablicę z żywych wpisów.
    static struct { char callsign[12]; uint32_t hash; } keep[HASH_SIZE];
    int n = 0;
    for (int i = 0; i < HASH_SIZE; ++i) {
        if (!hashes[i].callsign[0]) continue;
        uint8_t age = (uint8_t)(hashes[i].hash >> 24);
        if (age >= HASH_MAX_AGE) continue;
        memcpy(keep[n].callsign, hashes[i].callsign, 12);
        keep[n].hash = ((uint32_t)(age + 1) << 24) | (hashes[i].hash & 0x3FFFFFu);
        ++n;
    }
    memset(hashes, 0, sizeof(hashes));
    for (int i = 0; i < n; ++i) {
        uint32_t n22 = keep[i].hash & 0x3FFFFFu;
        hash_save(keep[i].callsign, n22);
        // przywróć wiek
        uint16_t h10 = (n22 >> 12) & 0x3FFu;
        int idx = (h10 * 23) % HASH_SIZE;
        while (strcmp(hashes[idx].callsign, keep[i].callsign) != 0) idx = (idx + 1) % HASH_SIZE;
        hashes[idx].hash = keep[i].hash;
    }
}

void ftxw_remember_call(const char *callsign)
{
    if (!callsign || !callsign[0]) return;
    char text[48];
    ftx_message_t msg;
    // Zakodowanie „CQ <znak>” zapisuje znak w tablicy skrótów przez hash_if.save_hash.
    snprintf(text, sizeof(text), "CQ %s", callsign);
    ftx_message_encode(&msg, &hash_if, text);
}

// ---------------------------------------------------------------- dekodowanie

static inline WF_ELEM_T *cell(const ftx_waterfall_t *wf, int block, int tsub, int fsub, int bin)
{
    return wf->mag + (((block * wf->time_osr + tsub) * wf->freq_osr + fsub) * wf->num_bins + bin);
}

/// Mediana jasności spektrogramu (w jednostkach 0,5 dB) - poziom szumu dla SNR i odejmowania.
static int noise_level(const ftx_waterfall_t *wf)
{
    static int hist[256];
    memset(hist, 0, sizeof(hist));
    long total = (long)wf->num_blocks * wf->block_stride;
    for (long i = 0; i < total; ++i) hist[wf->mag[i]]++;
    long acc = 0;
    for (int v = 0; v < 256; ++v) {
        acc += hist[v];
        if (acc * 2 >= total) return v;
    }
    return 128;
}

/// Pozycje (blok, ton) wszystkich symboli kanałowych zdekodowanej wiadomości.
static int channel_tones(const ftx_message_t *msg, int protocol, uint8_t *tones)
{
    if (protocol == FTXW_PROTOCOL_FT4) { ft4_encode(msg->payload, tones); return FT4_NN; }
    ft8_encode(msg->payload, tones);
    return FT8_NN;
}

/// SNR w paśmie 2500 Hz: średnia moc na nadawanych tonach wobec szumu.
/// Szum = dolny percentyl wszystkich komórek spektrogramu w oknie ±FTXW_NOISE_HZ wokół sygnału przez cały cykl.
/// Sam sygnał zajmuje mały ułamek okna, a sąsiednie stacje podnoszą górne percentyle, nie dolne.
/// Moc szumu w binie FFT ma rozkład wykładniczy: percentyl p = -ln(1-p) × średnia.
static float estimate_snr(const ftx_waterfall_t *wf, const ftx_candidate_t *c, const uint8_t *tones, int nn, int protocol,
                          float bin_hz)
{
    int num_tones = (protocol == FTXW_PROTOCOL_FT4) ? 4 : 8;
    int half = (int)(FTXW_NOISE_HZ / bin_hz);
    int lo = c->freq_offset + num_tones / 2 - half, hi = c->freq_offset + num_tones / 2 + half;
    if (lo < 0) lo = 0;
    if (hi > wf->num_bins) hi = wf->num_bins;
    int hist[256] = { 0 };
    long total = 0;
    for (int b = 0; b < wf->num_blocks; ++b)
        for (int bin = lo; bin < hi; ++bin) { hist[*cell(wf, b, c->time_sub, c->freq_sub, bin)]++; ++total; }
    if (total == 0) return -30;
    long acc = 0;
    int pv = 0;
    for (; pv < 256; ++pv) { acc += hist[pv]; if (acc >= total * FTXW_NOISE_PCT) break; }
    double noise = pow(10.0, WF_ELEM_MAG(pv) / 10.0) / -log(1.0 - FTXW_NOISE_PCT);
    double sig = 0;
    int count = 0;
    for (int k = 0; k < nn; ++k) {
        if (protocol == FTXW_PROTOCOL_FT4 && (k == 0 || k == nn - 1)) continue;   // rampy FT4
        int block = c->time_offset + k;
        if (block < 0 || block >= wf->num_blocks) continue;
        sig += pow(10.0, WF_ELEM_MAG(*cell(wf, block, c->time_sub, c->freq_sub, c->freq_offset + tones[k])) / 10.0);
        ++count;
    }
    if (count == 0 || noise <= 0) return -30;
    double ratio = sig / count / noise - 1.0;               // moc sygnału ponad szum w jednym binie
    if (ratio < 1e-3) ratio = 1e-3;
    // Bin = odstęp tonów (6,25 Hz FT8, 20,8 Hz FT4); WSJT-X podaje SNR w 2500 Hz.
    float tone_spacing = (protocol == FTXW_PROTOCOL_FT4) ? 1.0f / FT4_SYMBOL_PERIOD : 1.0f / FT8_SYMBOL_PERIOD;
    float raw = (float)(10.0 * log10(ratio)) - 10.0f * log10f(2500.0f / tone_spacing);
    // Skala fizyczna: na syntetycznym sygnale w białym szumie zmierzony SNR zgadza się z prawdziwym (±1 dB),
    // tak jak w WSJT-X. Nagrania testowe z WebSDR (z ARW) dawały wartości niższe o ok. 8 dB - nie kalibrujemy do nich.
    float snr = FTXW_SNR_SCALE * raw + FTXW_SNR_OFFSET;
    if (snr < -28) snr = -28;
    if (snr > 49) snr = 49;
    return snr;
}

/// Wygasza w spektrogramie tony zdekodowanej wiadomości (z sąsiednimi podziałami czasu i częstotliwości),
/// aby kolejny przebieg mógł znaleźć słabsze sygnały pod spodem.
static void subtract(ftx_waterfall_t *wf, const ftx_candidate_t *c, const uint8_t *tones, int nn, int noise)
{
    int tosr = wf->time_osr, fosr = wf->freq_osr;
    for (int k = 0; k < nn; ++k) {
        int tpos0 = (c->time_offset + k) * tosr + c->time_sub;           // pozycja w podziałach czasu
        int fpos0 = (c->freq_offset + tones[k]) * fosr + c->freq_sub;    // pozycja w podziałach częstotliwości
        for (int dt = 0; dt < tosr; ++dt) {
            int tpos = tpos0 + dt;
            int block = tpos / tosr, tsub = tpos % tosr;
            if (block < 0 || block >= wf->num_blocks) continue;
            for (int df = -FTXW_SUB_SPREAD; df <= FTXW_SUB_SPREAD; ++df) {
                int fpos = fpos0 + df;
                if (fpos < 0) continue;
                int bin = fpos / fosr, fsub = fpos % fosr;
                if (bin >= wf->num_bins) continue;
                WF_ELEM_T *p = cell(wf, block, tsub, fsub, bin);
                if (*p > noise) *p = (WF_ELEM_T)noise;
            }
        }
    }
}

int ftxw_decode(const float *samples, int num_samples, int protocol,
                int f_min, int f_max, int depth, ftxw_result_t *out, int max_out)
{
    if (!samples || !out || max_out <= 0) return 0;
    ftx_protocol_t proto = (protocol == FTXW_PROTOCOL_FT4) ? FTX_PROTOCOL_FT4 : FTX_PROTOCOL_FT8;
    monitor_config_t cfg = {
        .f_min = (float)f_min, .f_max = (float)f_max, .sample_rate = FTXW_SAMPLE_RATE,
        .time_osr = FTXW_TIME_OSR, .freq_osr = FTXW_FREQ_OSR, .protocol = proto
    };
    monitor_t mon;
    monitor_init(&mon, &cfg);
    for (int pos = 0; pos + mon.block_size <= num_samples; pos += mon.block_size)
        monitor_process(&mon, samples + pos);

    ftx_waterfall_t *wf = &mon.wf;
    int noise = noise_level(wf);
#ifdef FTXW_DEBUG
    {
        int zeros = 0; long total = (long)wf->num_blocks * wf->block_stride;
        for (long i = 0; i < total; ++i) zeros += wf->mag[i] == 0;
        fprintf(stderr, "noise %.1f dB, max %.1f dB, zeros %.1f%%\n", WF_ELEM_MAG(noise), mon.max_mag, 100.0 * zeros / total);
    }
#endif
    if (depth < 1) depth = 1;
    if (depth > 4) depth = 4;

    enum { MAX_CAND = 300, MAX_SEEN = 256 };
    static ftx_candidate_t cands[MAX_CAND];
    static uint8_t seen[MAX_SEEN][FTX_PAYLOAD_LENGTH_BYTES];
    int num_seen = 0, num_out = 0;
    uint8_t tones[FTXW_MAX_TONES];
    // Nadawanie zaczyna się 0,5 s po początku cyklu - DT liczone względem tego, jak w WSJT-X.
    // Okno analizy spektrogramu opóźnia pozycję o jeden symbol (zmierzone: +0,16 s dla FT8, rozrzut 0,04 s).
    const float nominal_start = 0.5f + mon.symbol_period;

    for (int pass = 1; pass <= depth; ++pass) {
        int new_in_pass = 0;
        int n = ftx_find_candidates(wf, MAX_CAND, cands, FTXW_MIN_SCORE);
        // Kandydaci do odjęcia po przebiegu (odejmowanie w trakcie psułoby kolejnych kandydatów z tej listy)
        static ftx_candidate_t done_c[MAX_SEEN];
        static ftx_message_t done_m[MAX_SEEN];
        int num_done = 0;

        for (int i = 0; i < n; ++i) {
            ftx_message_t msg;
            ftx_decode_status_t st;
            if (!ftx_decode_candidate(wf, &cands[i], FTXW_LDPC_ITERATIONS, &msg, &st)) continue;

            bool dup = false;
            for (int s = 0; s < num_seen; ++s)
                if (memcmp(seen[s], msg.payload, FTX_PAYLOAD_LENGTH_BYTES) == 0) { dup = true; break; }
            if (dup) continue;
            if (num_seen < MAX_SEEN) memcpy(seen[num_seen++], msg.payload, FTX_PAYLOAD_LENGTH_BYTES);

            char text[FTX_MAX_MESSAGE_LENGTH];
            ftx_message_offsets_t offsets;
            if (ftx_message_decode(&msg, &hash_if, text, &offsets) != FTX_MESSAGE_RC_OK) continue;

            int nn = channel_tones(&msg, protocol, tones);
            if (num_out < max_out) {
                ftxw_result_t *r = &out[num_out++];
                strncpy(r->text, text, sizeof(r->text) - 1);
                r->text[sizeof(r->text) - 1] = 0;
                r->freq = (mon.min_bin + cands[i].freq_offset + (float)cands[i].freq_sub / wf->freq_osr) / mon.symbol_period;
                r->dt = (cands[i].time_offset + (float)cands[i].time_sub / wf->time_osr) * mon.symbol_period - nominal_start;
                r->snr = estimate_snr(wf, &cands[i], tones, nn, protocol, 1.0f / mon.symbol_period);
                r->score = cands[i].score;
                r->pass = pass;
            }
            if (num_done < MAX_SEEN) { done_c[num_done] = cands[i]; done_m[num_done] = msg; ++num_done; }
            ++new_in_pass;
        }
        if (new_in_pass == 0 || pass == depth) break;
        for (int d = 0; d < num_done; ++d) {
            int nn = channel_tones(&done_m[d], protocol, tones);
            subtract(wf, &done_c[d], tones, nn, noise);
        }
    }
    monitor_free(&mon);
    return num_out;
}

// ---------------------------------------------------------------- nadawanie

int ftxw_encode(const char *text, int protocol, uint8_t *tones)
{
    ftx_message_t msg;
    ftx_message_rc_t rc = ftx_message_encode(&msg, &hash_if, text);
    if (rc != FTX_MESSAGE_RC_OK) return -(int)rc;
    return channel_tones(&msg, protocol, tones);
}

/// Porównanie tekstu z odczytem po zakodowaniu: bez nawiasów <> (znaki ze skrótu) i bez wielokrotnych spacji.
static bool same_message(const char *a, const char *b)
{
    for (;;) {
        while (*a == '<' || *a == '>' || (*a == ' ' && (a[1] == ' ' || a[1] == 0))) ++a;
        while (*b == '<' || *b == '>' || (*b == ' ' && (b[1] == ' ' || b[1] == 0))) ++b;
        if (*a == 0 || *b == 0) return *a == *b;
        if (*a != *b) return false;
        ++a; ++b;
    }
}

static void unpack_echo(const ftx_message_t *msg, char *echo, int echo_size)
{
    if (!echo || echo_size <= 0) return;
    echo[0] = 0;
    char decoded[FTX_MAX_MESSAGE_LENGTH];
    ftx_message_offsets_t offsets;
    if (ftx_message_decode(msg, &hash_if, decoded, &offsets) == FTX_MESSAGE_RC_OK) {
        strncpy(echo, decoded, (size_t)echo_size - 1);
        echo[echo_size - 1] = 0;
    }
}

int ftxw_encode_echo(const char *text, int protocol, uint8_t *tones, char *echo, int echo_size)
{
    char own[FTX_MAX_MESSAGE_LENGTH];
    if (echo == NULL || echo_size <= 0) { echo = own; echo_size = (int)sizeof(own); }
    echo[0] = 0;
    ftx_message_t msg;
    ftx_message_rc_t rc = ftx_message_encode(&msg, &hash_if, text);
    if (rc == FTX_MESSAGE_RC_OK) unpack_echo(&msg, echo, echo_size);
    // Tekst, który nie jest standardowym komunikatem (np. „HELLO WORLD 123” wzięte za znaki) - jak w WSJT-X
    // wysyłamy go jako tekst dowolny, o ile mieści się w 13 znakach.
    if ((rc != FTX_MESSAGE_RC_OK || !same_message(text, echo)) && strlen(text) <= 13) {
        ftx_message_t free_msg;
        if (ftx_message_encode_free(&free_msg, text) == FTX_MESSAGE_RC_OK) {
            msg = free_msg;
            rc = FTX_MESSAGE_RC_OK;
            unpack_echo(&msg, echo, echo_size);
        }
    }
    if (rc != FTX_MESSAGE_RC_OK) return -(int)rc;
    return channel_tones(&msg, protocol, tones);
}

static float symbol_period(int protocol) { return protocol == FTXW_PROTOCOL_FT4 ? FT4_SYMBOL_PERIOD : FT8_SYMBOL_PERIOD; }

int ftxw_synth_length(int num_tones, int protocol, int sample_rate)
{
    int n_spsym = (int)(0.5f + sample_rate * symbol_period(protocol));
    return num_tones * n_spsym;
}

#define FTXW_PI 3.14159265358979323846
#define GFSK_CONST_K 5.336446f   // pi * sqrt(2 / ln 2)

void ftxw_synth(const uint8_t *tones, int n_sym, int protocol, float f0, int sample_rate, float *signal)
{
    float bt = (protocol == FTXW_PROTOCOL_FT4) ? 1.0f : 2.0f;
    int n_spsym = (int)(0.5f + sample_rate * symbol_period(protocol));
    int n_wave = n_sym * n_spsym;
    float dphi_peak = 2.0f * (float)FTXW_PI / n_spsym;      // hmod = 1
    float *dphi = (float *)malloc(sizeof(float) * (n_wave + 2 * n_spsym));
    float *pulse = (float *)malloc(sizeof(float) * 3 * n_spsym);
    if (!dphi || !pulse) { free(dphi); free(pulse); memset(signal, 0, sizeof(float) * n_wave); return; }

    for (int i = 0; i < 3 * n_spsym; ++i) {
        float t = i / (float)n_spsym - 1.5f;
        pulse[i] = (erff(GFSK_CONST_K * bt * (t + 0.5f)) - erff(GFSK_CONST_K * bt * (t - 0.5f))) / 2;
    }
    for (int i = 0; i < n_wave + 2 * n_spsym; ++i) dphi[i] = 2.0f * (float)FTXW_PI * f0 / sample_rate;
    for (int i = 0; i < n_sym; ++i)
        for (int j = 0; j < 3 * n_spsym; ++j) dphi[j + i * n_spsym] += dphi_peak * tones[i] * pulse[j];
    for (int j = 0; j < 2 * n_spsym; ++j) {
        dphi[j] += dphi_peak * pulse[j + n_spsym] * tones[0];
        dphi[j + n_sym * n_spsym] += dphi_peak * pulse[j] * tones[n_sym - 1];
    }
    double phi = 0;
    for (int k = 0; k < n_wave; ++k) {
        signal[k] = (float)sin(phi);
        phi = fmod(phi + dphi[k + n_spsym], 2.0 * FTXW_PI);
    }
    int n_ramp = n_spsym / 8;
    for (int i = 0; i < n_ramp; ++i) {
        float env = (1 - cosf((float)FTXW_PI * i / n_ramp)) / 2;
        signal[i] *= env;
        signal[n_wave - 1 - i] *= env;
    }
    free(dphi);
    free(pulse);
}
