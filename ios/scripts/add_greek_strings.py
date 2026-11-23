"""Add the Greek (el) translations to the app's string catalog (#225).

    python3 ios/scripts/add_greek_strings.py [ios/TavliApp/TavliApp/Localizable.xcstrings]

Idempotent: it (re)writes the `el` entry of every key listed in `EL` and leaves every
other language untouched, so if the catalog conflicts on a rebase, take origin/main's
file and run this again. Output formatting matches Xcode's (`indent=2`, `" : "`), so the
diff only adds lines.

Checks before writing: every key exists in the catalog; every key that has a German
translation has a Greek one (the 8 untranslated keys -- "%@", "—", "Tavlo", ... -- are
skipped like in de/nl); and each value has the same format specifiers as its source
(positions ignored, so `%1$@ %2$@` matches `%@ %@`).

Terminology (glossary in ios/TavliApp/TavliApp/Views/REFERENCE.md): game names Τάβλι,
Πλακωτό, Φεύγα, Πόρτες; checker = πούλι; point = θέση; home board = σπίτι; pin =
πλακώνω; mother checker = μάνα; bear off = μαζεύω / μάζεμα; double game = διπλό; dice =
ζάρια, a roll = ζαριά; Computer = Υπολογιστής. Informal εσύ register. Greek uses ";" as
its question mark, so never use ";" as a semicolon in these strings. Player colours
("Λευκά"/"Κόκκινα") are neuter plural, so templates that take a side name use a
"Label: %@" shape instead of a verb that would need agreement.
"""
import json
import re
import sys
from collections import Counter
from pathlib import Path

