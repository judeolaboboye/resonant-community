# Ubiquitous Language

> Scope: Resonant Community Edition for macOS.

## Capture surfaces

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **Dictation** | A user-initiated short voice capture transcribed to text | Voice note, recording |
| **Meeting** | A long multi-speaker capture with notes, transcript, and summary | Call, session |
| **Memo** | A saved text artifact authored by the user, not transcribed | Note (ambiguous) |
| **Journal** | A dated reflective entry tied to a calendar day | Diary, log |
| **Ambient** | Passive background capture of app usage and screen activity | Tracking, telemetry |

## Meeting lifecycle

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **Backend** | A transcription engine (Parakeet, Qwen3, Cohere) selected per meeting | Engine, provider, model (overloaded) |
| **Model** | A specific weights artifact loaded by a **Backend** | Backend (when meaning weights) |
| **Hot mic** | An active microphone capture stream | Live mic, recording state |
| **Watchdog** | A supervisor that restarts audio capture on failure | Monitor, recovery |
| **Sidebar** | The right-edge panel that hosts the active **Meeting** UI | Panel, drawer |
| **Pill** | The collapsed right-edge affordance that expands into the **Sidebar** | Tab, handle |
| **Notch** | The top-of-screen overlay used for dictation status (legacy for meetings) | HUD, indicator |
| **Scratchpad** | The pre-revamp inline notes surface, being replaced by the **Sidebar** | Notes panel |

## Ambient work mirror

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **Commitment** | A stated intent extracted from **Dictation**, **Meeting**, or **Journal** | Todo, task |
| **Completion** | An acknowledged finish of a prior **Commitment** | Done item |
| **Drift** | A **Commitment** that has aged without a matching **Completion** | Stale todo, overdue |

## Relationships

- A **Meeting** has exactly one **Backend** at a time; the **Backend** loads one or more **Models**.
- A **Hot mic** stream is owned by one capture surface (**Dictation** or **Meeting**); the **Watchdog** supervises it.
- The **Sidebar** replaces both the **Scratchpad** and the meeting **Notch** in the current revamp.
- A **Commitment** belongs to one source artifact (**Dictation**, **Meeting**, or **Journal**) and produces zero or one **Completion**; otherwise it ages into **Drift**.

## Example dialogue

> **Dev:** "When a **User** starts a **Meeting**, does the **Backend** stay loaded across sessions?"
> **Domain expert:** "Yes — the **Model** is shared across **Meeting** and **Dictation** so we don't reload weights. The **Backend** wraps the **Model** with the streaming protocol."
> **Dev:** "And if the **Hot mic** dies mid-**Meeting**?"
> **Domain expert:** "The **Watchdog** restarts capture and surfaces a fatal in the **Notch**. Notes already in the **Sidebar** persist."

## Number formatting policy (ITN)

How spoken numbers become text. Rules live in `Sources/Resonant/TextProcessing/` (ITNProcessor + CurrencyStyler); guards live in `NumberContext`.

- **Conservative by default.** When a reading is ambiguous and no context anchor resolves it, leave the words as dictated. A wrong conversion is worse than no conversion.
- **Anchor precedence: currency > time > bare number.** "two fifty dollars" → "$250"; "two fifty pm" → "2:50 p.m."; explicit a.m./p.m. always wins. Payment verbs ("paid", "cost") and rate phrases ("a month", "each") count as currency anchors.
- **One house style for money.** Symbol-prefixed, comma-grouped, cents merged: "$5,000", "€50.20", never "5,000 dollars" or "$1000000". "N grand" compacts to "$Nk".
- **Casual stays casual.** "fifty bucks", "a couple hundred", "a few thousand" are prose — no digits forced on slang or vague quantities.
- **"percent" is a unit, not punctuation.** It converts to "%" regardless of the auto-punctuation setting. "half a percent" → "0.5%".
- **Fractions need plurality agreement and a plausible reading.** "three quarters" → "3/4", but "two quarters" stays prose (coins/fiscal — nobody dictates 2/4), and "the last three quarters" is a time span.
- **Qualified currencies stay prose.** "50 Australian dollars" is untouched; only bare "dollars"/"euros" adjacent to a number get a symbol.

## Flagged ambiguities

- **"Model"** is overloaded: it can mean transcription weights (Parakeet/Qwen3) or a Swift data model. Reserve **Model** for weights; use plain Swift type names for data structures.
- **"Backend"** vs **"Model"** were used interchangeably during the multi-backend rollout. **Backend** = engine integration; **Model** = the weights it serves. A single **Backend** may support multiple **Models**.
- **"Notch"** historically meant any top-screen overlay; now it is dictation-only. The **Meeting** equivalent is the **Sidebar** + **Pill**.
- **"Note"** is ambiguous between **Memo** (standalone artifact) and meeting notes (content inside a **Meeting**). Prefer the specific term.
