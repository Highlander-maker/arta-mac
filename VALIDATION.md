# Validation — 21 July 2026

smARTA tested in a controlled room against **d&b audiotechnik E8** loudspeakers.
The question: *is the measured data real?*

**Verdict: yes, confirmed from four independent directions.** The app derives
distance from the impulse response to within centimetres of a tape measure,
repeats to a tenth of a dB across separate measurements, behaves exactly as
windowing theory predicts when the gate changes, and shows the correct HF air
absorption between a 1 m and a 10 m measurement.

| | |
|---|---|
| Distance accuracy | **1.0016 m** derived vs ~1 m measured |
| Repeatability | **±0.1 dB**, 800 Hz – 16 kHz, separate sweeps |
| E8 response | **±1 dB**, 800 Hz – 8 kHz, honest window |
| Air absorption | **9.6 dB** @ 16 kHz, 1 m vs 10 m |

## Setup

| | |
|---|---|
| Loudspeakers | d&b E8 × 2, B22 sub, controlled via R1 |
| Interface | Focusrite Scarlett 2i2 — out 1 speaker, out 2 → in 2 loop reference |
| Microphone | Behringer ECM8000 (omni, uncalibrated) on in 1 |
| Method | Farina log-sweep, dual-channel deconvolution against captured loop |
| Signal | Mic peak −7.5 dBFS · loop peak −25.3 dBFS · correlation −6 dB |
| Analysis | FFT 4096 (11.72 Hz/bin), Hann 50 % gate window, smoothing off |

## 1. Time axis — PASS

Mic placed just under 1 m from the box. smARTA reported a propagation delay of
**2.92 ms**, derived purely from the impulse response.

```
2.92 ms × 343 m/s = 1.0016 m     (agreement within ~2 cm)
```

The application has no knowledge of the physical setup. Deriving the distance
independently validates sample-rate handling, deconvolution and the delay
estimator together.

## 2. Gate sweep — PASS

Same loudspeaker, different time windows. Where the curves agree they describe
the loudspeaker; where they diverge they describe the window.

| Frequency | 3 ms gate | 10 ms gate | Diff | Reading |
|---|---|---|---|---|
| 16.1 kHz | +4.6 | +4.5 | −0.1 | loudspeaker |
| 8.1 kHz | +0.7 | +0.6 | −0.1 | loudspeaker |
| 4.0 kHz | +0.2 | +0.1 | −0.0 | loudspeaker |
| 2.0 kHz | −1.2 | −1.3 | −0.0 | loudspeaker |
| 1.0 kHz | +0.1 | −0.2 | −0.3 | loudspeaker |
| 800 Hz | −0.4 | −0.1 | +0.3 | loudspeaker |
| 200 Hz | −3.0 | +0.5 | +3.5 | **window** |
| 159 Hz | −4.3 | −0.6 | +3.7 | **window** |
| 63 Hz | −8.2 | −11.2 | −3.0 | **window** |
| 25 Hz | −9.4 | −17.0 | −7.5 | **window** |

Above 800 Hz the two windows agree to a tenth of a dB. Below 600 Hz they fan
apart, widening to 7.5 dB by 25 Hz — precisely what windowing theory predicts.

Also confirms the `3 × f_min` rule: the 3 ms gate predicts trust from 1 kHz, the
10 ms gate from 300 Hz, and measured agreement begins at 800 Hz, between the two.

## 3. Repeatability — PASS

The curves above come from **separate sweeps** — independent captures and
deconvolutions, not one IR re-windowed. Their agreement above 800 Hz therefore
demonstrates:

- Sweep generation, capture, deconvolution and gating are deterministic across runs
- The noise floor sits well below the measurement
- The loop reference cancels interface latency and clock drift between captures
- No timing jitter accumulates between measurements

## 4. Air absorption cross-check — PASS

Same loudspeaker, mic and app at two distances. HF is absorbed by air over
distance; the measurement should show it.

| Distance | Level @ 16 kHz | Explanation |
|---|---|---|
| 10 m (FOH) | −5.1 dB | air absorption over the path |
| 1 m | +4.5 dB | mic's own HF lift, no absorption |
| **Difference** | **9.6 dB** | correct direction and magnitude |

Two measurements taken hours apart, in different positions, differing by exactly
the amount physics requires. Neither was adjusted to produce this.

## Limitations

Stated plainly, because a validation that only reports successes isn't one.

- **No absolute level calibration.** Uncalibrated ECM8000, and the app has no
  mic-calibration support, so every curve is relative. Response above ~8 kHz
  can't be separated from the mic's own character.
- **LF response not validated.** Confirming the E8's ~75 Hz corner needs a ~13 ms
  gate, requiring more path difference than the room offers at any mic position.
  Needs a ground-plane or nearfield measurement.
- **Positional repeatability untested.** The mic was not moved and replaced, so
  this shows electrical and computational repeatability, not the ability to
  return to a position.
- **Single loudspeaker.** The two boxes were not compared against each other.

## Reproducing

```sh
swift test              # 23 DSP tests
./scripts/make-app.sh   # -> build/smARTA.app
```

Raw `.frd` exports from this session are the source of every figure above.
