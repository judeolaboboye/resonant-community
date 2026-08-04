# Dictation Quality Pipeline

## Purpose

`dictation_quality_v1` measures whether dictated text survived the real product path without a user edit. It complements `dictation_latency_v2`: latency tells us whether the output was fast; quality tells us whether it was usable.

Use this event to decide whether polish, formatting, and personalization changes are reliable improvements.

## Event Boundary

The event is emitted after a successful paste and post-paste readback attempt. It sends only metadata and buckets. It must not include transcript text, pasted text, edited text, window titles, URLs, or exact app names.

Primary event:

```text
dictation_quality_v1
```

Important fields:

```text
pipeline_name=dictation_quality
measurement_point=post_paste_readback
delivery_status=delivered
quality_evaluable=true|false
readback_status=accepted|corrected|stale|bypassed|no_field_content|region_not_found|observation_replaced|observation_cancelled|auto_sent|personalization_unavailable
zero_edit_proxy=true|false
schema_version=4
model_family=parakeet|qwen3|cohere|other
target_profile=chat|email|code_editor|ai_coding_app|browser|terminal|native_app|unknown
surface_kind=email|chat|code|docs|task|browser|form|other...
cleanup_status=skipped|accepted|rejected|failed|fallback_local|not_applicable
cleanup_profile=default|message|emailFull|emailFragment
cleanup_sanitizer_reject_reason=...
confidence_overall_bucket=high|medium|low|unknown
confidence_recognition_bucket=high|medium|low|unknown
confidence_rewrite_bucket=high|medium|low|unknown
confidence_delivery_bucket=high|medium|low|unknown
confidence_reasons=comma,separated,enum,reasons
learning_eligible=true|false
auto_send_eligible=true|false
normalized_edit_distance_bucket=0|0-0.02|0.02-0.05|0.05-0.10|0.10-0.25|0.25+
correction_count=0..n
total_ms=...
cloud_cleanup_ms=...
paste_ms=...
context_personalization_assigned_variant=personalized|holdout|unassigned
context_personalization_opportunity=true|false
context_personalization_withheld_by_holdout=true|false
context_personalization_applied=true|false
boost_applied_count=0..n
boost_vetoed_count=0..n
```

This is a closed, identifier-free aggregate schema. It intentionally excludes
`install_id`, `dictation_id`, raw model identifiers, raw errors, transcripts,
and marketing attribution. Use `model_family` for safe segmentation. The
quality-specific payload cap is 128 properties so all reviewed v4 quality,
latency, experiment, and personalization fields survive sanitization; other
events retain the general 80-property cap.

## Core Metrics

### Readback Coverage

How often the quality pipeline can actually judge the result.

```text
count(quality_evaluable = true) / count(dictation_quality_v1)
```

Low coverage means we should improve readback, target-field support, or pasted-region isolation before trusting zero-edit conclusions for that surface.

`auto_sent`, `observation_replaced`, `observation_cancelled`, and
`personalization_unavailable` are terminal non-evaluable outcomes. They count
toward quality-event coverage, but not toward zero-edit rate.

### Zero-Edit Rate

Primary polish metric.

```text
count(zero_edit_proxy = true where quality_evaluable = true)
/
count(quality_evaluable = true)
```

Do not include non-evaluable readbacks in the denominator. They are product visibility gaps, not accepted outputs.

### Correction Rate

Inverse of zero-edit on evaluable events.

```text
count(readback_status = corrected)
/
count(quality_evaluable = true)
```

### Average Edit Severity

Use `normalized_edit_distance_bucket` distribution. For a quick panel, trend the percentage of corrected events with:

```text
normalized_edit_distance_bucket in ["0.10-0.25", "0.25+"]
```

This separates tiny punctuation edits from output that was meaningfully wrong.

### Quality-Adjusted Latency

Plot zero-edit rate against `total_ms` and `cloud_cleanup_ms` buckets.

Useful question:

```text
Did a slower path actually buy a higher zero-edit rate?
```

If not, prefer the faster path.

## Dashboard Panels

1. **Quality Coverage**
   - Event count: `dictation_quality_v1`
   - Readback coverage by `target_profile`, `surface_kind`, and `paste_delivery_mode`
   - Breakdown of non-evaluable `readback_status`

2. **Zero-Edit Rate**
   - Formula: zero-edit rate on `quality_evaluable = true`
   - Split by `target_profile`, `surface_kind`, `cleanup_profile`, and app version

3. **Cloud Cleanup Efficacy**
   - Zero-edit rate by `cleanup_status`
   - Correction rate by `cleanup_profile`
   - Fallback-local rate
   - Sanitizer reject reason distribution

4. **Edit Severity**
   - `normalized_edit_distance_bucket` distribution
   - Split by `target_profile`, `surface_kind`, and `cleanup_status`

5. **Latency vs Quality**
   - p50/p95 `total_ms`, `cloud_cleanup_ms`, and `paste_ms`
   - Overlay or table next to zero-edit rate
   - Split by `cleanup_status` and experiment flags

6. **Experiment Readout**
   - For each `experiment_*` property:
     - exposure count
     - zero-edit rate
     - readback coverage
     - p95 total latency
     - sanitizer reject rate
     - fallback-local rate

7. **Confidence Calibration**
   - Zero-edit rate by `confidence_overall_bucket`
   - Monotonicity check: high should beat medium, medium should beat low
   - Split by `confidence_recognition_bucket`, `confidence_rewrite_bucket`, and `confidence_delivery_bucket`
   - Reason distribution via `confidence_reasons`
   - Coverage of high-confidence events by `target_profile` and `surface_kind`

