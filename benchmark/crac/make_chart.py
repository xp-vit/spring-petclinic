#!/usr/bin/env python3
"""Cold-start bar chart (log x-axis) from committed raw data. Stdlib only.
Usage: python3 -I make_chart.py ../results-crac cold-start.svg
"""
import math, pathlib, sys

R = pathlib.Path(sys.argv[1]); out = pathlib.Path(sys.argv[2])
rows = [  # label, file, note
    ("JVM (Temurin 25)", "aws-v2-crac/jvm-cold-start-ms.txt", "2026-07-19 session"),
    ("JVM on Zulu CRaC distro, CRaC off", "aws-v2-crac/crac-jvm-cold-start-ms.txt", "2026-07-19 session"),
    ("CRaC onRefresh checkpoint", "aws-v2-crac/crac-onrefresh-cold-start-ms.txt", "2026-07-19 session"),
    ("CRaC warmed checkpoint", "aws-v2-crac/crac-cold-start-ms.txt", "2026-07-19 session"),
    ("GraalVM native", "aws-v2/native-cold-start-ms.txt", "file dated 2026-05-26, see caveats"),
]
vals = [(l, int((R / f).read_text().strip()), n) for l, f, n in rows]
W, H, L, T, BH, GAP = 760, 84 + len(vals) * 46, 250, 40, 28, 18
lo, hi = 100, 30000
x = lambda v: L + (W - L - 90) * (math.log10(v) - math.log10(lo)) / (math.log10(hi) - math.log10(lo))
s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="system-ui,sans-serif" font-size="13">',
     '<style>text{fill:#222}.g{stroke:#ddd}.b{fill:#3b6ea5}.n{fill:#777;font-size:11px}@media (prefers-color-scheme:dark){text{fill:#eee}.g{stroke:#444}.b{fill:#6fa0d8}.n{fill:#aaa}}</style>',
     f'<rect width="{W}" height="{H}" fill="none"/>',
     f'<text x="{L}" y="22" font-weight="600">Cold start: docker run to first 200 on /vets (ms, log scale, n=1 each)</text>']
for t in [100, 300, 1000, 3000, 10000, 30000]:
    s.append(f'<line class="g" x1="{x(t):.1f}" y1="{T}" x2="{x(t):.1f}" y2="{H-44}"/><text class="n" x="{x(t):.1f}" y="{H-30}" text-anchor="middle">{t:,}</text>')
for i, (l, v, n) in enumerate(vals):
    y = T + 8 + i * 46
    s.append(f'<text x="{L-8}" y="{y+BH/2+4}" text-anchor="end">{l}</text>')
    s.append(f'<rect class="b" x="{L}" y="{y}" width="{x(v)-L:.1f}" height="{BH}" rx="2"/>')
    s.append(f'<text x="{x(v)+6:.1f}" y="{y+BH/2+4}" font-weight="600">{v:,}</text>')
    s.append(f'<text class="n" x="{L-8}" y="{y+BH+10}" text-anchor="end">{n}</text>')
s.append('<text class="n" x="10" y="' + str(H - 8) + '">AWS c7i.large, 1 vCPU / 512 MiB container cap. Probe interval ~57 ms.</text>')
s.append("</svg>")
out.write_text("\n".join(s) + "\n")
print(out, [v for _, v, _ in vals])
