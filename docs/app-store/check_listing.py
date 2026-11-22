"""Check docs/app-store/listing.md against App Store Connect's field limits.

Usage: python3 docs/app-store/check_listing.py
"""
import pathlib, re, sys

LIMITS = {"Name": 30, "Subtitle": 30, "Promotional text": 170, "Keywords": 100, "Description": 4000}
text = (pathlib.Path(__file__).parent / "listing.md").read_text(encoding="utf-8")
ok = True
for section in re.split(r"\n## ", text)[1:]:
    locale = section.splitlines()[0]
    if locale.startswith("Shared"):
        continue
    fields = {}
    for m in re.finditer(r"\*\*(Name|Subtitle):\*\* (.+)", section):
        fields[m.group(1)] = m.group(2).strip()
    for key in ("Promotional text", "Keywords"):
        m = re.search(rf"\*\*{key}:\*\*\n(.+)", section)
        fields[key] = m.group(1).strip() if m else ""
    m = re.search(r"\*\*Description:\*\*\n\n```\n(.*?)\n```", section, re.S)
    fields["Description"] = m.group(1) if m else ""
    words = {w.lower() for f in ("Name", "Subtitle") for w in re.findall(r"\w+", fields.get(f, ""))}
    dup = [k for k in fields["Keywords"].split(",") if k.strip().lower() in words]
    print(f"\n{locale}")
    for key, limit in LIMITS.items():
        n = len(fields.get(key, ""))
        flag = "OK " if 0 < n <= limit else "BAD"
        ok &= flag == "OK "
        print(f"  {flag} {key:17} {n:4}/{limit}")
    if " ," in fields["Keywords"] or ", " in fields["Keywords"]:
        ok = False; print("  BAD keywords contain spaces around commas")
    if dup:
        print(f"  note: keywords repeat name/subtitle words: {dup}")
sys.exit(0 if ok else 1)
