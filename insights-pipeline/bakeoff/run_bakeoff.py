#!/usr/bin/env python3
"""Extraction bake-off harness (Phase 0, Task 0.1 of the Insights Trivia pipeline).

Compares candidate local LLMs + the extract_v1.txt prompt on the core extraction task:
turn a chunk of encyclopedia prose into a JSON array of grounded trivia facts.

For each (fixture x model):
  1. Call the model with extract_v1.txt as the system prompt and the fixture text as the
     user message. temperature=0, stream=False. Parse the JSON array response (with a
     tolerant repair path for models that wrap the array in prose or markdown fences).
  2. For each extracted fact, make a SECOND call to the SAME model asking it to judge
     whether the fact is fully grounded in the source text (yes/no).

Output: one HTML report per fixture (a table: model | fact text | category | spoiler |
grounded?), an overall index page, and a per-model summary (fact count, malformed-JSON
rate, ungrounded-fact rate) as both HTML and a plain-text/JSON summary.

Zero third-party dependencies -- stdlib only (urllib), so it runs on the Unraid box with
no pip install. Config below is env-overridable.

Usage:
    python3 run_bakeoff.py
    OLLAMA_BASE_URL=http://192.168.1.140:11434/v1 python3 run_bakeoff.py
"""

from __future__ import annotations

import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# --------------------------------------------------------------------------------------
# Config (env-overridable)
# --------------------------------------------------------------------------------------

BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434/v1").rstrip("/")
CHAT_ENDPOINT = f"{BASE_URL}/chat/completions"

MODELS = [m.strip() for m in os.environ.get(
    "BAKEOFF_MODELS",
    "qwen2.5:32b-instruct,qwen3.5:27b-q4_K_M,gemma4:31b-it-q4_K_M",
).split(",") if m.strip()]

SCRIPT_DIR = Path(__file__).resolve().parent
FIXTURES_DIR = Path(os.environ.get("BAKEOFF_FIXTURES_DIR", str(SCRIPT_DIR / "fixtures")))
PROMPT_PATH = Path(os.environ.get("BAKEOFF_PROMPT_PATH", str(SCRIPT_DIR / "prompts" / "extract_v1.txt")))
OUT_DIR = Path(os.environ.get("BAKEOFF_OUT_DIR", str(SCRIPT_DIR / "out")))

REQUEST_TIMEOUT_SECS = float(os.environ.get("BAKEOFF_TIMEOUT_SECS", "300"))
MAX_RETRIES = int(os.environ.get("BAKEOFF_MAX_RETRIES", "2"))

VALID_CATEGORIES = {
    "production", "casting", "adaptation", "reference", "lore", "goof", "music",
}
VALID_SPOILERS = {0, 1, 2}

GROUNDING_SYSTEM_PROMPT = (
    "You judge whether a single claimed fact is fully supported by a source text. "
    "Answer with exactly one word: yes or no. "
    "Answer 'yes' only if every part of the fact is directly and explicitly supported by "
    "the source text (rewording is fine; invented or unsupported detail is not). "
    "Answer 'no' if the fact adds anything -- a name, number, causal claim, or detail -- "
    "that is not present in the source text, or if it contradicts the source text."
)


# --------------------------------------------------------------------------------------
# HTTP (stdlib only)
# --------------------------------------------------------------------------------------

class ChatCallError(Exception):
    """Raised when the chat completion call fails after retries."""


def call_chat(model: str, system_prompt: str, user_content: str, *, temperature: float = 0.0) -> str:
    """Call the OpenAI-compatible /chat/completions endpoint. Returns assistant message content."""
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_content},
        ],
        "temperature": temperature,
        "stream": False,
    }
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        CHAT_ENDPOINT,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    last_err: Exception | None = None
    for attempt in range(1, MAX_RETRIES + 2):
        try:
            with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_SECS) as resp:
                raw = resp.read().decode("utf-8")
            data = json.loads(raw)
            return data["choices"][0]["message"]["content"]
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError,
                json.JSONDecodeError, KeyError, IndexError) as exc:
            last_err = exc
            if attempt <= MAX_RETRIES:
                time.sleep(2.0 * attempt)
                continue
    raise ChatCallError(f"chat call failed for model={model!r} after retries: {last_err!r}")


# --------------------------------------------------------------------------------------
# Tolerant JSON-array parsing
# --------------------------------------------------------------------------------------

