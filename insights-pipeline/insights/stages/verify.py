"""Stage 5: verify — the strengthened automated gate.

Per `bakeoff/DECISION.md`: gemma4:31b-it-q4_K_M was chosen for extraction
because its weaknesses (malformed records, filler, mistagged categories,
near-duplicates) are all "recoverable value only after a dedup +
category-fix pass" -- this stage IS that pass, and it is now load-bearing,
not optional cleanup. It must do more than a plain re-check:

1. Reject/repair malformed records — truncated text, missing/invalid
   category, before any LLM call (a cheap, pure, deterministic gate).
2. Drop filler — bare role-assignment facts ("X played Y") with no trivia
   substance, via a pure heuristic (no LLM call needed for the obvious
   cases the bake-off actually surfaced).
3. Dedup near-duplicates — same fact stated twice, or an over-split single
   production choice, via normalized-text + fuzzy similarity, pure.
4. Category sanity-check — re-confirm/fix the category (production
   anecdote mistagged as casting, etc.).
5. Re-check grounding against `source_snippet` and the `spoiler` tag.

(4) and (5) are folded into ONE LLM call per surviving fact (after 1-3 have
already run, which is the cheap part) — one JSON-object reply carrying
`grounded`, `spoiler`, and `category`, rather than three separate round
trips per fact.

Output: `facts_verified.jsonl` (the survivors, spoiler/category possibly
corrected) + a per-batch HTML spot-check report (fact | snippet | source
link | spoiler | verdict | drop reason) + a logged drop-rate — the quality
signal the spec calls out (a spiking drop-rate flags a bad extract prompt
or a bad source).

Pure core: `reject_malformed`, `is_filler_fact`, `dedup_facts`, and the
LLM-reply-to-decision mapping (`apply_verify_reply`) are unit tested
directly. `verify_batch` / `run` are the thin IO shell, exercised against a
fake ChatClient — no live LLM calls in tests.
"""

from __future__ import annotations

import html
import json
import logging
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from insights.config import Config
from insights.llm import ChatClient, LLMError, OllamaChatClient
from insights.models import CATEGORIES, SPOILER_LEVELS, Fact

logger = logging.getLogger(__name__)

MIN_FACT_LENGTH = 12  # shorter than this reads as truncated/garbage, not a real fact
# A truncated record from a model often just stops mid-clause; these are
# heuristics for "this doesn't look like a finished sentence," not a
# guarantee — genuinely malformed records are rare (bake-off: 1 in 75).
_TRUNCATION_SUFFIXES = (",", ";", ":", "-", "and", "or", "but", "the", "a", "an", "with", "of", "to")

VERIFY_SYSTEM_PROMPT = (
    "You are the quality-control pass for a movie/TV trivia extraction pipeline. "
    "You are given one previously-extracted fact, the exact source snippet it was "
    "extracted from, and its current category/spoiler tags. Judge three things and "
    "reply with ONLY a single JSON object (no markdown, no prose):\n"
    '{"grounded": true|false, "category": "<one of the enum values>", "spoiler": 0|1|2}\n\n'
    "- grounded: true only if every part of the fact is directly and explicitly "
    "supported by the source snippet (rewording is fine; invented or unsupported "
    "detail is not).\n"
    "- category: the single best-fitting category from this enum, re-deriving it "
    "yourself rather than trusting the given tag — production | casting | adaptation | "
    "reference | lore | goof | music.\n"
    "- spoiler: 0 (no spoiler risk), 1 (reveals a plot event/twist/outcome of THIS "
    "title), or 2 (reveals something about a LATER episode/season, or beyond this "
    "title's own story) — re-derive this yourself too.\n"
)


@dataclass(slots=True, frozen=True)
class VerifyDecision:
    fact: Fact
    kept: bool
    reason: str  # "" if kept; drop reason otherwise


# --- 1. malformed-record rejection (pure) ---


def looks_truncated(text: str) -> bool:
    """Pure heuristic: does this fact read like it was cut off mid-sentence?"""
    stripped = text.strip()
    if not stripped:
        return True
    if len(stripped) < MIN_FACT_LENGTH:
        return True
    # Ends with a dangling conjunction/preposition/article, or a bare comma/colon.
    last_word = re.sub(r"[^\w]", "", stripped.split()[-1]).lower() if stripped.split() else ""
    if stripped[-1] in ",;:-" or last_word in _TRUNCATION_SUFFIXES:
        return True
    return False


