# Z-machine specification: requirements

* Files: [README.md](README.md) (front matter, contents, sources), one `NN_Title.md` per section, [Appendices.md](Appendices.md), and [Discrepancies.md](Discrepancies.md) (the register).
* Diagrams and tables carry the content; prose only joins them.
* Every item carries zmachine's status (✓, ~, ✗); version 6 is kept brief.
* Sources: those in the README's table, each pinned to a commit or edition; none outranks another.
* Evidence stories: Infocom only, from `local/stories/`.
* The Standard and Frotz are restated, never copied.
* Each section ends with **Frotz** (source files and functions) and **Discrepancies** (register IDs).
* Register: one row per point, IDs `D<section>.<n>`; columns: point; Standard (Reisinger); Frotz (file: function); MojoZork, zvm, xyppy; Infocom games; zmachine and why.
* Diagrams: Unicode box-drawing in `text` fences, at most 80 columns, each with a one-line caption; an SVG may sit beside one that ASCII can't show clearly (color, crossing lines), never replace it.
* Indexed in [docs/specifications](../README.md) under "Written for zmachine".
