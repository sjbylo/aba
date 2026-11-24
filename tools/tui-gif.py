#!/usr/bin/env python3
"""Turn a TUI color-frame directory into a GIF.

A near-duplicate frame holds for half a second. A new dialog stays up
for at least one second, longer when there is more to read. The GIF
ends on a black frame held for three seconds. Pass the run directory
or its color/ subdirectory. An optional width draws the GIF at that
width so a page can show it without shrinking.
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FG = [
	(0, 0, 0), (170, 0, 0), (0, 170, 0), (170, 85, 0),
	(0, 0, 170), (170, 0, 170), (0, 170, 170), (170, 170, 170),
	(85, 85, 85), (255, 85, 85), (85, 255, 85), (255, 255, 85),
	(85, 85, 255), (255, 85, 255), (85, 255, 255), (255, 255, 255),
]
ANSI = re.compile(r"\x1b\[([0-9;]*)m")
BLUE = (20, 40, 160)
# Red Hat Mono's box-drawing glyphs are solid blocks, so the TUI frame
# is drawn with Source Code Pro.
FONTS = (
	(
		"/usr/share/fonts/adobe-source-code-pro/SourceCodePro-Regular.otf",
		"/usr/share/fonts/adobe-source-code-pro/SourceCodePro-Bold.otf",
	),
	(
		"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
	),
)


# Large enough to read when the GIF is opened on its own.
FONT_PX = 28
# Cursor motion, a moved highlight, or a progress tick on the same screen.
SAME_PAUSE_MS = 500
# A new dialog. Larger and important dialogs hold longer than this.
MIN_PAUSE_MS = 1000
# Black frame after the last screen, before the loop starts again.
END_BLACK_MS = 3000


def load_fonts(px=None):
	px = FONT_PX if px is None else px
	for regular, bold in FONTS:
		if Path(regular).is_file() and Path(bold).is_file():
			return ImageFont.truetype(regular, px), ImageFont.truetype(bold, px)
	raise SystemExit("no monospace font found for the GIF")


def font_px_for_width(cols, target):
	# Largest font whose drawing is no wider than target. Never scale up.
	if not target or cols < 1:
		return FONT_PX
	chosen = 8
	for px in range(8, FONT_PX + 1):
		font, _ = load_fonts(px)
		cw, _ = cell_size(font)
		if cols * cw + 32 <= target:
			chosen = px
		else:
			break
	return chosen


def cell_size(font):
	w = max(1, int(round(font.getlength("M"))))
	ascent, descent = font.getmetrics()
	return w, ascent + descent + 4


def parse(text):
	fg, bg, bold = 7, 0, False
	rows, row = [], []

	def apply(codes):
		nonlocal fg, bg, bold
		for c in codes:
			if c == 0:
				fg, bg, bold = 7, 0, False
			elif c == 1:
				bold = True
			elif c == 22:
				bold = False
			elif 30 <= c <= 37:
				fg = c - 30
			elif c == 39:
				fg = 7
			elif 40 <= c <= 47:
				bg = c - 40
			elif c == 49:
				bg = 0

	i = 0
	while i < len(text):
		if text[i] == "\x1b":
			m = ANSI.match(text, i)
			if not m:
				i += 1
				continue
			raw = m.group(1)
			apply([int(c) if c else 0 for c in raw.split(";")] if raw else [0])
			i = m.end()
			continue
		ch = text[i]
		i += 1
		if ch == "\n":
			rows.append(row)
			row = []
		elif ch != "\r":
			row.append((ch, fg, bg, bold))
	if row:
		rows.append(row)
	return rows


def plain(rows):
	return "\n".join("".join(ch for ch, *_ in r) for r in rows)


def visible_chars(text):
	return sum(1 for ch in text if not ch.isspace())


IMPORTANT = re.compile(
	r"Operator Set|Review|Confirm|Install Mirror|Install Cluster|Sync images|Day-2|OCP Version|Preflight|Warning|Choose",
	re.I,
)


def load_frame(path):
	text = path.read_text(encoding="utf-8", errors="replace")
	cursor = None
	if "\x1e" in text:
		text, meta = text.rsplit("\x1e", 1)
		m = re.search(r"CURSOR\s+(\d+)\s+(\d+)", meta)
		if m:
			cursor = (int(m.group(1)), int(m.group(2)))
	return text, cursor


def same_screen(a, b):
	if not a or not b:
		return False
	la, lb = a.splitlines(), b.splitlines()
	n = max(len(la), len(lb), 1)
	same = sum(1 for x, y in zip(la, lb) if x == y)
	return same / n >= 0.85


def delay_ms(text, prev, rows, cursor_only):
	# Same screen, or only the cursor moved. A new dialog stays readable.
	if cursor_only or (prev and same_screen(text, prev)):
		return SAME_PAUSE_MS
	cells = 0
	if rows:
		cells = len(rows) * max(len(r) for r in rows)
	ms = 600 + min(2800, cells // 2)
	if IMPORTANT.search(text):
		ms += 1400
	return max(MIN_PAUSE_MS, min(ms, 4500))


def crop_rows(rows, cursor):
	# The title rule is a full-width line of ─. Key off the dialog corners
	# so that line does not force a 160-column frame and tiny text.
	corners = []
	for y, r in enumerate(rows):
		for x, (ch, *_) in enumerate(r):
			if ch in "┌┐└┘":
				corners.append((y, x, ch))
	# A dialog taller than the pane has ┌┐ and no └┘. Skip the box
	# measurement then and use the visible text for the pause.
	tops = [y for y, _, ch in corners if ch in "┌┐"]
	bots = [y for y, _, ch in corners if ch in "└┘"]
	lefts = [x for _, x, ch in corners if ch in "┌└"]
	rights = [x for _, x, ch in corners if ch in "┐┘"]
	if tops and bots and lefts and rights:
		top, bot = min(tops), max(bots)
		lo, hi = min(lefts), max(rights)
		if bot >= top and hi >= lo:
			cropped = [r[lo:hi + 1] if len(r) > lo else [] for r in rows[top:bot + 1]]
			return cropped, _shift_cursor(cursor, lo, top, cropped)

	def empty(r):
		chars = [ch for ch, *_ in r if ch != " "]
		return not chars or all(ch == "─" for ch in chars)

	dropped = 0
	while rows and empty(rows[0]):
		rows.pop(0)
		dropped += 1
	while rows and empty(rows[-1]):
		rows.pop()
	if not rows:
		return [], None
	width = max(len(r) for r in rows)
	keep = [x for x in range(width) if any(x < len(r) and r[x][0] not in (" ", "─") for r in rows)]
	if not keep:
		return rows, _shift_cursor(cursor, 0, dropped, rows)
	lo, hi = keep[0], keep[-1]
	cropped = [r[lo:hi + 1] if len(r) > lo else [] for r in rows]
	return cropped, _shift_cursor(cursor, lo, dropped, cropped)


def _shift_cursor(cursor, x0, y0, rows):
	if not cursor or not rows:
		return None
	x, y = cursor[0] - x0, cursor[1] - y0
	if y < 0 or y >= len(rows) or x < 0 or x >= len(rows[y]):
		return None
	return (x, y)


def read_size(src):
	d = Path(src)
	for p in (d / "size", d.parent / "size"):
		if not p.is_file():
			continue
		parts = p.read_text(encoding="utf-8", errors="replace").split()
		if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
			w, h = int(parts[0]), int(parts[1])
			if w > 0 and h > 0:
				return w, h
	return None


def pad_rows(rows, cols, nrows):
	# Every frame is the same cell grid, so the GIF keeps the terminal's shape.
	bg = 4
	blank = (" ", 7, bg, False)
	out = []
	for r in rows[:nrows]:
		row = list(r[:cols])
		if len(row) < cols:
			row.extend([blank] * (cols - len(row)))
		out.append(row)
	while len(out) < nrows:
		out.append([blank] * cols)
	return out


def render(rows, font, font_b, cursor):
	if cursor and 0 <= cursor[1] < len(rows) and 0 <= cursor[0] < len(rows[cursor[1]]):
		x, y = cursor
		row = list(rows[y])
		ch, fgi, bgi, isb = row[x]
		# Reverse the cell so a cursor move is visible when the text did not change.
		row[x] = (ch if ch != " " else "█", bgi, fgi if fgi != bgi else 7, True)
		rows[y] = row
	cw, ch = cell_size(font)
	if not rows:
		return Image.new("RGB", (cw * 20, ch * 4), BLUE)
	cols = max(len(r) for r in rows)
	pad = 16
	img = Image.new("RGB", (cols * cw + pad * 2, len(rows) * ch + pad * 2), BLUE)
	dr = ImageDraw.Draw(img)
	for y, r in enumerate(rows):
		for x, (char, fgi, bgi, isb) in enumerate(r):
			fc = FG[min(fgi + (8 if isb and fgi < 8 else 0), 15)]
			bc = FG[bgi]
			x0, y0 = pad + x * cw, pad + y * ch
			dr.rectangle([x0, y0, x0 + cw - 1, y0 + ch - 1], fill=bc)
			if char != " ":
				dr.text((x0, y0), char, font=font_b if isb else font, fill=fc)
	return img


def frames_in(directory):
	d = Path(directory)
	color = d / "color"
	src = color if color.is_dir() else d
	files = sorted(src.glob("frame-*.txt"))
	if not files:
		files = sorted(p for p in src.glob("*.txt") if p.is_file())
	return files


def build(src, dest, width=None):
	if Path(dest).suffix.lower() != ".gif":
		print(f"destination must end in .gif: {dest}", file=sys.stderr)
		return 1
	files = frames_in(src)
	if not files:
		print(f"no color frames in {src}", file=sys.stderr)
		return 1
	kept = []
	for path in files:
		text, cursor = load_frame(path)
		rows = parse(text)
		body = plain(rows)
		if visible_chars(body) < 8:
			continue
		kept.append((rows, body, cursor))
	if not kept:
		print(f"no visible frames in {src}", file=sys.stderr)
		return 1
	size = read_size(src)
	if size:
		cols, nrows = size
	else:
		# No locked size on an older recording. Use the pane size that
		# occurred most, so one tall log does not change the shape.
		shapes = []
		for rows, _, _ in kept:
			w = max((len(r) for r in rows), default=0)
			shapes.append((w, len(rows)))
		cols, nrows = max(set(shapes), key=shapes.count)
	font, font_b = load_fonts(font_px_for_width(cols, width))
	images, durations, prev, prev_cursor = [], [], "", None
	for rows, body, cursor in kept:
		cursor_only = bool(prev) and body == prev and cursor != prev_cursor
		if prev and body == prev and cursor == prev_cursor:
			continue
		grid = pad_rows(rows, cols, nrows)
		cropped, _shown = crop_rows([list(r) for r in rows], cursor)
		images.append(render(grid, font, font_b, cursor))
		durations.append(delay_ms(body, prev, cropped, cursor_only))
		prev, prev_cursor = body, cursor
	if not images:
		print(f"no visible frames in {src}", file=sys.stderr)
		return 1
	# Fixed ANSI colors. An adaptive palette turns the red selection into gray
	# because most of the dialog is gray.
	flat = []
	for c in FG + [BLUE, (32, 32, 32), (64, 64, 64), (96, 96, 96), (128, 128, 128), (192, 192, 192), (220, 220, 220)]:
		flat.extend(c)
	flat.extend([0] * (768 - len(flat)))
	base = Image.new("P", (1, 1))
	base.putpalette(flat)
	durations[-1] = max(durations[-1], 2500)
	if width and images[0].size[0] > width:
		scaled = []
		for im in images:
			h = max(1, round(im.size[1] * width / images[0].size[0]))
			scaled.append(im.resize((width, h), Image.Resampling.LANCZOS))
		images = scaled
	images.append(Image.new("RGB", images[0].size, (0, 0, 0)))
	durations.append(END_BLACK_MS)
	frames = [im.quantize(palette=base, dither=Image.Dither.NONE) for im in images]
	Path(dest).parent.mkdir(parents=True, exist_ok=True)
	frames[0].save(
		dest,
		save_all=True,
		append_images=frames[1:],
		duration=durations,
		loop=0,
		optimize=True,
		disposal=2,
	)
	w, h = images[0].size
	_compress(dest)
	print(
		f"{dest}  frames={len(images)}  {w}x{h}  "
		f"pause={min(durations)}-{max(durations)}ms  bytes={Path(dest).stat().st_size}"
	)
	return 0


def _compress(path):
	# Frame delays do not add bytes. Identical margins and a shared palette do.
	# gifsicle -O3 keeps only the pixels that changed between frames.
	bin_path = shutil.which("gifsicle")
	if not bin_path:
		print("gifsicle is not installed; the GIF was not frame-optimized", file=sys.stderr)
		return
	cmd = [bin_path, "-O3", "-o", path, path]
	# --lossy keeps text and cuts the file. Older gifsicle has no --lossy.
	help_text = subprocess.run([bin_path, "--help"], capture_output=True, text=True).stdout
	if "--lossy" in help_text:
		cmd = [bin_path, "-O3", "--lossy=30", "-o", path, path]
	subprocess.run(cmd, check=False)


if __name__ == "__main__":
	if len(sys.argv) not in (3, 4):
		print(f"usage: {sys.argv[0]} RUN_DIR DEST.gif [WIDTH]", file=sys.stderr)
		sys.exit(2)
	width = None
	if len(sys.argv) == 4:
		if not sys.argv[3].isdigit() or int(sys.argv[3]) < 1:
			print("WIDTH must be a positive number of pixels", file=sys.stderr)
			sys.exit(2)
		width = int(sys.argv[3])
	sys.exit(build(sys.argv[1], sys.argv[2], width))
