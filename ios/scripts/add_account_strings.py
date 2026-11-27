"""Add the #285 strings (Server v1 account sheet: sign-in, name prompt, account page,
deletion, Settings row, error copy) to ios/TavliApp/TavliApp/Localizable.xcstrings in
de / nl / el / fa. Idempotent: existing keys are overwritten with these values. Greek and
Persian await native-speaker review, like the rest of those catalogs (glossaries in
Views/REFERENCE.md). The DEBUG-only Developer card is not localized (verbatim text)."""
import json
import pathlib

CATALOG = pathlib.Path(__file__).resolve().parents[1] / "TavliApp/TavliApp/Localizable.xcstrings"

STRINGS = {
    "Online account": {
        "de": "Online-Konto",
        "nl": "Online-account",
        "el": "Λογαριασμός online",
        "fa": "حساب آنلاین",
    },
    "The online server isn't available yet.": {
        "de": "Der Online-Server ist noch nicht verfügbar.",
        "nl": "De online server is nog niet beschikbaar.",
        "el": "Ο διακομιστής online δεν είναι ακόμη διαθέσιμος.",
        "fa": "سرور آنلاین هنوز در دسترس نیست.",
    },
    "Your account was deleted.": {
        "de": "Dein Konto wurde gelöscht.",
        "nl": "Je account is verwijderd.",
        "el": "Ο λογαριασμός σου διαγράφηκε.",
        "fa": "حساب تو حذف شد.",
    },
    "Sign in to play online": {
        "de": "Melde dich an, um online zu spielen",
        "nl": "Log in om online te spelen",
        "el": "Συνδέσου για να παίξεις online",
        "fa": "برای بازی آنلاین وارد شو",
    },
    "Your account keeps your name and your online matches on every device you sign in on.": {
        "de": "Dein Konto speichert deinen Namen und deine Online-Partien auf jedem Gerät, auf dem du dich anmeldest.",
        "nl": "Je account bewaart je naam en je online partijen op elk apparaat waarop je inlogt.",
        "el": "Ο λογαριασμός σου κρατά το όνομά σου και τις online παρτίδες σου σε κάθε συσκευή όπου συνδέεσαι.",
        "fa": "حسابت نام تو و بازی‌های آنلاینت را در هر دستگاهی که با آن وارد شوی نگه می‌دارد.",
    },
    "Sign in with Google": {
        "de": "Mit Google anmelden",
        "nl": "Inloggen met Google",
        "el": "Σύνδεση με Google",
        "fa": "ورود با گوگل",
    },
    "We keep only an account ID and the name you choose — no e-mail address.": {
        "de": "Wir speichern nur eine Konto-ID und den Namen, den du wählst – keine E-Mail-Adresse.",
        "nl": "We bewaren alleen een account-ID en de naam die je kiest – geen e-mailadres.",
        "el": "Κρατάμε μόνο ένα αναγνωριστικό λογαριασμού και το όνομα που διαλέγεις — καμία διεύθυνση email.",
        "fa": "ما فقط یک شناسهٔ حساب و نامی را که انتخاب می‌کنی نگه می‌داریم، بدون نشانی ایمیل.",
    },
    "Choose your name": {
        "de": "Wähle deinen Namen",
        "nl": "Kies je naam",
        "el": "Διάλεξε το όνομά σου",
        "fa": "نامت را انتخاب کن",
    },
    "Other players see this name in online games.": {
        "de": "Andere Spieler sehen diesen Namen in Online-Partien.",
        "nl": "Andere spelers zien deze naam in online partijen.",
        "el": "Οι άλλοι παίκτες βλέπουν αυτό το όνομα στις online παρτίδες.",
        "fa": "بازیکنان دیگر این نام را در بازی‌های آنلاین می‌بینند.",
    },
    "Skip for now": {
        "de": "Jetzt nicht",
        "nl": "Nu overslaan",
        "el": "Όχι τώρα",
        "fa": "فعلاً نه",
    },
    "Your name": {
        "de": "Dein Name",
        "nl": "Je naam",
        "el": "Το όνομά σου",
        "fa": "نام تو",
    },
    "1 to 24 characters.": {
        "de": "1 bis 24 Zeichen.",
        "nl": "1 tot 24 tekens.",
        "el": "1 έως 24 χαρακτήρες.",
        "fa": "۱ تا ۲۴ نویسه.",
    },
    "Saved": {
        "de": "Gespeichert",
        "nl": "Opgeslagen",
        "el": "Αποθηκεύτηκε",
        "fa": "ذخیره شد",
    },
    "Signed in with Apple": {
        "de": "Angemeldet mit Apple",
        "nl": "Ingelogd met Apple",
        "el": "Συνδέθηκες με Apple",
        "fa": "واردشده با اپل",
    },
    "Signed in with Google": {
        "de": "Angemeldet mit Google",
        "nl": "Ingelogd met Google",
        "el": "Συνδέθηκες με Google",
        "fa": "واردشده با گوگل",
    },
    "Member since %@": {
        "de": "Dabei seit %@",
        "nl": "Lid sinds %@",
        "el": "Μέλος από: %@",
        "fa": "عضو از %@",
    },
    "Sign out": {
        "de": "Abmelden",
        "nl": "Uitloggen",
        "el": "Αποσύνδεση",
        "fa": "خروج از حساب",
    },
    "Delete account": {
        "de": "Konto löschen",
        "nl": "Account verwijderen",
        "el": "Διαγραφή λογαριασμού",
        "fa": "حذف حساب",
    },
    "Deleting removes your account and your name from our server, and ends your online matches.": {
        "de": "Beim Löschen werden dein Konto und dein Name von unserem Server entfernt, und deine Online-Partien enden.",
        "nl": "Verwijderen haalt je account en je naam van onze server en beëindigt je online partijen.",
        "el": "Η διαγραφή αφαιρεί τον λογαριασμό και το όνομά σου από τον διακομιστή μας και τερματίζει τις online παρτίδες σου.",
        "fa": "با حذف، حساب و نامت از سرور ما پاک می‌شود و بازی‌های آنلاینت تمام می‌شوند.",
    },
    "Delete your account?": {
        "de": "Konto löschen?",
        "nl": "Je account verwijderen?",
        "el": "Διαγραφή του λογαριασμού σου;",
        "fa": "حسابت حذف شود؟",
    },
    "Your account and your name are removed from our server and your online matches end. This can't be undone.": {
        "de": "Dein Konto und dein Name werden von unserem Server entfernt, und deine Online-Partien enden. Das lässt sich nicht rückgängig machen.",
        "nl": "Je account en je naam worden van onze server verwijderd en je online partijen eindigen. Dit kan niet ongedaan worden gemaakt.",
        "el": "Ο λογαριασμός και το όνομά σου αφαιρούνται από τον διακομιστή μας και οι online παρτίδες σου τελειώνουν. Αυτό δεν αναιρείται.",
        "fa": "حساب و نامت از سرور ما پاک می‌شود و بازی‌های آنلاینت تمام می‌شوند. این کار برگشت‌پذیر نیست.",
    },
    "Signed in as %@": {
        "de": "Angemeldet als %@",
        "nl": "Ingelogd als %@",
        "el": "Συνδέθηκες ως %@",
        "fa": "واردشده با نام %@",
    },
    "Not signed in · preview for the new online server": {
        "de": "Nicht angemeldet · Vorschau für den neuen Online-Server",
        "nl": "Niet ingelogd · voorproefje van de nieuwe online server",
        "el": "Χωρίς σύνδεση · προεπισκόπηση του νέου διακομιστή online",
        "fa": "وارد نشده‌ای، پیش‌نمایش سرور آنلاین جدید",
    },
    "Not available yet": {
        "de": "Noch nicht verfügbar",
        "nl": "Nog niet beschikbaar",
        "el": "Δεν είναι ακόμη διαθέσιμο",
        "fa": "هنوز در دسترس نیست",
    },
    "Something went wrong. Please try again.": {
        "de": "Etwas ist schiefgelaufen. Bitte versuche es noch einmal.",
        "nl": "Er ging iets mis. Probeer het opnieuw.",
        "el": "Κάτι πήγε στραβά. Δοκίμασε ξανά.",
        "fa": "مشکلی پیش آمد. دوباره امتحان کن.",
    },
    "No connection to the server. Check your internet connection and try again.": {
        "de": "Keine Verbindung zum Server. Prüfe deine Internetverbindung und versuche es noch einmal.",
        "nl": "Geen verbinding met de server. Controleer je internetverbinding en probeer het opnieuw.",
        "el": "Δεν υπάρχει σύνδεση με τον διακομιστή. Έλεγξε τη σύνδεσή σου στο διαδίκτυο και δοκίμασε ξανά.",
        "fa": "اتصال به سرور برقرار نیست. اینترنتت را بررسی کن و دوباره امتحان کن.",
    },
    "Sign in with Google isn't available in this version yet.": {
        "de": "Die Anmeldung mit Google ist in dieser Version noch nicht verfügbar.",
        "nl": "Inloggen met Google is in deze versie nog niet beschikbaar.",
        "el": "Η σύνδεση με Google δεν είναι ακόμη διαθέσιμη σε αυτή την έκδοση.",
        "fa": "ورود با گوگل در این نسخه هنوز در دسترس نیست.",
    },
    "You were signed out. Please sign in again.": {
        "de": "Du wurdest abgemeldet. Bitte melde dich erneut an.",
        "nl": "Je bent uitgelogd. Log opnieuw in.",
        "el": "Αποσυνδέθηκες. Συνδέσου ξανά.",
        "fa": "از حساب خارج شدی. دوباره وارد شو.",
    },
    "Sign-in didn't work. Please try again.": {
        "de": "Die Anmeldung hat nicht geklappt. Bitte versuche es noch einmal.",
        "nl": "Inloggen is niet gelukt. Probeer het opnieuw.",
        "el": "Η σύνδεση δεν πέτυχε. Δοκίμασε ξανά.",
        "fa": "ورود انجام نشد. دوباره امتحان کن.",
    },
    "Too many attempts. Wait a minute and try again.": {
        "de": "Zu viele Versuche. Warte eine Minute und versuche es dann noch einmal.",
        "nl": "Te veel pogingen. Wacht een minuut en probeer het opnieuw.",
        "el": "Πάρα πολλές προσπάθειες. Περίμενε ένα λεπτό και δοκίμασε ξανά.",
        "fa": "تلاش‌ها زیاد بود. یک دقیقه صبر کن و دوباره امتحان کن.",
    },
    "The server isn't available right now. Please try again later.": {
        "de": "Der Server ist gerade nicht erreichbar. Bitte versuche es später noch einmal.",
        "nl": "De server is nu niet bereikbaar. Probeer het later opnieuw.",
        "el": "Ο διακομιστής δεν είναι διαθέσιμος αυτή τη στιγμή. Δοκίμασε ξανά αργότερα.",
        "fa": "سرور الان در دسترس نیست. بعداً دوباره امتحان کن.",
    },
    "Please update the app to play online.": {
        "de": "Bitte aktualisiere die App, um online zu spielen.",
        "nl": "Werk de app bij om online te spelen.",
        "el": "Ενημέρωσε την εφαρμογή για να παίξεις online.",
        "fa": "برای بازی آنلاین، برنامه را به‌روز کن.",
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
