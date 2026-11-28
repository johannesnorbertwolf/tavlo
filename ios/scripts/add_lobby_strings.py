"""Add the #287 strings (the server lobby, new online game, invite sheet, join with a code,
invite/push error copy, and the push texts) to ios/TavliApp/TavliApp/Localizable.xcstrings
in de / nl / el / fa, and drop the #286 developer-lobby strings it replaced. Idempotent:
existing keys are overwritten with these values. Greek and Persian await native-speaker
review, like the rest of those catalogs (glossaries in Views/REFERENCE.md).

The `PUSH_*` keys are the server's APNs `loc-key`s (server/src/push.ts): iOS renders them
from the app's strings with the other player's name as `%@`, so they carry an English value
too and are marked manual (never extracted from code, never stale)."""
import json
import pathlib

CATALOG = pathlib.Path(__file__).resolve().parents[1] / "TavliApp/TavliApp/Localizable.xcstrings"

# Push texts: key → en, de, nl, el, fa.
PUSH = {
    "PUSH_YOUR_TURN": {
        "en": "Your turn against %@.",
        "de": "Du bist dran gegen %@.",
        "nl": "Jouw beurt tegen %@.",
        "el": "Σειρά σου στην παρτίδα με %@.",
        "fa": "نوبت توست در بازی با %@.",
    },
    "PUSH_INVITE_RECEIVED": {
        "en": "%@ invites you to a game of tavli.",
        "de": "%@ lädt dich zu einer Partie Tavli ein.",
        "nl": "%@ nodigt je uit voor een potje tavli.",
        "el": "Πρόσκληση από %@ για μια παρτίδα τάβλι.",
        "fa": "%@ تو را به یک بازی تخته‌نرد دعوت کرده است.",
    },
    "PUSH_INVITE_ACCEPTED": {
        "en": "%@ joined your game.",
        "de": "%@ ist deiner Partie beigetreten.",
        "nl": "%@ doet mee met je partij.",
        "el": "%@: μπήκε στην παρτίδα σου.",
        "fa": "%@ به بازی‌ات پیوست.",
    },
    "PUSH_MATCH_WON": {
        "en": "You won your game against %@.",
        "de": "Du hast deine Partie gegen %@ gewonnen.",
        "nl": "Je hebt je partij tegen %@ gewonnen.",
        "el": "Κέρδισες την παρτίδα με %@.",
        "fa": "بازی با %@ را بردی.",
    },
    "PUSH_MATCH_LOST": {
        "en": "%@ won your game.",
        "de": "%@ hat eure Partie gewonnen.",
        "nl": "%@ heeft jullie partij gewonnen.",
        "el": "%@: κέρδισε την παρτίδα σας.",
        "fa": "%@ بازی‌تان را برد.",
    },
    "PUSH_MATCH_ENDED": {
        "en": "Your game against %@ is over.",
        "de": "Deine Partie gegen %@ ist vorbei.",
        "nl": "Je partij tegen %@ is afgelopen.",
        "el": "Η παρτίδα σου με %@ τελείωσε.",
        "fa": "بازی‌ات با %@ تمام شد.",
    },
    "PUSH_OPPONENT_LEFT": {
        "en": "%@ left the game. You win!",
        "de": "%@ hat die Partie verlassen. Du gewinnst!",
        "nl": "%@ heeft de partij verlaten. Jij wint!",
        "el": "%@: αποχώρησε από την παρτίδα. Κερδίζεις!",
        "fa": "%@ بازی را ترک کرد. تو بردی!",
    },
}

