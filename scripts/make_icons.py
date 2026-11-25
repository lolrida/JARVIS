"""Render the JARVIS app icons (PNG; iOS home-screen icons must be PNG). Run: python scripts/make_icons.py"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "jarvis" / "static" / "app" / "icons"
ASSETS = ROOT / "ios" / "JARVIS" / "Assets.xcassets"
S = 1024  # draw large, then downsample for smooth edges
BG = (11, 17, 28)
CYAN = (88, 196, 255)


def render() -> Image.Image:
    img = Image.new("RGB", (S, S), BG)
    c = S // 2

    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    g.ellipse([c - 300, c - 300, c + 300, c + 300], outline=CYAN + (255,), width=60)
    g.ellipse([c - 90, c - 90, c + 90, c + 90], fill=CYAN + (255,))
    glow = glow.filter(ImageFilter.GaussianBlur(40))
    img.paste(glow, (0, 0), glow)

    d = ImageDraw.Draw(img)
    d.ellipse([c - 300, c - 300, c + 300, c + 300], outline=CYAN, width=34)
    for i in range(12):  # segmented inner ring
        d.arc([c - 215, c - 215, c + 215, c + 215], i * 30 + 4, i * 30 + 24, fill=CYAN, width=26)
    d.ellipse([c - 82, c - 82, c + 82, c + 82], fill=(225, 246, 255))
    return img


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    big = render()
    for size, name in [(180, "apple-touch-icon.png"), (192, "icon-192.png"), (512, "icon-512.png")]:
        big.resize((size, size), Image.LANCZOS).save(OUT / name, optimize=True)
    # Maskable: same art shrunk into the safe zone so Android launchers don't crop the ring.
    m = Image.new("RGB", (S, S), BG)
    m.paste(big.resize((int(S * 0.8),) * 2, Image.LANCZOS), (int(S * 0.1),) * 2)
    m.resize((512, 512), Image.LANCZOS).save(OUT / "icon-maskable-512.png", optimize=True)
    # Native iOS app: one 1024px icon (RGB, no transparency, as the App Store requires) and an in-app logo.
    big.save(ASSETS / "AppIcon.appiconset" / "icon-1024.png", optimize=True)
    big.resize((256, 256), Image.LANCZOS).save(ASSETS / "Logo.imageset" / "logo.png", optimize=True)
    print("wrote icons")


if __name__ == "__main__":
    main()
