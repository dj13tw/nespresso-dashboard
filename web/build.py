"""Builds index.html from index.src.html by inlining the sample photo's wall map."""
from pathlib import Path

here = Path(__file__).parent
src = (here / "index.src.html").read_text()
sample = (here / "build/sample-prob.json").read_text().strip()
(here / "index.html").write_text(src.replace("/*SAMPLE_PROB*/null", sample))
print("index.html", (here / "index.html").stat().st_size // 1024, "KB")