def extract_json_array(raw_text: str) -> tuple[list[Any] | None, str | None]:
    """Try hard to recover a JSON array from a model's raw response.

    Returns (parsed_list, error) -- exactly one is non-None.
    """
    text = raw_text.strip()

    # 1. direct parse
    try:
        parsed = json.loads(text)
        if isinstance(parsed, list):
            return parsed, None
        return None, "top-level JSON was not an array"
    except json.JSONDecodeError:
        pass

    # 2. strip markdown code fences (```json ... ``` or ``` ... ```)
    fence_match = re.search(r"```(?:json)?\s*(.*?)```", text, re.DOTALL | re.IGNORECASE)
    if fence_match:
        candidate = fence_match.group(1).strip()
        try:
            parsed = json.loads(candidate)
            if isinstance(parsed, list):
                return parsed, None
        except json.JSONDecodeError:
            pass

    # 3. find the first '[' and the matching last ']' in the whole text (handles
    #    leading/trailing prose the model added despite instructions)
    start = text.find("[")
    end = text.rfind("]")
    if start != -1 and end != -1 and end > start:
        candidate = text[start:end + 1]
        try:
            parsed = json.loads(candidate)
            if isinstance(parsed, list):
                return parsed, None
        except json.JSONDecodeError as exc:
            return None, f"malformed JSON array after bracket-extraction repair: {exc}"

    return None, "no JSON array found in response"


def validate_fact(fact: Any) -> tuple[dict[str, Any] | None, str | None]:
    """Validate+normalize one fact dict against the schema. Returns (fact, error)."""
    if not isinstance(fact, dict):
        return None, f"fact entry was not an object: {fact!r}"

    text = fact.get("text")
    category = fact.get("category")
    spoiler = fact.get("spoiler")
    source = fact.get("source", "general")

    if not isinstance(text, str) or not text.strip():
        return None, f"missing/empty 'text' field: {fact!r}"

    if category not in VALID_CATEGORIES:
        return None, f"invalid category {category!r} (fact: {text[:60]!r}...)"

    # tolerate string spoiler values like "0"
    if isinstance(spoiler, str) and spoiler.isdigit():
        spoiler = int(spoiler)
    if spoiler not in VALID_SPOILERS:
        return None, f"invalid spoiler {spoiler!r} (fact: {text[:60]!r}...)"

    return {
        "text": text.strip(),
        "category": category,
        "spoiler": spoiler,
        "source": str(source) if source is not None else "general",
    }, None


# --------------------------------------------------------------------------------------
# Grounding check
# --------------------------------------------------------------------------------------

def check_grounded(model: str, fact_text: str, source_text: str) -> str:
    """Second call to the same model: is this fact fully supported by the source text?

    Returns "yes", "no", or "error" (call failed / unparseable answer).
    """
    user_msg = (
        f"Source text:\n---\n{source_text}\n---\n\n"
        f"Claimed fact: {fact_text}\n\n"
        "Is this fact fully supported by the source text? Answer yes or no."
    )
    try:
        reply = call_chat(model, GROUNDING_SYSTEM_PROMPT, user_msg, temperature=0.0)
    except ChatCallError:
        return "error"

    normalized = reply.strip().lower()
    if normalized.startswith("yes"):
        return "yes"
    if normalized.startswith("no"):
        return "no"
    # tolerant fallback: look for a standalone yes/no token anywhere in a short reply
    if re.search(r"\byes\b", normalized):
        return "yes"
    if re.search(r"\bno\b", normalized):
        return "no"
    return "error"


# --------------------------------------------------------------------------------------
# Data model for results
# --------------------------------------------------------------------------------------

@dataclass
class FactResult:
    text: str
    category: str
    spoiler: int
    source: str
    grounded: str  # "yes" | "no" | "error"


@dataclass
class FixtureModelResult:
    fixture_name: str
    model: str
    facts: list[FactResult] = field(default_factory=list)
    malformed: bool = False
    malformed_reason: str = ""
    invalid_fact_count: int = 0
    invalid_fact_reasons: list[str] = field(default_factory=list)
    call_error: str = ""
    elapsed_secs: float = 0.0


