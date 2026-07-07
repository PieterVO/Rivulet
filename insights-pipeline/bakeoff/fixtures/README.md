# Bake-off fixtures

Five hand-written excerpts, each modeled on the real structure/tone of Wikipedia or Fandom prose
(not copy-pasted from either — original text written for this harness) but grounded in real,
verifiable facts about real productions. Each targets a different extraction failure mode.

## 01_popular_movie_inception.txt
A dense, well-sourced Production + Casting section for a popular, heavily-documented film
(Inception, 2010). Tests: can the model pull a **high volume** of distinct facts out of a long,
information-dense passage without duplicating or merging unrelated facts, and does it correctly
split multi-clause sentences into one self-contained fact each (e.g. the rotating-corridor set
description contains three separable facts: practical build, full 360-degree rotation, cameras
bolted to the structure).

## 02_obscure_older_film.txt
A film noir (Detour, 1945) with thin, contested documentation: conflicting budget estimates, an
unverifiable claim about on-set friction between the two leads ("difficult to verify and is often
repeated without a clear original source"), and production folklore. Tests: does the model
correctly hedge or drop claims the source text itself flags as unverified, rather than restating
them as settled fact. This is the key hallucination/over-confidence trap in the set.

## 03_tv_episode_page.txt
A TV episode page (a Breaking Bad episode, structured as Plot / Production / Reception) with a
significant amount of **plot spoiler** content (character deaths, betrayals, the episode's
climax) plus separate low-spoiler Production/Reception facts (writer, director, awards, the title's
literary reference). Tests: correct `spoiler` tagging — plot-critical facts should be tagged
`spoiler: 1` (this title's own plot) while behind-the-scenes/awards/reception facts should be
`spoiler: 0`, and the model should not spoiler-tag production trivia just because it appears in
the same passage as plot spoilers.

## 04_lore_heavy_franchise_wiki.txt
A lore/wiki-style page (Game of Thrones' Night King) that is spoiler-dense by nature (it exists to
explain backstory and a major character death) and explicitly contains an **unconfirmed fan
theory**, clearly flagged as such in the source ("Some fan theories have speculated... though the
show itself never confirms"). Tests: (a) the `lore` category is used appropriately, (b) the model
does not launder the fan theory into a stated fact — it should either omit it, or extract it
correctly hedged as "fans have theorized," never as "the captive was a Stark ancestor" stated
plainly, and (c) since this entire page is about a major character's origin, backstory, and death,
most/all facts should be tagged `spoiler: 1` or higher, not `0`.

## 05_thin_near_empty_page.txt
A near-stub page for an obscure, minor film with almost no real content (title, cast, runtime, a
one-sentence plot, a one-sentence release note, and a "this article is a stub" notice). Tests: does
the model correctly emit only a handful of thin facts (or very few) instead of **inventing**
material to pad out a response, and does it correctly ignore the boilerplate stub/expansion notice
rather than treating it as a fact about the film.
