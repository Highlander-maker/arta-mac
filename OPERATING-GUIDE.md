# smARTA — Operating Guide

> How to work the app: the measurement workflows in the order you actually run them, on Highlander's own rig (Scarlett 2i2, loop reference on out 2, ECM8000 on in 1). Written 2026-08-08. Formatted version: `smarta-operating-guide — 2026-08-08.html`.

---

## 00 — Patch and stage (once per session)

Signal flow:

- **out 1 → speaker**
- **speaker → air → mic → in 1**
- **out 2 → in 2** (loop reference — copper, no air)

The sweep drives out 1 and out 2 together. The loop arrives instantly down copper, the mic arrives at the speed of sound. That difference is the measurement — and the interface's own latency, being in both, cancels. **Transfer function = mic ÷ loop.**

1. **Sidebar → Devices.** Pick the 2i2 for input *and* output. Out channel 1, In channel 1.
2. **Tick "Loop reference (dual-channel)"**, loop channel 2. *This resets on every launch — check it every time.*
3. **Stage the loop with the Generator (⌘G).** It fans out to the loop output too, so the In 2 meter moves while you turn the 2i2 gain. Aim for around **−26 dBFS**. 0.0 means clipping.
4. **Stop the generator** before measuring — starting a sweep stops it anyway, but check the red `GEN` badge is gone.

> ⚠️ **The meters stop during a sweep.** By design — the measurement owns the input. Don't watch In 2 during a Measure wondering why it's dead. The status line reports *"Loop peak X dBFS"* when it finishes, and warns if the loop was silent.

---

## 01 — Measure a response (the core loop)

1. **Sweep → Preset.** Full range for tops; Subwoofer (15–250 Hz, 3 s) for subs; Sub/Top crossover (30–400 Hz) for the crossover region.
2. **Level.** −12 dBFS for full range. **Drop to −20 for any band-limited preset** — the same level concentrated into one band is far hotter and will clip the mic.
3. **Measure (⌘R).** Watch the three chips top-right: `DELAY`, `IN PK`, `CORR`.
4. **Impulse Response tab — set the gate.** Press *Cursor to peak*, then click for gate start, shift-click for gate end. Scroll to zoom, `0` to fit.
5. **Back to Frequency Response.** The curve recomputes from the gate. Smoothing 1/6 is a good default.

### Reading the chips

| Chip | Want | Meaning |
|---|---|---|
| `IN PK` | −12 to −6 dBFS | Mic peak. Warns below −60 (nothing there) or above −3 (clipping). |
| `DELAY` | — | Direct-sound arrival: speaker-to-mic flight time. Sanity-check against a tape measure at 343 m/s. |
| `CORR` | > −20 dB | How much of the capture the reference explains. **≈ −7 dB is normal** for acoustic loop-ref — the mic is spectrally coloured against a flat electrical reference. Not a fault. |

> ⚠️ **The gate sets your low-frequency limit.** A gate resolves down to roughly **1/gate**, and only trust about **3×** that. A 1.6 ms gate means nothing below ~600 Hz is real — what you see down there is the window, not the speaker. Long gate for LF detail, tight gate to exclude the room; you cannot have both.

---

## 02 — Align two sources (main → delay ring)

**Freeze is the alignment tool.** There is only one reference slot, so the main stays frozen throughout.

1. **Measure the reference source** — usually the main.
2. **Impulse Response tab → Freeze.** Snapshots its arrival time.
3. **Re-patch to the second source and measure again.**
4. **Read Δ** next to the Freeze button — arrival difference in **ms and metres**.
5. **Dial into the processor, re-measure.** Δ should collapse to near zero (0.06 ms on 21 Jul).

> ⚠️ **"Set as overlay" does not give you a Δ.** It keeps a frequency-response curve for visual comparison — a different job. With no frozen reference the Δ readout is simply absent, with no warning. If Δ isn't showing, you forgot to Freeze.

**Haas offset is a separate decision.** On 21 Jul, 11.8 ms total gave only 1.24 ms of offset and sounded hollow (comb nulls 403 Hz / 1.2 k / 2 k). Around 22 ms total pushed nulls to every ~87 Hz and sounded markedly fuller.

---

## 03 — Compare two responses

1. **Measure the first source**, then **Set as overlay** on the Frequency Response tab. It carries its phase with it, in its own colour.
2. **Measure the second.** The live curve draws on top of the frozen overlay.
3. **Clear overlays** when done. **Load target...** pulls in an `.frd` as a dashed reference to tune against.

---

## 04 — Sub to tops (align on phase)

