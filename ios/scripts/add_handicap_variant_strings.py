"""Add the #246 strings (handicaps in every variant and across Full Tavli: the builder's
per-variant applicability note, disabled-item reasons, the "not measured yet" estimate, the
card's carry-over line) to ios/TavliApp/TavliApp/Localizable.xcstrings in de / nl / el / fa,
and drop the keys #246 replaced. Idempotent: existing keys are overwritten with these
values. Greek and Persian await native-speaker review, like the rest of those catalogs
(glossaries in Views/REFERENCE.md)."""
import json
import pathlib

CATALOG = pathlib.Path(__file__).resolve().parents[1] / "TavliApp/TavliApp/Localizable.xcstrings"

STRINGS = {
    "Not measured yet for %@.": {
        "de": "Für %@ noch nicht gemessen.",
        "nl": "Nog niet gemeten voor %@.",
        "el": "Δεν έχει μετρηθεί ακόμα για %@.",
        "fa": "هنوز برای %@ اندازه‌گیری نشده.",
    },
    "Not measured yet for Full Tavli.": {
        "de": "Für Full Tavli noch nicht gemessen.",
        "nl": "Nog niet gemeten voor Full Tavli.",
        "el": "Δεν έχει μετρηθεί ακόμα για το Πλήρες Τάβλι.",
        "fa": "هنوز برای تاولی کامل اندازه‌گیری نشده.",
    },
    "Starts every game of Full Tavli; no opening roll.": {
        "de": "Beginnt jedes Spiel von Full Tavli; kein Eröffnungswurf.",
        "nl": "Begint elk spel van Full Tavli; geen openingsworp.",
        "el": "Ξεκινά κάθε παιχνίδι του Πλήρους Τάβλι, χωρίς ζαριά έναρξης.",
        "fa": "هر بازیِ تاولی کامل را شروع می‌کند؛ بدون تاس شروع.",
    },
    "Plakoto (house rules), single or Best of 3: every item.": {
        "de": "Plakoto (Hausregeln), einzeln oder Best of 3: alles.",
        "nl": "Plakoto (huisregels), los of Best of 3: alles.",
        "el": "Πλακωτό (κανόνες σπιτιού), μονό ή 2 στα 3: όλα.",
        "fa": "پلاکوتو (قوانین خانگی)، تک‌بازی یا بهترین از ۳: همه موارد.",
    },
    "Standard Plakoto, Fevga, Portes and Full Tavli: weighted dice, rerolls, hints and moves first.": {
        "de": "Standard-Plakoto, Fevga, Portes und Full Tavli: gewichtete Würfel, Neuwürfe, Tipps und „Beginnt“.",
        "nl": "Standaard Plakoto, Fevga, Portes en Full Tavli: gewogen dobbelstenen, opnieuw gooien, hints en ‘Begint’.",
        "el": "Στάνταρ Πλακωτό, Φεύγα, Πόρτες και Πλήρες Τάβλι: ευνοϊκά ζάρια, νέες ζαριές, βοήθειες και «Ξεκινά».",
        "fa": "پلاکوتوی استاندارد، فوگا، پورتس و تاولی کامل: تاس‌های وزن‌دار، تاس دوباره، راهنمایی‌ها و «اول حرکت می‌کند».",
    },
    "Offline games only.": {
        "de": "Nur Offline-Spiele.",
        "nl": "Alleen offline potjes.",
        "el": "Μόνο παιχνίδια εκτός σύνδεσης.",
        "fa": "فقط بازی‌های آفلاین.",
    },
    "Off in Full Tavli: only in Plakoto (house rules), single game or Best of 3.": {
        "de": "Aus in Full Tavli: nur in Plakoto (Hausregeln), Einzelspiel oder Best of 3.",
        "nl": "Uit in Full Tavli: alleen in Plakoto (huisregels), enkel spel of Best of 3.",
        "el": "Ανενεργό στο Πλήρες Τάβλι: μόνο στο Πλακωτό (κανόνες σπιτιού), ένα παιχνίδι ή 2 στα 3.",
        "fa": "در تاولی کامل خاموش است: فقط در پلاکوتو (قوانین خانگی)، تک‌بازی یا بهترین از ۳.",
    },
    "Off in %@: only in Plakoto (house rules).": {
        "de": "Aus in %@: nur in Plakoto (Hausregeln).",
        "nl": "Uit in %@: alleen in Plakoto (huisregels).",
        "el": "Ανενεργό (%@): μόνο στο Πλακωτό (κανόνες σπιτιού).",
        "fa": "در %@ خاموش است: فقط در پلاکوتو (قوانین خانگی).",
    },
    "Your next game is %@: the head start and rule changes are left out.": {
        "de": "Dein nächstes Spiel ist %@: Vorsprung und Regeländerungen entfallen.",
        "nl": "Je volgende spel is %@: voorsprong en regelwijzigingen vervallen.",
        "el": "Το επόμενο παιχνίδι σου είναι %@: το προβάδισμα και οι αλλαγές κανόνων παραλείπονται.",
        "fa": "بازی بعدی‌ات %@ است: شروع جلوتر و تغییر قوانین حذف می‌شوند.",
    },
    "Changes count from the next roll and carry over to the next games of a Best of 3 or Full Tavli.": {
        "de": "Änderungen gelten ab dem nächsten Wurf und für die weiteren Spiele eines Best of 3 oder von Full Tavli.",
        "nl": "Wijzigingen gelden vanaf de volgende worp en voor de volgende potjes van een Best of 3 of Full Tavli.",
        "el": "Οι αλλαγές ισχύουν από την επόμενη ζαριά και για τα επόμενα παιχνίδια ενός 2 στα 3 ή του Πλήρους Τάβλι.",
        "fa": "تغییرات از تاس بعدی اعمال می‌شوند و در بازی‌های بعدی «بهترین از ۳» یا تاولی کامل هم می‌مانند.",
    },
}
OBSOLETE = [
    "Applies to offline games of Plakoto (house rules), single or Best of 3. Not online or Full Tavli.",
    "Changes count from the next roll and carry over to the next games of a Best of 3.",
]


def main() -> None:
    raw = CATALOG.read_text(encoding="utf-8")
    data = json.loads(raw)
    strings = data["strings"]
    for key in OBSOLETE:
        strings.pop(key, None)
    for key, langs in STRINGS.items():
        entry = strings.setdefault(key, {})
        locs = entry.setdefault("localizations", {})
        for lang, value in langs.items():
            locs[lang] = {"stringUnit": {"state": "translated", "value": value}}
        # Xcode keeps a key's languages sorted; match it so the diff stays minimal.
        entry["localizations"] = dict(sorted(locs.items()))
    text = json.dumps(data, ensure_ascii=False, indent=2, separators=(",", " : "))
    if raw.endswith("\n"):
        text += "\n"
    CATALOG.write_text(text, encoding="utf-8")
    print(f"added/updated {len(STRINGS)} keys, removed {len(OBSOLETE)} replaced ones")


if __name__ == "__main__":
    main()
