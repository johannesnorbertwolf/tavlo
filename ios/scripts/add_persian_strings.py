"""Add the Persian (Farsi, `fa`) translations to the app's string catalog (#185).

    python3 ios/scripts/add_persian_strings.py [ios/TavliApp/TavliApp/Localizable.xcstrings]

Idempotent: (re)writes every key's `fa` stringUnit from `FA` below and leaves all other
languages untouched. Writes back in Xcode's own formatting (`indent=2`,
`separators=(',', ' : ')`, non-ASCII kept), so the diff only adds the `fa` lines. If a
rebase conflicts on the catalog, take origin/main's version and re-run this script.

Conventions (see `ios/TavliApp/TavliApp/Views/REFERENCE.md`, "Right-to-left / Persian"):
- Informal but polite register (تو, imperative "کن"), like the German "du".
- Backgammon vocabulary: تخته\u200cنرد backgammon, مهره checker, خانه point, تاس die/dice,
  جفت doubles, بیرون بردن bearing off, حبس کردن pin (Plakoto), زدن hit, بار bar,
  مارس double game (gammon), مهرهٔ مادر mother checker, منطقهٔ خودی home board.
- Variants transliterated: پلاکوتو، فوگا، پورتس. "Full Tavli" = تاولی کامل.
- "Computer" = کامپیوتر. "Game Center" stays Latin (Apple's product name).
- Literal digits in prose are Persian (۱ ۲ ۳), matching what locale formatting gives the
  interpolated `%lld` numbers; format specifiers are kept exactly (positional `%1$@` …
  whenever a string has more than one argument, so word order can change freely).
- Persian has no grammatical plural after a number ("۳ حرکت"), so the catalog's separate
  singular/plural keys ("1 move" / "%lld moves") simply both translate.
- Arrows that mean "forward/next" point left (←) in RTL text.
- Zero-width non-joiner (U+200C) is written as the escape \\u200c (e.g. "می\\u200cخواهی").

A native speaker must review these strings before release.
"""

import json
import re
import sys
from pathlib import Path