def reject_malformed(facts: list[Fact]) -> tuple[list[Fact], list[VerifyDecision]]:
    """Pure: split into (keepable, rejected-with-reason).

    Rejects: empty/whitespace text, text shorter than MIN_FACT_LENGTH,
    text that looks truncated, category outside the enum, spoiler outside
    0/1/2, or missing source url (can't attribute).
    """
    kept: list[Fact] = []
    rejected: list[VerifyDecision] = []
    for fact in facts:
        if not fact.text.strip():
            rejected.append(VerifyDecision(fact, False, "malformed: empty text"))
            continue
        if looks_truncated(fact.text):
            rejected.append(VerifyDecision(fact, False, "malformed: truncated text"))
            continue
        if fact.category not in CATEGORIES:
            rejected.append(VerifyDecision(fact, False, f"malformed: invalid category {fact.category!r}"))
            continue
        if fact.spoiler not in SPOILER_LEVELS:
            rejected.append(VerifyDecision(fact, False, f"malformed: invalid spoiler {fact.spoiler!r}"))
            continue
        if not fact.source.url.strip():
            rejected.append(VerifyDecision(fact, False, "malformed: missing source url"))
            continue
        kept.append(fact)
    return kept, rejected


# --- 2. filler detection (pure) ---

# Bare role-listing patterns the bake-off actually surfaced from gemma4,
# e.g. "John Krasinski played Jim Halpert." with zero trivia substance
# beyond the cast assignment itself. Deliberately narrow + anchored so it
# doesn't eat genuinely interesting casting trivia ("X was cast after a
# nationwide search", "X based the character on their own experience").
_FILLER_RE = re.compile(
    r"^[A-Z][\w.'-]*(?:\s+[A-Z][\w.'-]*){0,3}\s+"
    r"(?:played|portrays|portrayed|plays)\s+"
    r"[A-Z][\w.'-]*(?:\s+[A-Z][\w.'-]*){0,3}\.?$"
)


def is_filler_fact(text: str) -> bool:
    """Pure: is this a bare "X played Y" role-listing with no trivia substance?

    A real trivia fact about casting has MORE than just the assignment —
    a reason, a story, a comparison. This only matches sentences that are
    *exactly* the bare assignment (optionally trailing punctuation), so
    "X played Y after a lengthy audition process" does not match (it has
    a trailing clause) and is preserved.
    """
    return bool(_FILLER_RE.match(text.strip()))


# --- 3. dedup (pure) ---


def _normalize_for_dedup(text: str) -> str:
    lowered = text.lower().strip()
    lowered = re.sub(r"[^\w\s]", "", lowered)
    return re.sub(r"\s+", " ", lowered)


def _token_set(text: str) -> set[str]:
    return set(_normalize_for_dedup(text).split())


def _jaccard_similarity(a: set[str], b: set[str]) -> float:
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def dedup_facts(facts: list[Fact], *, similarity_threshold: float = 0.6) -> tuple[list[Fact], list[VerifyDecision]]:
    """Pure: drop near-duplicate facts (same claim restated, or an
    over-split single production choice covered by an earlier fact).

    Exact normalized-text duplicates always dedup. Near-duplicates use
    token-set Jaccard similarity above `similarity_threshold`. A true
    restatement of the same claim ("X shot Y using Z instead of W" vs.
    "Y was shot using Z rather than W by X") lands around 0.6-0.7 once
    reworded, while two genuinely distinct facts about the same title
    typically share only stray function words (well under 0.2) — the
    threshold sits between those two clusters, calibrated against the
    bake-off's actual duplicate examples. First occurrence wins (keeps the
    earliest section's phrasing).
    """
    kept: list[Fact] = []
    kept_norms: list[set[str]] = []
    rejected: list[VerifyDecision] = []

    for fact in facts:
        norm = _token_set(fact.text)
        is_dup = False
        for existing_norm in kept_norms:
            if norm == existing_norm or _jaccard_similarity(norm, existing_norm) >= similarity_threshold:
                is_dup = True
                break
        if is_dup:
            rejected.append(VerifyDecision(fact, False, "duplicate: near-identical to an earlier fact"))
            continue
        kept.append(fact)
        kept_norms.append(norm)

    return kept, rejected


# --- 4 + 5. LLM re-check: grounding + category-fix + spoiler-recheck ---


def build_verify_user_prompt(fact: Fact) -> str:
    return (
        f"Source snippet:\n---\n{fact.source_snippet}\n---\n\n"
        f"Extracted fact: {fact.text}\n"
        f"Current category: {fact.category}\n"
        f"Current spoiler level: {fact.spoiler}\n\n"
        "Reply with the JSON object described in your instructions."
    )


