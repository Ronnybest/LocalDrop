#!/usr/bin/env python3
"""Renders the store screenshots: base/<name>.png framed under its caption, one set per language,
into <lang>/<name>.png at 1080×1920 (9:16, as Play requires). Needs Google Chrome."""
import html, json, pathlib, subprocess, tempfile

here = pathlib.Path(__file__).resolve().parent
chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
template = (here / "template.html").read_text()
captions = json.loads((here / "captions.json").read_text())

for name, langs in captions.items():
    for lang, (title, subtitle) in langs.items():
        page = (template.replace("{{title}}", html.escape(title))
                .replace("{{subtitle}}", html.escape(subtitle))
                .replace("{{image}}", (here / "base" / f"{name}.png").as_uri()))
        out = here / lang / f"{name}.png"
        out.parent.mkdir(exist_ok=True)
        with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
            f.write(page)
        subprocess.run([chrome, "--headless", "--disable-gpu", "--hide-scrollbars",
                        "--force-device-scale-factor=1", "--window-size=1080,1920",
                        "--allow-file-access-from-files", f"--screenshot={out}", pathlib.Path(f.name).as_uri()],
                       check=True, stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        pathlib.Path(f.name).unlink()
        print(out.relative_to(here))
