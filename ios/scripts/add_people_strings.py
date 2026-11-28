"""Add the #301 strings (people list, presence, one-tap challenges, find player by handle,
blocking, the account page's handle / privacy settings, the challenge notification's
actions, and the challenge push texts) to ios/TavliApp/TavliApp/Localizable.xcstrings in
de / nl / el / fa. Idempotent: existing keys are overwritten with these values. Greek and
Persian await native-speaker review, like the rest of those catalogs (glossaries in
Views/REFERENCE.md).

The `PUSH_*` keys are the server's APNs keys (server/src/push.ts): `PUSH_CHALLENGE_*` are
rendered with the other player's name as `%@`; the `PUSH_GAME_<VARIANT>_<1|2>` bodies of the
challenge push name the game ("Fevga · Best of 3") and take no argument. They carry an
English value too and are marked manual (never extracted from code, never stale)."""
import json
import re
import pathlib

CATALOG = pathlib.Path(__file__).resolve().parents[1] / "TavliApp/TavliApp/Localizable.xcstrings"

# Push texts with the other player's name: key → en, de, nl, el, fa.
PUSH = {
    "PUSH_CHALLENGE_RECEIVED": {
        "en": "%@ wants to play",
        "de": "%@ möchte spielen",
        "nl": "%@ wil spelen",
        "el": "%@: θέλει να παίξετε",
        "fa": "%@ می‌خواهد بازی کند",
    },
    "PUSH_CHALLENGE_ACCEPTED": {
        "en": "%@ accepted. Your game is ready.",
        "de": "%@ hat angenommen. Eure Partie ist bereit.",
        "nl": "%@ heeft geaccepteerd. Jullie partij staat klaar.",
        "el": "%@: δέχτηκε. Η παρτίδα σας είναι έτοιμη.",
        "fa": "%@ قبول کرد. بازی‌تان آماده است.",
    },
    "PUSH_CHALLENGE_DECLINED": {
        "en": "%@ can’t play right now.",
        "de": "%@ kann gerade nicht spielen.",
        "nl": "%@ kan nu niet spelen.",
        "el": "%@: δεν μπορεί να παίξει τώρα.",
        "fa": "%@ الان نمی‌تواند بازی کند.",
    },
}

# The challenge push's body: the game. Variant names + lengths as the app shows them.
VARIANTS = {
    "PLAKOTO": {"en": "Plakoto · House rules", "de": "Plakoto · Hausregeln", "nl": "Plakoto · Huisregels",
                "el": "Πλακωτό · Κανόνες σπιτιού", "fa": "پلاکوتو · قوانین خانگی"},
    "PLAKOTO_STANDARD": {"en": "Plakoto", "de": "Plakoto", "nl": "Plakoto", "el": "Πλακωτό", "fa": "پلاکوتو"},
    "FEVGA": {"en": "Fevga", "de": "Fevga", "nl": "Fevga", "el": "Φεύγα", "fa": "فوگا"},
    "PORTES": {"en": "Portes", "de": "Portes", "nl": "Portes", "el": "Πόρτες", "fa": "پورتس"},
}
LENGTHS = {
    1: {"en": "Single game", "de": "Einzelspiel", "nl": "Enkel spel", "el": "Ένα παιχνίδι", "fa": "تک‌بازی"},
    2: {"en": "Best of 3", "de": "Best of 3", "nl": "Best of 3", "el": "2 στα 3", "fa": "بهترین از ۳"},
}

