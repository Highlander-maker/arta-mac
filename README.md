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
| `ArtaApp` | The application: SwiftUI shell, device selection, full-duplex sweep measurement via `AVAudioEngine`, log-frequency FR plot with cursor/overlays/targets, IR view with click-to-gate, room acoustics table, STI. |
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

1. Pick output/input devices and channels in the sidebar (same device for
   both = one clock, the reference configuration).
2. Set sweep length/level. For rooms use 1–2 s sweeps and a decay wait longer
   than the reverb tail; for electronics 0.5 s is fine.
3. **Measure** (⌘R). You get the impulse response, estimated system delay,
   gated frequency response, and room parameters.
4. In the Impulse tab: click = gate start, shift-click = gate end. The FR tab
   recomputes from the gate. Smoothing 1/1–1/24 octave.
5. Overlay workflow: *Set as overlay* to keep a curve, *Load target...* to load
   an `.frd` target (drawn dashed red) — tune the system until the live curve
   sits on the target.
6. Save the IR as `.pir` (opens in real ARTA), export the FR as `.frd`.

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
