# Live RTA — design/build plan

> **Status 2026-07-23: BUILT.** Steps 1, 2, 4 and most of 5 are done in one pass —
> `Sources/ArtaDSP/RTASpectrum.swift` (pure state machine) + `Sources/ArtaApp/RTAEngine.swift`
> (capture) + `RTAPanel` in `MainView.swift`, reusing `FRPlotView` as hoped. Power-domain
> exponential averaging with the IEC Fast/Slow constants below, alpha derived from the hop
> interval. Peak hold done. **Step 3 (`vDSP_fft_zrip` migration) is still outstanding** —
> deferred on purpose per this doc's own advice to prove the pipeline against the slower
> complex FFT first. See TODO.md.

Research note, written before any code. Answers "how do we get a live spectrum
view that looks smooth like Smaart's RTA" — the short answer is **temporal
ballistics, not spectral smoothing**. `Smoothing.swift` already does the
spectral (1/n-octave) axis correctly; it's the missing time axis that makes
today's meter-style updates look jittery once it's a full spectrum.

## What's already there (reusable)

- **`AudioDevices.ensureInputDeviceSettled`** (`AudioDevices.swift:170`) is the
  device-set + settle + tap-at-`inputFormat(forBus:0)` dance, already fixed for
  the mono-downmix gotcha (`outputFormat` silently drops channels past the
  first — verified on a 2-ch Scarlett). Reuse verbatim; don't re-derive it.
- **`InputMeterEngine`** (`InputMeterEngine.swift:56`) is a raw peak/RMS
  follower, **no FFT**. Sample math (line 100-111) runs synchronously *inside*
  the `installTap` callback — i.e. on the audio render thread — then hops to
  main via `DispatchQueue.main.async` only to publish the two floats. That's
  fine for two scalars per 2048-sample buffer (~43 ms @ 48 kHz) but the same
  pattern must NOT be copied for RTA: an FFT + smoothing pass is too much work
  to risk on the render thread (dropout risk under load).
- **`FFT.swift`** wraps `vDSP_fft_zip` — complex FFT on real-input-as-complex,
  i.e. paying for the imaginary half for nothing. Existing TODO to move to
  `vDSP_fft_zrip` (real FFT, ~2x throughput). For one-shot sweep analysis this
  didn't matter; for a spectrum recomputed continuously at update rates in the
  tens of Hz it roughly doubles the CPU budget available for everything else.
  **Do this migration first or alongside the RTA build, not after** — cheaper
  to do once than to do twice (once for FFT.swift's own TODO, once under RTA
  time pressure).
- **`Smoothing.fractionalOctave`** (`Smoothing.swift:12`) — power-domain
  1/n-octave banding, already correct, already matches the picker pattern in
  `FRPanel` (`MainView.swift:442-451`, `model.smoothing` tags 0/1/3/6/12/24).
  Reuse as-is for the spectral axis.
- **`Window.hann`** etc (`Windows.swift:5`) plus `coherentGain(count:)` for
  magnitude correction — reuse for the overlapped analysis window.
- **`PlotStyle`** (`PlotViews.swift:10`) — charcoal bg, amber trace, cyan
  phase, `PlotStyle.panel()` wrapper. `FRPlotView` (`PlotViews.swift:43`)
  already draws a log-frequency-axis dB curve with grid/ticks — close enough
  in shape to a single RTA trace that it's worth trying to feed it a live
  `FRCurve` before building a bespoke plot.

## Research: how Smaart actually gets the smooth look

Sourced from the **Smaart v8 User Guide** (Rational Acoustics, Release 8.5),
fetched and grepped directly — not from memory.

