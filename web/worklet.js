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