@dataclass
class ModelSummary:
    model: str
    fixtures_attempted: int = 0
    fixtures_malformed: int = 0
    fixtures_call_failed: int = 0
    total_facts: int = 0
    invalid_fact_count: int = 0
    grounded_yes: int = 0
    grounded_no: int = 0
    grounded_error: int = 0

    @property
    def malformed_rate(self) -> float:
        return self.fixtures_malformed / self.fixtures_attempted if self.fixtures_attempted else 0.0

    @property
    def ungrounded_rate(self) -> float:
        judged = self.grounded_yes + self.grounded_no
        return self.grounded_no / judged if judged else 0.0

    @property
    def avg_facts_per_fixture(self) -> float:
        return self.total_facts / self.fixtures_attempted if self.fixtures_attempted else 0.0


# --------------------------------------------------------------------------------------
# Core run
# --------------------------------------------------------------------------------------

def run_one(model: str, fixture_path: Path, system_prompt: str) -> FixtureModelResult:
    fixture_name = fixture_path.name
    source_text = fixture_path.read_text(encoding="utf-8")
    result = FixtureModelResult(fixture_name=fixture_name, model=model)

    start = time.time()
    try:
        raw = call_chat(model, system_prompt, source_text, temperature=0.0)
    except ChatCallError as exc:
        result.call_error = str(exc)
        result.elapsed_secs = time.time() - start
        print(f"    [ERROR] call failed: {exc}", file=sys.stderr)
        return result

    parsed, err = extract_json_array(raw)
    if parsed is None:
        result.malformed = True
        result.malformed_reason = err or "unknown parse failure"
        result.elapsed_secs = time.time() - start
        print(f"    [MALFORMED] {err}", file=sys.stderr)
        return result

    for raw_fact in parsed:
        fact, ferr = validate_fact(raw_fact)
        if fact is None:
            result.invalid_fact_count += 1
            result.invalid_fact_reasons.append(ferr or "unknown validation failure")
            continue
        grounded = check_grounded(model, fact["text"], source_text)
        result.facts.append(FactResult(
            text=fact["text"],
            category=fact["category"],
            spoiler=fact["spoiler"],
            source=fact["source"],
            grounded=grounded,
        ))

    result.elapsed_secs = time.time() - start
    return result


def run_bakeoff(models: list[str], fixture_paths: list[Path], system_prompt: str) -> list[FixtureModelResult]:
    results: list[FixtureModelResult] = []
    total = len(models) * len(fixture_paths)
    n = 0
    for fixture_path in fixture_paths:
        for model in models:
            n += 1
            print(f"[{n}/{total}] fixture={fixture_path.name} model={model} ...", file=sys.stderr)
            r = run_one(model, fixture_path, system_prompt)
            status = (
                "call-error" if r.call_error else
                "malformed" if r.malformed else
                f"{len(r.facts)} facts ({r.invalid_fact_count} invalid)"
            )
            print(f"    -> {status} in {r.elapsed_secs:.1f}s", file=sys.stderr)
            results.append(r)
    return results


def summarize(results: list[FixtureModelResult], models: list[str]) -> dict[str, ModelSummary]:
    summaries = {m: ModelSummary(model=m) for m in models}
    for r in results:
        s = summaries[r.model]
        s.fixtures_attempted += 1
        if r.call_error:
            s.fixtures_call_failed += 1
            continue
        if r.malformed:
            s.fixtures_malformed += 1
            continue
        s.total_facts += len(r.facts)
        s.invalid_fact_count += r.invalid_fact_count
        for f in r.facts:
            if f.grounded == "yes":
                s.grounded_yes += 1
            elif f.grounded == "no":
                s.grounded_no += 1
            else:
                s.grounded_error += 1
    return summaries


# --------------------------------------------------------------------------------------
# HTML report generation
# --------------------------------------------------------------------------------------

def esc(s: Any) -> str:
    return html.escape(str(s), quote=True)