def parse_verify_reply(raw: str) -> dict[str, Any] | None:
    """Pure: parse the model's verify-call JSON object reply. None if unusable."""
    stripped = raw.strip()
    if stripped.startswith("```"):
        lines = stripped.splitlines()
        if lines:
            lines = lines[1:]
        if lines and lines[-1].strip().startswith("```"):
            lines = lines[:-1]
        stripped = "\n".join(lines).strip()
    try:
        data = json.loads(stripped)
    except json.JSONDecodeError:
        start, end = stripped.find("{"), stripped.rfind("}")
        if start == -1 or end == -1 or end < start:
            return None
        try:
            data = json.loads(stripped[start : end + 1])
        except json.JSONDecodeError:
            return None
    if not isinstance(data, dict):
        return None
    return data


def apply_verify_reply(fact: Fact, reply: dict[str, Any] | None) -> VerifyDecision:
    """Pure: turn a parsed verify reply into a keep/drop decision + possibly-corrected fact.

    An unparseable reply is treated conservatively: dropped rather than
    kept-unverified (verify is the gate; silence is not a pass).
    """
    if reply is None:
        return VerifyDecision(fact, False, "verify call: unparseable reply")

    grounded = reply.get("grounded")
    if grounded is not True:
        return VerifyDecision(fact, False, "ungrounded: not supported by source_snippet")

    category = reply.get("category")
    if category not in CATEGORIES:
        category = fact.category  # keep original if the model's fix is itself invalid

    spoiler = reply.get("spoiler")
    if isinstance(spoiler, str) and spoiler.isdigit():
        spoiler = int(spoiler)
    if spoiler not in SPOILER_LEVELS:
        spoiler = fact.spoiler

    corrected = Fact(
        text=fact.text,
        category=category,
        spoiler=spoiler,
        source=fact.source,
        source_snippet=fact.source_snippet,
    )
    return VerifyDecision(corrected, True, "")


def llm_verify_fact(chat_client: ChatClient, fact: Fact) -> VerifyDecision:
    """IO: one verify call for one fact. LLM failure -> dropped (conservative)."""
    try:
        reply_text = chat_client.chat(VERIFY_SYSTEM_PROMPT, build_verify_user_prompt(fact))
    except LLMError as exc:
        logger.warning("verify: LLM call failed for fact %r: %s", fact.text[:60], exc)
        return VerifyDecision(fact, False, f"verify call failed: {exc}")
    return apply_verify_reply(fact, parse_verify_reply(reply_text))


# --- batch orchestration ---


@dataclass(slots=True)
class VerifyBatchResult:
    key: str
    verified: list[Fact]
    all_decisions: list[VerifyDecision]  # kept + dropped, in pipeline order, for the report

    @property
    def drop_rate(self) -> float:
        total = len(self.all_decisions)
        if total == 0:
            return 0.0
        dropped = sum(1 for d in self.all_decisions if not d.kept)
        return dropped / total


def verify_batch(chat_client: ChatClient, key: str, facts: list[Fact]) -> VerifyBatchResult:
    """Run the full verify pipeline for one work item's raw facts.

    Order matters and is deliberately cheap-first: malformed rejection and
    filler/dedup (all pure, no LLM cost) run before the LLM grounding/
    category/spoiler call, so a batch with a lot of junk doesn't spend LLM
    time on facts that were always going to be dropped.
    """
    all_decisions: list[VerifyDecision] = []

    survivors, malformed_dropped = reject_malformed(facts)
    all_decisions.extend(malformed_dropped)

    filler_dropped = [f for f in survivors if is_filler_fact(f.text)]
    survivors = [f for f in survivors if not is_filler_fact(f.text)]
    all_decisions.extend(VerifyDecision(f, False, "filler: bare role-listing") for f in filler_dropped)

    survivors, dedup_dropped = dedup_facts(survivors)
    all_decisions.extend(dedup_dropped)

    verified: list[Fact] = []
    for fact in survivors:
        decision = llm_verify_fact(chat_client, fact)
        all_decisions.append(decision)
        if decision.kept:
            verified.append(decision.fact)

    result = VerifyBatchResult(key=key, verified=verified, all_decisions=all_decisions)
    logger.info(
        "verify: %s -> %d/%d kept (drop rate %.0f%%)",
        key,
        len(verified),
        len(all_decisions),
        result.drop_rate * 100,
    )
    return result


# --- IO: jsonl + HTML report ---