FA = {
    "Hide debug pane": "پنهان کردن پنل اشکال\u200cزدایی",
    "More": "بیشتر",
    "Show debug pane": "نمایش پنل اشکال\u200cزدایی",
    " · skipped %lld": " · %lld رد شد",
    "Two players on this iPhone": "دو نفره روی همین آیفون",
    "· Blunder %@ of %@": "· اشتباه بزرگ %1$@ از %2$@",
    "· Blunder %lld of %lld": "· اشتباه بزرگ %1$lld از %2$lld",
    "(pass)": "(بدون حرکت)",
    "%@ moving…": "%@ در حال حرکت…",
    "%@ wins": "%@ برنده شد",
    "%@'s turn": "نوبت %@",
    "%@W – %@L": "%1$@ برد – %2$@ باخت",
    "%lld losses in a row ↓": "%lld باخت پشت سر هم ↓",
    "%lld wins in a row ↑": "%lld برد پشت سر هم ↑",
    "−%@ win chance": "−%@ شانس برد",
    "−%@ win chance vs your move": "−%@ شانس برد نسبت به حرکت تو",
    "1 loss in a row ↓": "۱ باخت پشت سر هم ↓",
    "1 win in a row ↑": "۱ برد پشت سر هم ↑",
    "All %@": "همه %@",
    "All %lld": "همه %lld",
    "All moves": "همهٔ حرکت\u200cها",
    "Analyzing move %@ of %@…": "در حال تحلیل حرکت %1$@ از %2$@…",
    "Analyzing move %lld of %lld…": "در حال تحلیل حرکت %1$lld از %2$lld…",
    "Analyzing your moves…": "در حال تحلیل حرکت\u200cهایت…",
    "Animate computer moves": "انیمیشن حرکت کامپیوتر",
    "Auto-roll": "ریختن خودکار تاس",
    "Back": "بازگشت",
    "best": "بهترین",
    "Best move": "بهترین حرکت",
    "Best move played ✓": "بهترین حرکت انجام شد ✓",
    "Blunder": "اشتباه بزرگ",
    "both": "هر دو",
    "Cancel": "لغو",
    "Checking…": "در حال بررسی…",
    "Choose destination": "مقصد را انتخاب کن",
    "Choose where to land in between": "خانهٔ میانی را انتخاب کن",
    "Close": "بستن",
    "Close — there's a better move. Try again.": "نزدیک بود — حرکت بهتری هست. دوباره امتحان کن.",
    "Compare": "مقایسه",
    "Continue last game": "ادامهٔ بازی قبلی",
    "Couldn't evaluate — try again.": "ارزیابی ممکن نشد — دوباره امتحان کن.",
    "d=%@ %@": "d=%1$@ %2$@",
    "Dice %@ · %@": "تاس %1$@ و %2$@",
    "Dice %@ · %@ — find a better move": "تاس %1$@ و %2$@ — حرکت بهتری پیدا کن",
    "Dice %lld · %lld": "تاس %1$lld و %2$lld",
    "Dice %lld · %lld — find a better move": "تاس %1$lld و %2$lld — حرکت بهتری پیدا کن",
    "Dice roll automatically at the start of your turn.": "تاس\u200cها در شروع نوبتت خودکار ریخته می\u200cشوند.",
    "Display": "نمایش",
    "Done": "تمام",
    "Drill": "تمرین",
    "Drill blunders": "تمرین اشتباه\u200cها",
    "Drill complete": "تمرین تمام شد",
    "Excellent — that's the best move!": "عالی — این بهترین حرکت است!",
    "Finding your blunders…": "در حال پیدا کردن اشتباه\u200cهایت…",
    "First move": "حرکت اول",
    "Game · ": "بازی · ",
    "Give up": "تسلیم",
    "Great — very close to optimal.": "خیلی خوب — تقریباً بهترین حرکت.",
    "History": "تاریخچه",
    "Human vs Computer": "انسان در برابر کامپیوتر",
    "I start": "اول من",
    "Invite a friend": "دعوت از یک دوست",
    "Keep playing": "ادامهٔ بازی",
    "Last 20": "۲۰ بازی آخر",
    "Leave match": "ترک مسابقه",
    "Make your move on the board.": "حرکتت را روی صفحه انجام بده.",
    "Move %@ of %@": "حرکت %1$@ از %2$@",
    "Move %lld of %lld": "حرکت %1$lld از %2$lld",
    "Move history": "تاریخچهٔ حرکت\u200cها",
    "Moves": "حرکت\u200cها",
    "My blunders": "اشتباه\u200cهای من",
    "My Record": "کارنامهٔ من",
    "Name": "نام",
    "Name this save so you can find it on the start screen.": "برای این بازی ذخیره\u200cشده نامی بگذار تا در صفحهٔ شروع پیدایش کنی.",
    "Next": "بعدی",
    "Next →": "بعدی ←",
    "No blunders — nicely played!": "بدون اشتباه بزرگ — خوب بازی کردی!",
    "No blunders to drill — well played!": "اشتباهی برای تمرین نیست — آفرین!",
    "No games in progress. Invite a friend to start one.": "بازی در جریانی نداری. یک دوست را دعوت کن تا بازی را شروع کنید.",
    "No games yet": "هنوز بازی\u200cای نیست",
    "No moves to review.": "حرکتی برای بررسی نیست.",
    "No moves yet": "هنوز حرکتی نیست",
    "None": "هیچ\u200cکدام",
    "Not quite — think a little harder.": "نه کاملاً — کمی بیشتر فکر کن.",
    "Only move available": "تنها حرکت ممکن",
    "Opening roll": "تاس شروع",
    "Opening Roll": "تاس شروع بازی",
    "Or choose manually:": "یا دستی انتخاب کن:",
    "Pick a checker": "یک مهره انتخاب کن",
    "Play a game to start your record.": "یک بازی کن تا کارنامه\u200cات شروع شود.",
    "Play Again": "بازی دوباره",
    "Play as": "بازی با",
    "Play Online": "بازی آنلاین",
    "played": "انجام\u200cشده",
    "Prev": "قبلی",
    "Red": "قرمز",
    "Resign": "تسلیم",
    "Review game": "بررسی بازی",
    "Review needs the AI model, which isn’t available.": "بررسی به مدل هوش مصنوعی نیاز دارد که در دسترس نیست.",
    "Rolling…": "در حال ریختن تاس…",
    "Save": "ذخیره",
    "Save game": "ذخیرهٔ بازی",
    "Saved games": "بازی\u200cهای ذخیره\u200cشده",
    "Settings": "تنظیمات",
    "Show on board": "نمایش روی صفحه",
    "Show solution": "نمایش راه\u200cحل",
    "Show your live chance of winning during the game.": "شانس بردت را در طول بازی نشان می\u200cدهد.",
    "Sign in to Game Center to invite a friend and play online.": "برای دعوت از دوستت و بازی آنلاین، وارد Game Center شو.",
    "Skip": "رد کردن",
    "Slow dice roll and one-by-one checker hops on the computer's turn.": "در نوبت کامپیوتر، تاس آهسته ریخته می\u200cشود و مهره\u200cها یکی\u200cیکی حرکت می\u200cکنند.",
    "Solved %lld of %lld": "%1$lld از %2$lld حل شد",
    "Streak": "پیاپی",
    "Tap dice to roll": "برای ریختن، روی تاس بزن",
    "Tap the board to roll": "برای ریختن تاس، روی صفحه بزن",
    "Computer goes first!": "کامپیوتر شروع می\u200cکند!",
    "Computer played": "حرکت کامپیوتر",
    "Computer played the best ✓": "کامپیوتر بهترین حرکت را زد ✓",
    "Computer starts": "اول کامپیوتر",
    "Computer is thinking…": "کامپیوتر در حال فکر کردن است…",
    "The opening roll decides who starts, unless you force a side.": "تاس شروع تعیین می\u200cکند چه کسی اول بازی کند، مگر اینکه خودت یک طرف را انتخاب کنی.",
    "Tie (%lld vs %lld) — rolling again…": "مساوی (%1$lld در برابر %2$lld) — دوباره ریخته می\u200cشود…",
    "Top moves": "بهترین حرکت\u200cها",
    "Try again": "دوباره امتحان کن",
    "Turn: %@  Dice: %@,%@": "نوبت: %1$@  تاس: %2$@,%3$@",
    "Undo": "برگرداندن",
    "Waiting for %@…": "در انتظار %@…",
    "White": "سفید",
    "Win chance": "شانس برد",
    "Win chance through the game": "شانس برد در طول بازی",
    "Win-probability bar": "نوار احتمال برد",
    "You": "تو",
    "You go first!": "تو شروع می\u200cکنی!",
    "You played": "حرکت تو",
    "You start": "تو شروع می\u200cکنی",
    "You still have a %@%% chance of winning. Are you sure you want to give up?": "هنوز %@%% شانس برد داری. مطمئنی می\u200cخواهی تسلیم شوی؟",
    "You tried": "تلاش تو",
    "Your games": "بازی\u200cهای تو",
    "Your move": "حرکت تو",
    "Yours": "مال تو",
    "Plakoto": "پلاکوتو",
    "Standard": "استاندارد",
    "Portes": "پورتس",
    "Fevga": "فوگا",
    "Plakoto (house rules)": "پلاکوتو (قوانین خانگی)",
    "Plakoto (standard rules)": "پلاکوتو (قوانین استاندارد)",
    "The pinning game, as the computer first learned it. Land on a lone opposing checker to pin it under yours until you leave. Bear off only with exact rolls; every win counts as one game.":
        "بازی حبس کردن، همان\u200cطور که کامپیوتر اول یاد گرفت. اگر روی یک مهرهٔ تنهای حریف فرود بیایی، آن را زیر مهرهٔ خودت حبس می\u200cکنی تا وقتی که از آنجا بروی. مهره\u200cها را فقط با تاس دقیق می\u200cشود بیرون برد؛ هر برد یک بازی حساب می\u200cشود.",
    "Plakoto by the standard (bkgm) rules: use both dice whenever you can (the larger one if only one fits), bear off with higher rolls from your highest point. Pinning your opponent's last checker on its start point (the mother) wins two points once your own start point is clear; if both mothers are pinned, the game is a draw. Winning before your opponent bears off any checker also scores two points.":
        "پلاکوتو با قوانین استاندارد (bkgm): هر وقت بتوانی از هر دو تاس استفاده کن (اگر فقط یکی جا شود، تاس بزرگ\u200cتر را)، و با تاس بزرگ\u200cتر از دورترین خانه\u200cات مهره بیرون ببر. اگر آخرین مهرهٔ حریف را روی خانهٔ شروعش (مادر) حبس کنی، به محض خالی شدن خانهٔ شروع خودت دو امتیاز می\u200cبری؛ اگر هر دو مادر حبس شوند، بازی مساوی است. بردن پیش از آنکه حریف حتی یک مهره بیرون ببرد هم دو امتیاز دارد.",
    "Greek backgammon without the doubling cube. A lone checker that is hit goes to the bar and must re-enter in your opponent's home before anything else moves. Winning before your opponent bears off any checker scores two points.":
        "تخته\u200cنرد یونانی بدون مکعب دوبل. مهرهٔ تنهایی که زده شود به بار می\u200cرود و باید پیش از هر حرکت دیگری در منطقهٔ خودی حریف دوباره وارد شود. بردن پیش از آنکه حریف حتی یک مهره بیرون ببرد دو امتیاز دارد.",
    "The running game: both sides race the same way round the board from opposite corners. One checker holds a point, nothing is ever hit or pinned, and you may not lock your opponent in behind six points in a row. A win before your opponent bears off scores two points.":
        "بازی مسابقه\u200cای: هر دو طرف از گوشه\u200cهای روبه\u200cرو، در یک جهت دور صفحه می\u200cدوند. یک مهره برای گرفتن یک خانه کافی است، هیچ مهره\u200cای زده یا حبس نمی\u200cشود، و نمی\u200cتوانی حریف را پشت شش خانهٔ پشت سر هم گیر بیندازی. بردن پیش از آنکه حریف مهره\u200cای بیرون ببرد دو امتیاز دارد.",
    "Game": "بازی",
    "Computer not available yet": "کامپیوتر هنوز در دسترس نیست",
    "Equity": "ارزش موقعیت",
    "−%@ equity": "−%@ ارزش موقعیت",
    "Double game · 2 points": "مارس · ۲ امتیاز",
    "Single game · 1 point": "برد ساده · ۱ امتیاز",
    "Draw": "مساوی",
    "Both mother checkers are pinned — nobody scores.": "هر دو مهرهٔ مادر حبس شده\u200cاند — هیچ\u200cکس امتیاز نمی\u200cگیرد.",
    "Two players on this iPad": "دو نفره روی همین آیپد",
    "The computer is still learning %@. Play it with two players for now.": "کامپیوتر هنوز در حال یادگرفتن %@ است. فعلاً آن را دو نفره بازی کن.",
    "%@ · two players": "%@ · دو نفره",
    "Equity through the game": "ارزش موقعیت در طول بازی",
    "−%@ equity vs your move": "−%@ ارزش موقعیت نسبت به حرکت تو",
    "bar": "بار",
    "Full Tavli": "تاولی کامل",
    "Full Tavli · ": "تاولی کامل · ",
    "Full Tavli · %@": "تاولی کامل · %@",
    "Game %lld of 3 · %@": "بازی %1$lld از ۳ · %2$@",
    "Next: game %lld of 3": "بعدی: بازی %lld از ۳",
    "Start %@": "شروع %@",
    "Continue": "ادامه",
    "See final result": "دیدن نتیجهٔ نهایی",
    "Back to menu": "بازگشت به منو",
    "Game over": "پایان بازی",
    "%@ · 1 point": "%@ · ۱ امتیاز",
    "%@ · %lld points": "%1$@ · %2$lld امتیاز",
    "Drawn session": "دوره مساوی شد",
    "You won the Full Tavli!": "تاولی کامل را بردی!",
    "%@ won the Full Tavli": "%@ تاولی کامل را برد",
    "%@ wins the Full Tavli!": "%@ برندهٔ تاولی کامل شد!",
    "Equal points after three games — the session is drawn.": "امتیازها پس از سه بازی برابر است — دوره مساوی شد.",
    "New Full Tavli": "تاولی کامل جدید",
    "The computer is still learning some of the Full Tavli games. Play Full Tavli with two players for now.":
        "کامپیوتر هنوز در حال یادگرفتن بعضی از بازی\u200cهای تاولی کامل است. فعلاً تاولی کامل را دو نفره بازی کن.",
    "Land on a lone opposing checker to pin it until you leave. Every win counts one point.":
        "روی یک مهرهٔ تنهای حریف فرود بیا تا آن را حبس کنی تا وقتی که از آنجا بروی. هر برد یک امتیاز دارد.",
    "Land on a lone opposing checker to pin it; pinning the mother checker can win two points.":
        "روی یک مهرهٔ تنهای حریف فرود بیا تا حبسش کنی؛ حبس کردن مهرهٔ مادر می\u200cتواند دو امتیاز بیاورد.",
    "Hit lone checkers to the bar; they must re-enter before anything else moves.":
        "مهره\u200cهای تنها را بزن و به بار بفرست؛ باید پیش از هر حرکت دیگری دوباره وارد شوند.",
    "Both sides race the same way round; one checker holds a point and nothing is hit.":
        "هر دو طرف در یک جهت می\u200cدوند؛ یک مهره خانه را نگه می\u200cدارد و هیچ مهره\u200cای زده نمی\u200cشود.",
    "You win": "بردی",
    "You win a double game": "با مارس بردی",
    "%@ wins a double game": "%@ با مارس برد",
    "Give up this game?": "از این بازی تسلیم می\u200cشوی؟",
    "You still have a %lld%% chance of winning.": "هنوز %lld%% شانس برد داری.",
    "The computer still rates your position at %@ points.": "کامپیوتر هنوز موقعیتت را %@ امتیاز ارزیابی می\u200cکند.",
    "Game %lld of %lld": "بازی %1$lld از %2$lld",
    "Final": "نهایی",
    "Next game": "بازی بعدی",
    "Rematch": "مسابقهٔ دوباره",
    "Back to lobby": "بازگشت به لابی",
    "Variant": "نوع بازی",
    "Advanced": "پیشرفته",
    "Best of 3": "بهترین از ۳",
    "One game": "یک بازی",
    "First to two games wins": "هر کس زودتر دو بازی ببرد، برنده است",
    "Portes → Fevga → Plakoto": "پورتس ← فوگا ← پلاکوتو",
    "No saved games yet": "هنوز بازی ذخیره\u200cشده\u200cای نیست",
    "Save a game from its menu to come back to it later.": "بازی را از منوی آن ذخیره کن تا بعداً به آن برگردی.",
    "1 move": "۱ حرکت",
    "%lld moves": "%lld حرکت",
    "Delete": "حذف",
    "Match length": "طول مسابقه",
    "Analyze during play": "تحلیل در حین بازی",
    "Work out each move's best play as you go, so the post-game review opens instantly. Off by default — it shares the computer's processing power, so the computer can be slower to move. Uses a little more battery.":
        "بهترین حرکت هر نوبت را همان موقع محاسبه می\u200cکند تا بررسی پس از بازی فوراً باز شود. به\u200cطور پیش\u200cفرض خاموش است — از توان پردازشی کامپیوتر سهم می\u200cبرد، پس ممکن است کامپیوتر کندتر حرکت کند. کمی باتری بیشتری مصرف می\u200cکند.",
    "No move": "بدون حرکت",
    "Mother pinned": "مادر حبس شد",
    "Random": "تصادفی",
    "Play the computer": "بازی با کامپیوتر",
    "Level %lld": "سطح %lld",
    "Level": "سطح",
    "Length": "طول",
    "Play": "بازی کن",
    "Game setup": "تنظیم بازی",
    "Single game": "تک\u200cبازی",
    "Standard Plakoto": "پلاکوتوی استاندارد",
    "Full Tavli plays all three variants in turn.": "تاولی کامل هر سه نوع بازی را به نوبت بازی می\u200cکند.",
    "The colour you play against the computer. Random picks a side for each new game.":
        "رنگی که با آن در برابر کامپیوتر بازی می\u200cکنی. «تصادفی» برای هر بازی جدید یک طرف را انتخاب می\u200cکند.",
    "Beginner: often misses the best move.": "مبتدی: اغلب بهترین حرکت را از دست می\u200cدهد.",
    "Casual: still slips up a lot.": "تفننی: هنوز زیاد اشتباه می\u200cکند.",
    "Relaxed: playable, with frequent slips.": "آرام: قابل بازی، با اشتباه\u200cهای مکرر.",
    "Solid: slips now and then.": "محکم: گاهی اشتباه می\u200cکند.",
    "Steady: rarely far from its best move.": "پایدار: به\u200cندرت از بهترین حرکتش دور است.",
    "Strong: only occasional slips.": "قوی: فقط گاه\u200cبه\u200cگاه اشتباه می\u200cکند.",
    "Sharp: always its best move, without looking ahead.": "تیز: همیشه بهترین حرکتش را می\u200cزند، بدون نگاه به جلو.",
    "Full strength: looks ahead to your reply.": "قدرت کامل: پاسخ تو را هم پیش\u200cبینی می\u200cکند.",
    "Computer": "کامپیوتر",
    "Computer is moving…": "کامپیوتر در حال حرکت است…",
    "Appearance": "ظاهر",
    "System": "سیستم",
    "Light": "روشن",
    "Dark": "تیره",
    "System follows your device's light or dark mode.": "«سیستم» از حالت روشن یا تیرهٔ دستگاهت پیروی می\u200cکند.",
    "%@: %lld checkers start 6 points ahead": "%1$@: %2$lld مهره ۶ خانه جلوتر شروع می\u200cکنند",
    "%@: %lld hints per game": "%1$@: %2$lld راهنمایی در هر بازی",
    "%@: %lld rerolls per game": "%1$@: %2$lld تاس دوباره در هر بازی",
    "%@: 1 checker starts 6 points ahead": "%@: ۱ مهره ۶ خانه جلوتر شروع می\u200cکند",
    "%@: 1 hint per game": "%@: ۱ راهنمایی در هر بازی",
    "%@: 1 reroll per game": "%@: ۱ تاس دوباره در هر بازی",
    "%@: bears off from the last %lld points only": "%1$@: فقط از %2$lld خانهٔ آخر مهره بیرون می\u200cبرد",
    "%@: may bear off with a higher die": "%@: می\u200cتواند با تاس بزرگ\u200cتر مهره بیرون ببرد",
    "%@: moves first": "%@: اول حرکت می\u200cکند",
    "%@: plays with %lld checkers": "%1$@: با %2$lld مهره بازی می\u200cکند",
    "%@: safe point %lld (a lone checker there can't be pinned)": "%1$@: خانهٔ امن %2$lld (مهرهٔ تنها آنجا حبس نمی\u200cشود)",
    "Checkers %lld–%lld": "مهره\u200cها %1$lld–%2$lld",
    "Dice favour %@ %@": "تاس\u200cها %2$@ به نفع %1$@ است",
    "Dice favour you %@": "تاس\u200cها %@ به نفع توست",
    "Head start %lld": "شروع جلوتر %lld",
    "Hints %lld": "راهنمایی %lld",
    "Home %lld points": "منطقهٔ خودی %lld خانه",
    "Moderate": "متوسط",
    "Moves first": "اول حرکت می\u200cکند",
    "Off": "خاموش",
    "On": "روشن",
    "Overshoot bear-off": "بیرون بردن با تاس بزرگ\u200cتر",
    "Rerolls %lld": "تاس دوباره %lld",
    "Safe point %lld": "خانهٔ امن %lld",
    "Slight": "کم",
    "Strong": "زیاد",
    "Very strong": "خیلی زیاد",
    "Weighted dice": "تاس\u200cهای وزن\u200cدار",
    "moderately": "تا حدی",
    "slightly": "کمی",
    "strongly": "خیلی",
    "very strongly": "بسیار زیاد",
    "%lld checkers": "%lld مهره",
    "%lld per game": "%lld در هر بازی",
    "1 checker": "۱ مهره",
    "A lone checker of this side on this point can't be pinned. Points count from the side's own start. A small advantage.":
        "مهرهٔ تنهای این طرف روی این خانه حبس نمی\u200cشود. خانه\u200cها از نقطهٔ شروع همان طرف شمرده می\u200cشوند. یک برتری کوچک.",
    "Always starts the game; no opening roll.": "همیشه بازی را شروع می\u200cکند؛ بدون تاس شروع.",
    "Applies to offline games of Plakoto (house rules), single or Best of 3. Not online or Full Tavli.":
        "برای بازی\u200cهای آفلاین پلاکوتو (قوانین خانگی)، تک\u200cبازی یا بهترین از ۳. نه آنلاین و نه تاولی کامل.",
    "Bear off only from the last points of the home board. A smaller home is a disadvantage.":
        "مهره\u200cها فقط از آخرین خانه\u200cهای منطقهٔ خودی بیرون برده می\u200cشوند. منطقهٔ خودی کوچک\u200cتر یک ضعف است.",
    "Before each roll the dice lean towards rolls that are good for this side. The game says so in its Handicap tag.":
        "پیش از هر ریختن، تاس\u200cها به سمت عددهایی متمایل می\u200cشوند که برای این طرف خوب است. بازی این را در برچسب هندیکپ نشان می\u200cدهد.",
    "Checkers": "مهره\u200cها",
    "Checkers that start 6 points ahead of the stack.": "مهره\u200cهایی که ۶ خانه جلوتر از دسته شروع می\u200cکنند.",
    "For": "برای",
    "Give one side an advantage so players of different strength get a close game.":
        "به یک طرف برتری بده تا بازیکنان با قدرت متفاوت بازی نزدیکی داشته باشند.",
    "Handicap": "هندیکپ",
    "Head start": "شروع جلوتر",
    "Hints": "راهنمایی\u200cها",
    "Home size": "اندازهٔ منطقهٔ خودی",
    "How many checkers each side plays with (normally 15). More checkers is the advantage.":
        "هر طرف با چند مهره بازی کند (معمولاً ۱۵). مهرهٔ بیشتر یعنی برتری.",
    "May bear off with a higher die than needed, from the farthest checker (as in standard Plakoto). A big advantage.":
        "می\u200cتواند با تاسی بزرگ\u200cتر از لازم، از دورترین مهره بیرون ببرد (مثل پلاکوتوی استاندارد). یک برتری بزرگ.",
    "Playing the computer": "بازی با کامپیوتر",
    "Rerolls": "تاس دوباره",
    "Roll again after seeing the dice, this many times per game.": "پس از دیدن تاس\u200cها دوباره بریز، به این تعداد در هر بازی.",
    "Rule changes": "تغییر قوانین",
    "Safe point": "خانهٔ امن",
    "Show the computer's best move (without playing it), this many times per game.":
        "بهترین حرکت کامپیوتر را (بدون انجام دادنش) نشان بده، به این تعداد در هر بازی.",
    "Sides": "طرف\u200cها",
    "Two players": "دو نفره",
    "Use handicaps": "استفاده از هندیکپ",
    "Your next game is %@, so it will be played without a handicap.": "بازی بعدی\u200cات %@ است، پس بدون هندیکپ بازی می\u200cشود.",
    "Your next game is Full Tavli, so it will be played without a handicap.": "بازی بعدی\u200cات تاولی کامل است، پس بدون هندیکپ بازی می\u200cشود.",
    "%@ %@ · %@ %@": "%1$@ %2$@ · %3$@ %4$@",
    "%@: hints left %lld of %lld": "%1$@: %2$lld از %3$lld راهنمایی مانده",
    "%@: not measured yet, so not in the number.": "%@: هنوز اندازه\u200cگیری نشده، پس در این عدد حساب نشده.",
    "%@: rerolls left %lld of %lld": "%1$@: %2$lld از %3$lld تاس دوباره مانده",
    "%lld games": "%lld بازی",
    "%lldW – %lldL": "%1$lld برد – %2$lld باخت",
    "1 game": "۱ بازی",
    "Best move shown in blue": "بهترین حرکت با آبی نشان داده شده",
    "Computer used a reroll (%lld left)": "کامپیوتر تاس را دوباره ریخت (%lld مانده)",
    "Estimate needs the computer's model, which isn't available.": "تخمین به مدل کامپیوتر نیاز دارد که در دسترس نیست.",
    "Estimated win chance": "شانس برد تخمینی",
    "Estimated win chance (approx.)": "شانس برد تخمینی (تقریبی)",
    "Estimating…": "در حال تخمین…",
    "Handicap game: win chances assume fair dice": "بازی با هندیکپ: شانس\u200cهای برد با فرض تاس منصفانه است",
    "Handicap games": "بازی\u200cهای با هندیکپ",
    "Hint (%lld left)": "راهنمایی (%lld مانده)",
    "Hints aren't counted: what they're worth depends on the player.": "راهنمایی\u200cها حساب نمی\u200cشوند: ارزششان به بازیکن بستگی دارد.",
    "If both played at the computer's full strength.": "اگر هر دو با قدرت کامل کامپیوتر بازی می\u200cکردند.",
    "Not counted in your record against the computer.": "در کارنامهٔ تو در برابر کامپیوتر حساب نمی\u200cشود.",
    "Reroll (%lld left)": "تاس دوباره (%lld مانده)",
    "Weighted dice and rerolls": "تاس\u200cهای وزن\u200cدار و تاس دوباره",
    "Win chances in the review and the win-probability bar still assume fair dice.":
        "شانس\u200cهای برد در بررسی و نوار احتمال برد همچنان تاس منصفانه را فرض می\u200cکنند.",
    "Your opponent left the match. You win!": "حریفت مسابقه را ترک کرد. تو بردی!",
    "Couldn’t send your move. It’s saved and will be sent when you’re back online.":
        "حرکتت ارسال نشد. ذخیره شده و وقتی دوباره آنلاین شوی ارسال می\u200cشود.",
    "It’s your turn in another game.": "در یک بازی دیگر نوبت توست.",
    "It’s your turn against %@.": "در بازی با %@ نوبت توست.",
    "Finished": "تمام\u200cشده",
    "Remove": "حذف",
    "Forfeit this match?": "از این مسابقه انصراف می\u200cدهی؟",
    "Forfeit": "انصراف",
    "%@ wins the match. To continue later instead, use the back button.":
        "%@ مسابقه را می\u200cبرد. اگر می\u200cخواهی بعداً ادامه دهی، از دکمهٔ بازگشت استفاده کن.",
    "Match ended.": "مسابقه تمام شد.",
    "Opponent": "حریف",
    "Sign in to Game Center to play online.": "برای بازی آنلاین وارد Game Center شو.",
    "Their turn": "نوبت حریف",
    "Your turn": "نوبت توست",
    "Waiting for opponent to start…": "در انتظار شروع حریف…",
}

