#!/usr/bin/env python3
"""
gen_index.py - Generates top-level index.html from index.html.in template.
"""

import argparse
import sys

def main():
    parser = argparse.ArgumentParser(description="Generate index.html from template.")
    parser.add_argument("template", help="Path to index.html.in template")
    parser.add_argument("output", help="Path to output index.html")
    parser.add_argument("demos", nargs="*", help="List of demo names")
    args = parser.parse_args()

    with open(args.template, "r", encoding="utf-8") as f:
        content = f.read()

    links = "\n".join(
        f'    <li><a href="build/{demo}/main.html">{demo}</a></li>'
        for demo in args.demos
    )

    result = content.replace("<!-- DEMO_LINKS -->", links)

    with open(args.output, "w", encoding="utf-8") as f:
        f.write(result)

    return 0

if __name__ == "__main__":
    sys.exit(main())
