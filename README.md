# arta-mac-spike — Phase 0 audio I/O spike

This is **not the app**. It is the Phase 0 de-risking spike for **arta-mac**, a
planned native macOS clone of ARTA (dual-channel FFT analyzer / impulse
response measurement). Before building any DSP or UI, this spike proves the
one thing the whole project depends on: **tight full-duplex audio I/O on
Core Audio** — playing an excitation signal while simultaneously recording the
response, with both directions on one `AVAudioEngine`, and recovering the
round-trip delay to sample accuracy.

The method is ARTA's own "System Delay Estimation" (manual section 4.5):
play an exponential (Farina) swept sine, record it back through a loopback,
take the generalized cross-correlation (IFFT of the PHAT-normalized
cross-spectrum) between played and recorded signals — the correlation peak
position is the round-trip delay in samples.

## Build

```sh
swift build
.build/debug/arta-mac-spike help
```

## Commands

| Command | What it does |
|---|---|
| `devices` | List Core Audio devices: ID, name, in/out channel counts, sample rates |
| `sweep` | Generate the 20 Hz - 20 kHz log sweep offline, print stats, optionally `--write out.wav` |
| `selftest` | Hardware-free DSP check: known synthetic delay + noise must be recovered exactly |
| `measure` | The real thing: play sweep + record simultaneously, report round-trip delay |

## Getting a real round-trip latency number

1. **Physical loopback**: cable from your interface's output 1 straight into
   input 1 (or use the interface's internal loopback / direct-monitor path).
2. Turn monitor speakers down — the sweep goes out of the selected output.
3. Find your interface's device ID:

   ```sh
   .build/debug/arta-mac-spike devices
   ```

4. Measure (same device for input and output = one device clock, which is the
   configuration that matters for ARTA-style measurement):

   ```sh
   .build/debug/arta-mac-spike measure --input-device <ID> --output-device <ID>
   ```

Useful options: `--input-channel N --output-channel N` (1-based),
`--duration 2 --amplitude 0.1`, `--dump-dir /tmp/spike` (writes
`reference.wav` / `captured.wav` for inspection in a DAW).

The tool reports: capture level, correlation peak index / lag /
peak-to-noise, the scheduled playback offset it subtracts out, the
**round-trip delay in samples and ms**, and the driver-claimed latency sum
(device latency + safety offset + buffer size for both directions) for
comparison. It warns loudly when the input is silent or the correlation peak
is too weak to trust.

## Known caveats

- **Microphone permission**: macOS gates audio *input* for CLI tools by the
  terminal that launches them. First run of `measure` should pop a permission
  dialog for your terminal; if input reads -200 dBFS with the loopback
  definitely connected, check System Settings > Privacy & Security >
  Microphone for your terminal app. (Shells spawned by automation agents can
  report "authorized" but still receive silence — run from a real terminal.)
- **Different input/output devices** work but run on separate clocks; expect
  drift over long captures. Same-device loopback is the reference setup.
- Playback is scheduled at a known host time and that offset is subtracted,
  so the reported number is genuine I/O round-trip (output buffer + DAC +
  cable + ADC + input buffer + safety offsets), not scheduling slack.

## Phase 0 scope

Deliberately **not** here: frequency response / smoothing, impulse response
deconvolution, room acoustics, STI, directivity, SPL metering, any UI. If
this spike's numbers hold up (stable, repeatable, matching driver-reported
latency to within a buffer or so), the DSP layer gets built on this
foundation.
