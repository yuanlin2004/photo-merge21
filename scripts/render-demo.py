#!/usr/bin/env python3
"""Render an image-only README demo using Photo Flip's geometry and timing.
Requires Pillow and NumPy. This is a rendered demonstration, not a screen capture.
"""
from pathlib import Path
import math
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
DEMO = ROOT / 'demo' / 'silver-jubilee'
W, H = 768, 512
CW, CH = W / 1.6, H / 1.6  # FlipGeometry.canvasScale
DISTANCE = max(800, CW * 1.5)
BACKGROUND = (245, 245, 247)
photos = [Image.open(DEMO / name).convert('RGB') for name in ('front.png', 'back.png')]


def ease_in(t):
    # Core Animation's easeIn cubic Bezier: (0.42, 0), (1, 1).
    lo, hi = 0., 1.
    for _ in range(35):
        u = (lo + hi) / 2
        x = 3 * (1-u)**2 * u * .42 + 3 * (1-u) * u*u + u**3
        if x < t:
            lo = u
        else:
            hi = u
    u = (lo + hi) / 2
    return 3 * (1-u) * u*u + u**3


def frame(photo, angle):
    target = []
    for x, y in [(-CW/2, -CH/2), (CW/2, -CH/2), (CW/2, CH/2), (-CW/2, CH/2)]:
        z = -x * math.sin(angle)
        denominator = 1 - z / DISTANCE
        target.append((W/2 + x * math.cos(angle) / denominator, H/2 + y / denominator))
    source = [(0, 0), (photo.width, 0), (photo.width, photo.height), (0, photo.height)]
    matrix, values = [], []
    for (x, y), (u, v) in zip(target, source):
        matrix.extend([[x,y,1,0,0,0,-u*x,-u*y], [0,0,0,x,y,1,-v*x,-v*y]])
        values.extend([u, v])
    coeff = np.linalg.solve(np.array(matrix), np.array(values))
    return photo.transform((W,H), Image.Transform.PERSPECTIVE, coeff,
                           Image.Resampling.BICUBIC, fillcolor=BACKGROUND)


frames, durations = [frame(photos[0], 0)], [1800]
for outgoing, incoming, hold in [(0, 1, 3500), (1, 0, 500)]:
    # 0.24 seconds per half, 50 fps; exchange faces edge-on.
    for i in range(1, 12):
        frames.append(frame(photos[outgoing], math.pi/2 * ease_in(i / 12)))
        durations.append(20)
    frames.append(Image.new('RGB', (W,H), BACKGROUND))
    durations.append(20)
    for i in range(1, 13):
        eased = 1 - ease_in(1 - i / 12)
        frames.append(frame(photos[incoming], -math.pi/2 * (1 - eased)))
        durations.append(20 if i < 12 else hold)

# A shared palette prevents color shimmer during the turn.
strip = Image.new('RGB', (240 * len(frames), 160))
for i, image in enumerate(frames):
    strip.paste(image.resize((240,160), Image.Resampling.LANCZOS), (240*i,0))
palette = strip.quantize(colors=256, method=Image.Quantize.MEDIANCUT)
indexed = [image.quantize(palette=palette, dither=Image.Dither.NONE) for image in frames]
output = DEMO / 'flip-demo.gif'
indexed[0].save(output, save_all=True, append_images=indexed[1:], duration=durations,
                loop=0, disposal=1, optimize=True)
preview = ROOT / '.build' / 'demo-preview'
preview.mkdir(parents=True, exist_ok=True)
for name, index in [('front',0), ('mid-flip',8), ('back',24)]:
    frames[index].save(preview / (name + '.png'))
print(f'{output}: {len(frames)} frames, {sum(durations)/1000:.2f}s, {output.stat().st_size/1024/1024:.2f} MiB')
