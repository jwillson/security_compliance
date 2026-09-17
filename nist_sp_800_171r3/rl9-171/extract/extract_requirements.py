#!/usr/bin/env python3
"""
Parse NIST SP 800-171r3 into a machine-readable requirement catalog.

Reads the published PDF, extracts every security requirement (including
withdrawn ones), and emits JSON. Structure of a requirement in the source
document:

    03.01.01 Account Management
                a. Define the types of system accounts allowed and prohibited.
                ...
                DISCUSSION
                ...
                REFERENCES
                Source Controls: AC-02, AC-02(03), ...
                Supporting Publications: SP 800-46 [14], ...

Withdrawn requirements carry the literal title "Withdrawn" and a one-line
disposition ("Addressed by 03.13.08." / "Incorporated into 03.01.12.").

Usage:
    ./extract_requirements.py NIST.SP.800-171r3.pdf -o catalog/requirements.json
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Requirement heading at column 0: "03.01.01 Account Management"
RE_REQ = re.compile(r"^(\d{2}\.\d{2}\.\d{2})\s+(.+?)\s*$")
# Family heading at column 0: "3.1. Access Control"
RE_FAMILY = re.compile(r"^3\.(\d{1,2})\.\s+(.+?)\s*$")
# Running page furniture we strip from the body text.
RE_PAGE_NUM = re.compile(r"^\s*\d{1,3}\s*$")
RE_HEADER = re.compile(r"^NIST SP 800-171r3\s")
RE_DATE_LINE = re.compile(r"^(May 2024|January 2024)\s*$")
RE_SOURCE_CTL = re.compile(r"^Source Controls?:\s*(.+)$")
RE_SUPPORTING = re.compile(r"^Supporting Publications?:\s*(.+)$")
# Reference tokens: AC-02, AC-02(03), SI-04(12)
RE_CTL_TOKEN = re.compile(r"\b([A-Z]{2})-(\d{2})(?:\((\d{2})\))?")

FAMILY_ABBREV = {
    "Access Control": "AC",
    "Awareness and Training": "AT",
    "Audit and Accountability": "AU",
    "Configuration Management": "CM",
    "Identification and Authentication": "IA",
    "Incident Response": "IR",
    "Maintenance": "MA",
    "Media Protection": "MP",
    "Personnel Security": "PS",
    "Physical Protection": "PE",
    "Risk Assessment": "RA",
    "Security Assessment and Monitoring": "CA",
    "System and Communications Protection": "SC",
    "System and Information Integrity": "SI",
    "Planning": "PL",
    "System and Services Acquisition": "SA",
    "Supply Chain Risk Management": "SR",
}


def pdf_to_text(pdf: Path) -> str:
    """Render the PDF to layout-preserving text via poppler's pdftotext."""
    if not shutil.which("pdftotext"):
        sys.exit("error: pdftotext not found (install poppler-utils)")
    out = subprocess.run(
        ["pdftotext", "-layout", str(pdf), "-"],
        capture_output=True,
        text=True,
        check=True,
    )
    return out.stdout


def is_furniture(line: str) -> bool:
    """True for running headers, footers, and bare page numbers."""
    return bool(
        RE_PAGE_NUM.match(line)
        or RE_HEADER.match(line)
        or RE_DATE_LINE.match(line)
        or line.strip() == "Protecting Controlled Unclassified Information"
    )


def clean_block(lines: list[str]) -> str:
    """Dedent and rewrap a block of body lines into paragraphs.

    The PDF indents requirement bodies by 12 columns and wraps them at a fixed
    width. We preserve the enumerated structure (a. / 1.) by keeping relative
    indentation, but collapse the hard wraps that are purely typographic.
    """
    kept = [ln.rstrip() for ln in lines if not is_furniture(ln)]
    while kept and not kept[0].strip():
        kept.pop(0)
    while kept and not kept[-1].strip():
        kept.pop()
    if not kept:
        return ""

    # Remove the common left margin.
    indents = [len(ln) - len(ln.lstrip()) for ln in kept if ln.strip()]
    margin = min(indents) if indents else 0
    kept = [ln[margin:] if len(ln) >= margin else ln.lstrip() for ln in kept]

    # Join continuation lines. A line starts a new logical line if it is blank,
    # or begins an enumerator (a. / 1. / i.) at its own indent level.
    enum = re.compile(r"^\s*(?:[a-z]\.|\d+\.)\s")
    out: list[str] = []
    for ln in kept:
        if not ln.strip():
            if out and out[-1] != "":
                out.append("")
            continue
        if not out or out[-1] == "" or enum.match(ln):
            out.append(ln.rstrip())
        else:
            # Continuation of the previous logical line.
            out[-1] = out[-1].rstrip() + " " + ln.strip()
    return "\n".join(out).strip()


