#!/usr/bin/env python3
"""Renders the Mac App Store screenshots: base/<name>.png framed under its caption, one set per language,
into <lang>/<name>.png at 2880×1800 (16:10, as the Mac App Store requires). Needs Google Chrome."""
import html, json, pathlib, re, subprocess, tempfile

here = pathlib.Path(__file__).resolve().parent
chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
template = (here / "template.html").read_text()
captions = json.loads((here / "captions.json").read_text())


def typeset(text):
    """Keeps short words (prepositions, conjunctions) with the next word and a dash with the
    previous one, so no line ends with "на" or starts with "—"."""
    text = re.sub(r"(?<!\S)(\w{1,2}) ", "\\1\u00a0", text)
    return text.replace(" —", "\u00a0—")


for name, langs in captions.items():
    for lang, (title, subtitle) in langs.items():
        page = (template.replace("{{title}}", html.escape(typeset(title)))
                .replace("{{subtitle}}", html.escape(typeset(subtitle)))
                .replace("{{image}}", (here / "base" / f"{name}.png").as_uri()))
        out = here / lang / f"{name}.png"
        out.parent.mkdir(exist_ok=True)
        with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
            f.write(page)
        subprocess.run([chrome, "--headless", "--disable-gpu", "--hide-scrollbars",
                        "--force-device-scale-factor=1", "--window-size=2880,1800",
                        "--allow-file-access-from-files", f"--screenshot={out}", pathlib.Path(f.name).as_uri()],
                       check=True, stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        pathlib.Path(f.name).unlink()
        print(out.relative_to(here))