1. **Temporal averaging is exponential, first-order, on Fast/Slow — and it's
   the main lever, not spectral smoothing.** Direct quote (p.17, "Fundamental
   Concepts"): *"Fast and Slow averaging model the decay characteristics of
   Fast and Slow exponential time integration used in standard sound level
   meters. These are first-order exponential averages with time constants of
   0.125 and 1.0 seconds respectively."* This is the same 125 ms / 1000 ms
   IEC 61672 SPL meter Fast/Slow ballistics your instinct expected — confirmed
   in writing, not inferred. Smaart also offers **FIFO** (equal-weighted
   moving average of the last 2/4/8/16 frames), a proprietary **"1-10 Sec"
   variable-averaging blend of FIFO + exponential**, and **Infinite**
   (unweighted cumulative, reset on [V]). For a first RTA build, first-order
   exponential (leaky integrator) on Fast/Slow is the right minimum feature —
   it's the one the smooth "Smaart look" is most associated with, and it's a
   single `y = y + α(x - y)` per bin, trivial to implement.
   - **Nuance/inference, not confirmed by the doc:** the guide is explicit
     that SPL Fast/Slow integrates *power* (mean-square pressure). For
     spectral magnitude averaging specifically, Smaart instead exposes a
     **Polar vs Complex** choice (p.118): Polar averages dB magnitudes
     directly (log-domain), Complex keeps running real/imag averages. The
     doc does not state which domain Fast/Slow exponential averaging itself
     runs in for the RTA case. **Recommend defaulting to power-domain
     exponential averaging** (average `|X|²`, then convert to dB) since it's
     the physically-motivated choice (matches SPL meter behaviour, avoids the
     log-averaging bias toward quiet frames) — but flag this as a design
     choice, not a copied spec.
2. **Overlap.** Smaart defines overlap as shared data between successive FFT
   frames (p.27) and it's a first-class control for spectrograph display, but
   the User Guide doesn't publish a specific default overlap % for the RTA
   path itself. General real-time spectrum-analyzer literature (Tektronix
   "Understanding FFT Overlap Processing Fundamentals"; SRS "About FFT
   Analyzers" app note) is consistent on *why* overlap matters here: with a
   Hann-windowed frame, non-overlapped consecutive frames each throw away the
   tapered edges' contribution, so a transient near a frame boundary is
   under-weighted in one frame and over-weighted in the next — that's a
   source of jitter independent of the temporal averaging. 50-75%+ overlap is
   the commonly cited range for real-time displays; treat that figure as
   **inference from general SA literature, not a Smaart-specific spec**.
3. **Single FFT + log-frequency banding for RTA — NOT multi-resolution.**
   This directly answers the "one big FFT vs constant-Q" question, and the
   answer is unambiguous in the source (p.11-12, p.118): Smaart's
   multi-time-window (MTW) — multiple decimated-rate FFTs combined for good
   LF resolution without excess HF resolution — is used **only for dual-
   channel transfer-function measurements**. Direct quote: *"Real-time
   spectrum analyzer (RTA) and Spectrograph displays are based on
   single-channel FFT analysis... In RTA measurements, the use of fractional
   octave banding effectively nullifies the excess high-frequency resolution
   issue."* i.e. exactly the architecture arta-mac already has the pieces
   for: one FFT size (16k-32k typical), then `Smoothing.fractionalOctave`
   does the log-axis cleanup. No constant-Q/multi-resolution engine needed for
   this feature — that's real added complexity Smaart itself reserves for a
   different (dual-channel) mode.

Sources: Smaart v8 User Guide (rationalacoustics.com, downloaded and text-
extracted directly, Release 8.5, pp.11-12, 17, 27, 118); Rational Acoustics
support article "Time Weighting: SPL Fast, Slow, Leq, and Peak Explained"
(125 ms / 1 s IEC-style time constants, corroborating); Tektronix "Understanding
FFT Overlap Processing Fundamentals" (overlap-vs-jitter mechanism, general SA
theory, not Smaart-specific).

## Build plan

**New files:**
- `Sources/ArtaDSP/RTASpectrum.swift` — pure state machine, no audio I/O
  (matches the `ArtaDSP` target's "no audio I/O, no UI" contract in
  `Package.swift:17`). Owns: windowed-frame → real FFT (`vDSP_fft_zrip`,
  post-migration) → power spectrum → **exponential power-domain average per
  bin** (`y[i] += α * (x[i] - y[i])`, α derived from time-constant + hop
  interval) → `Smoothing.fractionalOctave` → `Smoothing.powerToDB`. One
  `process(frame: [Float]) -> [Float]` call per hop; caller owns hop timing.
- `Sources/ArtaApp/RTAMeterEngine.swift` — the capture side, sibling to
  `InputMeterEngine.swift`, reusing `AudioDevices.ensureInputDeviceSettled`.
  Owns a ring buffer fed from `installTap`'s callback (copy only — no math on
  the render thread), and a background `DispatchQueue` (or `Thread` with a
  semaphore) that drains the ring buffer in overlapped windowed chunks,
  calls `RTASpectrum.process`, and publishes to an `@Published` array via
  `DispatchQueue.main.async`, same pattern as `InputMeter.apply` — but
  **throttled**: don't let a 75%-overlap 16k-FFT hop rate (order 100+ Hz)
  drive SwiftUI redraws directly. Coalesce to ~30 fps with a `Timer`/
  `CADisplayLink`-style gate or a simple "drop if a redraw is already
  pending" flag on the published property.
- UI: new `MainView.Tab` case, `RTAPanel` in `MainView.swift` alongside
  `FRPanel`. Controls: averaging Fast/Slow/(+ maybe a numeric time-constant
  field later), the existing smoothing picker pattern lifted from
  `MainView.swift:442-451`, peak-hold toggle (same decay-per-tick idea as
  `InputMeter.holdDecayPerTick`, `InputMeterEngine.swift:16`). Plot: try
  reusing `FRPlotView` first before writing a new Canvas view.

**Sequencing (small wins, per Highlander's stated preference):**
1. Continuous capture → single FFT (existing `vDSP_fft_zip`, no migration
   yet) → log-bin via existing `Smoothing` → static plot with **no temporal
   averaging**. Proves the pipeline end-to-end. One sitting.
2. Add the power-domain exponential averager (Fast/Slow only, no FIFO/Infinite
   yet) — this is the step that actually produces "the smooth Smaart look."
3. Migrate `FFT.swift` to `vDSP_fft_zrip` — do this once the pipeline is
   proven correct against the slower complex FFT, so there's a known-good
   reference to diff against.
4. Add overlap + throttled redraw once the above is visibly smooth but CPU or
   frame-pacing is the bottleneck — don't add overlap speculatively before
   there's a visible problem to fix.
5. Peak-hold, additional averaging modes, numeric time-constant control — P3
   polish, same tier as the existing `TODO.md` P3 items.