def write_facts_verified_jsonl(results: list[VerifyBatchResult], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for result in results:
            f.write(
                json.dumps(
                    {"key": result.key, "facts": [fact.to_working_dict() for fact in result.verified]}
                )
                + "\n"
            )


def load_facts_verified_jsonl(path: Path) -> dict[str, list[Fact]]:
    if not path.exists():
        return {}
    result: dict[str, list[Fact]] = {}
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            result[d["key"]] = [Fact.from_working_dict(fd) for fd in d["facts"]]
    return result


_REPORT_CSS = """
body { font-family: -apple-system, Helvetica, Arial, sans-serif; margin: 2rem; background: #0b0d12; color: #e6e8ec; }
h1, h2 { font-weight: 600; }
table { border-collapse: collapse; width: 100%; margin-bottom: 1.5rem; font-size: 0.85rem; }
th, td { border: 1px solid #333; padding: 6px 10px; text-align: left; vertical-align: top; }
th { background: #1a1e26; }
tr:nth-child(even) { background: #14171d; }
.kept { color: #6fdc8c; }
.dropped { color: #ff8080; font-weight: 600; }
.meta { color: #888; font-size: 0.85rem; }
"""


def render_spot_check_report(results: list[VerifyBatchResult]) -> str:
    """Render the per-batch HTML spot-check report: fact | snippet | source
    link | spoiler | verdict | drop reason — this is what gets sample-audited.
    """
    rows: list[str] = []
    total = 0
    dropped_total = 0
    for result in results:
        for decision in result.all_decisions:
            total += 1
            verdict_class = "kept" if decision.kept else "dropped"
            verdict_text = "KEPT" if decision.kept else "DROPPED"
            if not decision.kept:
                dropped_total += 1
            fact = decision.fact
            rows.append(
                "<tr>"
                f"<td>{html.escape(result.key)}</td>"
                f"<td>{html.escape(fact.text)}</td>"
                f'<td><a href="{html.escape(fact.source.url)}">{html.escape(fact.source.name)}</a></td>'
                f"<td>{html.escape(str(fact.category))}</td>"
                f"<td>{fact.spoiler}</td>"
                f'<td class="{verdict_class}">{verdict_text}</td>'
                f"<td>{html.escape(decision.reason)}</td>"
                "</tr>"
            )

    overall_drop_rate = (dropped_total / total) if total else 0.0
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Verify spot-check report</title>
<style>{_REPORT_CSS}</style></head>
<body>
<h1>Verify spot-check report</h1>
<p class="meta">{len(results)} work items &middot; {total} facts judged &middot;
{dropped_total} dropped &middot; overall drop rate {overall_drop_rate:.0%}</p>
<table>
<tr><th>work item</th><th>fact</th><th>source</th><th>category</th><th>spoiler</th><th>verdict</th><th>reason</th></tr>
{''.join(rows)}
</table>
</body></html>"""


def run(
    config: Config, facts_by_key: dict[str, list[Fact]] | None = None
) -> list[VerifyBatchResult]:
    """IO shell: verify every work item's raw facts, write facts_verified.jsonl + spot-check report.

    `facts_by_key` defaults to loading extract's on-disk output
    (`facts_raw.jsonl`) so this stage can run standalone from the CLI; pass
    it explicitly when chaining stages in-process.
    """
    if facts_by_key is None:
        from insights.stages.extract import load_facts_raw_jsonl

        facts_by_key = load_facts_raw_jsonl(config.data_dir / "facts_raw.jsonl")

    facts_verified_path = config.data_dir / "facts_verified.jsonl"
    already_verified = load_facts_verified_jsonl(facts_verified_path)

    chat_client = OllamaChatClient(config=config)
    results: list[VerifyBatchResult] = []

    for key, facts in facts_by_key.items():
        if key in already_verified:
            results.append(
                VerifyBatchResult(key=key, verified=already_verified[key], all_decisions=[])
            )
            continue
        results.append(verify_batch(chat_client, key, facts))

    report_dir = config.data_dir / "reports"
    report_dir.mkdir(parents=True, exist_ok=True)
    report_path = report_dir / "verify_spot_check.html"
    report_path.write_text(render_spot_check_report(results), encoding="utf-8")

    write_facts_verified_jsonl(results, facts_verified_path)

    total_judged = sum(len(r.all_decisions) for r in results)
    total_dropped = sum(sum(1 for d in r.all_decisions if not d.kept) for r in results)
    overall_rate = (total_dropped / total_judged) if total_judged else 0.0
    logger.info(
        "verify: %d work items, %d facts judged, overall drop rate %.0f%% -- report: %s",
        len(results),
        total_judged,
        overall_rate * 100,
        report_path,
    )
    return results