SPEC = re.compile(r"%(?:(\d+)\$)?(lld|@|%)")
ARABIC_LOOKALIKES = {"ي": "ي (use Persian ی)", "ك": "ك (use Persian ک)"}


def specifiers(s: str) -> list[str]:
    """The argument types in argument order (positional resolved; `%%` ignored)."""
    out, implicit = {}, 0
    for m in SPEC.finditer(s):
        pos, kind = m.groups()
        if kind == "%":
            continue
        if pos is None:
            implicit += 1
            idx = implicit
        else:
            idx = int(pos)
        out[idx] = kind
    return [out[i] for i in sorted(out)]


def check(key: str, value: str) -> None:
    assert specifiers(key) == specifiers(value), f"format specifiers differ: {key!r} -> {value!r}"
    assert key.count("%%") == value.count("%%"), f"%% differs: {key!r}"
    for ch, why in ARABIC_LOOKALIKES.items():
        assert ch not in value, f"{why} in {value!r}"


def main() -> None:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else
                Path(__file__).resolve().parent.parent / "TavliApp/TavliApp/Localizable.xcstrings")
    catalog = json.loads(path.read_text(encoding="utf-8"))
    strings = catalog["strings"]

    missing = [k for k, v in strings.items() if "de" in v.get("localizations", {}) and k not in FA]
    stale = [k for k in FA if k not in strings]
    if missing:
        sys.exit("No Persian for: " + ", ".join(map(repr, missing)))
    if stale:
        print("note: not in the catalog (skipped): " + ", ".join(map(repr, stale)))

    for key, value in FA.items():
        if key not in strings:
            continue
        check(key, value)
        locs = strings[key].setdefault("localizations", {})
        locs["fa"] = {"stringUnit": {"state": "translated", "value": value}}
        # Xcode keeps a key's languages sorted; match it so the diff stays minimal.
        strings[key]["localizations"] = dict(sorted(locs.items()))

    text = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "))
    path.write_text(text, encoding="utf-8")  # Xcode writes no trailing newline
    print(f"fa: {sum(k in strings for k in FA)} strings written to {path}")


if __name__ == "__main__":
    main()
