#!/usr/bin/env python3
"""Generuje strony wiki GitHub z pomocy programu (Sources/FT710Control/Help.swift).

Wiki zawsze mówi to samo co pomoc w programie - po zmianie pomocy wystarczy uruchomić skrypt ponownie.

Użycie (w folderze projektu):
    python3 tools/make_wiki.py              -> build/wiki/*.md
    python3 tools/make_wiki.py <folder>     -> <folder>/*.md (np. sklonowane repozytorium wiki)
"""
import os
import re
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELP = os.path.join(ROOT, "Sources", "FT710Control", "Help.swift")
ADIF = os.path.join(ROOT, "Sources", "FT710Control", "ADIF.swift")
REPO = "https://github.com/sp5xtf/FT710Control"


def read_topics():
    text = open(HELP, encoding="utf-8").read()
    pattern = re.compile(
        r'HelpTopic\(id: "(?P<id>[^"]+)", icon: "[^"]*", titlePL: "(?P<tpl>[^"]+)", titleEN: "(?P<ten>[^"]+)",\s*'
        r'bodyPL: """\n(?P<bpl>.*?)\n"""\s*,\s*bodyEN: """\n(?P<ben>.*?)\n"""', re.S)
    topics = [m.groupdict() for m in pattern.finditer(text)]
    if len(topics) != len(re.findall(r'HelpTopic\(id: "', text)):
        sys.exit("Nie udało się odczytać wszystkich tematów pomocy - sprawdź format Help.swift")
    return topics


def version():
    m = re.search(r'programVersion = "([^"]+)"', open(ADIF, encoding="utf-8").read())
    return m.group(1) if m else "?"


def slug(title):
    """Nazwa strony: bez znaków diakrytycznych i interpunkcji (np. „Praca zdalna” -> „Praca-zdalna”)."""
    ascii_title = unicodedata.normalize("NFKD", title.replace("ł", "l").replace("Ł", "L"))
    ascii_title = "".join(c for c in ascii_title if not unicodedata.combining(c))
    ascii_title = re.sub(r"[^A-Za-z0-9]+", "-", ascii_title).strip("-")
    return ascii_title


def to_markdown(body):
    """Format pomocy -> Markdown GitHub: wiersz „**Tytuł**” = nagłówek, „•” = punkt listy, wiersz = akapit."""
    out = []
    for line in body.split("\n"):
        stripped = line.strip()
        if not stripped:
            continue
        if re.fullmatch(r"\*\*[^*]+\*\*", stripped):                      # sam pogrubiony wiersz - nagłówek
            out.append(("heading", "### " + stripped[2:-2]))
        elif stripped.startswith("•"):
            out.append(("list", "- " + stripped[1:].strip()))
        elif re.match(r"\d+\. ", stripped):
            out.append(("list", stripped))
        else:
            out.append(("para", stripped))
    lines = []
    for i, (kind, text) in enumerate(out):
        lines.append(text)
        following = out[i + 1][0] if i + 1 < len(out) else None
        if not (kind == "list" and following == "list"):               # elementy listy razem, reszta osobno
            lines.append("")
    return "\n".join(lines).strip() + "\n"


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "wiki")
    os.makedirs(target, exist_ok=True)
    # strony usuniętych tematów nie mogą zostać w wiki - wszystkie strony są generowane, więc stare .md usuwamy
    # (tylko w folderze wiki: pustym albo z Home.md)
    existing = [f for f in os.listdir(target) if f.endswith(".md")]
    if not existing or "Home.md" in existing:
        for name in existing:
            os.remove(os.path.join(target, name))
    topics = read_topics()
    ver = version()
    en_pages = [(t, slug(t["ten"])) for t in topics]
    pl_pages = [(t, "PL-" + slug(t["tpl"])) for t in topics]
    names = [n for _, n in en_pages + pl_pages]
    if len(set(names)) != len(names):
        sys.exit("Powtarzające się nazwy stron wiki")

    def nav(pages, index, home, prev_label, next_label):
        parts = []
        if index > 0:
            parts.append(f"← [{pages[index - 1][0]['ten' if home == 'Home' else 'tpl']}]({pages[index - 1][1]})")
        parts.append(f"[{'Home' if home == 'Home' else 'Strona główna'}](Home)")
        if index + 1 < len(pages):
            parts.append(f"[{pages[index + 1][0]['ten' if home == 'Home' else 'tpl']}]({pages[index + 1][1]}) →")
        return " · ".join(parts)

    for i, (topic, name) in enumerate(en_pages):
        pl_name = pl_pages[i][1]
        content = (f"# {topic['ten']}\n\n*[Wersja polska]({pl_name})*\n\n{to_markdown(topic['ben'])}\n---\n"
                   f"{nav(en_pages, i, 'Home', 'Previous', 'Next')}\n")
        open(os.path.join(target, name + ".md"), "w", encoding="utf-8").write(content)
    for i, (topic, name) in enumerate(pl_pages):
        en_name = en_pages[i][1]
        content = (f"# {topic['tpl']}\n\n*[English version]({en_name})*\n\n{to_markdown(topic['bpl'])}\n---\n"
                   f"{nav(pl_pages, i, 'Strona', 'Poprzednia', 'Następna')}\n")
        open(os.path.join(target, name + ".md"), "w", encoding="utf-8").write(content)

    en_list = "\n".join(f"- [{t['ten']}]({n})" for t, n in en_pages)
    pl_list = "\n".join(f"- [{t['tpl']}]({n})" for t, n in pl_pages)
    home = f"""# FT-710 Control

**A native macOS station program for the Yaesu FT-710** – rig control, RF scope and waterfall, FT8/FT4
(including Fox/Hound), logbook with QSL confirmations and awards, DX Cluster, POTA, contests, CW/RTTY/SSTV and
remote operation from an iPhone or iPad browser.

> **Public beta {ver}.** Download: [Releases]({REPO}/releases) · Bug reports: [Issues]({REPO}/issues) ·
> Requirements: macOS 13 or later, Apple Silicon, Yaesu FT-710 over USB.

This documentation is the program's built-in help (menu **Help → FT-710 Control Help**, ⌘?), in English and Polish.

## English

{en_list}

## Po polsku

**FT-710 Control** – program stacyjny dla Yaesu FT-710 na macOS. Dokumentacja to wbudowana pomoc programu
(menu **Pomoc**, ⌘?).

{pl_list}
"""
    open(os.path.join(target, "Home.md"), "w", encoding="utf-8").write(home)
    sidebar = f"**[Home](Home)**\n\n**English**\n\n{en_list}\n\n**Po polsku**\n\n{pl_list}\n"
    open(os.path.join(target, "_Sidebar.md"), "w", encoding="utf-8").write(sidebar)
    footer = (f"*Generated from the built-in help of FT-710 Control {ver} – do not edit here; changes go into the program "
              f"(Help.swift) and `tools/make_wiki.py`. · Wygenerowane z pomocy programu – nie edytuj tutaj.*\n")
    open(os.path.join(target, "_Footer.md"), "w", encoding="utf-8").write(footer)
    print(f"Wiki: {len(en_pages) + len(pl_pages) + 3} plików w {target} (wersja {ver})")


if __name__ == "__main__":
    main()
