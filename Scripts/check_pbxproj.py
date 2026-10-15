#!/usr/bin/env python3
"""Fail loudly if any .swift file on disk is missing from project.pbxproj.

Xcode only compiles files registered in the .pbxproj. An unregistered file
builds "green" while silently doing nothing — exactly how the simulator
build broke (and how 6 test suites never ran). Run before every commit:

    python Scripts/check_pbxproj.py   (exit 0 = clean)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBX = os.path.join(ROOT, "ZYRAXIS-iOS.xcodeproj", "project.pbxproj")


def main() -> int:
    with open(PBX, encoding="utf-8") as f:
        pbx = f.read()
    missing = []
    for dirpath, _dirs, files in os.walk(ROOT):
        if ".git" in dirpath or ".xcodeproj" in dirpath:
            continue
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            # PBXFileReference entry looks like:  <ID> /* Name.swift */ = {...name = Name.swift; ...
            if "name = %s;" % name not in pbx:
                missing.append(os.path.relpath(os.path.join(dirpath, name), ROOT))
    if missing:
        print("UNREGISTERED SWIFT FILES (add to project.pbxproj):")
        for m in missing:
            print("  -", m)
        return 1
    # Cross-check the other way: every referenced swift file exists on disk.
    dangling = []
    for ref in sorted(set(re.findall(r"name = (\S+\.swift);", pbx))):
        found = False
        for dirpath, _dirs, files in os.walk(ROOT):
            if ".git" in dirpath or ".xcodeproj" in dirpath:
                continue
            if ref in files:
                found = True
                break
        if not found:
            dangling.append(ref)
    if dangling:
        print("DANGLING PBX REFERENCES (file missing on disk):")
        for d in dangling:
            print("  -", d)
        return 1
    total = sum(1 for _d, _ds, fs in os.walk(ROOT) for _f in fs if _f.endswith(".swift"))
    print("OK: every .swift file on disk is registered (%d files)." % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