# App strings: key (the English source) → de, nl, el, fa.
STRINGS = {
    # People rows
    "People": {"de": "Leute", "nl": "Mensen", "el": "Παίκτες", "fa": "هم‌بازی‌ها"},
    "Find player": {"de": "Spieler finden", "nl": "Speler zoeken", "el": "Βρες παίκτη", "fa": "پیدا کردن بازیکن"},
    "People you play show up here. Find a friend by their handle.": {
        "de": "Hier stehen die Leute, mit denen du spielst. Finde Freunde über ihren Handle.",
        "nl": "Hier staan de mensen met wie je speelt. Zoek een vriend op zijn handle.",
        "el": "Εδώ εμφανίζονται όσοι παίζεις μαζί τους. Βρες φίλους με το όνομα χρήστη τους.",
        "fa": "کسانی که با آن‌ها بازی می‌کنی اینجا می‌آیند. دوستانت را با شناسه‌شان پیدا کن.",
    },
    "Pinned": {"de": "Angeheftet", "nl": "Vastgezet", "el": "Καρφιτσωμένος", "fa": "سنجاق‌شده"},
    "Pin": {"de": "Anheften", "nl": "Vastzetten", "el": "Καρφίτσωμα", "fa": "سنجاق"},
    "Pin to top": {"de": "Oben anheften", "nl": "Bovenaan vastzetten", "el": "Καρφίτσωμα στην κορυφή", "fa": "سنجاق در بالا"},
    "Unpin": {"de": "Loslösen", "nl": "Losmaken", "el": "Ξεκαρφίτσωμα", "fa": "برداشتن سنجاق"},
    "Block": {"de": "Blockieren", "nl": "Blokkeren", "el": "Αποκλεισμός", "fa": "مسدود کردن"},
    "Block %@": {"de": "%@ blockieren", "nl": "%@ blokkeren", "el": "Αποκλεισμός: %@", "fa": "مسدود کردن %@"},
    "Block %@?": {"de": "%@ blockieren?", "nl": "%@ blokkeren?", "el": "Αποκλεισμός: %@;", "fa": "%@ مسدود شود؟"},
    "They can’t challenge you, find you or see when you’re online any more. You can unblock them on your account page.": {
        "de": "Diese Person kann dich dann nicht mehr herausfordern, finden oder sehen, wann du online bist. Auf deiner Kontoseite kannst du die Blockierung aufheben.",
        "nl": "Diegene kan je dan niet meer uitdagen, vinden of zien wanneer je online bent. Op je accountpagina kun je de blokkering opheffen.",
        "el": "Δεν θα μπορεί πια να σε προκαλεί, να σε βρίσκει ή να βλέπει πότε είσαι συνδεδεμένος. Μπορείς να τον ξεμπλοκάρεις από τη σελίδα του λογαριασμού σου.",
        "fa": "دیگر نمی‌تواند تو را به بازی دعوت کند، پیدایت کند یا ببیند کی آنلاینی. از صفحهٔ حسابت می‌توانی رفع مسدودی کنی.",
    },
    "Online now": {"de": "Jetzt online", "nl": "Nu online", "el": "Συνδεδεμένος τώρα", "fa": "الان آنلاین"},
    "Active %@": {"de": "Aktiv %@", "nl": "Actief %@", "el": "Ενεργός %@", "fa": "فعال %@"},
    "just now": {"de": "gerade eben", "nl": "zojuist", "el": "μόλις τώρα", "fa": "همین حالا"},
    "Wants to play": {"de": "Will spielen", "nl": "Wil spelen", "el": "Θέλει να παίξετε", "fa": "می‌خواهد بازی کند"},
    "Waiting for answer…": {"de": "Wartet auf Antwort…", "nl": "Wacht op antwoord…", "el": "Αναμονή απάντησης…", "fa": "در انتظار پاسخ…"},
    # Challenge sheet
    "Play with %@": {"de": "Mit %@ spielen", "nl": "Spelen met %@", "el": "Παιχνίδι με %@", "fa": "بازی با %@"},
    "%@ gets a notification and can accept or decline.": {
        "de": "%@ bekommt eine Mitteilung und kann annehmen oder ablehnen.",
        "nl": "%@ krijgt een melding en kan accepteren of weigeren.",
        "el": "%@: θα λάβει ειδοποίηση και μπορεί να δεχτεί ή να αρνηθεί.",
        "fa": "%@ یک اعلان می‌گیرد و می‌تواند قبول یا رد کند.",
    },
    "This player takes challenges only from people they know.": {
        "de": "Diese Person nimmt Herausforderungen nur von Leuten an, die sie kennt.",
        "nl": "Deze speler neemt alleen uitdagingen aan van mensen die hij kent.",
        "el": "Αυτός ο παίκτης δέχεται προκλήσεις μόνο από άτομα που γνωρίζει.",
        "fa": "این بازیکن فقط از آشنایانش دعوت به بازی می‌پذیرد.",
    },
    "Waiting for %@…": {"de": "Warte auf %@…", "nl": "Wachten op %@…", "el": "Αναμονή για %@…", "fa": "در انتظار %@…"},
    "You can close this. When %@ answers, you get a notification.": {
        "de": "Du kannst das schließen. Wenn %@ antwortet, bekommst du eine Mitteilung.",
        "nl": "Je kunt dit sluiten. Als %@ antwoordt, krijg je een melding.",
        "el": "Μπορείς να το κλείσεις. Όταν απαντήσει %@, θα λάβεις ειδοποίηση.",
        "fa": "می‌توانی این را ببندی. وقتی %@ پاسخ بدهد، اعلان می‌گیری.",
    },
    "Cancel challenge": {"de": "Herausforderung zurückziehen", "nl": "Uitdaging intrekken", "el": "Ακύρωση πρόκλησης", "fa": "لغو دعوت"},
    "Play now": {"de": "Jetzt spielen", "nl": "Nu spelen", "el": "Παίξε τώρα", "fa": "الان بازی کن"},
    "%@ accepted": {"de": "%@ hat angenommen", "nl": "%@ heeft geaccepteerd", "el": "%@: δέχτηκε", "fa": "%@ قبول کرد"},
    "%@ can’t play right now": {"de": "%@ kann gerade nicht", "nl": "%@ kan nu niet", "el": "%@: δεν μπορεί τώρα", "fa": "%@ الان نمی‌تواند"},
    "%@ didn’t answer": {"de": "%@ hat nicht geantwortet", "nl": "%@ heeft niet geantwoord", "el": "%@: δεν απάντησε", "fa": "%@ پاسخ نداد"},
    "Challenge cancelled": {"de": "Herausforderung zurückgezogen", "nl": "Uitdaging ingetrokken", "el": "Η πρόκληση ακυρώθηκε", "fa": "دعوت لغو شد"},
    # Incoming challenge card + notification actions
    "%@ wants to play": {"de": "%@ möchte spielen", "nl": "%@ wil spelen", "el": "%@: θέλει να παίξετε", "fa": "%@ می‌خواهد بازی کند"},
    "Accept": {"de": "Annehmen", "nl": "Accepteren", "el": "Αποδοχή", "fa": "قبول"},
    "Later": {"de": "Später", "nl": "Later", "el": "Αργότερα", "fa": "بعداً"},
    # Find player
    "Type at least 3 letters of their handle, like @alex. Ask them for it — it’s on their account page.": {
        "de": "Tippe mindestens 3 Zeichen ihres Handles, z. B. @alex. Frag danach – er steht auf ihrer Kontoseite.",
        "nl": "Typ minstens 3 tekens van hun handle, zoals @alex. Vraag ernaar – hij staat op hun accountpagina.",
        "el": "Γράψε τουλάχιστον 3 χαρακτήρες από το όνομα χρήστη, π.χ. @alex. Ζήτα το — υπάρχει στη σελίδα του λογαριασμού τους.",
        "fa": "دست‌کم ۳ حرف از شناسه‌اش را بنویس، مثل ‎@alex. از خودش بپرس — در صفحهٔ حسابش هست.",
    },
    "Handle": {"de": "Handle", "nl": "Handle", "el": "Όνομα χρήστη", "fa": "شناسه"},
    "handle": {"de": "handle", "nl": "handle", "el": "όνομα χρήστη", "fa": "شناسه"},
    "Nobody with that handle.": {"de": "Niemand mit diesem Handle.", "nl": "Niemand met die handle.", "el": "Κανείς με αυτό το όνομα χρήστη.", "fa": "کسی با این شناسه نیست."},
    "In your people": {"de": "Bei deinen Leuten", "nl": "Bij je mensen", "el": "Στους παίκτες σου", "fa": "در هم‌بازی‌هایت"},
    "Add to people": {"de": "Zu deinen Leuten", "nl": "Toevoegen aan je mensen", "el": "Προσθήκη στους παίκτες", "fa": "افزودن به هم‌بازی‌ها"},
    # Errors
    "Handles are 3–20 letters, digits or _ (no spaces).": {
        "de": "Handles haben 3–20 Buchstaben, Ziffern oder _ (keine Leerzeichen).",
        "nl": "Een handle heeft 3–20 letters, cijfers of _ (geen spaties).",
        "el": "Το όνομα χρήστη έχει 3–20 λατινικά γράμματα, ψηφία ή _ (χωρίς κενά).",
        "fa": "شناسه ۳ تا ۲۰ حرف لاتین، رقم یا _ است (بدون فاصله).",
    },
    "Someone else has that handle. Try another one.": {
        "de": "Diesen Handle hat schon jemand. Versuch einen anderen.",
        "nl": "Iemand anders heeft die handle al. Probeer een andere.",
        "el": "Αυτό το όνομα χρήστη το έχει ήδη κάποιος. Δοκίμασε άλλο.",
        "fa": "این شناسه مال کس دیگری است. یکی دیگر امتحان کن.",
    },
    "This challenge isn’t open any more.": {
        "de": "Diese Herausforderung ist nicht mehr offen.",
        "nl": "Deze uitdaging staat niet meer open.",
        "el": "Αυτή η πρόκληση δεν ισχύει πια.",
        "fa": "این دعوت دیگر باز نیست.",
    },
    "Your handle can be changed only once.": {
        "de": "Deinen Handle kannst du nur einmal ändern.",
        "nl": "Je handle kun je maar één keer wijzigen.",
        "el": "Το όνομα χρήστη αλλάζει μόνο μία φορά.",
        "fa": "شناسه‌ات را فقط یک بار می‌توانی عوض کنی.",
    },
    # Account page + name prompt
    "Your handle: friends find you by it. 3–20 letters, digits or _.": {
        "de": "Dein Handle: Freunde finden dich darüber. 3–20 Buchstaben, Ziffern oder _.",
        "nl": "Je handle: vrienden vinden je hiermee. 3–20 letters, cijfers of _.",
        "el": "Το όνομα χρήστη σου: έτσι σε βρίσκουν οι φίλοι. 3–20 λατινικά γράμματα, ψηφία ή _.",
        "fa": "شناسه‌ات: دوستانت با آن پیدایت می‌کنند. ۳ تا ۲۰ حرف لاتین، رقم یا _.",
    },
    "You can change your handle once.": {
        "de": "Du kannst deinen Handle einmal ändern.",
        "nl": "Je kunt je handle één keer wijzigen.",
        "el": "Μπορείς να αλλάξεις το όνομα χρήστη μία φορά.",
        "fa": "یک بار می‌توانی شناسه‌ات را عوض کنی.",
    },
    "Copy handle": {"de": "Handle kopieren", "nl": "Handle kopiëren", "el": "Αντιγραφή ονόματος χρήστη", "fa": "کپی شناسه"},
    "Share handle": {"de": "Handle teilen", "nl": "Handle delen", "el": "Κοινοποίηση ονόματος χρήστη", "fa": "اشتراک‌گذاری شناسه"},
    "Find me on Tavtav: @%@ (Play Online → People → Find player)": {
        "de": "Finde mich bei Tavtav: @%@ (Online spielen → Leute → Spieler finden)",
        "nl": "Vind me op Tavtav: @%@ (Online spelen → Mensen → Speler zoeken)",
        "el": "Βρες με στο Tavtav: @%@ (Online παιχνίδι → Παίκτες → Βρες παίκτη)",
        "fa": "مرا در Tavtav پیدا کن: ‎@%@ (بازی آنلاین ← هم‌بازی‌ها ← پیدا کردن بازیکن)",
    },
    "Friends find you by your handle in Play Online → Find player.": {
        "de": "Freunde finden dich über deinen Handle unter Online spielen → Spieler finden.",
        "nl": "Vrienden vinden je met je handle via Online spelen → Speler zoeken.",
        "el": "Οι φίλοι σε βρίσκουν με το όνομα χρήστη από Online παιχνίδι → Βρες παίκτη.",
        "fa": "دوستانت با شناسه‌ات از «بازی آنلاین ← پیدا کردن بازیکن» پیدایت می‌کنند.",
    },
    "Change handle": {"de": "Handle ändern", "nl": "Handle wijzigen", "el": "Αλλαγή ονόματος χρήστη", "fa": "تغییر شناسه"},
    "Show when I’m online": {"de": "Zeigen, wenn ich online bin", "nl": "Tonen wanneer ik online ben", "el": "Να φαίνεται πότε είμαι συνδεδεμένος", "fa": "نشان بده کی آنلاینم"},
    "Only people you’ve played with see it.": {
        "de": "Das sehen nur Leute, mit denen du gespielt hast.",
        "nl": "Alleen mensen met wie je hebt gespeeld zien dit.",
        "el": "Το βλέπουν μόνο όσοι έχεις παίξει μαζί τους.",
        "fa": "فقط کسانی که با آن‌ها بازی کرده‌ای این را می‌بینند.",
    },
    "Who can challenge me": {"de": "Wer mich herausfordern darf", "nl": "Wie mij mag uitdagen", "el": "Ποιος μπορεί να με προκαλεί", "fa": "چه کسی می‌تواند دعوتم کند"},
    "Everyone": {"de": "Alle", "nl": "Iedereen", "el": "Όλοι", "fa": "همه"},
    "Only my people": {"de": "Nur meine Leute", "nl": "Alleen mijn mensen", "el": "Μόνο οι παίκτες μου", "fa": "فقط هم‌بازی‌هایم"},
    "Blocked": {"de": "Blockiert", "nl": "Geblokkeerd", "el": "Αποκλεισμένοι", "fa": "مسدودشده‌ها"},
    "Unblock": {"de": "Freigeben", "nl": "Deblokkeren", "el": "Ξεμπλοκάρισμα", "fa": "رفع مسدودی"},
}


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def main() -> None:
    raw = CATALOG.read_text(encoding="utf-8")
    data = json.loads(raw)
    strings = data["strings"]
    for key, langs in STRINGS.items():
        assert set(langs) == {"de", "nl", "el", "fa"}, key
        n = key.count("%@")
        for lang, value in langs.items():
            assert value.count("%@") == n, (key, lang)
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
    for variant, names in VARIANTS.items():
        for n, lengths in LENGTHS.items():
            strings[f"PUSH_GAME_{variant}_{n}"] = {
                "comment": "Challenge push body (server/src/push.ts gameLocKey): the game asked for.",
                "extractionState": "manual",
                "localizations": {lang: unit(f"{names[lang]} · {lengths[lang]}") for lang in sorted(names)},
            }
    text = json.dumps(data, ensure_ascii=False, indent=2, separators=(",", " : "))
    # Xcode writes an empty entry as "{\n\n<indent>}": keep its format (a small diff).
    text = re.sub(r'^( *)(.*) : \{\}', lambda m: f"{m.group(1)}{m.group(2)} : {{\n\n{m.group(1)}}}", text, flags=re.M)
    if raw.endswith("\n"):
        text += "\n"
    CATALOG.write_text(text, encoding="utf-8")
    print(f"added/updated {len(STRINGS) + len(PUSH) + len(VARIANTS) * len(LENGTHS)} keys")


if __name__ == "__main__":
    main()
