# Extraction model decision

**Date:** 2026-07-07
**Decision:** **gemma4:31b-it-q4_K_M** for extraction, paired with a strengthened verify stage.

## How it was decided
A 3-member council judged the bake-off output (2 models × 5 real fixtures: The Office
production + "Dinner Party" episode; Silo production + lore/spoilers + a thin music stub),
each on a distinct lens. Time/cost was explicitly not a factor (user has the GPU indefinitely).

| Lens | Winner | Why |
|---|---|---|
| Factual accuracy / grounding | **gemma4** (moderate) | Both hallucination-free and neither padded the thin stub. gemma preserves source *hedges* more reliably ("roughly ten thousand", the Apple streaming-data caveat, the Carell-negotiation qualifier) where qwen2.5 drops them — the precise over-video risk. gemma's only strike: one malformed/truncated record. |
| Spoiler tagging | **gemma4** (mod-high) | **Zero leaks from either model** on the real twists — both correctly hid the Silo S1 finale reveals (fabricated outside view; other silos exist) as spoiler-1 and the book-ahead reveals as spoiler-2. gemma is better *calibrated* (premise=0, reveal=1) vs qwen's over-cautious blanket spoiler-1 on safe worldbuilding, and gemma additionally surfaced AND correctly spoiler-1-tagged the Office finale Michael cameo that qwen never extracted. |
| Rewrite / category / value | **qwen2.5** (moderate) | qwen categorizes more reliably and carries zero filler. gemma mistags a production anecdote as `casting`, emits bare cast-listings ("John Krasinski played Jim Halpert"), same-fact duplicates, and one corrupted record — but its extra volume includes genuinely valuable distinct facts (the Pact/relics/criminalized-questions lore, "Wool" self-published 2011, the studio name qwen dropped). Verdict: gemma's volume is "recoverable value only after a dedup + category-fix pass." |

## Why gemma4 despite the split
2 of 3 lenses favor gemma4, including the single most consequential one (spoiler safety —
neither leaks, gemma is better calibrated). The dissent is not "qwen is better" but "gemma
over-produces and needs cleanup." Crucially:
- **gemma's weaknesses are all fixable downstream in the verify stage**: dedup, filler-strip
  (bare role-listings), category-fix, and malformed-record rejection are exactly what verify does.
- **gemma's strengths are model-intrinsic**: hedge preservation, spoiler calibration, coverage
  (surfacing the finale cameo), and specificity cannot be added by a later pass.

Both dissenting-adjacent notes independently pointed here: accuracy said gemma only "narrows
toward a tie" if the malformed record can't be sanitized (verify sanitizes it); quality said
gemma's volume is "net positive after a dedup + category-fix pass" (that IS the verify stage).

## Consequences for the pipeline
The verify stage (Task 1.6) is now load-bearing and MUST also:
1. **Reject/repair malformed records** (truncated text, missing category) — never publish them.
2. **Drop filler** — bare role-assignment facts ("X played Y") with no trivia substance.
3. **Dedup near-duplicates** — same fact stated twice, or over-split single production choices.
4. **Category sanity-check** — re-confirm the category, fixing obvious mistags (production
   anecdote tagged casting, etc.).
5. Keep the existing job: drop ungrounded facts, re-check spoiler tags against the snippet.

Default model in `config.py` / `.env.example` updated to `gemma4:31b-it-q4_K_M`.
qwen3.5:27b remains excluded (reasoning model, hangs the batch). qwen2.5:32b stays available
as a fallback if gemma's verify-stage cleanup proves insufficient at scale.