> ⚠️ **Do not align subs on arrival time.** A 30–400 Hz sweep gives an inherently smeared IR and the peak wanders — it read 37.79 ms (12.96 m) in the warehouse, which was nonsense. Subs get aligned on **phase at the crossover**.

1. **Polarity first.** Get that wrong and everything after is chasing a ghost.
2. **Rough in with Freeze/Δ** to get inside a few ms — good enough to start, not to finish.
3. **Measure tops → Set as overlay → measure subs.**
4. **Tick Phase, tick Unwrap**, push **FFT to 16384+** for resolution down low.
5. **Right-drag the plot to the crossover band** (e.g. 30–200 Hz). Phase unwraps across only what's visible, so zooming in is what makes the traces readable. **Esc** returns to full range.
6. **Adjust delay until the two phase traces lie on top of each other** through the crossover. That's the alignment.

---

## 05 — Tone burst (damping, and sub arrival)

Answers a different question from a sweep: *how well damped is this driver?* **Ring-out** is the envelope level one burst-length after the burst stops, relative to peak — more negative = better damped. The test sub read −20 / −19 / −19 dB at 50 / 63 / 80 Hz.

1. **Set frequency and cycles** (2–20), envelope raised-cosine or Gaussian.
2. **Check level.** Fires a repeating burst *train*, not a steady tone — a continuous tone over-reads at LF because room modes pump it up. Drive mic peak to **−12…−6 dBFS**.
3. **Burst (⌘B).** Amber = measured envelope, cyan dashed = ideal.
4. **Freeze / Δ works here too** — fire through main, freeze, fire through sub, read Δ. This is the reliable arrival number at crossover frequencies where the sweep's IR peak wanders.

> ⚠️ **Ring-out that changes with drive level means you're measuring the noise floor, not the sub.** Get the mic peak up first, then trust the number. Watch the `zero` readout: "loop ref" is the accurate one, "schedule" means no loop was available. Δ is withheld entirely if the frozen reference and the live burst used different zeros.

---

## 06 — RTA (live spectrum)

Live input spectrum, no sweep — for programme material, noise floors, or a quick look at the room. **Average: Fast = 125 ms, Slow = 1 s** (same time constants as an SPL meter) — this is the setting that makes it look smooth rather than frantic. Peak hold with Reset alongside.

---

## 07 — Reference

### Keyboard

| Key | Does |
|---|---|
| ⌘R | Measure (sweep) |
| ⌘B | Fire tone burst |
| ⌘G | Generator on / off |
| Esc | Frequency Response: back to full range |
| = / − | Impulse Response: zoom in / out |
| 0 | Impulse Response: fit whole IR |

### Mouse

- **FR plot** — right-drag to zoom to a band, Esc resets. Hover for frequency / dB / phase readout.
- **IR plot** — scroll to zoom, shift-scroll for amplitude, click for gate start, shift-click for gate end.

### Files

| Format | Holds | Reopens as |
|---|---|---|
| `.pir` | The impulse response. Opens in real ARTA too. | A full measurement — Load .pir restores FR, gate, room parameters |
| `.frd` | Frequency + magnitude + phase, plain ASCII | An overlay, via *Load target...* |
| `.tbr` | A tone burst result | The burst, via *Load burst...* |

**Save the `.pir` if you want to pick the work back up.** The `.frd` is a portable reference curve, not a resumable session.

### Known traps

- **Settings don't persist across launches.** The loop-reference toggle resets every time.
- **`.frd` export writes the *smoothed* curve**, and the header records no gate, smoothing, FFT size or sample rate. An exported file can't be interpreted later without remembering the settings.
- **A clipped capture still reports a confident delay figure** rather than refusing. Check `IN PK` before trusting `DELAY`.
- **No mic calibration support yet.** With the ECM8000, trust ~200 Hz – 8 kHz ±3 dB. Judge shape, not absolute level.
- **Only one Freeze slot** — can't hold a main plus several delay rings at once.
- **The Desktop copy is a straight copy.** After any rebuild it's stale until re-copied.

---

**Rig:** Scarlett 2i2 · out 1 → speaker · out 2 → in 2 loop · ECM8000 → in 1 · Air/Auto-Gain/Clip-Safe off, line, 48 V
**Tabs:** Frequency Response · RTA · Impulse Response · Analysis · Tone Burst · Room Acoustics
**Rules of thumb:** trust the curve above 3 ÷ gate · 343 m/s · sanity-check delay against a tape measure

See also `README.md` for build instructions and `VALIDATION.md` for the evidence the measurement chain is accurate.