EL = {
    "Hide debug pane": "Απόκρυψη debug",
    "More": "Περισσότερα",
    "Show debug pane": "Εμφάνιση debug",
    " · skipped %lld": " · παραλείφθηκαν %lld",
    "Two players on this iPhone": "Δύο παίκτες σε αυτό το iPhone",
    "· Blunder %@ of %@": "· Γκάφα %1$@ από %2$@",
    "· Blunder %lld of %lld": "· Γκάφα %1$lld από %2$lld",
    "(pass)": "(πάσο)",
    "%@ moving…": "Παίζει: %@…",
    "%@ wins": "Νίκη: %@",
    "%@'s turn": "Σειρά: %@",
    "%@W – %@L": "%1$@Ν – %2$@Η",
    "%lld losses in a row ↓": "%lld ήττες στη σειρά ↓",
    "%lld wins in a row ↑": "%lld νίκες στη σειρά ↑",
    "−%@ win chance": "−%@ πιθανότητα νίκης",
    "−%@ win chance vs your move": "−%@ πιθανότητα νίκης έναντι της κίνησής σου",
    "1 loss in a row ↓": "1 ήττα στη σειρά ↓",
    "1 win in a row ↑": "1 νίκη στη σειρά ↑",
    "All %@": "Σύνολο %@",
    "All %lld": "Σύνολο %lld",
    "All moves": "Όλες οι κινήσεις",
    "Analyzing move %@ of %@…": "Ανάλυση κίνησης %1$@ από %2$@…",
    "Analyzing move %lld of %lld…": "Ανάλυση κίνησης %1$lld από %2$lld…",
    "Analyzing your moves…": "Αναλύω τις κινήσεις σου…",
    "Animate computer moves": "Κινήσεις υπολογιστή με εφέ",
    "Auto-roll": "Αυτόματη ζαριά",
    "Back": "Πίσω",
    "best": "καλύτερη",
    "Best move": "Καλύτερη κίνηση",
    "Best move played ✓": "Έπαιξες την καλύτερη ✓",
    "Blunder": "Γκάφα",
    "both": "και οι δύο",
    "Cancel": "Άκυρο",
    "Checking…": "Έλεγχος…",
    "Choose destination": "Διάλεξε προορισμό",
    "Choose where to land in between": "Διάλεξε ενδιάμεση θέση",
    "Close": "Κλείσιμο",
    "Close — there's a better move. Try again.": "Παραλίγο — υπάρχει καλύτερη κίνηση. Ξαναπροσπάθησε.",
    "Compare": "Σύγκριση",
    "Continue last game": "Συνέχισε την παρτίδα",
    "Couldn't evaluate — try again.": "Δεν έγινε αξιολόγηση — ξαναπροσπάθησε.",
    "d=%@ %@": "d=%1$@ %2$@",
    "Dice %@ · %@": "Ζάρια %1$@ · %2$@",
    "Dice %@ · %@ — find a better move": "Ζάρια %1$@ · %2$@ — βρες καλύτερη κίνηση",
    "Dice %lld · %lld": "Ζάρια %1$lld · %2$lld",
    "Dice %lld · %lld — find a better move": "Ζάρια %1$lld · %2$lld — βρες καλύτερη κίνηση",
    "Dice roll automatically at the start of your turn.": "Τα ζάρια ρίχνονται αυτόματα στην αρχή της σειράς σου.",
    "Display": "Προβολή",
    "Done": "Τέλος",
    "Drill": "Εξάσκηση",
    "Drill blunders": "Ξεκίνα εξάσκηση",
    "Drill complete": "Η εξάσκηση ολοκληρώθηκε",
    "Excellent — that's the best move!": "Εξαιρετικά — αυτή είναι η καλύτερη κίνηση!",
    "Finding your blunders…": "Ψάχνω τις γκάφες σου…",
    "First move": "Πρώτη κίνηση",
    "Game · ": "Παρτίδα · ",
    "Give up": "Παραίτηση",
    "Great — very close to optimal.": "Πολύ καλά — σχεδόν τέλεια.",
    "History": "Ιστορικό",
    "Human vs Computer": "Εσύ – Υπολογιστής",
    "I start": "Εγώ",
    "Invite a friend": "Κάλεσε φίλο",
    "Keep playing": "Συνέχισε",
    "Last 20": "Τελευταίες 20",
    "Leave match": "Αποχώρηση",
    "Make your move on the board.": "Κάνε την κίνησή σου στο ταμπλό.",
    "Move %@ of %@": "Κίνηση %1$@ από %2$@",
    "Move %lld of %lld": "Κίνηση %1$lld από %2$lld",
    "Move history": "Ιστορικό κινήσεων",
    "Moves": "Κινήσεις",
    "My blunders": "Οι γκάφες μου",
    "My Record": "Το ρεκόρ μου",
    "Name": "Όνομα",
    "Name this save so you can find it on the start screen.": "Δώσε ένα όνομα για να τη βρίσκεις στην αρχική οθόνη.",
    "Next": "Επόμενη",
    "Next →": "Επόμενη →",
    "No blunders — nicely played!": "Καμία γκάφα — μπράβο!",
    "No blunders to drill — well played!": "Καμία γκάφα για εξάσκηση — μπράβο!",
    "No games in progress. Invite a friend to start one.": "Δεν υπάρχουν παρτίδες σε εξέλιξη. Κάλεσε έναν φίλο για να ξεκινήσετε μία.",
    "No games yet": "Καμία παρτίδα ακόμα",
    "No moves to review.": "Δεν υπάρχουν κινήσεις για ανάλυση.",
    "No moves yet": "Καμία κίνηση ακόμα",
    "None": "Κανένα",
    "Not quite — think a little harder.": "Όχι ακριβώς — σκέψου λίγο ακόμα.",
    "Only move available": "Μοναδική δυνατή κίνηση",
    "Opening roll": "Με ζαριά",
    "Opening Roll": "Ποιος ξεκινάει;",
    "Or choose manually:": "Ή διάλεξε εσύ ποιος ξεκινά:",
    "Pick a checker": "Διάλεξε πούλι",
    "Play a game to start your record.": "Παίξε μια παρτίδα για να ξεκινήσει το ρεκόρ σου.",
    "Play Again": "Ξαναπαίξε",
    "Play as": "Παίζεις με",
    "Play Online": "Παίξε online",
    "played": "δική σου",
    "Prev": "Προηγούμενη",
    "Red": "Κόκκινα",
    "Resign": "Παραίτηση",
    "Review game": "Ανάλυση παρτίδας",
    "Review needs the AI model, which isn’t available.": "Η ανάλυση χρειάζεται το μοντέλο AI, που δεν είναι διαθέσιμο.",
    "Rolling…": "Ρίχνει…",
    "Save": "Αποθήκευση",
    "Save game": "Αποθήκευση παρτίδας",
    "Saved games": "Αποθηκευμένες παρτίδες",
    "Settings": "Ρυθμίσεις",
    "Show on board": "Δείξε στο ταμπλό",
    "Show solution": "Δείξε τη λύση",
    "Show your live chance of winning during the game.": "Δείχνει τη ζωντανή πιθανότητα νίκης σου στη διάρκεια της παρτίδας.",
    "Sign in to Game Center to invite a friend and play online.": "Συνδέσου στο Game Center για να καλέσεις φίλο και να παίξεις online.",
    "Skip": "Παράλειψη",
    "Slow dice roll and one-by-one checker hops on the computer's turn.": "Αργή ζαριά και πούλια που κινούνται ένα-ένα όταν παίζει ο υπολογιστής.",
    "Solved %lld of %lld": "Λύθηκαν %1$lld από %2$lld",
    "Streak": "Σερί",
    "Tap dice to roll": "Πάτα τα ζάρια",
    "Tap the board to roll": "Πάτα το ταμπλό για ζαριά",
    "Computer goes first!": "Ξεκινάει ο Υπολογιστής!",
    "Computer played": "Ο Υπολογιστής έπαιξε",
    "Computer played the best ✓": "Ο Υπολογιστής έπαιξε την καλύτερη ✓",
    "Computer starts": "Υπολογιστής",
    "Computer is thinking…": "Ο Υπολογιστής σκέφτεται…",
    "The opening roll decides who starts, unless you force a side.": "Η ζαριά έναρξης αποφασίζει ποιος ξεκινάει, εκτός αν διαλέξεις εσύ.",
    "Tie (%lld vs %lld) — rolling again…": "Ίδια ζάρια (%1$lld – %2$lld) — ξαναρίχνουμε…",
    "Top moves": "Κορυφαίες κινήσεις",
    "Try again": "Ξαναπροσπάθησε",
    "Turn: %@  Dice: %@,%@": "Σειρά: %1$@  Ζάρια: %2$@,%3$@",
    "Undo": "Αναίρεση",
    "Waiting for %@…": "Αναμονή για %@…",
    "White": "Λευκά",
    "Win chance": "Πιθανότητα νίκης",
    "Win chance through the game": "Πιθανότητα νίκης στη διάρκεια της παρτίδας",
    "Win-probability bar": "Μπάρα πιθανότητας νίκης",
    "You": "Εσύ",
    "You go first!": "Ξεκινάς εσύ!",
    "You played": "Έπαιξες",
    "You start": "Εσύ",
    "You still have a %@%% chance of winning. Are you sure you want to give up?": "Έχεις ακόμα %@%% πιθανότητα να νικήσεις. Σίγουρα θέλεις να παραιτηθείς;",
    "You tried": "Δοκίμασες",
    "Your games": "Οι παρτίδες σου",
    "Your move": "Η κίνησή σου",
    "Yours": "Δική σου",
    "Plakoto": "Πλακωτό",
    "Standard": "Στάνταρ",
    "Portes": "Πόρτες",
    "Fevga": "Φεύγα",
    "Plakoto (house rules)": "Πλακωτό (κανόνες σπιτιού)",
    "Plakoto (standard rules)": "Πλακωτό (στάνταρ κανόνες)",
    "The pinning game, as the computer first learned it. Land on a lone opposing checker to pin it under yours until you leave. Bear off only with exact rolls; every win counts as one game.":
        "Το παιχνίδι του πλακώματος, όπως το πρωτοέμαθε ο υπολογιστής. Αν πέσεις σε μοναχό πούλι του αντιπάλου, το πλακώνεις κάτω από το δικό σου μέχρι να φύγεις. Μαζεύεις μόνο με ακριβείς ζαριές και κάθε νίκη μετράει ένα παιχνίδι.",
    "Plakoto by the standard (bkgm) rules: use both dice whenever you can (the larger one if only one fits), bear off with higher rolls from your highest point. Pinning your opponent's last checker on its start point (the mother) wins two points once your own start point is clear; if both mothers are pinned, the game is a draw. Winning before your opponent bears off any checker also scores two points.":
        "Πλακωτό με τους στάνταρ κανόνες (bkgm): παίζεις και τα δύο ζάρια όποτε μπορείς (το μεγαλύτερο, αν χωράει μόνο το ένα) και μαζεύεις με μεγαλύτερες ζαριές από την ψηλότερη θέση σου. Αν πλακώσεις το τελευταίο πούλι του αντιπάλου στην αφετηρία του (τη μάνα), κερδίζεις δύο πόντους μόλις αδειάσει η δική σου αφετηρία. Αν πλακωθούν και οι δύο μάνες, το παιχνίδι λήγει ισόπαλο. Αν νικήσεις πριν μαζέψει ο αντίπαλος έστω ένα πούλι, παίρνεις επίσης δύο πόντους.",
    "Greek backgammon without the doubling cube. A lone checker that is hit goes to the bar and must re-enter in your opponent's home before anything else moves. Winning before your opponent bears off any checker scores two points.":
        "Ελληνικό τάβλι χωρίς κύβο διπλασιασμού. Ένα μοναχό πούλι που χτυπιέται βγαίνει έξω και πρέπει να ξαναμπεί στο σπίτι του αντιπάλου πριν κινηθεί οτιδήποτε άλλο. Αν νικήσεις πριν μαζέψει ο αντίπαλος έστω ένα πούλι, παίρνεις δύο πόντους.",
    "The running game: both sides race the same way round the board from opposite corners. One checker holds a point, nothing is ever hit or pinned, and you may not lock your opponent in behind six points in a row. A win before your opponent bears off scores two points.":
        "Το παιχνίδι του τρεξίματος: και οι δύο πλευρές τρέχουν προς την ίδια κατεύθυνση γύρω από το ταμπλό, ξεκινώντας από αντίθετες γωνίες. Ένα πούλι κρατάει τη θέση, τίποτα δεν χτυπιέται ούτε πλακώνεται, και δεν επιτρέπεται να κλείσεις τον αντίπαλο πίσω από έξι συνεχόμενες θέσεις. Νίκη πριν μαζέψει ο αντίπαλος δίνει δύο πόντους.",
    "Game": "Παιχνίδι",
    "Computer not available yet": "Ο Υπολογιστής δεν είναι ακόμα διαθέσιμος",
    "Equity": "Equity",
    "−%@ equity": "−%@ equity",
    "Double game · 2 points": "Διπλό · 2 πόντοι",
    "Single game · 1 point": "Μονό · 1 πόντος",
    "Draw": "Ισοπαλία",
    "Both mother checkers are pinned — nobody scores.": "Και οι δύο μάνες είναι πλακωμένες — κανείς δεν παίρνει πόντους.",
    "Two players on this iPad": "Δύο παίκτες σε αυτό το iPad",
    "The computer is still learning %@. Play it with two players for now.": "Ο υπολογιστής μαθαίνει ακόμα: %@. Προς το παρόν παίξε με δύο παίκτες.",
    "%@ · two players": "%@ · δύο παίκτες",
    "Equity through the game": "Equity στη διάρκεια της παρτίδας",
    "−%@ equity vs your move": "−%@ equity έναντι της κίνησής σου",
    "bar": "έξω",
    "Full Tavli": "Πλήρες Τάβλι",
    "Full Tavli · ": "Πλήρες Τάβλι · ",
    "Full Tavli · %@": "Πλήρες Τάβλι · %@",
    "Game %lld of 3 · %@": "Παιχνίδι %1$lld από 3 · %2$@",
    "Next: game %lld of 3": "Επόμενο: παιχνίδι %lld από 3",
    "Start %@": "Ξεκίνα: %@",
    "Continue": "Συνέχεια",
    "See final result": "Δες το τελικό αποτέλεσμα",
    "Back to menu": "Πίσω στο μενού",
    "Game over": "Τέλος παρτίδας",
    "%@ · 1 point": "%@ · 1 πόντος",
    "%@ · %lld points": "%1$@ · %2$lld πόντοι",
    "Drawn session": "Ισοπαλία",
    "You won the Full Tavli!": "Κέρδισες το Πλήρες Τάβλι!",
    "%@ won the Full Tavli": "Νικητής στο Πλήρες Τάβλι: %@",
    "%@ wins the Full Tavli!": "Νικητής στο Πλήρες Τάβλι: %@!",
    "Equal points after three games — the session is drawn.": "Ίσοι πόντοι μετά από τρία παιχνίδια — ισοπαλία.",
    "New Full Tavli": "Νέο Πλήρες Τάβλι",
    "The computer is still learning some of the Full Tavli games. Play Full Tavli with two players for now.":
        "Ο υπολογιστής μαθαίνει ακόμα μερικά από τα παιχνίδια του Πλήρους Τάβλι. Προς το παρόν παίξε το Πλήρες Τάβλι με δύο παίκτες.",
    "Land on a lone opposing checker to pin it until you leave. Every win counts one point.":
        "Πλάκωσε μοναχό πούλι του αντιπάλου μέχρι να φύγεις. Κάθε νίκη μετράει έναν πόντο.",
    "Land on a lone opposing checker to pin it; pinning the mother checker can win two points.":
        "Πλάκωσε μοναχό πούλι του αντιπάλου. Με πλακωμένη μάνα μπορείς να πάρεις δύο πόντους.",
    "Hit lone checkers to the bar; they must re-enter before anything else moves.":
        "Χτύπα τα μοναχά πούλια και βγάλ' τα έξω. Πρέπει να ξαναμπούν πριν κινηθεί οτιδήποτε άλλο.",
    "Both sides race the same way round; one checker holds a point and nothing is hit.":
        "Όλοι τρέχουν προς την ίδια μεριά. Ένα πούλι κρατάει τη θέση, τίποτα δεν χτυπιέται.",
    "You win": "Κέρδισες",
    "You win a double game": "Κέρδισες διπλό",
    "%@ wins a double game": "Νίκη με διπλό: %@",
    "Give up this game?": "Παραιτείσαι από αυτό το παιχνίδι;",
    "You still have a %lld%% chance of winning.": "Έχεις ακόμα %lld%% πιθανότητα να νικήσεις.",
    "The computer still rates your position at %@ points.": "Ο υπολογιστής εκτιμά ακόμα τη θέση σου στους %@ πόντους.",
    "Game %lld of %lld": "Παιχνίδι %1$lld από %2$lld",
    "Final": "Τελικό",
    "Next game": "Επόμενο παιχνίδι",
    "Rematch": "Ρεβάνς",
    "Back to lobby": "Πίσω στο λόμπι",
    "Variant": "Παραλλαγή",
    "Advanced": "Προχωρημένα",
    "Best of 3": "2 στα 3",
    "One game": "Ένα παιχνίδι",
    "First to two games wins": "Κερδίζει όποιος φτάσει πρώτος τις δύο νίκες",
    "Portes → Fevga → Plakoto": "Πόρτες → Φεύγα → Πλακωτό",
    "No saved games yet": "Καμία αποθηκευμένη παρτίδα ακόμα",
    "Save a game from its menu to come back to it later.": "Αποθήκευσε μια παρτίδα από το μενού της για να επιστρέψεις σε αυτήν αργότερα.",
    "1 move": "1 κίνηση",
    "%lld moves": "%lld κινήσεις",
    "Delete": "Διαγραφή",
    "Match length": "Διάρκεια αγώνα",
    "Analyze during play": "Ανάλυση την ώρα που παίζεις",
    "Work out each move's best play as you go, so the post-game review opens instantly. Off by default — it shares the computer's processing power, so the computer can be slower to move. Uses a little more battery.":
        "Υπολογίζει την καλύτερη κίνηση σε κάθε γύρο ενώ παίζεις, ώστε η ανάλυση μετά την παρτίδα να ανοίγει αμέσως. Ανενεργό από προεπιλογή — μοιράζεται την υπολογιστική ισχύ με τον αντίπαλο υπολογιστή, οπότε αυτός μπορεί να παίζει πιο αργά. Καταναλώνει λίγη παραπάνω μπαταρία.",
    "No move": "Πάσο",
    "Mother pinned": "Πλακώθηκε η μάνα",
    "Random": "Τυχαία",
    "Play the computer": "Παίξε με Υπολογιστή",
    "Level %lld": "Επίπεδο %lld",
    "Level": "Επίπεδο",
    "Length": "Διάρκεια",
    "Play": "Παίξε",
    "Game setup": "Ρυθμίσεις παιχνιδιού",
    "Single game": "Ένα παιχνίδι",
    "Standard Plakoto": "Στάνταρ Πλακωτό",
    "Full Tavli plays all three variants in turn.": "Το Πλήρες Τάβλι παίζει και τα τρία παιχνίδια με τη σειρά.",
    "The colour you play against the computer. Random picks a side for each new game.":
        "Το χρώμα με το οποίο παίζεις απέναντι στον υπολογιστή. Με το «Τυχαία» διαλέγεται πλευρά σε κάθε νέο παιχνίδι.",
    "Beginner: often misses the best move.": "Αρχάριος: συχνά χάνει την καλύτερη κίνηση.",
    "Casual: still slips up a lot.": "Χαλαρός: κάνει ακόμα πολλά λάθη.",
    "Relaxed: playable, with frequent slips.": "Άνετος: παίζεται, αλλά με συχνά λάθη.",
    "Solid: slips now and then.": "Σταθερός: λάθη πού και πού.",
    "Steady: rarely far from its best move.": "Σίγουρος: σπάνια μακριά από την καλύτερη κίνηση.",
    "Strong: only occasional slips.": "Δυνατός: μόνο περιστασιακά λάθη.",
    "Sharp: always its best move, without looking ahead.": "Κοφτερός: πάντα η καλύτερη κίνηση, χωρίς να κοιτάει μπροστά.",
    "Full strength: looks ahead to your reply.": "Πλήρης δύναμη: προβλέπει και την απάντησή σου.",
    "Computer": "Υπολογιστής",
    "Computer is moving…": "Ο Υπολογιστής παίζει…",
    "Appearance": "Εμφάνιση",
    "System": "Σύστημα",
    "Light": "Φωτεινό",
    "Dark": "Σκούρο",
    "System follows your device's light or dark mode.": "Το «Σύστημα» ακολουθεί τη φωτεινή ή σκούρα λειτουργία της συσκευής σου.",
    "%@: %lld checkers start 6 points ahead": "%1$@: %2$lld πούλια ξεκινούν 6 θέσεις μπροστά",
    "%@: %lld hints per game": "%1$@: %2$lld βοήθειες ανά παιχνίδι",
    "%@: %lld rerolls per game": "%1$@: %2$lld νέες ζαριές ανά παιχνίδι",
    "%@: 1 checker starts 6 points ahead": "%@: 1 πούλι ξεκινά 6 θέσεις μπροστά",
    "%@: 1 hint per game": "%@: 1 βοήθεια ανά παιχνίδι",
    "%@: 1 reroll per game": "%@: 1 νέα ζαριά ανά παιχνίδι",
    "%@: bears off from the last %lld points only": "%1$@: μαζεύει μόνο από τις τελευταίες %2$lld θέσεις",
    "%@: may bear off with a higher die": "%@: μπορεί να μαζέψει με μεγαλύτερο ζάρι",
    "%@: moves first": "%@: ξεκινά",
    "%@: plays with %lld checkers": "%1$@: παίζει με %2$lld πούλια",
    "%@: safe point %lld (a lone checker there can't be pinned)": "%1$@: ασφαλής θέση %2$lld (εκεί ένα μοναχό πούλι δεν πλακώνεται)",
    "Checkers %lld–%lld": "Πούλια %1$lld–%2$lld",
    "Dice favour %@ %@": "Ζάρια υπέρ: %1$@ · %2$@",
    "Dice favour you %@": "Τα ζάρια σε ευνοούν %@",
    "Head start %lld": "Προβάδισμα %lld",
    "Hints %lld": "Βοήθειες %lld",
    "Home %lld points": "Σπίτι %lld θέσεων",
    "Moderate": "Μέτρια",
    "Moves first": "Ξεκινά",
    "Off": "Όχι",
    "On": "Ναι",
    "Overshoot bear-off": "Μάζεμα με μεγαλύτερο ζάρι",
    "Rerolls %lld": "Νέες ζαριές %lld",
    "Safe point %lld": "Ασφαλής θέση %lld",
    "Slight": "Ελαφριά",
    "Strong": "Έντονη",
    "Very strong": "Πολύ έντονη",
    "Weighted dice": "Ευνοϊκά ζάρια",
    "moderately": "μέτρια",
    "slightly": "ελαφρά",
    "strongly": "έντονα",
    "very strongly": "πολύ έντονα",
    "%lld checkers": "%lld πούλια",
    "%lld per game": "%lld ανά παιχνίδι",
    "1 checker": "1 πούλι",
    "A lone checker of this side on this point can't be pinned. Points count from the side's own start. A small advantage.":
        "Ένα μοναχό πούλι αυτής της πλευράς δεν πλακώνεται σε αυτή τη θέση. Οι θέσεις μετράνε από την αφετηρία της πλευράς. Μικρό πλεονέκτημα.",
    "Always starts the game; no opening roll.": "Ξεκινά πάντα το παιχνίδι, χωρίς ζαριά έναρξης.",
    "Bear off only from the last points of the home board. A smaller home is a disadvantage.":
        "Μάζεμα μόνο από τις τελευταίες θέσεις του σπιτιού. Μικρότερο σπίτι είναι μειονέκτημα.",
    "Before each roll the dice lean towards rolls that are good for this side. The game says so in its Handicap tag.":
        "Πριν από κάθε ζαριά, τα ζάρια γέρνουν προς ζαριές που βοηθούν αυτή την πλευρά. Το παιχνίδι το δείχνει στην ένδειξη Χάντικαπ.",
    "Checkers": "Πούλια",
    "Checkers that start 6 points ahead of the stack.": "Πούλια που ξεκινούν 6 θέσεις μπροστά από τη στοίβα.",
    "For": "Για",
    "Give one side an advantage so players of different strength get a close game.":
        "Δώσε πλεονέκτημα σε μία πλευρά, ώστε παίκτες διαφορετικού επιπέδου να παίξουν ένα ισορροπημένο παιχνίδι.",
    "Handicap": "Χάντικαπ",
    "Head start": "Προβάδισμα",
    "Hints": "Βοήθειες",
    "Home size": "Μέγεθος σπιτιού",
    "How many checkers each side plays with (normally 15). More checkers is the advantage.":
        "Με πόσα πούλια παίζει κάθε πλευρά (κανονικά 15). Περισσότερα πούλια είναι το πλεονέκτημα.",
    "May bear off with a higher die than needed, from the farthest checker (as in standard Plakoto). A big advantage.":
        "Μπορεί να μαζέψει με μεγαλύτερο ζάρι από όσο χρειάζεται, από το πιο μακρινό πούλι (όπως στο στάνταρ Πλακωτό). Μεγάλο πλεονέκτημα.",
    "Playing the computer": "Με Υπολογιστή",
    "Rerolls": "Νέες ζαριές",
    "Roll again after seeing the dice, this many times per game.": "Ξαναρίχνεις τα ζάρια αφού τα δεις, τόσες φορές ανά παιχνίδι.",
    "Rule changes": "Αλλαγές κανόνων",
    "Safe point": "Ασφαλής θέση",
    "Show the computer's best move (without playing it), this many times per game.":
        "Δείχνει την καλύτερη κίνηση του υπολογιστή (χωρίς να την παίζει), τόσες φορές ανά παιχνίδι.",
    "Sides": "Πλευρές",
    "Two players": "Δύο παίκτες",
    "Use handicaps": "Χρήση χάντικαπ",
    "Your next game is %@, so it will be played without a handicap.": "Το επόμενο παιχνίδι σου είναι %@, οπότε θα παιχτεί χωρίς χάντικαπ.",
    "Your next game is Full Tavli, so it will be played without a handicap.": "Το επόμενο παιχνίδι σου είναι Πλήρες Τάβλι, οπότε θα παιχτεί χωρίς χάντικαπ.",
    "%@ %@ · %@ %@": "%@ %@ · %@ %@",
    "%@: hints left %lld of %lld": "%1$@: απομένουν %2$lld από %3$lld βοήθειες",
    "%@: not measured yet, so not in the number.": "%@: δεν έχει μετρηθεί ακόμα, οπότε δεν περιλαμβάνεται στον αριθμό.",
    "%@: rerolls left %lld of %lld": "%1$@: απομένουν %2$lld από %3$lld νέες ζαριές",
    "%lld games": "%lld παιχνίδια",
    "%lldW – %lldL": "%1$lldΝ – %2$lldΗ",
    "1 game": "1 παιχνίδι",
    "Best move shown in blue": "Η καλύτερη κίνηση με μπλε",
    "Computer used a reroll (%lld left)": "Ο Υπολογιστής ξαναέριξε (απομένουν %lld)",
    "Estimate needs the computer's model, which isn't available.": "Η εκτίμηση χρειάζεται το μοντέλο του υπολογιστή, που δεν είναι διαθέσιμο.",
    "Estimated win chance": "Εκτιμώμενη πιθανότητα νίκης",
    "Estimated win chance (approx.)": "Εκτιμώμενη πιθανότητα νίκης (περίπου)",
    "Estimating…": "Εκτίμηση…",
    "Handicap game: win chances assume fair dice": "Παιχνίδι με χάντικαπ: οι πιθανότητες νίκης υποθέτουν δίκαια ζάρια",
    "Handicap games": "Παιχνίδια με χάντικαπ",
    "Hint (%lld left)": "Βοήθεια (απομένουν %lld)",
    "Hints aren't counted: what they're worth depends on the player.": "Οι βοήθειες δεν μετράνε: η αξία τους εξαρτάται από τον παίκτη.",
    "If both played at the computer's full strength.": "Αν έπαιζαν και οι δύο με την πλήρη δύναμη του υπολογιστή.",
    "Not counted in your record against the computer.": "Δεν μετράει στο ρεκόρ σου απέναντι στον υπολογιστή.",
    "Reroll (%lld left)": "Ξαναρίξε (απομένουν %lld)",
    "Weighted dice and rerolls": "Ευνοϊκά ζάρια και νέες ζαριές",
    "Win chances in the review and the win-probability bar still assume fair dice.":
        "Οι πιθανότητες νίκης στην ανάλυση και στη μπάρα πιθανότητας υποθέτουν πάντα δίκαια ζάρια.",
    "Your opponent left the match. You win!": "Ο αντίπαλος αποχώρησε από την παρτίδα. Κέρδισες!",
    "Couldn’t send your move. It’s saved and will be sent when you’re back online.":
        "Η κίνησή σου δεν στάλθηκε. Έχει αποθηκευτεί και θα σταλεί μόλις συνδεθείς ξανά.",
    "It’s your turn in another game.": "Είναι η σειρά σου σε άλλη παρτίδα.",
    "It’s your turn against %@.": "Είναι η σειρά σου στην παρτίδα με %@.",
    "Finished": "Ολοκληρωμένες",
    "Remove": "Αφαίρεση",
    "Forfeit this match?": "Παραιτείσαι από την παρτίδα;",
    "Forfeit": "Παραίτηση",
    "%@ wins the match. To continue later instead, use the back button.":
        "Νικητής της παρτίδας: %@. Για να συνεχίσεις αργότερα, πάτησε το κουμπί επιστροφής.",
    "Match ended.": "Η παρτίδα τελείωσε.",
    "Opponent": "Αντίπαλος",
    "Sign in to Game Center to play online.": "Συνδέσου στο Game Center για να παίξεις online.",
    "Their turn": "Σειρά του αντιπάλου",
    "Your turn": "Σειρά σου",
    "Waiting for opponent to start…": "Αναμονή να ξεκινήσει ο αντίπαλος…",
}