STRINGS = {
    "New game": {"de": "Neue Partie", "nl": "Nieuwe partij", "el": "Νέα παρτίδα", "fa": "بازی جدید"},
    "Join with a code": {
        "de": "Mit Code beitreten", "nl": "Meedoen met code", "el": "Συμμετοχή με κωδικό", "fa": "پیوستن با کد",
    },
    "New online game": {
        "de": "Neue Online-Partie", "nl": "Nieuwe online partij", "el": "Νέα παρτίδα online", "fa": "بازی آنلاین جدید",
    },
    "Random opponent": {
        "de": "Zufälliger Gegner", "nl": "Willekeurige tegenstander", "el": "Τυχαίος αντίπαλος", "fa": "حریف تصادفی",
    },
    "Send a link or a code. You can make your first move while you wait.": {
        "de": "Schick einen Link oder einen Code. Du kannst schon deinen ersten Zug machen, während du wartest.",
        "nl": "Stuur een link of een code. Je kunt je eerste zet al doen terwijl je wacht.",
        "el": "Στείλε σύνδεσμο ή κωδικό. Μπορείς να παίξεις την πρώτη σου κίνηση όσο περιμένεις.",
        "fa": "یک پیوند یا کد بفرست. تا منتظری می‌توانی اولین حرکتت را انجام دهی.",
    },
    "Play someone who is looking for the same game.": {
        "de": "Spiel gegen jemanden, der dieselbe Partie sucht.",
        "nl": "Speel tegen iemand die hetzelfde spel zoekt.",
        "el": "Παίξε με κάποιον που ψάχνει το ίδιο παιχνίδι.",
        "fa": "با کسی بازی کن که دنبال همین بازی است.",
    },
    "Waiting for a friend": {
        "de": "Warte auf deinen Freund", "nl": "Wachten op je vriend", "el": "Αναμονή για φίλο", "fa": "در انتظار دوست",
    },
    "Code %@": {"de": "Code %@", "nl": "Code %@", "el": "Κωδικός %@", "fa": "کد %@"},
    "Invites you": {"de": "Lädt dich ein", "nl": "Nodigt je uit", "el": "Σε προσκαλεί", "fa": "دعوتت کرده"},
    "Looking for an opponent…": {
        "de": "Suche Gegner …", "nl": "Tegenstander zoeken…", "el": "Αναζήτηση αντιπάλου…", "fa": "در جست‌وجوی حریف…",
    },
    "You won": {"de": "Gewonnen", "nl": "Gewonnen", "el": "Κέρδισες", "fa": "بردی"},
    "You lost": {"de": "Verloren", "nl": "Verloren", "el": "Έχασες", "fa": "باختی"},
    "You left": {"de": "Aufgegeben", "nl": "Opgegeven", "el": "Αποχώρησες", "fa": "ترک کردی"},
    "No games yet. Invite a friend or play a random opponent.": {
        "de": "Noch keine Partien. Lade einen Freund ein oder spiel gegen einen zufälligen Gegner.",
        "nl": "Nog geen partijen. Nodig een vriend uit of speel tegen een willekeurige tegenstander.",
        "el": "Δεν υπάρχουν ακόμη παρτίδες. Κάλεσε έναν φίλο ή παίξε με τυχαίο αντίπαλο.",
        "fa": "هنوز بازی‌ای نیست. یک دوست را دعوت کن یا با حریف تصادفی بازی کن.",
    },
    "Share invite": {"de": "Einladung teilen", "nl": "Uitnodiging delen", "el": "Κοινοποίηση πρόσκλησης", "fa": "اشتراک دعوت"},
    "Cancel invite": {"de": "Einladung zurückziehen", "nl": "Uitnodiging intrekken", "el": "Ακύρωση πρόσκλησης", "fa": "لغو دعوت"},
    "Stop looking": {"de": "Suche beenden", "nl": "Stoppen met zoeken", "el": "Τέλος αναζήτησης", "fa": "توقف جست‌وجو"},
    "Sign in to your online account to join your friend’s game.": {
        "de": "Melde dich bei deinem Online-Konto an, um der Partie deines Freundes beizutreten.",
        "nl": "Log in op je online-account om mee te doen met de partij van je vriend.",
        "el": "Συνδέσου στον λογαριασμό σου online για να μπεις στην παρτίδα του φίλου σου.",
        "fa": "برای پیوستن به بازی دوستت وارد حساب آنلاینت شو.",
    },
    "Send this link to your friend. It opens Tavtav, or the App Store if they don’t have it yet. They can also type the code in Play Online → Join with a code.": {
        "de": "Schick diesen Link deinem Freund. Er öffnet Tavtav – oder den App Store, falls die App noch fehlt. Man kann den Code auch unter Online spielen → Mit Code beitreten eingeben.",
        "nl": "Stuur deze link naar je vriend. Hij opent Tavtav, of de App Store als de app er nog niet op staat. De code kan ook worden ingetypt bij Online spelen → Meedoen met code.",
        "el": "Στείλε αυτόν τον σύνδεσμο στον φίλο σου. Ανοίγει το Tavtav ή το App Store, αν δεν έχει ακόμη την εφαρμογή. Μπορεί επίσης να γράψει τον κωδικό στο Παιχνίδι online → Συμμετοχή με κωδικό.",
        "fa": "این پیوند را برای دوستت بفرست. Tavtav را باز می‌کند، یا اگر هنوز برنامه را ندارد App Store را. کد را هم می‌شود در «بازی آنلاین ← پیوستن با کد» وارد کرد.",
    },
    "Invite code %@": {"de": "Einladungscode %@", "nl": "Uitnodigingscode %@", "el": "Κωδικός πρόσκλησης %@", "fa": "کد دعوت %@"},
    "Play tavli with me": {"de": "Spiel Tavli mit mir", "nl": "Speel tavli met me", "el": "Παίξε τάβλι μαζί μου", "fa": "با من تخته‌نرد بازی کن"},
    "Share invite link": {"de": "Einladungslink teilen", "nl": "Uitnodigingslink delen", "el": "Κοινοποίηση συνδέσμου", "fa": "اشتراک پیوند دعوت"},
    "Copied": {"de": "Kopiert", "nl": "Gekopieerd", "el": "Αντιγράφηκε", "fa": "کپی شد"},
    "Copy code": {"de": "Code kopieren", "nl": "Code kopiëren", "el": "Αντιγραφή κωδικού", "fa": "کپی کد"},
    "Start playing": {"de": "Losspielen", "nl": "Begin met spelen", "el": "Ξεκίνα να παίζεις", "fa": "شروع بازی"},
    "Open until %@ · one friend can join.": {
        "de": "Offen bis %@ · ein Freund kann beitreten.",
        "nl": "Open tot %@ · één vriend kan meedoen.",
        "el": "Ανοιχτή έως %@ · μπορεί να μπει ένας φίλος.",
        "fa": "تا %@ باز است · یک دوست می‌تواند بپیوندد.",
    },
    "Type the 6-character code your friend sent you, or paste the invite link.": {
        "de": "Gib den 6-stelligen Code ein, den du bekommen hast, oder füge den Einladungslink ein.",
        "nl": "Typ de code van 6 tekens die je kreeg, of plak de uitnodigingslink.",
        "el": "Γράψε τον κωδικό των 6 χαρακτήρων που σου έστειλε ο φίλος σου ή επικόλλησε τον σύνδεσμο.",
        "fa": "کد ۶ نویسه‌ای را که دوستت فرستاده وارد کن، یا پیوند دعوت را بچسبان.",
    },
    "Code": {"de": "Code", "nl": "Code", "el": "Κωδικός", "fa": "کد"},
    "Find game": {"de": "Partie suchen", "nl": "Partij zoeken", "el": "Βρες την παρτίδα", "fa": "پیدا کردن بازی"},
    "%@ invites you to play.": {
        "de": "%@ lädt dich zum Spielen ein.",
        "nl": "%@ nodigt je uit om te spelen.",
        "el": "Πρόσκληση από %@ για παιχνίδι.",
        "fa": "%@ تو را به بازی دعوت کرده است.",
    },
    "This invite isn’t open any more. Ask your friend for a new one.": {
        "de": "Diese Einladung ist nicht mehr offen. Bitte um eine neue.",
        "nl": "Deze uitnodiging is niet meer open. Vraag om een nieuwe.",
        "el": "Αυτή η πρόσκληση δεν είναι πια ανοιχτή. Ζήτα μια καινούρια.",
        "fa": "این دعوت دیگر باز نیست. از دوستت دعوت تازه‌ای بخواه.",
    },
    "Join game": {"de": "Beitreten", "nl": "Meedoen", "el": "Συμμετοχή", "fa": "پیوستن"},
    "Play %@ with me on Tavtav! Tap the link, or type the code %@ in Play Online → Join with a code.": {
        "de": "Spiel %1$@ mit mir auf Tavtav! Tipp auf den Link oder gib den Code %2$@ unter Online spielen → Mit Code beitreten ein.",
        "nl": "Speel %1$@ met me op Tavtav! Tik op de link, of typ de code %2$@ bij Online spelen → Meedoen met code.",
        "el": "Παίξε %1$@ μαζί μου στο Tavtav! Πάτα τον σύνδεσμο ή γράψε τον κωδικό %2$@ στο Παιχνίδι online → Συμμετοχή με κωδικό.",
        "fa": "در Tavtav با من %1$@ بازی کن! روی پیوند بزن، یا کد %2$@ را در «بازی آنلاین ← پیوستن با کد» وارد کن.",
    },
    "That doesn’t look like an invite code. Codes have 6 letters and digits.": {
        "de": "Das sieht nicht wie ein Einladungscode aus. Codes haben 6 Buchstaben und Ziffern.",
        "nl": "Dat lijkt geen uitnodigingscode. Codes hebben 6 letters en cijfers.",
        "el": "Αυτό δεν μοιάζει με κωδικό πρόσκλησης. Οι κωδικοί έχουν 6 γράμματα και ψηφία.",
        "fa": "این شبیه کد دعوت نیست. کدها ۶ حرف و رقم دارند.",
    },
    "You can’t do that in this game.": {
        "de": "Das geht in dieser Partie nicht.",
        "nl": "Dat kan niet in deze partij.",
        "el": "Δεν μπορείς να το κάνεις αυτό σε αυτή την παρτίδα.",
        "fa": "در این بازی نمی‌توانی این کار را بکنی.",
    },
}

