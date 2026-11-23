"""Add the #236 strings (handicap button + adjustable handicap card, My Record tag) to
ios/TavliApp/TavliApp/Localizable.xcstrings in de / nl / el / fa. Idempotent: existing
keys are overwritten with these values. Greek and Persian await native-speaker review,
like the rest of those catalogs (glossaries in Views/REFERENCE.md)."""
import json
import pathlib

CATALOG = pathlib.Path(__file__).resolve().parents[1] / "TavliApp/TavliApp/Localizable.xcstrings"

STRINGS = {
    "Handicap, even": {
        "de": "Handicap, ausgeglichen",
        "nl": "Handicap, in evenwicht",
        "el": "Χάντικαπ, ισορροπημένο",
        "fa": "هندیکپ، متعادل",
    },
    "Handicap, favours %@": {
        "de": "Handicap, begünstigt %@",
        "nl": "Handicap, in het voordeel van %@",
        "el": "Χάντικαπ, ευνοεί: %@",
        "fa": "هندیکپ، به نفع %@",
    },
    "Favours %@": {
        "de": "Begünstigt %@",
        "nl": "In het voordeel van %@",
        "el": "Ευνοεί: %@",
        "fa": "به نفع %@",
    },
    "Evenly balanced": {
        "de": "Ausgeglichen",
        "nl": "In evenwicht",
        "el": "Ισορροπημένο",
        "fa": "متعادل",
    },
    "Set at the start": {
        "de": "Zu Beginn festgelegt",
        "nl": "Bij de start vastgelegd",
        "el": "Ορίστηκαν στην αρχή",
        "fa": "تعیین‌شده در شروع بازی",
    },
    "These can't change during a game.": {
        "de": "Diese lassen sich während eines Spiels nicht ändern.",
        "nl": "Deze kunnen tijdens een potje niet veranderen.",
        "el": "Αυτά δεν αλλάζουν κατά τη διάρκεια του παιχνιδιού.",
        "fa": "این‌ها در طول بازی تغییر نمی‌کنند.",
    },
    "Rerolls left": {
        "de": "Neuwürfe übrig",
        "nl": "Keer opnieuw gooien over",
        "el": "Νέες ζαριές που απομένουν",
        "fa": "تاس دوبارهٔ باقی‌مانده",
    },
    "Hints left": {
        "de": "Tipps übrig",
        "nl": "Hints over",
        "el": "Βοήθειες που απομένουν",
        "fa": "راهنمایی‌های باقی‌مانده",
    },
    "1 adjusted during the game": {
        "de": "1 während des Spiels angepasst",
        "nl": "1 tijdens het potje aangepast",
        "el": "1 προσαρμόστηκε κατά το παιχνίδι",
        "fa": "۱ مورد در طول بازی تغییر کرد",
    },
    "%lld adjusted during the game": {
        "de": "%lld während des Spiels angepasst",
        "nl": "%lld tijdens het potje aangepast",
        "el": "%lld προσαρμόστηκαν κατά το παιχνίδι",
        "fa": "%lld مورد در طول بازی تغییر کرد",
    },
}


def main() -> None:
    data = json.loads(CATALOG.read_text(encoding="utf-8"))
    strings = data["strings"]
    for key, langs in STRINGS.items():
        entry = strings.setdefault(key, {})
        locs = entry.setdefault("localizations", {})
        for lang, value in langs.items():
            locs[lang] = {"stringUnit": {"state": "translated", "value": value}}
        # Xcode keeps a key's languages sorted; match it so the diff stays minimal.
        entry["localizations"] = dict(sorted(locs.items()))
    text = json.dumps(data, ensure_ascii=False, indent=2, separators=(",", " : "))
    CATALOG.write_text(text, encoding="utf-8")  # Xcode writes no trailing newline
    print(f"added/updated {len(STRINGS)} keys")


if __name__ == "__main__":
    main()
