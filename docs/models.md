# Speech and Helper Models

Resonant source code does not include speech-model weights. Selecting a model can
download weights from Hugging Face through FluidAudio. Model terms are independent
from the MIT license for this repository.

Approximate sizes below come from the adapters and may change upstream:

| Model | Runtime | Approximate download | Source used by the app | License status |
|---|---|---:|---|---|
| Parakeet TDT 0.6b v3 Core ML, INT8 | macOS 14+, Apple Neural Engine | 735 MB | [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) | Review the derivative repository and original NVIDIA model notices; attribution is required |
| Qwen3-ASR 0.6b Core ML, F32 | macOS 15+, Apple Neural Engine | 1.75 GB | [FluidInference/qwen3-asr-0.6b-coreml](https://huggingface.co/FluidInference/qwen3-asr-0.6b-coreml) | Repository metadata identifies Apache-2.0; verify the exact revision and upstream model terms |
| Cohere Transcribe Core ML, Q8 | macOS 15+, Apple Neural Engine | 2.0 GB | [FluidInference/cohere-transcribe-03-2026-coreml](https://huggingface.co/FluidInference/cohere-transcribe-03-2026-coreml) | **Ambiguous:** derivative metadata and license text have not consistently agreed; do not assume commercial permission |
| CTC 110m vocabulary helper | Used with Parakeet vocabulary boosting | 98 MB | Downloaded by FluidAudio | Verify the FluidAudio release's model source and terms |
| Silero VAD Core ML v6 | Meeting speech segmentation; optional dictation diagnostics | ~1 MB | [FluidInference/silero-vad-coreml](https://huggingface.co/FluidInference/silero-vad-coreml) | MIT upstream; verify the exact derivative revision before redistribution |

Sizes exclude temporary download space, Core ML compilation artifacts, and multiple
precision variants. Keep several additional gigabytes free.

## License and revision policy

Hugging Face repository metadata, model cards, and files can change independently.
The current downloader follows repository content rather than a documented
immutable revision/checksum manifest. Before distributing a binary or using a
model commercially, a maintainer should:

1. Record the exact repository revision and every downloaded filename.
2. Verify checksums and preserve the model card, license text, and required notices.
3. Confirm that both the original model and Core ML derivative permit the intended
   use and distribution method.
4. Show the applicable terms to users before download.
5. Re-review the evidence whenever the model or FluidAudio version changes.

Until the Cohere derivative's conflicting licensing signals are resolved, treat it
as restricted and seek clarification from the publisher before commercial use or
redistribution. Removing a commercial paywall does not automatically make every
downstream user's use non-commercial.

## Network and deletion

A model download sends ordinary request metadata to Hugging Face but does not need
to send recordings or transcripts. Transcription then runs locally.

The Silero VAD helper is downloaded only as part of a visible meeting-model
download action. Ordinary dictation uses the local energy fallback when VAD is
not already cached; starting a recording does not fetch it silently.

Model caches can be much larger than the nominal download and may be shared through
FluidAudio's cache locations. Use in-app model removal when available. When cleaning
manually, inspect the exact directory and quit every app using FluidAudio before
deleting it.