SPEC = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f|%)")


def specs(s: str) -> Counter:
    return Counter(re.sub(r"\d+\$", "", m) for m in SPEC.findall(s))


def main() -> None:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else
                Path(__file__).resolve().parents[1] / "TavliApp/TavliApp/Localizable.xcstrings")
    catalog = json.loads(path.read_text(encoding="utf-8"))
    strings = catalog["strings"]

    errors = [f"not in catalog: {k!r}" for k in EL if k not in strings]
    for key, entry in strings.items():
        locs = entry.get("localizations", {})
        if "de" in locs and key not in EL:
            errors.append(f"missing Greek: {key!r}")
        if key in EL:
            source = locs.get("en", {}).get("stringUnit", {}).get("value", key)
            if specs(source) != specs(EL[key]):
                errors.append(f"format specifiers differ: {key!r} -> {EL[key]!r}")
            if ";" in EL[key] and not EL[key].endswith(";"):
                errors.append(f"';' is a question mark in Greek: {EL[key]!r}")
    if errors:
        sys.exit("\n".join(errors))

    for key, value in EL.items():
        locs = strings[key].setdefault("localizations", {})
        locs["el"] = {"stringUnit": {"state": "translated", "value": value}}
        strings[key]["localizations"] = dict(sorted(locs.items()))  # Xcode keeps them sorted
    text = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "))
    path.write_text(text, encoding="utf-8")  # Xcode writes no trailing newline
    print(f"wrote {len(EL)} Greek strings to {path}")


if __name__ == "__main__":
    main()