REPORT_CSS = """
body { font-family: -apple-system, Helvetica, Arial, sans-serif; margin: 2rem; background: #0b0d12; color: #e6e8ec; }
h1, h2 { font-weight: 600; }
h1 { font-size: 1.4rem; }
h2 { font-size: 1.1rem; margin-top: 2.5rem; border-bottom: 1px solid #333; padding-bottom: 0.4rem; }
table { border-collapse: collapse; width: 100%; margin-bottom: 1.5rem; font-size: 0.85rem; }
th, td { border: 1px solid #333; padding: 6px 10px; text-align: left; vertical-align: top; }
th { background: #1a1e26; position: sticky; top: 0; }
tr:nth-child(even) { background: #14171d; }
.grounded-yes { color: #6fdc8c; }
.grounded-no { color: #ff8080; font-weight: 600; }
.grounded-error { color: #d8b34a; }
.spoiler-0 { color: #8fb8ff; }
.spoiler-1 { color: #e0a030; }
.spoiler-2 { color: #ff6f6f; }
.malformed { color: #ff8080; font-weight: 600; }
.callerror { color: #ff4040; font-weight: 700; }
code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
pre.source { white-space: pre-wrap; background: #14171d; border: 1px solid #333; padding: 1rem; border-radius: 6px; max-height: 300px; overflow-y: auto; }
.summary-table td, .summary-table th { text-align: right; }
.summary-table td:first-child, .summary-table th:first-child { text-align: left; }
nav { margin-bottom: 1.5rem; }
nav a { color: #8fb8ff; margin-right: 1rem; }
.meta { color: #888; font-size: 0.8rem; }
"""


def render_fixture_report(fixture_path: Path, results_for_fixture: list[FixtureModelResult]) -> str:
    source_text = fixture_path.read_text(encoding="utf-8")
    rows = []
    for r in results_for_fixture:
        if r.call_error:
            rows.append(
                f'<tr><td>{esc(r.model)}</td><td colspan="4" class="callerror">'
                f'CALL FAILED: {esc(r.call_error)}</td></tr>'
            )
            continue
        if r.malformed:
            rows.append(
                f'<tr><td>{esc(r.model)}</td><td colspan="4" class="malformed">'
                f'MALFORMED JSON: {esc(r.malformed_reason)}</td></tr>'
            )
            continue
        if not r.facts:
            rows.append(
                f'<tr><td>{esc(r.model)}</td><td colspan="4"><em>0 facts extracted'
                f'{f" ({r.invalid_fact_count} invalid entries dropped)" if r.invalid_fact_count else ""}'
                f'</em></td></tr>'
            )
            continue
        for i, f in enumerate(r.facts):
            model_cell = esc(r.model) if i == 0 else ""
            grounded_class = f"grounded-{f.grounded}"
            spoiler_class = f"spoiler-{f.spoiler}"
            rows.append(
                "<tr>"
                f"<td>{model_cell}</td>"
                f"<td>{esc(f.text)}</td>"
                f"<td>{esc(f.category)}</td>"
                f'<td class="{spoiler_class}">{f.spoiler}</td>'
                f'<td class="{grounded_class}">{esc(f.grounded)}</td>'
                "</tr>"
            )
        if r.invalid_fact_count:
            rows.append(
                f'<tr><td></td><td colspan="4"><span class="meta">'
                f'({r.invalid_fact_count} invalid entries dropped: '
                f'{esc("; ".join(r.invalid_fact_reasons[:3]))}'
                f'{"..." if len(r.invalid_fact_reasons) > 3 else ""})</span></td></tr>'
            )

    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Bake-off: {esc(fixture_path.stem)}</title>
