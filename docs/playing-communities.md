# Playing communities: who plays our three games, and under what names

Research notes from 2026-11-23, made while drafting the App Store listing (#184). This is the
background for the multi-community epic #248. **Current
focus is the Greek set (tavli). Nothing here is planned work yet.**

## Summary

Tavtav plays the three Greek games of **tavli**: Portes, Plakoto and Fevga. Each has close
relatives elsewhere, played under other names and with small rule differences:

| Our game | Same or very close game | Where | Known rule differences (vs ours) |
|---|---|---|---|
| **Portes** (backgammon with hitting, no cube) | **Takhteh nard** / takhteh (Iran) · **Tavla** (Turkey) · **'Aada** ("regular" tawla, Egypt) · shesh besh (Levant, Israel) | Iran, Turkey, the Arab world, Israel; standard backgammon generally | Takhteh = Tavla (identical rule lists on bkgm). Both add: **no hit-and-run in your own home board**; **no needless pip-wasting in bear-off**; a checker hit during bear-off must re-enter and come home before bearing off resumes. Same as Portes: opening winner rerolls, 1 point or 2 for a gammon, no triple, no cube. Our Portes doesn't enforce the hit-and-run rule (`docs/variants/portes.md` item 11, "not adopted"). |
| **Plakoto** (pinning, no hitting) | **Tapa** (Bulgaria, North Macedonia) · **Tsillitón** (Cyprus) · **Mahbusa / Mahbouseh / Mahbousa** (Arabic: Egypt, Syria, Lebanon) | Balkans, Cyprus, the Arab world | Tapa: **no "mother" checker rule**, usually only 2 checkers placed at the start, played as the 3rd game of a match (Wikipedia). Mahbusa: trapped-checker game described in Egyptian/Arab sources; exact rule differences vs Plakoto not established. Evidence that it's played in **Turkey** is weak (one primer). |
| **Fevga** (same-direction race, no hitting, one checker holds a point) | **Long nardy** / Narde (Russia and the ex-USSR incl. the Caucasus) · **Moultezim** (Turkey) · **Tawla 31 / Maghribiyyah** (Egypt, Lebanon) · Gul bara / Gülbahar (related) | Russia, Caucasus, Central Asia, Turkey, the Arab world | Long nardy: only **one checker may leave the head per turn** (two on the first roll), no six-prime in front of all opposing checkers, 1 point or 2 ("mars"). Moultezim: players roll for first play, no limit on primes. Tawla 31: the winner scores the opponent's checkers left on the board, set to 31 points. Gul bara: doublets are very powerful (repeated sequences). |

## By community

- **Greek (Greece, Cyprus, diaspora):** the full tavli set (Portes → Plakoto → Fevga, to
  5 or 7 points). Our current target.
- **Iranian (Persian):** **takhteh nard** = Portes with the two extra rules above. No sign
  that Plakoto- or Fevga-like games are played there. Note that Iranica says regional variants
  were never systematically recorded, so small local games can't be ruled out. Persian UI
  already ships (RTL, #185).
- **Arabic-speaking (Egypt, Levant: Syria, Lebanon):** the closest match to the full set
  outside Greece. Egypt's five common tawla games are **'Aada** (≈ Portes), **Mahbousa**
  (≈ Plakoto), **31** (no-hitting race, related to Fevga), **Gulbehar** (diagonal start,
  powerful doubles) and **Al-Yahudiyya** (a simple half-board game for children). Needs Arabic
  (RTL; the Persian RTL work carries over).
- **Turkish:** **tavla** (= takhteh rules) is played everywhere (cafés, homes, parks);
  **Moultezim** (≈ Fevga) is recorded as "still played". Mahbusa in Turkey: unconfirmed.
- **Russian-speaking / ex-USSR / Caucasus (Russia, Georgia, Armenia, Azerbaijan, Central
  Asia):** "nardy" usually means **long nardy** (≈ Fevga), plus "short nardy" (≈ backgammon).
  Note that **"nard" means backgammon (≈ Portes) to Iranians but long nardy (≈ Fevga) in
  Russian**.
- **Bulgarian / North Macedonian:** **Tapa** (≈ Plakoto) within their own tables set.
- **Others listed for tavli** (Wikipedia): Serbia, Croatia, Bosnia and Herzegovina, Iraq,
  Azerbaijan. No detail found.

## Implications for the app (for the epic)

- **Names:** each community looks for its own names. Cheap first step: keywords and in-app
  aliases ("Portes (takhteh, tavla)").
- **Rule variants:**
  - **Small switches on an existing game:** Takhteh/Tavla's hit-and-run and pip-waste rules
    on Portes; Tapa's no-mother rule on Plakoto. These change legal moves, so the current
    models may be slightly off-distribution. Measure before shipping.
  - **New games** that need their own move generator and model: long nardy, Moultezim,
    Tawla 31 (different scoring), Gul bara/Gulbehar.
  - Model policy: separate rule sets need separate trained models (as for the variants
    today); see `ios/CLAUDE.md` / `ModelCatalog`.
- **Languages:** Arabic (RTL), Turkish, Russian, Bulgarian would follow. Persian already
  exists.
- **Listing wording (decision 2026-11-23):** the listing makes **no cultural-insider claims**
  (the author loves the game but isn't part of the Greek community), at most a factual line
  with the other names.

## Caveats

- Sources are mostly bkgm.com ("Backgammon Galore", a long-running rules reference) and
  Wikipedia, plus Egyptian press. Some claims rest on a single source (marked above).
- No reliable numbers on how many people play which game where. "Popular" means "described
  as common", not measured.
- Iran-specific and Turkey-today sources were thin. Native players in each community should
  confirm the rules before we build anything.

## Sources

- bkgm.com: [Takhteh](https://www.bkgm.com/variants/Takhteh.html) ·
  [Tavla](https://www.bkgm.com/variants/Tavla.html) ·
  [Portes](https://www.bkgm.com/variants/Portes.html) ·
  [Plakoto](https://www.bkgm.com/variants/Plakoto.html) ·
  [Narde](https://bkgm.com/variants/Narde.html) ·
  [Gul bara](https://bkgm.com/variants/GulBara.html)
- Wikipedia: [Tavli](https://en.wikipedia.org/wiki/Tavli) ·
  [Plakoto / Tapa](https://en.wikipedia.org/wiki/Plakoto) ·
  [Fevga](https://en.wikipedia.org/wiki/Fevga) ·
  [Long Nardy](https://en.wikipedia.org/wiki/Long_Nardy) ·
  [Nard](https://en.wikipedia.org/wiki/Nard_(game))
- Egypt: [Egyptian Streets, Egypt's 5 most common tawla games (2022)](https://egyptianstreets.com/2022/09/10/sheesh-beesh-egypts-5-most-common-tawla-games-and-how-theyre-played/) ·
  [Egypt Independent, Tawla](https://egyptindependent.com/tawla-tale-strategy/)
- [Encyclopedia.com, Sheshbesh](https://www.encyclopedia.com/humanities/encyclopedias-almanacs-transcripts-and-maps/sheshbesh)
  (names in Syria/Arabia, incl. mahbusa)
- [Encyclopaedia Iranica](https://www.iranicaonline.org/?p=1549) (Iranian board games, variants
  not systematically recorded)
- [GNU bug-gnubg list, backgammon variants (2011)](https://lists.gnu.org/archive/html/bug-gnubg/2011-06/msg00012.html)
