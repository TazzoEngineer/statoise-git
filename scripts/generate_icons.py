#!/usr/bin/env python3
"""Generate overlay icons and app icon for Statoise Git.

Overlay icons: simple circular badges with symbols
App icon: git branch symbol with 'S' branding
"""

from PIL import Image, ImageDraw, ImageFont
import os
import math

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
OVERLAY_DIR_EXT = os.path.join(PROJECT_ROOT, "StatoiseGit/FinderExtension/OverlayIcons")
OVERLAY_DIR_RES = os.path.join(PROJECT_ROOT, "StatoiseGit/Resources/OverlayIcons")
APP_ICON_DIR = os.path.join(PROJECT_ROOT, "StatoiseGit/Resources/Assets.xcassets/AppIcon.appiconset")


def draw_circle_badge(draw, size, bg_color, border_color=None):
    """Draw a filled circle badge."""
    margin = size // 8
    bbox = [margin, margin, size - margin, size - margin]
    draw.ellipse(bbox, fill=bg_color)
    if border_color:
        draw.ellipse(bbox, outline=border_color, width=max(2, size // 40))


def draw_checkmark(draw, size, color):
    """Draw a checkmark symbol."""
    cx, cy = size // 2, size // 2
    s = size // 4
    points = [
        (cx - s * 0.6, cy),
        (cx - s * 0.1, cy + s * 0.5),
        (cx + s * 0.8, cy - s * 0.5),
    ]
    draw.line(points, fill=color, width=max(3, size // 20), joint="curve")


def draw_plus(draw, size, color):
    """Draw a plus symbol."""
    cx, cy = size // 2, size // 2
    s = size // 5
    w = max(3, size // 20)
    draw.line([(cx - s, cy), (cx + s, cy)], fill=color, width=w)
    draw.line([(cx, cy - s), (cx, cy + s)], fill=color, width=w)


def draw_x(draw, size, color):
    """Draw an X symbol."""
    cx, cy = size // 2, size // 2
    s = size // 5
    w = max(3, size // 20)
    draw.line([(cx - s, cy - s), (cx + s, cy + s)], fill=color, width=w)
    draw.line([(cx + s, cy - s), (cx - s, cy + s)], fill=color, width=w)


def draw_exclamation(draw, size, color):
    """Draw an exclamation mark."""
    cx, cy = size // 2, size // 2
    s = size // 5
    w = max(3, size // 18)
    draw.line([(cx, cy - s), (cx, cy + s * 0.3)], fill=color, width=w)
    dot_r = max(2, size // 40)
    draw.ellipse([cx - dot_r, cy + s * 0.7 - dot_r, cx + dot_r, cy + s * 0.7 + dot_r], fill=color)


def draw_warning(draw, size, color):
    """Draw a warning triangle with !"""
    cx, cy = size // 2, size // 2
    s = size // 4
    # Triangle
    points = [(cx, cy - s), (cx - s, cy + s * 0.7), (cx + s, cy + s * 0.7)]
    draw.polygon(points, outline=color, fill=None)
    # Inner !
    w = max(2, size // 30)
    draw.line([(cx, cy - s * 0.3), (cx, cy + s * 0.2)], fill=color, width=w)
    dot_r = max(1, size // 50)
    draw.ellipse([cx - dot_r, cy + s * 0.4 - dot_r, cx + dot_r, cy + s * 0.4 + dot_r], fill=color)


def draw_dash(draw, size, color):
    """Draw a dash/minus symbol."""
    cx, cy = size // 2, size // 2
    s = size // 5
    w = max(3, size // 20)
    draw.line([(cx - s, cy), (cx + s, cy)], fill=color, width=w)


def draw_question(draw, size, color):
    """Draw a question mark."""
    cx, cy = size // 2, size // 2
    s = size // 5
    w = max(2, size // 25)
    # Curve of ?
    arc_bbox = [cx - s * 0.6, cy - s, cx + s * 0.6, cy + s * 0.3]
    draw.arc(arc_bbox, start=180, end=360, fill=color, width=w)
    draw.line([(cx + s * 0.6, cy - s * 0.35), (cx, cy + s * 0.1)], fill=color, width=w)
    dot_r = max(1, size // 50)
    draw.ellipse([cx - dot_r, cy + s * 0.5 - dot_r, cx + dot_r, cy + s * 0.5 + dot_r], fill=color)


def draw_lock(draw, size, color):
    """Draw a padlock symbol."""
    cx, cy = size // 2, size // 2
    s = size // 5
    w = max(2, size // 30)
    # Lock body
    body = [cx - s * 0.6, cy - s * 0.1, cx + s * 0.6, cy + s * 0.7]
    draw.rectangle(body, outline=color, width=w, fill=None)
    # Shackle
    arc_bbox = [cx - s * 0.4, cy - s * 0.8, cx + s * 0.4, cy]
    draw.arc(arc_bbox, start=180, end=0, fill=color, width=w)


def draw_pencil(draw, size, color):
    """Draw a pencil/edit symbol."""
    cx, cy = size // 2, size // 2
    s = size // 4
    w = max(2, size // 25)
    # Diagonal line (pencil body)
    draw.line([(cx - s * 0.6, cy + s * 0.6), (cx + s * 0.6, cy - s * 0.6)], fill=color, width=w)
    # Pencil tip
    draw.polygon([
        (cx - s * 0.6, cy + s * 0.6),
        (cx - s * 0.8, cy + s * 0.8),
        (cx - s * 0.4, cy + s * 0.8),
    ], fill=color)


# Define overlay icons: (name, bg_color, symbol_func, symbol_color)
OVERLAY_ICONS = [
    ("NormalIcon", (56, 176, 80), draw_checkmark, (255, 255, 255)),       # Green + white checkmark
    ("ModifiedIcon", (230, 126, 34), draw_pencil, (255, 255, 255)),       # Orange + white pencil
    ("AddedIcon", (52, 152, 219), draw_plus, (255, 255, 255)),            # Blue + white plus
    ("ConflictIcon", (231, 76, 60), draw_warning, (255, 255, 255)),       # Red + white warning
    ("DeletedIcon", (192, 57, 43), draw_x, (255, 255, 255)),             # Dark red + white X
    ("IgnoredIcon", (149, 165, 166), draw_dash, (255, 255, 255)),         # Gray + white dash
    ("LockedIcon", (142, 68, 173), draw_lock, (255, 255, 255)),           # Purple + white lock
    ("UnversionedIcon", (127, 140, 141), draw_question, (255, 255, 255)), # Dark gray + white ?
    ("ReadOnlyIcon", (108, 117, 125), draw_lock, (255, 255, 255)),        # Slate + white lock
]


def generate_overlay_icon(name, bg_color, symbol_func, symbol_color, size):
    """Generate a single overlay icon."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw_circle_badge(draw, size, bg_color)
    symbol_func(draw, size, symbol_color)
    return img


def generate_app_icon(size):
    """Generate app icon: rounded square with git branch symbol and 'S'."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Rounded rectangle background (gradient-like: dark blue to teal)
    margin = size // 16
    corner_radius = size // 5
    bg_color = (41, 60, 93)  # Dark navy blue

    # Draw rounded rect
    bbox = [margin, margin, size - margin, size - margin]
    draw.rounded_rectangle(bbox, radius=corner_radius, fill=bg_color)

    # Draw git branch symbol
    cx, cy = size // 2, size // 2
    s = size // 3
    node_r = size // 16
    line_w = max(4, size // 40)
    branch_color = (100, 200, 240)  # Light cyan/blue

    # Main vertical line (trunk)
    trunk_top = cy - s * 0.7
    trunk_bottom = cy + s * 0.7
    draw.line([(cx - s * 0.15, trunk_top), (cx - s * 0.15, trunk_bottom)],
              fill=branch_color, width=line_w)

    # Branch line
    branch_start = (cx - s * 0.15, cy - s * 0.1)
    branch_end = (cx + s * 0.35, cy - s * 0.5)
    # Curved branch via intermediate point
    mid = (cx + s * 0.1, cy - s * 0.1)
    draw.line([branch_start, mid, branch_end], fill=branch_color, width=line_w, joint="curve")

    # Nodes (circles at endpoints)
    for (nx, ny) in [(cx - s * 0.15, trunk_top), (cx - s * 0.15, trunk_bottom), branch_end]:
        draw.ellipse([nx - node_r, ny - node_r, nx + node_r, ny + node_r],
                     fill=branch_color)

    # 'S' letter (skip for very small sizes)
    if size >= 64:
        try:
            font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", size // 4)
        except (OSError, IOError):
            font = ImageFont.load_default()
        text_color = (220, 230, 255)
        draw.text((cx + s * 0.15, cy + s * 0.05), "S", fill=text_color, font=font, anchor="mm")

    return img


def main():
    print("Generating overlay icons...")

    for name, bg, sym_func, sym_color in OVERLAY_ICONS:
        for suffix, sz in [("", 128), ("@2x", 256)]:
            img = generate_overlay_icon(name, bg, sym_func, sym_color, sz)
            filename = f"{name}{suffix}.png"

            # Save to both directories
            for out_dir in [OVERLAY_DIR_EXT, OVERLAY_DIR_RES]:
                path = os.path.join(out_dir, filename)
                img.save(path)

            print(f"  {filename} ({sz}x{sz})")

    print("\nGenerating app icon...")
    app_sizes = [16, 32, 64, 128, 256, 512, 1024]
    for sz in app_sizes:
        img = generate_app_icon(sz)
        path = os.path.join(APP_ICON_DIR, f"icon_{sz}x{sz}.png")
        img.save(path)
        print(f"  icon_{sz}x{sz}.png")

    print("\nDone! All icons generated.")


if __name__ == "__main__":
    main()