def parse_refs(lines: list[str]) -> dict:
    """Pull Source Controls and Supporting Publications out of a REFERENCES block."""
    text = " ".join(ln.strip() for ln in lines if not is_furniture(ln))
    source, supporting = "", ""
    m = RE_SOURCE_CTL.search(text)
    if not m:
        # The label may be mid-string after dedenting.
        m = re.search(r"Source Controls?:\s*(.+?)(?:Supporting Publications?:|$)", text)
    if m:
        source = m.group(1).strip()
    m2 = re.search(r"Supporting Publications?:\s*(.+)$", text)
    if m2:
        supporting = m2.group(1).strip()

    controls = []
    for fam, num, enh in RE_CTL_TOKEN.findall(source):
        controls.append(f"{fam}-{num}({enh})" if enh else f"{fam}-{num}")
    # De-duplicate, preserve order.
    seen, ordered = set(), []
    for c in controls:
        if c not in seen:
            seen.add(c)
            ordered.append(c)
    return {
        "source_controls": ordered,
        "supporting_publications": re.sub(r"\s+", " ", supporting).strip(),
    }


def parse(text: str) -> list[dict]:
    lines = text.splitlines()

    # Requirements live between "3.1. Access Control" and "Appendix A.".
    start = next(
        i for i, ln in enumerate(lines) if RE_FAMILY.match(ln) and "Access Control" in ln
    )
    end = next(
        i for i, ln in enumerate(lines) if ln.startswith("Appendix A. Acronyms") and i > start
    )
    body = lines[start:end]

    reqs: list[dict] = []
    family_name = ""
    current: dict | None = None
    section = "statement"  # statement -> discussion -> references
    buf: dict[str, list[str]] = {"statement": [], "discussion": [], "references": []}

    def flush() -> None:
        nonlocal current, buf
        if current is None:
            return
        current["statement"] = clean_block(buf["statement"])
        current["discussion"] = clean_block(buf["discussion"])
        current.update(parse_refs(buf["references"]))
        reqs.append(current)
        current = None
        buf = {"statement": [], "discussion": [], "references": []}

    for raw in body:
        line = raw.rstrip("\n")

        fam = RE_FAMILY.match(line)
        if fam:
            family_name = fam.group(2).strip()
            continue

        req = RE_REQ.match(line)
        if req:
            flush()
            rid, title = req.group(1), req.group(2).strip()
            current = {
                "id": rid,
                "family_id": rid[:5],  # "03.01"
                "family": family_name,
                "family_abbrev": FAMILY_ABBREV.get(family_name, ""),
                "title": title,
                "withdrawn": title.lower() == "withdrawn",
            }
            section = "statement"
            continue

        if current is None:
            continue

        stripped = line.strip()
        if stripped == "DISCUSSION":
            section = "discussion"
            continue
        if stripped == "REFERENCES":
            section = "references"
            continue

        buf[section].append(line)

    flush()
    return reqs


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("pdf", type=Path, help="NIST SP 800-171r3 PDF")
    ap.add_argument("-o", "--out", type=Path, required=True, help="output JSON path")
    args = ap.parse_args()

    if not args.pdf.is_file():
        sys.exit(f"error: no such file: {args.pdf}")

    reqs = parse(pdf_to_text(args.pdf))
    active = [r for r in reqs if not r["withdrawn"]]

    catalog = {
        "source": {
            "title": "NIST SP 800-171r3, Protecting Controlled Unclassified "
                     "Information in Nonfederal Systems and Organizations",
            "doi": "10.6028/NIST.SP.800-171r3",
            "published": "2024-05",
            "file": args.pdf.name,
        },
        "counts": {
            "total": len(reqs),
            "active": len(active),
            "withdrawn": len(reqs) - len(active),
            "families": len({r["family_id"] for r in reqs}),
        },
        "requirements": reqs,
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(catalog, indent=2) + "\n")

    print(f"parsed {len(reqs)} requirements "
          f"({len(active)} active, {len(reqs) - len(active)} withdrawn) "
          f"across {catalog['counts']['families']} families -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
