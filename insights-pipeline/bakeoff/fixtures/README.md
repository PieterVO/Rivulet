# Bake-off fixtures

Real, recognizable content (The Office US, Silo) so extracted facts are easy to sanity-check
by eye. Each is encyclopedia-style prose approximating Wikipedia/Fandom sections, with real
verifiable facts plus deliberate spoiler and hedge test cases.

- `01_the_office_production.txt` — production/casting prose. Tests: production/casting/adaptation
  categories; a hedged claim ("difficult to verify" re: Carell's exit) that must stay hedged;
  a spoiler-1 finale reveal (Michael's cameo) that must be tagged.
- `02_silo_production.txt` — production/casting/adaptation. Tests: adaptation-from-novels facts;
  a hedged streaming-figures claim; the "cleaning" motif (spoiler-adjacent, level 1).
- `03_the_office_episode_dinner_party.txt` — single episode. Tests: episode-level production
  facts, plot-detail spoiler tagging (the TV-through-screen moment = spoiler 1).
- `04_silo_lore_spoilers.txt` — spoiler-rich lore. Tests: heavy spoiler-1 (season finale reveal:
  the outside view is faked; other silos exist) AND spoiler-2 (book reveals beyond the show);
  hedged fan-theory sentences that must stay hedged, not stated as fact.
- `05_silo_thin_stub.txt` — near-empty stub. Tests: thin-source-thin-output (should yield ~1
  fact or zero; must NOT pad).
