#!/usr/bin/env python3
"""UI test shards for the iOS CI jobs.

Each shard lists the XCTestCase classes of IronPetRemoteUITests that one CI job runs.
The shards are balanced by per-class run time: CI durations from a green main run, scaled by what the local before and after runs measured. To rebalance, move a class
between SHARDS lists; `check` keeps every class in exactly one shard.

  ios_ui_shards.py check            fail if a UI test class is in no shard, in two shards, or no longer exists
  ios_ui_shards.py args <shard>     print the -only-testing arguments for a shard (1-based)
  ios_ui_shards.py list             print "shard class" for every class
  ios_ui_shards.py count            print the number of shards
"""
import pathlib
import re
import sys

SHARDS = [
    # Shard 1 (about 10 minutes of test time on CI)
    ["ChatCacheUITests", "ChatFindUITests", "ChatMenuKeyboardUITests", "ChatMermaidUITests", "ChatModeUITests", "ChatOutboxUITests", "ChatSelectionUITests", "NetworkStatesUITests", "VoiceRecordingUITests"],
    # Shard 2 (about 10 minutes of test time on CI)
    ["AttachPhotoUITests", "BackgroundUITests", "ChatStreamingUITests", "PasteUITests"],
    # Shard 3 (about 10 minutes of test time on CI)
    ["ChatPagingUITests", "ChatParityUITests", "ChatSwipeReplyUITests", "IronPetRemoteUITests", "MemoryUITests", "PhaseFiveUITests", "PhaseFourUITests", "PhaseThreeUITests"],
    # Shard 4 (about 10 minutes of test time on CI)
    ["ChatFileLinksUITests", "ChatFormPagesUITests", "ChatSendStatesUITests", "ChatTextSizeUITests"],
]

TARGET = "IronPetRemoteUITests"
ROOT = pathlib.Path(__file__).resolve().parent.parent / "iOS" / TARGET


def classes_on_disk():
    found = set()
    for path in ROOT.glob("*.swift"):
        found.update(re.findall(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase", path.read_text(), re.M))
    return found


def check():
    disk = classes_on_disk()
    listed = [c for shard in SHARDS for c in shard]
    problems = []
    for c in sorted(disk - set(listed)):
        problems.append(f"{c} is in no shard. Add it to SHARDS in scripts/ios_ui_shards.py.")
    for c in sorted({c for c in listed if listed.count(c) > 1}):
        problems.append(f"{c} is in more than one shard.")
    for c in sorted(set(listed) - disk):
        problems.append(f"{c} is in a shard but no such test class exists.")
    for p in problems:
        print(p, file=sys.stderr)
    return 1 if problems else 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "check":
        return check()
    if cmd == "count":
        print(len(SHARDS))
        return 0
    if cmd == "list":
        for i, shard in enumerate(SHARDS, 1):
            for c in shard:
                print(i, c)
        return 0
    if cmd == "args" and len(argv) == 3 and argv[2].isdigit() and 1 <= int(argv[2]) <= len(SHARDS):
        print(" ".join(f"-only-testing:{TARGET}/{c}" for c in SHARDS[int(argv[2]) - 1]))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