<style>{REPORT_CSS}</style></head>
<body>
<nav><a href="index.html">&larr; index</a></nav>
<h1>Fixture: {esc(fixture_path.name)}</h1>
<h2>Source text</h2>
<pre class="source">{esc(source_text)}</pre>
<h2>Extracted facts by model</h2>
<table>
<tr><th>model</th><th>fact text</th><th>category</th><th>spoiler</th><th>grounded?</th></tr>
{''.join(rows)}
</table>
</body></html>"""


def render_index(
    fixture_paths: list[Path],
    summaries: dict[str, ModelSummary],
    models: list[str],
) -> str:
    fixture_links = "".join(
        f'<li><a href="{esc(p.stem)}.html">{esc(p.name)}</a></li>' for p in fixture_paths
    )

    summary_rows = []
    for m in models:
        s = summaries[m]
        summary_rows.append(
            "<tr>"
            f"<td>{esc(m)}</td>"
            f"<td>{s.fixtures_attempted}</td>"
            f"<td>{s.fixtures_call_failed}</td>"
            f"<td>{s.fixtures_malformed}</td>"
            f"<td>{s.malformed_rate:.0%}</td>"
            f"<td>{s.total_facts}</td>"
            f"<td>{s.avg_facts_per_fixture:.1f}</td>"
            f"<td>{s.invalid_fact_count}</td>"
            f"<td>{s.grounded_yes}</td>"
            f"<td>{s.grounded_no}</td>"
            f"<td>{s.grounded_error}</td>"
            f"<td>{s.ungrounded_rate:.0%}</td>"
            "</tr>"
        )

    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Extraction bake-off — index</title>
<style>{REPORT_CSS}</style></head>
<body>
<h1>Extraction bake-off: model comparison</h1>
<p class="meta">Prompt: extract_v1.txt &middot; base URL: {esc(BASE_URL)} &middot; models: {esc(', '.join(models))}</p>

<h2>Per-model summary</h2>
<table class="summary-table">
<tr>
  <th>model</th><th>fixtures run</th><th>call failures</th><th>malformed JSON</th>
  <th>malformed rate</th><th>total facts</th><th>avg facts/fixture</th>
  <th>invalid fact entries</th><th>grounded=yes</th><th>grounded=no</th>
  <th>grounded=error</th><th>ungrounded rate</th>
</tr>
{''.join(summary_rows)}
</table>
<p class="meta">"ungrounded rate" = grounded=no / (grounded=yes + grounded=no), i.e. excludes grounding-check call errors from the denominator.</p>

<h2>Per-fixture reports</h2>
<ul>{fixture_links}</ul>
</body></html>"""


def write_reports(
    results: list[FixtureModelResult],
    fixture_paths: list[Path],
    summaries: dict[str, ModelSummary],
    models: list[str],
    out_dir: Path,
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)

    by_fixture: dict[str, list[FixtureModelResult]] = {}
    for r in results:
        by_fixture.setdefault(r.fixture_name, []).append(r)

    for fixture_path in fixture_paths:
        frs = by_fixture.get(fixture_path.name, [])
        html_out = render_fixture_report(fixture_path, frs)
        (out_dir / f"{fixture_path.stem}.html").write_text(html_out, encoding="utf-8")

    index_html = render_index(fixture_paths, summaries, models)
    (out_dir / "index.html").write_text(index_html, encoding="utf-8")

    # machine-readable summary too
    summary_json = {
        m: {
            "fixtures_attempted": s.fixtures_attempted,
            "fixtures_call_failed": s.fixtures_call_failed,
            "fixtures_malformed": s.fixtures_malformed,
            "malformed_rate": s.malformed_rate,
            "total_facts": s.total_facts,
            "avg_facts_per_fixture": s.avg_facts_per_fixture,
            "invalid_fact_count": s.invalid_fact_count,
            "grounded_yes": s.grounded_yes,
            "grounded_no": s.grounded_no,
            "grounded_error": s.grounded_error,
            "ungrounded_rate": s.ungrounded_rate,
        }
        for m, s in summaries.items()
    }
    (out_dir / "summary.json").write_text(json.dumps(summary_json, indent=2), encoding="utf-8")


# --------------------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------------------

def main() -> int:
    if not PROMPT_PATH.exists():
        print(f"prompt file not found: {PROMPT_PATH}", file=sys.stderr)
        return 2
    system_prompt = PROMPT_PATH.read_text(encoding="utf-8")

    fixture_paths = sorted(
        p for p in FIXTURES_DIR.glob("*.txt") if p.is_file()
    )
    if not fixture_paths:
        print(f"no .txt fixtures found in {FIXTURES_DIR}", file=sys.stderr)
        return 2

    print(f"base URL: {BASE_URL}", file=sys.stderr)
    print(f"models: {MODELS}", file=sys.stderr)
    print(f"fixtures: {[p.name for p in fixture_paths]}", file=sys.stderr)

    results = run_bakeoff(MODELS, fixture_paths, system_prompt)
    summaries = summarize(results, MODELS)
    write_reports(results, fixture_paths, summaries, MODELS, OUT_DIR)

    print("\n=== Summary ===", file=sys.stderr)
    for m in MODELS:
        s = summaries[m]
        print(
            f"{m}: facts={s.total_facts} malformed_rate={s.malformed_rate:.0%} "
            f"ungrounded_rate={s.ungrounded_rate:.0%} call_failures={s.fixtures_call_failed}",
            file=sys.stderr,
        )
    print(f"\nHTML report written to: {OUT_DIR / 'index.html'}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
