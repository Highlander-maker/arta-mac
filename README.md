# arta-mac

A native macOS acoustic measurement application in the spirit of **ARTA**
(the Windows impulse-response / real-time analyzer standard), built on
Core Audio + Accelerate. Swept-sine impulse response measurement, gated
frequency response with fractional-octave smoothing, overlays and target
curves, ISO 3382 room acoustics, STI — with file-level interoperability with
real ARTA (`.pir`, `.frd`).

## Layout

| Target | What it is |
|---|---|
| `ArtaDSP` | Pure measurement mathematics. FFT, Farina log-sweep generation + deconvolution, GCC delay estimation, averaged H1 estimator with coherence, gate windows, 1/n-octave smoothing, ETC/step response/CSD, minimum phase, 6-pole Butterworth band filters, IEC 61672 A/C weighting, Schroeder decay + ISO 3382 parameters (wideband and per octave band), STI per IEC 60268-16 (male), `.pir`/`.frd` file I/O. No audio, no UI. Fully unit-tested (`swift test`). |
| `ArtaApp` | The application: SwiftUI shell, device selection, full-duplex sweep measurement via `AVAudioEngine`, band-focused sweep presets (sub / crossover / mid-high), continuous alignment-tone generator (sine, pink, band-limited pink), log-frequency FR plot with phase trace, cursor/overlays/targets, IR view with click-to-gate, ETC/step/CSD analysis, room acoustics table, STI. |
| `arta-mac-spike` | Phase 0 de-risking CLI (kept as a diagnostic tool): device listing, sweep generator, DSP selftest, round-trip latency measurement. |

## Build & run

```sh
swift build            # everything
swift test             # DSP test suite
./scripts/make-app.sh  # release build -> build/Arta.app
open build/Arta.app
```

First launch will ask for microphone access — that's the measurement input.

## Measuring

1. Pick output/input devices and channels in the sidebar. **Supported device
   configs:** the system default devices, or one full-duplex interface selected
   for both sides (one clock — the reference configuration). Split explicit
   input/output devices are refused: macOS `AVAudioEngine` runs both directions
   through a single AUHAL, so they physically can't be honoured.
2. Pick a sweep preset — Full range, Subwoofer (15–250 Hz, 3 s), Sub/Top
   crossover (30–400 Hz), Mid–High (800 Hz+) — or set a custom range. Longer
   band-limited sweeps concentrate energy where you're working (better LF S/N
   for sub work). For rooms use a decay wait longer than the reverb tail.
3. **Measure** (⌘R). You get the impulse response, estimated system delay,
   gated frequency response, and room parameters.
4. In the Impulse tab: click = gate start, shift-click = gate end. The FR tab
   recomputes from the gate. Smoothing 1/1–1/24 octave.
5. Overlay workflow: *Set as overlay* to keep a curve, *Load target...* to load
   an `.frd` target (drawn dashed red) — tune the system until the live curve
   sits on the target.
6. Save the IR as `.pir` (opens in real ARTA), export the FR as `.frd`.
7. **Phase**: tick the Phase checkbox on the FR tab. The gate-start → direct
   sound pre-delay is removed automatically, leaving the system's own phase —
   the number you're matching when aligning sub to tops at the crossover.

### Delay between two sources (the Δ readout)

Measuring how far apart two sources arrive — main vs delay ring, top vs sub —
is a **Freeze**, not an overlay:

1. Measure the first source (the reference — usually the main).
2. **Freeze** on the Impulse tab. That snapshots its arrival time.
3. Re-patch / move to the second source and measure again.
4. Read **Δ** on the Impulse tab: the arrival difference in **ms and metres**.
   Dial that into the processor, re-measure, and Δ should collapse to ~0.

*Set as overlay* is a different tool — it keeps a **frequency response curve**
for visual comparison and carries its phase, but it does **not** produce a Δ.
Only Freeze does. With no frozen reference the Δ readout is simply absent.

The Tone Burst tab (⌘B) has the same Freeze → Δ workflow for sub alignment,
where a band-limited sweep's IR peak is too smeared to trust.

### Trial delay and summation (aligning a crossover)

A delay rotates phase linearly with frequency and leaves magnitude alone, so the
sum of two measured sources at any delay is arithmetic on data you already have:
`H_sum = H_A + H_B · e^(−j2πfτ)`. The **Trial delay** row on the FR tab does that
live:

1. Measure the first source, **Set as overlay**.
2. Measure the second. Tick **Phase** and **Unwrap**, right-drag to the crossover band.
3. Slide **Trial delay** — the live curve's phase trace rotates against the
   overlay's. Line them up through the crossover. ± nudges by 0.05 ms.
4. Tick **Combine** to draw the predicted sum. Phase-match says the sources agree;
   the sum says what you'll actually hear, including how deep any notch is left.
5. Dial the delay you landed on into the processor and re-measure to confirm.

Both curves must carry a complex spectrum, so a `.frd` target loaded from disk
can't take part. Overlays measured at a different FFT size or sample rate are
refused rather than resampled — the app says why instead of drawing nothing.

**It predicts the sum at that one mic position**, from data no better than the
capture it came from. That's a limit of the physics, not of the method — the same
limit applies to measuring it for real. What changes is that an iteration costs a
second instead of a trip to the processor.

### Zooming the frequency axis

**Right-drag** across the FR plot to zoom to that band; **Esc** (or the range
button in the toolbar) goes back to full range. Phase is unwrapped across the
*visible* span only, so zooming to a crossover — say 30–200 Hz — is what makes
two sources' phase traces readable enough to align on.

## Alignment tones (Generator)

Continuous signals for sub/top delay and polarity work, on the selected
output channel: steady sine (quick-pick chips at 40/63/80/100/125 Hz and
1/4/10 kHz), full-range pink noise, and 1/1- or 1/3-octave band-limited pink
noise for crossover-region checks. Loop-rendered (whole cycles / crossfaded
seam) so there are no clicks. ⌘G toggles it; starting a measurement stops the
generator automatically.

## Diagnostic CLI (Phase 0 spike)

```sh
.build/debug/arta-mac-spike devices    # Core Audio device IDs
.build/debug/arta-mac-spike selftest   # hardware-free DSP check
.build/debug/arta-mac-spike measure --input-device <ID> --output-device <ID>
```

`measure` wants a physical loopback (interface out 1 → in 1, monitors down)
and reports round-trip latency in samples/ms plus the driver-claimed latency
sum for comparison.

**Microphone permission caveat**: macOS gates audio input for CLI tools by
the launching terminal. If capture reads -200 dBFS with the loopback
definitely connected, check System Settings → Privacy & Security →
Microphone. Shells spawned by automation agents can report "authorized" but
still receive silence — run from a real terminal, or use `build/Arta.app`
which owns its permission via its bundle.

## Roadmap

- [x] Phase 0 — full-duplex Core Audio + sample-exact delay recovery (spike)
- [x] Phase 1 — sweep → IR → gated FR, smoothing, overlays/targets, `.pir`/`.frd`
- [x] Phase 3 (core) — Schroeder decay, RT60/EDT/C50/C80/D50/Ts wideband + per band, STI
- [x] Phase 2 — ETC / step response / CSD waterfall views
- [ ] Real-time modes — spectrum analyzer, dual-channel FR with live averaging
- [ ] Phase 4 — SPL meter, octave/third-octave meters, noise ratings
- [ ] Phase 5 — directivity patterns, polar plots, turntable automation

DSP references: ARTA user manual (Mateljan), Farina 2000 (swept-sine),
Schroeder 1965/1979, IEC 60268-16:2011, ISO 3382, IEC 61672.
