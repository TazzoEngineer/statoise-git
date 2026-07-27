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
    """Draw a bold checkmark symbol (large & thick for small-size legibility)."""
    cx, cy = size // 2, size // 2
    s = size * 0.44
    points = [
        (cx - s * 0.78, cy + s * 0.02),
        (cx - s * 0.18, cy + s * 0.62),
        (cx + s * 0.85, cy - s * 0.62),
    ]
    w = max(7, size // 6)
    draw.line(points, fill=color, width=w, joint="curve")
    # Round the stroke ends for a cleaner bold tick
    r = w / 2
    for (px, py) in points:
        draw.ellipse([px - r, py - r, px + r, py + r], fill=color)


def draw_plus(draw, size, color):
    """Draw a bold plus symbol."""
    cx, cy = size // 2, size // 2
    s = size * 0.32
    w = max(7, size // 6)
    draw.line([(cx - s, cy), (cx + s, cy)], fill=color, width=w)
    draw.line([(cx, cy - s), (cx, cy + s)], fill=color, width=w)


def draw_x(draw, size, color):
    """Draw a bold X symbol."""
    cx, cy = size // 2, size // 2
    s = size * 0.3
    w = max(7, size // 6)
    draw.line([(cx - s, cy - s), (cx + s, cy + s)], fill=color, width=w)
    draw.line([(cx + s, cy - s), (cx - s, cy + s)], fill=color, width=w)


def draw_exclamation(draw, size, color):
    """Draw a bold exclamation mark."""
    cx, cy = size // 2, size // 2
    s = size // 4
    w = max(6, size // 9)
    draw.line([(cx, cy - s), (cx, cy + s * 0.25)], fill=color, width=w)
    dot_r = max(3, size // 16)
    draw.ellipse([cx - dot_r, cy + s * 0.65 - dot_r, cx + dot_r, cy + s * 0.65 + dot_r], fill=color)


def draw_warning(draw, size, color):
    """Draw a bold '!' for conflicts (clear and legible at small sizes)."""
    cx, cy = size // 2, size // 2
    s = size * 0.34
    w = max(7, size // 6)
    draw.line([(cx, cy - s), (cx, cy + s * 0.2)], fill=color, width=w)
    dot_r = max(4, size // 11)
    draw.ellipse([cx - dot_r, cy + s * 0.62 - dot_r, cx + dot_r, cy + s * 0.62 + dot_r], fill=color)


def draw_dash(draw, size, color):
    """Draw a bold dash/minus symbol."""
    cx, cy = size // 2, size // 2
    s = size * 0.32
    w = max(7, size // 6)
    draw.line([(cx - s, cy), (cx + s, cy)], fill=color, width=w)


def draw_question(draw, size, color):
    """Draw a bold question mark."""
    cx, cy = size // 2, size // 2
    s = size * 0.34
    w = max(7, size // 7)
    # Curve of ?
    arc_bbox = [cx - s * 0.62, cy - s, cx + s * 0.62, cy + s * 0.28]
    draw.arc(arc_bbox, start=180, end=360, fill=color, width=w)
    draw.line([(cx + s * 0.62, cy - s * 0.3), (cx, cy + s * 0.18)], fill=color, width=w)
    dot_r = max(4, size // 12)
    draw.ellipse([cx - dot_r, cy + s * 0.6 - dot_r, cx + dot_r, cy + s * 0.6 + dot_r], fill=color)


def draw_lock(draw, size, color):
    """Draw a bold padlock symbol."""
    cx, cy = size // 2, size // 2
    s = size * 0.34
    w = max(6, size // 9)
    # Lock body
    body = [cx - s * 0.62, cy - s * 0.1, cx + s * 0.62, cy + s * 0.72]
    draw.rectangle(body, outline=color, width=w, fill=None)
    # Shackle
    arc_bbox = [cx - s * 0.42, cy - s * 0.82, cx + s * 0.42, cy]
    draw.arc(arc_bbox, start=180, end=0, fill=color, width=w)


def draw_pencil(draw, size, color):
    """Draw a bold pencil/edit symbol with a clear tip (distinct from a check)."""
    cx, cy = size // 2, size // 2
    s = size * 0.4
    w = max(8, size // 6)
    # Thick diagonal body
    start = (cx - s * 0.55, cy + s * 0.55)
    end = (cx + s * 0.62, cy - s * 0.62)
    draw.line([start, end], fill=color, width=w, joint="curve")
    # Solid triangular pencil tip at the lower-left end
    tip = size * 0.26
    draw.polygon([
        (cx - s * 0.85, cy + s * 0.85),
        (cx - s * 0.85 + tip, cy + s * 0.4),
        (cx - s * 0.4, cy + s * 0.85),
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
    """Generate a single overlay icon that fills the canvas edge-to-edge.

    Finder scales the badge to a fixed fraction of the file icon (very small in
    list view), so every pixel counts: the colored disc is drawn to the very
    edge with only a hairline outline for separation, maximizing the visible
    colored area and symbol size at tiny render sizes.
    """
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    # Colored disc filling essentially the whole canvas.
    margin = max(1, size // 40)
    draw.ellipse([margin, margin, size - margin, size - margin], fill=bg_color)
    # Hairline white ring hugging the edge for contrast on any background,
    # without eating into the colored fill the way a thick halo would.
    ring_w = max(2, size // 22)
    draw.ellipse(
        [margin, margin, size - margin, size - margin],
        outline=(255, 255, 255, 255),
        width=ring_w,
    )
    symbol_func(draw, size, symbol_color)
    return img


def bezier_curve(p0, p1, p2, p3, steps=50):
    """Calculate cubic Bezier curve points."""
    points = []
    for i in range(steps + 1):
        t = i / steps
        x = (1-t)**3 * p0[0] + 3*(1-t)**2*t * p1[0] + 3*(1-t)*t**2 * p2[0] + t**3 * p3[0]
        y = (1-t)**3 * p0[1] + 3*(1-t)**2*t * p1[1] + 3*(1-t)*t**2 * p2[1] + t**3 * p3[1]
        points.append((x, y))
    return points


def draw_thick_bezier(draw, p0, p1, p2, p3, color, width, steps=50):
    """Draw a thick smooth Bezier curve by drawing circles along the path."""
    points = bezier_curve(p0, p1, p2, p3, steps)
    r = width / 2
    for (x, y) in points:
        draw.ellipse([x - r, y - r, x + r, y + r], fill=color)


def generate_app_icon(size):
    """Generate app icon: Git orange background with bold branch fork symbol."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Rounded rectangle background - Git orange
    margin = size // 16
    corner_radius = size // 5
    bg_color = (240, 80, 50)  # Git orange #F05032

    bbox = [margin, margin, size - margin, size - margin]
    draw.rounded_rectangle(bbox, radius=corner_radius, fill=bg_color)

    cx, cy = size // 2, size // 2
    s = size // 3
    node_r = max(3, size // 12)
    line_w = max(4, size // 18)
    sym_color = (255, 255, 255)

    # Main vertical trunk (left)
    trunk_x = cx - s * 0.2
    trunk_top = cy - s * 0.85
    trunk_bottom = cy + s * 0.85

    # Branch endpoint (right, upper)
    branch_x = cx + s * 0.5
    branch_top = cy - s * 0.85

    # Draw main trunk as thick line (circles along path for smoothness)
    r = line_w / 2
    steps = max(20, size // 4)
    for i in range(steps + 1):
        t = i / steps
        y = trunk_top + (trunk_bottom - trunk_top) * t
        draw.ellipse([trunk_x - r, y - r, trunk_x + r, y + r], fill=sym_color)

    # Branch vertical segment (short trunk above fork point)
    for i in range(steps + 1):
        t = i / steps
        y = branch_top + (cy - s * 0.3 - branch_top) * t
        draw.ellipse([branch_x - r, y - r, branch_x + r, y + r], fill=sym_color)

    # Smooth Bezier curve connecting trunk to branch
    fork_y = cy + s * 0.15
    curve_start = (trunk_x, fork_y)
    ctrl1 = (trunk_x, cy - s * 0.1)
    ctrl2 = (branch_x, cy - s * 0.05)
    curve_end = (branch_x, cy - s * 0.3)
    draw_thick_bezier(draw, curve_start, ctrl1, ctrl2, curve_end, sym_color, line_w, steps)

    # Nodes (circles) at three endpoints - drawn last to cover line ends
    nodes = [
        (trunk_x, trunk_top),
        (trunk_x, trunk_bottom),
        (branch_x, branch_top),
    ]
    for (nx, ny) in nodes:
        draw.ellipse([nx - node_r, ny - node_r, nx + node_r, ny + node_r],
                     fill=sym_color)

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
