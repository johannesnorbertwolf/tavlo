# App Store listing — Tavtav v1 (#184)

Draft texts for App Store Connect, one section per locale. Limits (App Store Connect): name ≤ 30,
subtitle ≤ 30, promotional text ≤ 170, keywords ≤ 100 (comma-separated, no spaces after commas),
description ≤ 4000 characters. `docs/app-store/check_listing.py` checks them.

Words already in the name or subtitle are left out of the keywords (Apple indexes them anyway).
Greek needs a native-speaker check, like the in-app texts.

**Listing rules (decided 2026-11-23):**
- No cultural-insider claims: describe the games, not the culture.
- Values first: free, open source (AGPL-3.0, public repo), no ads, no tracking, no account, online
  or offline.
- Handicaps stay out of the listing while they are experimental.
- The drill leads the LEARN list.
- Language order: English, Greek, German, Dutch.
- **No Persian/Iran references and no Persian (fa) App Store localization** until Tavtav fully
  supports the Iranian (takhteh) rules (see `docs/playing-communities.md`, #248). The app itself
  keeps Persian, and the privacy page keeps its Persian section.
- Store name is "Tavtav: Tavli & Backgammon" (decided 2026-11-25).

## Shared fields (all locales)

| Field | Value |
|---|---|
| Primary category | Games › Board |
| Secondary category | Games › Strategy |
| Price | Free, no in-app purchases |
| Age rating | 4+ (every questionnaire item "None"; dice without betting is not simulated gambling) |
| Support URL | https://johannesnorbertwolf.github.io/tavlo/ |
| Marketing URL | https://johannesnorbertwolf.github.io/tavlo/ |
| Privacy policy URL | https://johannesnorbertwolf.github.io/tavlo/privacy.html |
| Copyright | `2026` + the name on the developer account (filled in at submission) |
| Game Center | On (online play is turn-based Game Center matches) |

**Notes for App Review** (English only):

> Tavtav is a free backgammon app for the three Greek variants (Plakoto, Fevga, Portes). No account
> or login is needed. Everything except "Play Online" works offline against an on-device neural
> network. "Play Online" uses Game Center turn-based matches: sign in to Game Center, tap
> "Invite a friend" and send the invite to a second Game Center account, or use auto-match. The
> post-game review and drill are reached from the game-over screen ("Review").

---

## English (en-US, primary)

**Name:** Tavtav: Tavli & Backgammon

**Subtitle:** Plakoto, Fevga & Portes

**Promotional text:**
Free and open source, with no ads and no account. Play Plakoto, Fevga and Portes against the computer, a friend or family online, then drill the moves you got wrong.

**Keywords:**
tavla,τάβλι,tawla,narde,mahbusa,tapa,long nardy,board game,dice,strategy,two player,offline,classic

**Description:**

```
Tavtav is free, open-source tavli. No ads, no tracking, no account, nothing to buy. Play online or offline, on iPhone and iPad.

Three games: Plakoto, Fevga and Portes. You may know them by other names: Portes is close to backgammon (tavla), Plakoto to tapa and mahbusa, Fevga to long nardy.

PLAY
• Against the computer, at eight levels
• With a friend on one iPhone or iPad
• Online with friends and family, at your own pace
• A single game, best of three, or Full Tavli: all three in a row

LEARN
• Drill the positions you got wrong until you find the better move
• A win-chance graph of every game
• Your move next to the best move
• Inaccuracies, mistakes and blunders, and an accuracy score
• How much the dice decided, and how much you did

Dark mode. English, Greek, German and Dutch.
```

---

## Greek (el) — needs a native-speaker check

**Name:** Tavtav: Τάβλι & Backgammon

**Subtitle:** Πλακωτό, Φεύγα και Πόρτες

**Promotional text:**
Δωρεάν και ανοιχτού κώδικα, χωρίς διαφημίσεις και λογαριασμό. Παίξε Πλακωτό, Φεύγα και Πόρτες με τον υπολογιστή, με φίλο ή online, και μετά εξασκήσου στα λάθη σου.

**Keywords:**
tavli,ταβλι,πλακωτο,φευγα,πορτες,επιτραπέζιο,ζάρια,στρατηγική,δύο παίκτες,offline,tavla,mahbusa,tapa

**Description:**

```
Το Tavtav είναι δωρεάν τάβλι ανοιχτού κώδικα. Χωρίς διαφημίσεις, χωρίς παρακολούθηση, χωρίς λογαριασμό, χωρίς αγορές. Παίξε online ή offline, σε iPhone και iPad.

Τρία παιχνίδια: Πλακωτό, Φεύγα και Πόρτες. Ίσως τα ξέρεις και με άλλα ονόματα: οι Πόρτες μοιάζουν με το backgammon (tavla), το Πλακωτό με το tapa και το mahbusa, η Φεύγα με το long nardy.

ΠΑΙΞΕ
• Με τον υπολογιστή, σε οκτώ επίπεδα
• Με φίλο στο ίδιο iPhone ή iPad
• Online με φίλους και οικογένεια, με τον δικό σου ρυθμό
• Ένα παιχνίδι, 2 στα 3, ή Πλήρες Τάβλι: και τα τρία στη σειρά

ΜΑΘΕ
• Εξάσκηση: ξαναπαίξε τις θέσεις όπου έκανες λάθος, μέχρι να βρεις την καλύτερη κίνηση
• Γράφημα με την πιθανότητα νίκης σε κάθε παρτίδα
• Η κίνησή σου δίπλα στην καλύτερη
• Ανακρίβειες, λάθη και γκάφες, και βαθμός ακρίβειας
• Πόσο έκριναν τα ζάρια και πόσο εσύ

Σκοτεινή λειτουργία. Στα αγγλικά, ελληνικά, γερμανικά και ολλανδικά.
```

---

## German (de-DE)

**Name:** Tavtav: Tavli & Backgammon

**Subtitle:** Plakoto, Fevga und Portes

**Promotional text:**
Kostenlos und Open Source, ohne Werbung und ohne Konto. Spiele Plakoto, Fevga und Portes gegen den Computer, zu zweit oder online – und übe danach deine Fehler.

**Keywords:**
tavla,τάβλι,puff,brettspiel,würfelspiel,strategie,zwei spieler,offline,mahbusa,tapa,long nardy

**Description:**

```
Tavtav ist kostenloses Open-Source-Tavli. Keine Werbung, kein Tracking, kein Konto, nichts zu kaufen. Spiele online oder offline, auf iPhone und iPad.

Drei Spiele: Plakoto, Fevga und Portes. Vielleicht kennst du sie unter anderen Namen: Portes ähnelt Backgammon (Tavla), Plakoto Tapa und Mahbusa, Fevga Long Nardy.

SPIELEN
• Gegen den Computer, in acht Stufen
• Zu zweit auf einem iPhone oder iPad
• Online mit Freunden und Familie, in deinem Tempo
• Ein Spiel, Best of 3 oder Full Tavli: alle drei hintereinander

LERNEN
• Drill: Übe die Stellungen, in denen du danebenlagst, bis du den besseren Zug findest
• Ein Gewinnchancen-Graph jeder Partie
• Dein Zug neben dem besten Zug
• Ungenauigkeiten, Fehler und grobe Patzer, dazu eine Genauigkeit in Prozent
• Wie viel die Würfel entschieden haben und wie viel du

Dark Mode. Auf Englisch, Griechisch, Deutsch und Niederländisch.
```

---

## Dutch (nl-NL)

**Name:** Tavtav: Tavli & Backgammon

**Subtitle:** Plakoto, Fevga en Portes

**Promotional text:**
Gratis en open source, zonder advertenties en zonder account. Speel Plakoto, Fevga en Portes tegen de computer, met z'n tweeën of online, en oefen daarna je fouten.

**Keywords:**
tavla,τάβλι,bordspel,dobbelstenen,strategie,twee spelers,offline,klassiek,triktrak,mahbusa,tapa

**Description:**

```
Tavtav is gratis, opensource tavli. Geen advertenties, geen tracking, geen account, niets te koop. Speel online of offline, op iPhone en iPad.

Drie spellen: Plakoto, Fevga en Portes. Misschien ken je ze onder andere namen: Portes lijkt op backgammon (tavla), Plakoto op tapa en mahbusa, Fevga op long nardy.

SPELEN
• Tegen de computer, op acht niveaus
• Met z'n tweeën op één iPhone of iPad
• Online met vrienden en familie, in je eigen tempo
• Eén spel, best of 3, of Full Tavli: alle drie achter elkaar

LEREN
• Drill: oefen de stellingen waarin je de mist inging, tot je de betere zet vindt
• Een winstkansgrafiek van elke partij
• Jouw zet naast de beste zet
• Onnauwkeurigheden, fouten en blunders, en een nauwkeurigheidsscore
• Hoeveel de dobbelstenen bepaalden, en hoeveel jij

Donkere modus. In het Engels, Grieks, Duits en Nederlands.
```
