#!/usr/bin/env python3
"""Look at scenario captures in one call (Python 3 + Pillow).

  python look.py <out_dir> [--screen top|bottom|both] [--crop x,y,w,h] [--scale N]
                 [--sheet] [--match GLOB] [--gif] [--fps 15] [--out DIR]

<out_dir> is a scenario output folder or a suite folder (subfolders are walked).
Captures are 256x384 (top screen y 0..191, bottom y 192..383); --crop is in
DS pixels of the chosen screen. Scaling is always NEAREST. Prints a short summary.
"""
import argparse, fnmatch, json, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

W, H = 256, 192


def find_pngs(root, match):
    out = []
    for p in sorted(root.rglob("*.png")):
        rel = p.relative_to(root)
        if "_look" in rel.parts:
            continue
        if match and not (fnmatch.fnmatch(p.name, match) or fnmatch.fnmatch(p.stem, match)
                          or fnmatch.fnmatch(rel.as_posix(), match)):
            continue
        out.append(p)
    return out


def label_of(p, root):
    rel = p.relative_to(root)
    return "/".join(rel.parts[:-1] + (p.stem,))


def has_content(img):
    return img.convert("RGB").getbbox() is not None


def pick_screen(img, screen):
    img = img.convert("RGB")
    if img.height < 2 * H:  # single-screen capture
        return img
    top, bot = img.crop((0, 0, W, H)), img.crop((0, H, W, 2 * H))
    if screen == "top":
        return top
    if screen == "bottom":
        return bot
    if screen == "both":
        return img
    t, b = has_content(top), has_content(bot)
    if t and b:
        return img
    return bot if b and not t else top


def process(p, a, crop):
    img = pick_screen(Image.open(p), a.screen)
    if crop:
        x, y, w, h = crop
        img = img.crop((x, y, x + w, y + h))
    s = a.scale or (4 if crop else 2)
    return img.resize((img.width * s, img.height * s), Image.NEAREST)


def read_results(root):
    """Return (status line, [fail lines]) from result.json / suite.json files."""
    lines, status = [], []
    files = sorted(root.rglob("result.json"))
    for f in files:
        if "_look" in f.parts:
            continue
        try:
            r = json.loads(f.read_text(encoding="utf-8-sig"))
        except Exception:
            lines.append(f"{f.parent.name}: result.json ilegible")
            continue
        st = r.get("status", "?")
        status.append(st)
        name = r.get("name") or f.parent.name
        if st != "PASS":
            lines.append(f"{name}: {st}")
            for d in (r.get("failed") or [])[:3]:
                if isinstance(d, dict):
                    msg = d.get("message") or f"{d.get('check')} expected={d.get('expected')} actual={d.get('actual')}"
                else:
                    msg = str(d)
                lines.append("  - " + " ".join(str(msg).split())[:160])
            err = r.get("error")
            if err:
                lines.append("  error: " + " ".join(str(err).split())[:160])
    head = "sin result.json"
    if status:
        n = len(status)
        npass = status.count("PASS")
        head = ("PASS" if npass == n else "FAIL") + f" ({npass}/{n} escenarios PASS)"
    sj = root / "suite.json"
    if sj.is_file():
        try:
            s = json.loads(sj.read_text(encoding="utf-8-sig"))
            head = f"{s.get('status')} (suite {s.get('pass')}/{s.get('total')} PASS)"
        except Exception:
            pass
    return head, lines[:12]


def make_sheet(items, out_path, cell_w):
    import math
    font = ImageFont.load_default()
    n = len(items)
    cols = max(1, min(n, max(1, 1600 // (cell_w + 8))))
    rows = math.ceil(n / cols)
    cell_h = max(i.height for _, i in items)
    lab_h = 14
    sheet = Image.new("RGB", (cols * (cell_w + 8) + 8, rows * (cell_h + lab_h + 8) + 8), (32, 32, 32))
    d = ImageDraw.Draw(sheet)
    for k, (lab, im) in enumerate(items):
        x = 8 + (k % cols) * (cell_w + 8)
        y = 8 + (k // cols) * (cell_h + lab_h + 8)
        sheet.paste(im, (x, y))
        d.text((x, y + im.height + 2), lab[-max(8, cell_w // 6):], fill=(235, 235, 235), font=font)
    sheet.save(out_path)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder")
    ap.add_argument("--screen", choices=["top", "bottom", "both"], default="auto")
    ap.add_argument("--crop")
    ap.add_argument("--scale", type=int)
    ap.add_argument("--sheet", action="store_true")
    ap.add_argument("--match")
    ap.add_argument("--gif", action="store_true")
    ap.add_argument("--fps", type=int, default=15)
    ap.add_argument("--out")
    a = ap.parse_args()

    root = Path(a.folder)
    if not root.is_dir():
        sys.exit(f"No existe la carpeta: {root}")
    crop = None
    if a.crop:
        try:
            crop = tuple(int(v) for v in a.crop.split(","))
            assert len(crop) == 4 and crop[2] > 0 and crop[3] > 0
        except Exception:
            sys.exit("--crop debe ser x,y,w,h")
    fps = max(15, a.fps)
    out = Path(a.out) if a.out else root / "_look"
    out.mkdir(parents=True, exist_ok=True)

    head, fails = read_results(root)
    pngs = find_pngs(root, a.match)
    print(f"RESULTADO: {head}")
    for l in fails:
        print(l)
    print(f"Capturas: {len(pngs)}")
    if not pngs:
        return
    items = [(label_of(p, root), process(p, a, crop)) for p in pngs]
    made = []
    if a.sheet:
        cell_w = max(i.width for _, i in items)
        sp = out / "sheet.png"
        make_sheet(items, sp, cell_w)
        made.append(sp)
    if a.gif:
        gp = out / "anim.gif"
        frames = [i for _, i in items]
        frames[0].save(gp, save_all=True, append_images=frames[1:], duration=max(1, 1000 // fps), loop=0)
        made.append(gp)
    if not a.sheet and not a.gif:
        for (lab, im) in items[:40]:
            ip = out / (lab.replace("/", "__") + ".png")
            im.save(ip)
            made.append(ip)
    for m in made[:12]:
        print(f"IMG: {m}")
    if len(made) > 12:
        print(f"... y {len(made) - 12} imagenes mas en {out}")


if __name__ == "__main__":
    main()
