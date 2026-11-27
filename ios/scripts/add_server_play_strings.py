"""Add the #286 strings (online play through the server: the server lobby, server error
copy, the failed server roll) to ios/TavliApp/TavliApp/Localizable.xcstrings in
de / nl / el / fa. Idempotent: existing keys are overwritten with these values. Greek and
Persian await native-speaker review, like the rest of those catalogs (glossaries in
Views/REFERENCE.md). The developer switch "Play online via the server" is not localized
(verbatim text, like the other developer cards)."""
import json
import pathlib

CATALOG = pathlib.Path(__file__).resolve().parents[1] / "TavliApp/TavliApp/Localizable.xcstrings"

STRINGS = {
    "Couldn’t get your dice from the server. Tap the dice to try again.": {
        "de": "Deine Würfel kamen nicht vom Server. Tippe die Würfel an, um es noch einmal zu versuchen.",
        "nl": "Je dobbelstenen kwamen niet van de server. Tik op de dobbelstenen om het opnieuw te proberen.",
        "el": "Τα ζάρια σου δεν ήρθαν από τον διακομιστή. Πάτα τα ζάρια για να δοκιμάσεις ξανά.",
        "fa": "تاس‌هایت از سرور نرسید. دوباره روی تاس بزن.",
    },
    "Couldn’t reach the server. Check your connection and try again.": {
        "de": "Der Server ist nicht erreichbar. Prüfe deine Verbindung und versuche es noch einmal.",
        "nl": "De server is niet bereikbaar. Controleer je verbinding en probeer het opnieuw.",
        "el": "Δεν ήταν δυνατή η σύνδεση με τον διακομιστή. Έλεγξε τη σύνδεσή σου και δοκίμασε ξανά.",
        "fa": "به سرور دسترسی نیست. اتصالت را بررسی کن و دوباره امتحان کن.",
    },
    "Please sign in to your online account again.": {
        "de": "Bitte melde dich erneut bei deinem Online-Konto an.",
        "nl": "Log opnieuw in op je online-account.",
        "el": "Συνδέσου ξανά στον λογαριασμό σου online.",
        "fa": "لطفاً دوباره وارد حساب آنلاینت شو.",
    },
    "That player or game wasn’t found.": {
        "de": "Dieser Spieler oder diese Partie wurde nicht gefunden.",
        "nl": "Die speler of partij is niet gevonden.",
        "el": "Ο παίκτης ή η παρτίδα δεν βρέθηκε.",
        "fa": "این بازیکن یا بازی پیدا نشد.",
    },
    "This game is over.": {
        "de": "Diese Partie ist vorbei.",
        "nl": "Deze partij is afgelopen.",
        "el": "Αυτή η παρτίδα τελείωσε.",
        "fa": "این بازی تمام شده است.",
    },
    "Too many requests. Please wait a minute.": {
        "de": "Zu viele Anfragen. Bitte warte eine Minute.",
        "nl": "Te veel verzoeken. Wacht even een minuut.",
        "el": "Πάρα πολλά αιτήματα. Περίμενε ένα λεπτό.",
        "fa": "درخواست‌ها زیاد است. لطفاً یک دقیقه صبر کن.",
    },
    "Challenge a player": {
        "de": "Spieler herausfordern",
        "nl": "Daag een speler uit",
        "el": "Πρόκληση σε παίκτη",
        "fa": "به چالش کشیدن یک بازیکن",
    },
    "Your player ID: %@": {
        "de": "Deine Spieler-ID: %@",
        "nl": "Je speler-ID: %@",
        "el": "Το αναγνωριστικό παίκτη σου: %@",
        "fa": "شناسهٔ بازیکن تو: %@",
    },
    "Copy": {
        "de": "Kopieren",
        "nl": "Kopiëren",
        "el": "Αντιγραφή",
        "fa": "کپی",
    },
    "Player ID": {
        "de": "Spieler-ID",
        "nl": "Speler-ID",
        "el": "Αναγνωριστικό παίκτη",
        "fa": "شناسهٔ بازیکن",
    },
    "Challenge": {
        "de": "Herausfordern",
        "nl": "Uitdagen",
        "el": "Πρόκληση",
        "fa": "چالش",
    },
    "No games in progress. Challenge a player to start one.": {
        "de": "Keine laufenden Partien. Fordere einen Spieler heraus, um eine zu starten.",
        "nl": "Geen lopende partijen. Daag een speler uit om er een te starten.",
        "el": "Δεν υπάρχουν παρτίδες σε εξέλιξη. Προκάλεσε έναν παίκτη για να ξεκινήσετε μία.",
        "fa": "بازی در جریانی نداری. یک بازیکن را به چالش بکش تا بازی را شروع کنید.",
    },
    "Decline": {
        "de": "Ablehnen",
        "nl": "Weigeren",
        "el": "Απόρριψη",
        "fa": "رد کردن",
    },
    "Sign in to your online account to play through the server.": {
        "de": "Melde dich bei deinem Online-Konto an, um über den Server zu spielen.",
        "nl": "Log in op je online-account om via de server te spelen.",
        "el": "Συνδέσου στον λογαριασμό σου online για να παίξεις μέσω του διακομιστή.",
        "fa": "برای بازی از طریق سرور، وارد حساب آنلاینت شو.",
    },
    "Invited": {
        "de": "Eingeladen",
        "nl": "Uitgenodigd",
        "el": "Πρόσκληση",
        "fa": "دعوت‌شده",
    },
    "Waiting for opponent": {
        "de": "Warte auf Gegner",
        "nl": "Wachten op tegenstander",
        "el": "Αναμονή αντιπάλου",
        "fa": "در انتظار حریف",
    },
}


def main() -> None:
    raw = CATALOG.read_text(encoding="utf-8")
    data = json.loads(raw)
    strings = data["strings"]
    for key, langs in STRINGS.items():
        assert set(langs) == {"de", "nl", "el", "fa"}, key
        for lang, value in langs.items():
            assert value.count("%@") == key.count("%@"), (key, lang)
        entry = strings.setdefault(key, {})
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
