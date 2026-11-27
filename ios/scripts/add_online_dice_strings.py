"""Add the #272 strings (the online game's shared weighted-dice tag + card, and the two
Game Center exchange push texts) to ios/TavliApp/TavliApp/Localizable.xcstrings in
de / nl / el / fa. Idempotent: existing keys are overwritten with these values. The two
push keys are only used by GameKit (`sendExchange` / `reply` message keys), never by
`String(localized:)`, so they are marked "manual" to keep Xcode from flagging them stale.
Greek and Persian await native-speaker review, like the rest of those catalogs
(glossaries in Views/REFERENCE.md)."""
import json
import pathlib

CATALOG = pathlib.Path(__file__).resolve().parents[1] / "TavliApp/TavliApp/Localizable.xcstrings"

STRINGS = {
    "Fair dice": {
        "de": "Faire Würfel",
        "nl": "Eerlijke dobbelstenen",
        "el": "Δίκαια ζάρια",
        "fa": "تاس منصفانه",
    },
    "Fair": {
        "de": "Fair",
        "nl": "Eerlijk",
        "el": "Δίκαια",
        "fa": "منصفانه",
    },
    "Favours you · %@": {
        "de": "Begünstigt dich · %@",
        "nl": "In jouw voordeel · %@",
        "el": "Ευνοεί εσένα · %@",
        "fa": "به نفع تو، %@",
    },
    "Favours %@ · %@": {
        "de": "Begünstigt %1$@ · %2$@",
        "nl": "In het voordeel van %1$@ · %2$@",
        "el": "Ευνοεί: %1$@ · %2$@",
        "fa": "به نفع %1$@، %2$@",
    },
    "Weighted dice: %@": {
        "de": "Gewichtete Würfel: %@",
        "nl": "Gewogen dobbelstenen: %@",
        "el": "Ευνοϊκά ζάρια: %@",
        "fa": "تاس‌های وزن‌دار: %@",
    },
    "Shared with %@": {
        "de": "Gemeinsam mit %@",
        "nl": "Gedeeld met %@",
        "el": "Κοινά με: %@",
        "fa": "مشترک با %@",
    },
    "Good rolls for one side are bad rolls for the other. Either of you can change it; it counts for both players from the next roll.": {
        "de": "Gute Würfe für die eine Seite sind schlechte für die andere. Jeder von euch kann es ändern; es gilt für beide ab dem nächsten Wurf.",
        "nl": "Goede worpen voor de een zijn slechte voor de ander. Jullie kunnen het allebei veranderen; het geldt voor beide spelers vanaf de volgende worp.",
        "el": "Οι καλές ζαριές για τη μία πλευρά είναι κακές για την άλλη. Μπορεί να το αλλάξει οποιοσδήποτε από τους δύο· ισχύει και για τους δύο παίκτες από την επόμενη ζαριά.",
        "fa": "تاس خوب برای یک طرف، تاس بد برای طرف دیگر است. هر کدام از شما می‌تواند آن را تغییر دهد؛ از تاس بعدی برای هر دو بازیکن اعمال می‌شود.",
    },
    "Other handicaps are only for games on this device.": {
        "de": "Andere Handicaps gibt es nur für Spiele auf diesem Gerät.",
        "nl": "Andere handicaps zijn er alleen voor spellen op dit apparaat.",
        "el": "Τα άλλα χάντικαπ υπάρχουν μόνο για παιχνίδια σε αυτή τη συσκευή.",
        "fa": "هندیکپ‌های دیگر فقط برای بازی‌های روی همین دستگاه هستند.",
    },
    "Weighted dice need the computer’s model for this variant.": {
        "de": "Gewichtete Würfel brauchen das Computermodell für diese Variante.",
        "nl": "Gewogen dobbelstenen hebben het computermodel voor deze variant nodig.",
        "el": "Τα ευνοϊκά ζάρια χρειάζονται το μοντέλο του υπολογιστή για αυτή την παραλλαγή.",
        "fa": "تاس‌های وزن‌دار برای این نوع بازی به مدل کامپیوتر نیاز دارند.",
    },
    "Sent to %@. It counts from their next roll once it arrives, and from your next roll at the latest.": {
        "de": "An %@ gesendet. Es gilt ab dem nächsten Wurf der Gegenseite, sobald es ankommt, spätestens ab deinem nächsten Wurf.",
        "nl": "Verstuurd naar %@. Het geldt vanaf hun volgende worp zodra het aankomt, en uiterlijk vanaf jouw volgende worp.",
        "el": "Στάλθηκε: %@. Ισχύει από την επόμενη ζαριά του αντιπάλου μόλις φτάσει, και το αργότερο από τη δική σου επόμενη ζαριά.",
        "fa": "برای %@ فرستاده شد. وقتی برسد از تاس بعدی او اعمال می‌شود و حداکثر از تاس بعدی خودت.",
    },
    "Last changed by you.": {
        "de": "Zuletzt von dir geändert.",
        "nl": "Het laatst door jou gewijzigd.",
        "el": "Τελευταία αλλαγή από εσένα.",
        "fa": "آخرین تغییر را تو دادی.",
    },
    "Last changed by %@.": {
        "de": "Zuletzt von %@ geändert.",
        "nl": "Het laatst gewijzigd door %@.",
        "el": "Τελευταία αλλαγή από: %@.",
        "fa": "آخرین تغییر را %@ داد.",
    },
    # Game Center exchange push texts (GameKit message keys).
    "%@ changed the shared dice.": {
        "de": "%@ hat die gemeinsamen Würfel geändert.",
        "nl": "%@ heeft de gedeelde dobbelstenen aangepast.",
        "el": "%@: άλλαξαν τα κοινά ζάρια.",
        "fa": "%@ تاس‌های مشترک را تغییر داد.",
    },
    "The shared dice were updated.": {
        "de": "Die gemeinsamen Würfel wurden aktualisiert.",
        "nl": "De gedeelde dobbelstenen zijn bijgewerkt.",
        "el": "Τα κοινά ζάρια ενημερώθηκαν.",
        "fa": "تاس‌های مشترک به‌روز شدند.",
    },
}

MANUAL = {"%@ changed the shared dice.", "The shared dice were updated."}


def main() -> None:
    raw = CATALOG.read_text(encoding="utf-8")
    data = json.loads(raw)
    strings = data["strings"]
    for key, langs in STRINGS.items():
        entry = strings.setdefault(key, {})
        if key in MANUAL:
            entry["extractionState"] = "manual"
        locs = entry.setdefault("localizations", {})
        for lang, value in langs.items():
            locs[lang] = {"stringUnit": {"state": "translated", "value": value}}
        # Xcode keeps a key's languages sorted; match it so the diff stays minimal.
        entry["localizations"] = dict(sorted(locs.items()))
        strings[key] = dict(sorted(entry.items()))
    text = json.dumps(data, ensure_ascii=False, indent=2, separators=(",", " : "))
    if raw.endswith("\n"):
        text += "\n"
    CATALOG.write_text(text, encoding="utf-8")
    print(f"added/updated {len(STRINGS)} keys")


if __name__ == "__main__":
    main()