# The #286 developer lobby's challenge-by-player-id card is gone.
REMOVED = [
    "Challenge a player",
    "Your player ID: %@",
    "Copy",
    "Player ID",
    "Challenge",
    "No games in progress. Challenge a player to start one.",
    "Invited",
    "Invite sent",  # an earlier draft of this script
]


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def main() -> None:
    raw = CATALOG.read_text(encoding="utf-8")
    data = json.loads(raw)
    strings = data["strings"]
    for key in REMOVED:
        strings.pop(key, None)
    for key, langs in STRINGS.items():
        assert set(langs) == {"de", "nl", "el", "fa"}, key
        n = key.count("%@")
        for lang, value in langs.items():
            assert value.count("%@") + value.count("$@") == n, (key, lang)
        entry = strings.setdefault(key, {})
        locs = entry.setdefault("localizations", {})
        for lang, value in langs.items():
            locs[lang] = unit(value)
        entry["localizations"] = dict(sorted(locs.items()))
        strings[key] = dict(sorted(entry.items()))
    for key, langs in PUSH.items():
        assert set(langs) == {"en", "de", "nl", "el", "fa"}, key
        for lang, value in langs.items():
            assert value.count("%@") == 1, (key, lang)
        strings[key] = {
            "comment": "Push notification text (server/src/push.ts loc-key); %@ = the other player's name.",
            "extractionState": "manual",
            "localizations": {lang: unit(v) for lang, v in sorted(langs.items())},
        }
    text = json.dumps(data, ensure_ascii=False, indent=2, separators=(",", " : "))
    if raw.endswith("\n"):
        text += "\n"
    CATALOG.write_text(text, encoding="utf-8")
    print(f"added/updated {len(STRINGS) + len(PUSH)} keys, removed {len(REMOVED)}")


if __name__ == "__main__":
    main()