8. **Personalization Holdout**
   - Filter to `context_personalization_opportunity = true`
   - Compare evaluable share, zero-edit rate, and p95 latency by
     `context_personalization_assigned_variant`
   - Show `context_personalization_withheld_by_holdout` and
     `context_personalization_applied` counts as assignment-integrity checks
   - Split only by coarse target/surface and `model_family`; do not reconstruct
     user-level or text-level cohorts

9. **Vocabulary Boost**
   - Trend `boost_applied_count`, `boost_vetoed_count`, and
     `boost_dropped_with_veto_count` on quality v4
   - Use `vocabulary_boost_attempt_v1` for the typed one-outcome attempt funnel
   - Treat `vocabulary_boost_decision` as a closed metric-only diagnostic event;
     terms and transcript spans must never be properties

## HogQL Starters

Use these once `dictation_quality_v1` appears in PostHog.

### Event Presence

```sql
SELECT event, count() AS events
FROM events
WHERE timestamp >= now() - INTERVAL 7 DAY
  AND event = 'dictation_quality_v1'
  AND properties.analytics_source = 'resonant_swift'
  AND toInt(properties.schema_version) = 4
GROUP BY event
ORDER BY events DESC
LIMIT 100
```

### Readback Coverage By Target Profile

```sql
SELECT
  properties.target_profile AS target_profile,
  count() AS events,
  countIf(properties.quality_evaluable = true) AS evaluable,
  round(100 * evaluable / events, 1) AS readback_coverage_pct
FROM events
WHERE timestamp >= now() - INTERVAL 7 DAY
  AND event = 'dictation_quality_v1'
  AND properties.analytics_source = 'resonant_swift'
  AND toInt(properties.schema_version) = 4
GROUP BY target_profile
ORDER BY events DESC
LIMIT 100
```

### Zero-Edit Rate By Surface

```sql
SELECT
  properties.target_profile AS target_profile,
  properties.surface_kind AS surface_kind,
  countIf(properties.quality_evaluable = true) AS evaluable,
  countIf(properties.quality_evaluable = true AND properties.zero_edit_proxy = true) AS zero_edit,
  round(100 * zero_edit / evaluable, 1) AS zero_edit_pct
FROM events
WHERE timestamp >= now() - INTERVAL 7 DAY
  AND event = 'dictation_quality_v1'
  AND properties.analytics_source = 'resonant_swift'
  AND toInt(properties.schema_version) = 4
GROUP BY target_profile, surface_kind
HAVING evaluable >= 10
ORDER BY zero_edit_pct ASC, evaluable DESC
LIMIT 100
```

### Cloud Cleanup Efficacy

```sql
SELECT
  properties.cleanup_status AS cleanup_status,
  properties.cleanup_profile AS cleanup_profile,
  countIf(properties.quality_evaluable = true) AS evaluable,
  countIf(properties.quality_evaluable = true AND properties.zero_edit_proxy = true) AS zero_edit,
  round(100 * zero_edit / evaluable, 1) AS zero_edit_pct,
  quantile(0.95)(toFloat(properties.total_ms)) AS p95_total_ms
FROM events
WHERE timestamp >= now() - INTERVAL 7 DAY
  AND event = 'dictation_quality_v1'
  AND properties.analytics_source = 'resonant_swift'
  AND toInt(properties.schema_version) = 4
GROUP BY cleanup_status, cleanup_profile
HAVING evaluable >= 10
ORDER BY zero_edit_pct ASC, evaluable DESC
LIMIT 100
```

### Non-Evaluable Readback Reasons

```sql
SELECT
  properties.target_profile AS target_profile,
  properties.readback_status AS readback_status,
  count() AS events
FROM events
WHERE timestamp >= now() - INTERVAL 7 DAY
  AND event = 'dictation_quality_v1'
  AND properties.analytics_source = 'resonant_swift'
  AND toInt(properties.schema_version) = 4
  AND properties.quality_evaluable = false
GROUP BY target_profile, readback_status
ORDER BY events DESC
LIMIT 100
```

## Decision Rules

### A polish change is a reliable improvement when:

- zero-edit rate improves on evaluable events,
- readback coverage does not drop,
- p95 total latency does not materially regress,
- sanitizer reject rate does not rise,
- fallback-local rate does not rise,
- the gain appears in at least one target surface without causing broad regressions elsewhere.

### If zero-edit rate is low and readback coverage is high:

Improve cleanup quality:

- app/surface-specific cleanup profile,
- bounded context hints,
- identifier preservation,
- personalization style hints,
- stricter copy-preserving prompt or sanitizer behavior.

### If zero-edit rate is low only when `cleanup_status=accepted`:

The cloud output is being accepted but still edited by users. Investigate:

- prompt profile mismatch,
- weak context grounding,
- missing user terminology,
- over-formatting or under-formatting,
- email/message special cases.

### If fallback-local rate is high:

Improve reliability before model quality:

- cloud timeout budget,
- auth/subscription gating,
- dedicated endpoint availability,
- sanitizer rejects,
- network/session behavior.

### If readback coverage is low:

Improve measurement and delivery support:

- accessibility readback for that target profile,
- pasted-region isolation,
- paste mode selection,
- bypass rules.

Do not conclude quality improved or regressed from low-coverage surfaces.

### If latency improves but zero-edit worsens:

Treat it as a product regression unless the target surface explicitly values speed over polish. Time-to-send is a guardrail, not the primary polish metric.

## First Weekly Review

After the event has enough volume, review:

- top three target profiles by event count,
- readback coverage by target profile,
- zero-edit rate by target profile,
- zero-edit rate by cleanup status,
- correction severity distribution,
- p95 total latency by cleanup status,
- sanitizer reject reasons.

The first product bets should come from the largest high-coverage surfaces with the lowest zero-edit rate.
