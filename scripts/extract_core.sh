#!/bin/bash
# Creates the IronPetCore target and moves the non-UI half of ironpet into it. Run it from a checkout of the commit before the
# extraction, on a clean working tree; it refuses to run when Sources/IronPetCore exists. When main moves while a branch is in
# review, run it again on fresh main instead of rebasing, then redo the hand edits listed below.
#
# What it does:
#   1. `git mv` of the files listed in MOVE from Sources/IronPet to Sources/IronPetCore, so `git log --follow` works.
#   2. In the moved files, declarations without an access modifier become `package`, and a struct or class without an initialiser
#      gets a `package` one, because the Mac target cannot call an internal memberwise initialiser. Types stay private to the
#      repo (`package`, not `public`).
#   3. `import CryptoKit` becomes a `#if canImport(CryptoKit)` block that falls back to swift-crypto's `Crypto`, and files that use
#      URLSession import FoundationNetworking where it exists.
#   4. `import IronPetCore` is added to every file left in Sources/IronPet.
#   5. Package.swift gets the IronPetCore and IronPetCoreTests targets, and IronPet depends on IronPetCore.
#   6. Tests that touch only core types move to Tests/IronPetCoreTests, with their fixtures.
#
# What it does not do. These files hold a type or a default that needs the Mac, so they are edited by hand after the script, and
# a rerun on fresh main needs the same edits:
#
#   Split by hand, the portable half in core and the Mac half beside it in Sources/IronPet:
#     Chat/Markdown.swift (parser in core) and Chat/MarkdownView.swift (AppKit rendering)
#     Chat/ChatBackground.swift and Meeting/MicIgnoreList.swift (the enum in core, the Mac extension in Sources/IronPet)
#     Meeting/CallDetector.swift (detector in core) and Meeting/CallMonitor.swift (monitor)
#     Meeting/AudioApps.swift (core) and Platform/Mac/AudioApps+Running.swift (NSWorkspace lookup)
#     Pet/PetLibrary.swift (core) and Pet/PetPreview.swift (NSImage preview)
#     Pet/Atlas.swift (aliases moved to core as Pet/AtlasAliases.swift)
#     Capture/CaptureService.swift (CaptureStatusModel moved to core as Capture/CaptureStatusModel.swift)
#     Remote/RemoteIdentity.swift (core) and Remote/RemoteTLSKeychain.swift (Security calls)
#     Desktop/DesktopAX.swift (protocols and idle adapters in core) and Desktop/LiveDesktopAX.swift (AX and CGEvent)
#     Voice/SpeechPlayer.swift (SpeechProducer, SpeechChunkReader and ClipPlaying moved to core as Voice/SpeechProducer.swift)
#     Pet/TaskListView.swift (the TaskLink display helpers moved to core as Tasks/TaskLink+Display.swift)
#   Edited by hand so the file compiles without a Mac framework:
#     Activity/WelcomeBack.swift, Brief/BriefSource.swift (BriefModel only where Combine exists), Chat/ChatFind.swift,
#     Desktop/DesktopKeys.swift (DesktopKeyFlags instead of CGEventFlags), Desktop/DesktopSafety.swift, Desktop/DesktopService.swift,
#     Support/Log.swift (no os import; Log.fallbackSink, which main.swift sets to OSLogLog), Voice/LevelBuffer.swift, Voice/SpeechText.swift,
#     Remote/RemoteChat.swift
#   Facades that defaulted to a Mac type now default to a core type, and the Mac side wires the real one:
#     API/ChatAPI.swift, API/IronPetAPI.swift, API/PetAPI.swift, App/AppDelegate.swift, main.swift, App/Announcer.swift
#   Written by hand: Tests/IronPetCoreTests/ImportAllowListTests.swift
#   Tests edited by hand: BoundaryTests, BubbleDataTests, ChatSessionCoreTests, DesktopControlTests, DesktopKeysAndActionsTests,
#     PlatformServicesTests, PlatformTests, SupportPortabilityTests (they read Sources/IronPetCore as well) and CaptureViewTests
#   Docs and generators: AGENTS.md, SPEC.md, .agents/skills/swift/SKILL.md, .cursor/skills/dev-open-pr/SKILL.md,
#     .cursor/skills/dev-code-review/tooling.md, scripts/gen_skills.py, scripts/gen_agent_catalog.py
#
# Usage: scripts/extract_core.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
python3 -I - "$@" <<'PY'
import re
import sys

DECL = re.compile(
    r'^(?P<indent>[ \t]*)'
    r'(?P<attrs>(?:@[\w.]+(?:\([^()\n]*\))?[ \t]+)*)'
    r'(?P<mods>(?:(?:static|final|override|mutating|nonmutating|nonisolated\((?:unsafe|nonsending)\)|nonisolated|unowned\((?:safe|unsafe)\)|lazy|weak|unowned|indirect|convenience|required|dynamic|'
    r'isolated|consuming|borrowing|optional|prefix|postfix|infix|class(?=[ \t]+(?:func|var|let|subscript))|'
    r'private\(set\)|fileprivate\(set\)|internal\(set\)|package\(set\)|package|public|internal|open|private(?!\()|fileprivate(?!\())[ \t]+)*)'
    r'(?P<kw>class|struct|enum|protocol|actor|func|var|let|init|typealias|subscript)\b'
)
ACCESS = re.compile(r'\b(private|fileprivate|public|internal|open|package)\b(?!\()')
TYPE_KW = {'class', 'struct', 'enum', 'protocol', 'actor'}
HEADER = re.compile(
    r'^[ \t]*(?:@[\w.]+(?:\([^()\n]*\))?[ \t]+|(?:final|public|private|fileprivate|package|internal|open|indirect|nonisolated)[ \t]+)*'
    r'(class|struct|enum|protocol|actor|extension|func|var|let|init|subscript|typealias|deinit)\b', re.M)


def blank_code(src):
    """Returns src with comments and string contents replaced by spaces (newlines kept), same length."""
    out = list(src)
    n = len(src)
    i = 0

    def blank(a, b):
        for k in range(a, b):
            if out[k] != '\n':
                out[k] = ' '

    def skip_string(i):
        # i is at the opening quote or at the first `#` of a raw string. Returns the index after the string.
        hashes = 0
        while src[i] == '#':
            hashes += 1
            i += 1
        multi = src.startswith('"""', i)
        i += 3 if multi else 1
        close = ('"""' if multi else '"') + '#' * hashes
        interp = '\\' + '#' * hashes + '('
        while i < n:
            if src.startswith(interp, i):
                i = skip_parens(i + len(interp))
                continue
            if hashes == 0 and src[i] == '\\':
                i += 2
                continue
            if src.startswith(close, i):
                return i + len(close)
            i += 1
        return i

    def skip_parens(i):
        depth = 1
        while i < n and depth:
            c = src[i]
            if c == '"' or (c == '#' and re.match(r'#+"', src[i:i + 8])):
                i = skip_string(i)
                continue
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
            i += 1
        return i

    while i < n:
        c = src[i]
        if src.startswith('//', i):
            j = src.find('\n', i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif src.startswith('/*', i):
            depth = 1
            j = i + 2
            while j < n and depth:
                if src.startswith('/*', j):
                    depth += 1
                    j += 2
                elif src.startswith('*/', j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif c == '"' or (c == '#' and re.match(r'#+"', src[i:i + 8])):
            j = skip_string(i)
            # keep the quotes out too: blank everything
            blank(i, j)
            i = j
        else:
            i += 1
    return ''.join(out)


PROP = re.compile(r'^\s*(?:@[\w.]+(?:\([^()]*\))?\s+)*package\s+(?:private\(set\)\s+)?(?:(?:final|nonisolated|weak|unowned|lazy)\s+)*(?P<kw>var|let)\s+(?P<name>\w+)\s*(?::\s*(?P<type>[^=]+?))?\s*(?:=\s*(?P<def>.+?))?\s*(?:\{\s*(?:willSet|didSet).*)?$')
LITERALS = [(re.compile(r'^(true|false)$'), 'Bool'), (re.compile(r'^-?\d[\d_]*$'), 'Int'), (re.compile(r'^-?\d[\d_]*\.\d[\d_]*$'), 'Double'),
            (re.compile(r'^"[^"\\]*"$'), 'String')]


class FakeProp:
    def __init__(self, kw, name, typ):
        self._d = {'kw': kw, 'name': name, 'type': typ, 'def': None}

    def group(self, key):
        return self._d[key]


def split_top(text):
    parts, depth, cur = [], 0, ''
    for ch in text:
        if ch in '<([':
            depth += 1
        elif ch in '>)]':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(cur.strip())
            cur = ''
        else:
            cur += ch
    if cur.strip():
        parts.append(cur.strip())
    return parts


def is_optional(typ):
    typ = typ.strip()
    if '->' in typ and not typ.endswith(')?'):
        return False
    return typ.endswith('?')


def member_type(expr, lines):
    # `Type.name` or `Self.name`, where this file declares `static let name` with a type or a literal.
    m = re.match(r'^(?:Self|[A-Z]\w*)\.(\w+)$', expr)
    if not m:
        return None
    for line in lines:
        d = re.match(r'^\s*(?:@\w+\s+)*(?:package\s+|public\s+|internal\s+)?(?:nonisolated\s+)?static\s+(?:let|var)\s+' + m.group(1) + r'\s*(?::\s*([^=]+?))?\s*(?:=\s*(.+?))?\s*$', line)
        if d:
            return (d.group(1) or '').strip() or literal_type((d.group(2) or '').strip())
    return None


def literal_type(expr):
    for rx, t in LITERALS:
        if rx.match(expr):
            return t
    call = re.match(r'^([A-Z][\w.]*)\(\)$', expr)
    return call.group(1) if call else None


def make_inits(lines, clines, state_at, types):
    inserts = {}
    for tid, info in types.items():
        kw = info['kw']
        if kw not in ('struct', 'class'):
            continue
        if re.search(r'\b(private|fileprivate)\b(?!\()', info['header'].split(kw, 1)[0]):
            continue
        if kw == 'class' and re.search(r'\bclass\s+\w+(<[^>]*>)?\s*:\s*[A-Z]\w*(?:\s*[,{]|\s*$)', info['header']) and False:
            continue
        # direct member lines
        members = []
        for ln in range(info['open_line'] + 1, len(lines)):
            stack_t, paren_l, bracket_l = state_at[ln]
            ids = [e[2] for e in stack_t]
            if tid not in ids:
                break
            if ids[-1] == tid and paren_l == 0 and bracket_l == 0 and clines[ln].strip():
                members.append(ln)
        has_init = False
        props = []
        ok = True
        private_struct = False
        for ln in members:
            text = clines[ln]
            m = DECL.match(text)
            if m and m.group('kw') == 'init':
                has_init = True
                break
            if m and m.group('kw') in ('var', 'let') and 'static' not in m.group('mods') and 'class' not in m.group('mods'):
                brace = text.find('{')
                eq = re.search(r'(?<![=!<>])=(?![=>])', text)
                if brace >= 0 and (eq is None or brace < eq.start()):
                    continue  # computed property or accessor block
                if re.search(r'\b(private|fileprivate)\b(?!\()', text[:m.end('kw')]):
                    # A private property takes no part in a class's `init()`, which only needs every property to have a value.
                    has_value = '=' in text or (m.group('kw') == 'var' and re.search(r'\?\s*$', text.split('=')[0].rstrip()))
                    if not has_value:
                        ok = False
                    elif kw == 'struct':
                        private_struct = True
                    continue
                multi = re.match(r'^\s*(?:@[\w.]+\s+)*package\s+(?:private\(set\)\s+)?(?P<kw>let|var)\s+(?P<rest>\w+\s*:.*)$', lines[ln])
                if multi and '=' not in multi.group('rest') and len(split_top(multi.group('rest'))) > 1:
                    for part in split_top(multi.group('rest')):
                        nm, _, tp = part.partition(':')
                        props.append(FakeProp(multi.group('kw'), nm.strip(), tp.strip()))
                    continue
                observed = ln + 1 < len(lines) and re.match(r'\s*(willSet|didSet)\b', clines[ln + 1]) and text.rstrip().endswith('{')
                pm = PROP.match(re.sub(r'\s*\{\s*$', '', lines[ln]) if observed else lines[ln])
                if observed and pm:
                    props.append(pm)
                    continue
                if not pm:
                    if text.rstrip().endswith('{'):
                        continue  # computed property or accessor block
                    ok = False
                    continue
                if text.rstrip().endswith(('{', '[', '(', ',')) and pm.group('def'):
                    ok = False
                    continue
                props.append(pm)
        if has_init or not ok:
            continue
        if private_struct:
            # A private stored property makes the memberwise initialiser private. The zero-argument one stays, when every property has a value.
            if all(p.group('def') is not None or (p.group('kw') == 'var' and is_optional((p.group('type') or '').split('{')[0])) for p in props) \
                    and info['line_text'].rstrip()[-1:] == '{':
                inserts.setdefault(info['open_line'] + 1, []).extend([re.match(r'\s*', lines[info['open_line']]).group(0) + '    package init() {}', ''])
            continue
        open_text = info['line_text']
        # The opening brace must end its line, so the init goes on the next line.
        if open_text.rstrip()[-1:] != '{':
            continue
        indent = re.match(r'\s*', lines[info['open_line']]).group(0) + '    '
        body = []
        if kw == 'class':
            if all(p.group('def') is not None or is_optional(p.group('type') or '') and p.group('kw') == 'var' for p in props):
                body = [indent + 'package init() {}', '']
        else:
            params, assigns = [], []
            for p in props:
                name, typ, default = p.group('name'), (p.group('type') or '').split('{')[0].strip(), p.group('def')
                if p.group('kw') == 'let' and default is not None:
                    continue
                if not typ and default is not None:
                    typ = literal_type(default.strip()) or member_type(default.strip(), lines) or ''
                    if not typ:
                        # The type is not written down, so the property keeps its default and the caller sets it afterwards.
                        continue
                if p.group('kw') == 'var' and not default and is_optional(typ):
                    default = 'nil'
                if '->' in typ and not typ.endswith(')?') and re.match(r'^(@[\w.]+\s+)*\(', typ):
                    typ = '@escaping ' + typ
                params.append(f'{name}: {typ}' + (f' = {default.strip()}' if default is not None else ''))
                assigns.append(f'{indent}    self.{name} = {name}')
            if not ok:
                continue
            sig = ', '.join(params)
            if len(indent + 'package init(' + sig + ') {') > 140 and params:
                head = [indent + 'package init(']
                head += [indent + '    ' + q + (',' if i < len(params) - 1 else '') for i, q in enumerate(params)]
                head += [indent + ') {']
            else:
                head = [indent + 'package init(' + sig + ') {']
            body = head + assigns + [indent + '}', '']
            if not params:
                body = [indent + 'package init() {}', '']
        if body:
            if lines[info['open_line'] + 1].strip() != '' or True:
                body = body if body[-1] == '' else body + ['']
            inserts.setdefault(info['open_line'] + 1, []).extend(body)
    return inserts


def strip_empty(lines, types):
    remove = []
    for tid, info in types.items():
        at = info['open_line'] + 1
        if at < len(lines) and lines[at].strip() == 'package init() {}':
            end = at + 1 if at + 1 < len(lines) and lines[at + 1].strip() == '' else at
            remove.append((at, end))
    for start, end in sorted(remove, reverse=True):
        del lines[start:end + 1]
    return '\n'.join(lines), bool(remove)


def strip_dups(lines, clines, state_at, types):
    remove = []
    for tid, info in types.items():
        inits = []
        for ln in range(info['open_line'] + 1, len(lines)):
            stack_t, paren_l, bracket_l = state_at[ln]
            ids = [e[2] for e in stack_t]
            if tid not in ids:
                break
            if ids[-1] == tid and paren_l == 0 and bracket_l == 0:
                m = DECL.match(clines[ln])
                if m and m.group('kw') == 'init':
                    inits.append(ln)
        if len(inits) >= 2 and inits[0] == info['open_line'] + 1 and lines[inits[0]].strip().startswith('package init('):
            start = inits[0]
            end = start
            if not lines[start].rstrip().endswith('{}'):
                indent = re.match(r'\s*', lines[start]).group(0)
                while lines[end] != indent + '}':
                    end += 1
            if end + 1 < len(lines) and lines[end + 1].strip() == '':
                end += 1
            remove.append((start, end))
    for start, end in sorted(remove, reverse=True):
        del lines[start:end + 1]
    return '\n'.join(lines), bool(remove)


def process(src, dedupe=False):
    code = blank_code(src)
    lines = src.split('\n')
    clines = code.split('\n')
    # Scan the blanked code for braces, parens and brackets, recording the state at each line start.
    stack = []  # entries: (kind, skip, id)
    types = {}  # id -> dict(name, kw, open_line, header)
    next_id = [0]
    paren = 0
    bracket = 0
    state_at = []
    stmt_start = 0
    pos = 0
    for ln, cl in enumerate(clines):
        state_at.append((tuple(stack), paren, bracket))
        for k, ch in enumerate(cl):
            at = pos + k
            if ch == '(':
                paren += 1
            elif ch == ')':
                paren = max(0, paren - 1)
            elif ch == '[':
                bracket += 1
            elif ch == ']':
                bracket = max(0, bracket - 1)
            elif ch == '{':
                kind, skip = 'other', False
                tinfo = None
                if paren == 0 and bracket == 0:
                    text = code[stmt_start:at]
                    last = None
                    for m in HEADER.finditer(text):
                        last = m
                    if last:
                        header = text[last.start():]
                        kw = last.group(1)
                        if kw in ('class', 'struct', 'enum', 'protocol', 'actor', 'extension'):
                            kind = 'protocol' if kw == 'protocol' else 'type'
                            skip = bool(re.search(r'\b(private|fileprivate)\b(?!\()', header.split(kw, 1)[0]))
                            nm = re.match(r'\s*([\w.]+)', header.split(kw, 1)[1])
                            tinfo = dict(name=nm.group(1) if nm else '?', kw=kw, open_line=ln, header=header, open_col=k, line_text=cl)
                next_id[0] += 1
                if tinfo is not None:
                    types[next_id[0]] = tinfo
                stack.append((kind, skip, next_id[0]))
                stmt_start = at + 1
            elif ch == '}':
                if stack:
                    stack.pop()
                stmt_start = at + 1
            elif ch == ';' and paren == 0:
                stmt_start = at + 1
        pos += len(cl) + 1
        # A declaration ends at a newline when nothing continues it; keep stmt_start at the last boundary but
        # advance it past complete simple statements so HEADER only sees the current one.
        if paren == 0 and bracket == 0 and not cl.rstrip().endswith((',', ':', '=', '&&', '||', '->', '(', '.', 'where')):
            stripped = cl.strip()
            if stripped and not stripped.endswith('{') and not stripped.startswith(('.', '&&', '||', '?', ':', '->')):
                nxt = clines[ln + 1].strip() if ln + 1 < len(clines) else ''
                if not nxt.startswith(('.', '&&', '||', '?', ':', '->', '{', 'where')):
                    stmt_start = pos
    if dedupe:
        return strip_empty(lines, types)
    changed = False
    for ln, line in enumerate(lines):
        stack_t, paren_l, bracket_l = state_at[ln]
        if paren_l or bracket_l:
            continue
        if stack_t:
            kind, skip, _id = stack_t[-1]
            if kind != 'type' or any(e[1] for e in stack_t):
                continue
        # The line must start in code: a line that begins in a string or comment is blank in clines.
        if not clines[ln].strip():
            continue
        m = DECL.match(clines[ln])
        if not m:
            continue
        before_kw = clines[ln][:m.end('kw')]
        if ACCESS.search(before_kw):
            continue
        ins = m.end('attrs')
        lines[ln] = line[:ins] + 'package ' + line[ins:]
        changed = True
    inserts = make_inits(lines, clines, state_at, types)
    for at in sorted(inserts, reverse=True):
        lines[at:at] = inserts[at]
        changed = True
    return '\n'.join(lines), changed


# ---- driver -------------------------------------------------------------------------------------------------------------
import os
import shutil
import subprocess

ROOT = subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip()
os.chdir(ROOT)

MOVE = """
API/APIError.swift
API/APIEvent.swift
API/AgentsAPI.swift
API/AlertsAPI.swift
API/AssistantAPI.swift
API/AutomationsAPI.swift
API/BubblesAPI.swift
API/ChatAPI.swift
API/DesktopAPI.swift
API/IronPetAPI.swift
API/MeetingsAPI.swift
API/MemoryAPI.swift
API/NotificationsAPI.swift
API/PetAPI.swift
API/ScreenAPI.swift
API/ScreenTools.swift
API/SettingsAPI.swift
API/TasksAPI.swift
API/TodayAPI.swift
API/UsageAPI.swift
API/VoiceAPI.swift
Activity/ActivityDigest.swift
Activity/ActivityEvent.swift
Activity/ActivityLog.swift
Activity/AwayTracker.swift
Activity/Presence.swift
Activity/WelcomeBack.swift
Automations/AutomationAgentPrompts.swift
Automations/AutomationDefaults.swift
Automations/AutomationEngine.swift
Automations/AutomationMCP.swift
Automations/AutomationModel.swift
Automations/AutomationPrompt.swift
Automations/AutomationScript.swift
Automations/AutomationService.swift
Automations/AutomationSession.swift
Automations/AutomationState.swift
Automations/AutomationStore.swift
Automations/EventCoalescer.swift
Automations/HeartbeatRemoval.swift
Automations/PollEngine.swift
Automations/StreamEngine.swift
Automations/StreamProcess.swift
Bridge/HTTPRequest.swift
Bridge/MCPEndpoint.swift
Bridge/StatusSnapshot.swift
Brief/Brief.swift
Brief/BriefSource.swift
Capture/CaptureBlocks.swift
Capture/CaptureModel.swift
Capture/CapturePipeline.swift
Capture/CapturePrivacy.swift
Capture/CaptureRedactor.swift
Capture/CaptureScheduler.swift
Capture/CaptureStore.swift
Capture/CaptureText.swift
Capture/CaptureTree.swift
Capture/CaptureTreeStore.swift
Capture/CaptureURL.swift
Capture/CaptureView.swift
Capture/ScreenMCP.swift
Chat/ACP/ACPAgent.swift
Chat/ACP/ACPBackend.swift
Chat/ACP/ACPClient.swift
Chat/ACP/ACPRuntime.swift
Chat/ACP/ACPToolCall.swift
Chat/ACP/AgentCatalogData.swift
Chat/ACP/Elicitation.swift
Chat/ACP/TerminalLauncher.swift
Chat/ChatFind.swift
Chat/ChatLog.swift
Chat/ChatSession.swift
Chat/DraftPolicy.swift
Chat/ElicitationPager.swift
Chat/MCPAuthSharing.swift
Chat/Markdown.swift
Chat/MessageCollapse.swift
Chat/SlashCommands.swift
Chat/SystemNotice.swift
Chat/ThreadStore.swift
Chat/TranscriptRecorder.swift
Desktop/DesktopAX.swift
Desktop/DesktopKeys.swift
Desktop/DesktopMCP.swift
Desktop/DesktopSafety.swift
Desktop/DesktopService.swift
Hooks/HookInstaller.swift
Hooks/HookScript.swift
Jobs/AssistantMCP.swift
Jobs/JobModel.swift
Jobs/JobService.swift
Jobs/ProjectResolver.swift
Meeting/AudioApps.swift
Meeting/CallDetector.swift
Meeting/CallPrompt.swift
Meeting/Chunker.swift
Meeting/MeetingLibrary.swift
Meeting/MeetingRegenerator.swift
Meeting/MeetingSpeakers.swift
Meeting/MeetingSummary.swift
Meeting/MeetingTranscript.swift
Meeting/SpeakerDiarizing.swift
Meeting/SpeakerMatcher.swift
Meeting/TrackRecorder.swift
Meeting/VoiceStore.swift
Memory/EntityMatcher.swift
Memory/EntityMemoryStore.swift
Memory/MemoryIndex.swift
Memory/MemoryMCP.swift
Memory/MemoryMigration.swift
Memory/MemoryNote.swift
Memory/MemoryPreamble.swift
Memory/MemoryReflector.swift
Memory/MemoryStore.swift
Notifications/NotificationDraft+Sources.swift
Notifications/NotificationMCP.swift
Notifications/NotificationModel.swift
Notifications/NotificationStore.swift
Pet/Bubble.swift
Pet/BubbleActionTable.swift
Pet/BubbleStore.swift
Pet/PetLibrary.swift
Pet/PetMood.swift
Platform/AppInfo.swift
Platform/AudioTranscoder.swift
Platform/CapabilityError.swift
Platform/CaptureControl.swift
Platform/FileIntake.swift
Platform/LogSink.swift
Platform/Mac/ChatSession+ObservableObject.swift -> Chat/ChatSession+ObservableObject.swift
Platform/MeetingRecorder.swift
Platform/POSIXProcessSpawner.swift
Platform/PetAssets.swift
Platform/Platform.swift
Platform/PresenceSource.swift
Platform/ProcessSpawner.swift
Platform/SecretStore.swift
Platform/SpeechOutput.swift
Platform/URLOpener.swift
Platform/WallClock.swift
Remote/RemoteAutomations.swift
Remote/RemoteChat.swift
Remote/RemoteIdentity.swift
Remote/RemoteMeetings.swift
Remote/RemotePhoneSettings.swift
Remote/RemoteResources.swift
Remote/RemoteScreen.swift
Remote/RemoteService.swift
Remote/RemoteStore.swift
Remote/RemoteTasks.swift
Sessions/AgentSession.swift
Sessions/SessionStore.swift
Signals/SignalStore.swift
Skills/BundledSkills.swift
Skills/BundledSkillsData.swift
Skills/SkillInstaller.swift
Support/ChangeSignal.swift
Support/Config.swift
Support/Database.swift
Support/DatabaseNotice.swift
Support/ListNavigation.swift
Support/Log.swift
Support/Paths.swift
Tasks/ActionItems.swift
Tasks/TaskDetailLogic.swift
Tasks/TaskJSON.swift
Tasks/TaskMCP.swift
Tasks/TaskModel.swift
Tasks/TaskStore.swift
Telegram/TelegramAPI.swift
Telegram/TelegramBridge.swift
Telegram/TelegramFormat.swift
Telegram/TelegramForms.swift
Telegram/TelegramMedia.swift
Usage/UsagePricing.swift
Usage/UsageStore.swift
Voice/ConversationPorts.swift
Voice/FrontDesk.swift
Voice/LevelBuffer.swift
Voice/ReplySpeaker.swift
Voice/SegmentFilter.swift
Voice/SpeechText.swift
Voice/Synthesizer.swift
Voice/Transcriber.swift
Voice/VoiceActivity.swift
Voice/VoiceConversation.swift
Voice/VoiceKey.swift
Voice/VoiceTiming.swift
Voice/WAV.swift
""".strip().splitlines()

TESTS_MOVE = """
ACPRuntimeTests.swift
ActivityDigestTests.swift
ActivityLogTests.swift
ApprovalRulesTests.swift
AssistantMCPTests.swift
AutomationScriptTests.swift
CaptureMigrationTests.swift
CaptureRedactionTests.swift
CaptureSchedulerTests.swift
CaptureStorageBenchmarkTests.swift
CaptureStoreTests.swift
CaptureTextTests.swift
CaptureTreeFixtures.swift
CaptureTreeTests.swift
CaptureViewTests.swift
ChangeSignalTests.swift
ChatFindTests.swift
ElicitationTests.swift
FileIntakeTests.swift
FrontDeskTests.swift
HookInstallerTests.swift
MCPEndpointTests.swift
MarkdownTests.swift
MeetingRegenerationTests.swift
MemoryIndexTests.swift
MemoryReflectorTests.swift
MessageCollapseTests.swift
PasteLimitsTests.swift
SessionMappingTests.swift
SkillInstallerTests.swift
SpeechTextTests.swift
InboxLinkTests.swift
TaskTimeTests.swift
ThreadRestoreTests.swift
VoiceActivityTests.swift
SegmentFilterTests.swift
""".split()

SHARED_TEST_HELPERS = ['CISkip.swift', 'TestMemory.swift', 'CaptureTestSupport.swift', 'StubProtocol.swift']


def git(*args):
    subprocess.check_call(['git', *args])


def swift_files(folder):
    for base, _, names in os.walk(folder):
        for name in sorted(names):
            if name.endswith('.swift'):
                yield os.path.join(base, name)


def rewrite_imports(path):
    with open(path, encoding='utf-8') as f:
        s = f.read()
    o = s
    s = re.sub(r'^import CryptoKit\n', '#if canImport(CryptoKit)\nimport CryptoKit\n#else\nimport Crypto\n#endif\n', s, flags=re.M)
    if re.search(r'\bURLSession|\bURLRequest|HTTPURLResponse', s) and 'FoundationNetworking' not in s:
        s = re.sub(r'^import Foundation\n', 'import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n', s, count=1, flags=re.M)
    if s != o:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(s)


def add_import(path, testable=False):
    with open(path, encoding='utf-8') as f:
        s = f.read()
    line = '@testable import IronPetCore' if testable else 'import IronPetCore'
    if re.search(r'^(@testable )?import IronPetCore$', s, re.M):
        return
    lines = s.split('\n')
    idx = [i for i, l in enumerate(lines) if re.match(r'^(@testable )?import \w', l)]
    if not idx:
        k = 0
        while k < len(lines) and lines[k].startswith('//'):
            k += 1
        lines[k:k] = [line, ''] if k < len(lines) and lines[k].strip() else [line]
    else:
        first = idx[0]
        last = first
        while last + 1 < len(lines) and (re.match(r'^(@testable )?import \w', lines[last + 1]) or lines[last + 1].startswith('#')):
            last += 1
        block = [i for i in range(first, last + 1) if re.match(r'^(@testable )?import \w', lines[i])]
        pos = None
        for i in block:
            if lines[i].split('import ')[1].strip() > 'IronPetCore':
                pos = i
                break
        pos = pos if pos is not None else last + 1
        # Never insert inside an `#if` block, which the file may use to guard an import.
        depth, opened = 0, []
        for i in range(first, pos):
            if lines[i].startswith('#if'):
                depth += 1
                opened.append(i)
            elif lines[i].startswith('#endif'):
                depth -= 1
                opened.pop()
        if depth > 0:
            pos = opened[0]
        lines.insert(pos, line)
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))


def edit_package():
    with open('Package.swift', encoding='utf-8') as f:
        s = f.read()
    start = s.index('        .executableTarget(name: "IronPet"')
    end = s.index('    ]\n)')
    new = '''        // The half of ironpet that needs no UI and no Mac framework: stores, the agent client, automations, tasks, the API layer
        // and the platform protocols. Tests/IronPetCoreTests/ImportAllowListTests.swift fails when a file here imports a framework
        // outside its allow list. A feature with no UI lands here, and UI code calls only IronPetAPI.
        .target(name: "IronPetCore", dependencies: ["IronPetKit", .product(name: "JMESPath", package: "jmespath.swift"), .product(name: "QuickJS", package: "QuickJS-Swift"), .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows])), .target(name: "CSQLite", condition: .when(platforms: [.linux, .windows]))], path: "Sources/IronPetCore"),
        .testTarget(name: "IronPetCoreTests", dependencies: ["IronPetCore"], path: "Tests/IronPetCoreTests", resources: [.copy("Fixtures")]),
        .executableTarget(name: "IronPet", dependencies: ["IronPetCore", "IronPetKit", "IronPetObjC", .product(name: "JMESPath", package: "jmespath.swift"), .product(name: "QuickJS", package: "QuickJS-Swift"), .product(name: "FluidAudio", package: "FluidAudio"), .product(name: "Hummingbird", package: "hummingbird"), .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"), .product(name: "NIOTransportServices", package: "swift-nio-transport-services")], path: "Sources/IronPet"),
        .testTarget(name: "IronPetTests", dependencies: ["IronPet", "IronPetCore"], path: "Tests/IronPetTests"),
'''
    s = s[:start] + new + s[end:]
    with open('Package.swift', 'w', encoding='utf-8') as f:
        f.write(s)


def main():
    if os.path.exists('Sources/IronPetCore'):
        sys.exit('Sources/IronPetCore exists already. Run this on a checkout of the commit before the extraction.')
    for entry in MOVE:
        rel, _, renamed = entry.partition(' -> ')
        src, dst = f'Sources/IronPet/{rel}', f'Sources/IronPetCore/{renamed or rel}'
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        git('mv', src, dst)
    for path in swift_files('Sources/IronPetCore'):
        rewrite_imports(path)
        with open(path, encoding='utf-8') as f:
            src = f.read()
        out, changed = process(src)
        if changed:
            with open(path, 'w', encoding='utf-8') as f:
                f.write(out)
    for path in swift_files('Sources/IronPet'):
        add_import(path)
    edit_package()
    move_tests()


def retarget_import(path, core):
    with open(path, encoding='utf-8') as f:
        s = f.read()
    o = s
    if core:
        s = re.sub(r'^@testable import IronPet$', '@testable import IronPetCore', s, flags=re.M)
    elif re.search(r'^@testable import IronPet$', s, re.M) and not re.search(r'^@testable import IronPetCore$', s, re.M):
        s = re.sub(r'^@testable import IronPet$', '@testable import IronPet\n@testable import IronPetCore', s, count=1, flags=re.M)
    if s != o:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(s)


def split_stub_protocol():
    # StubProtocol sits in TranscriberTests, which stays on the Mac side, but SegmentFilterTests in core uses it too.
    path = 'Tests/IronPetTests/TranscriberTests.swift'
    with open(path, encoding='utf-8') as f:
        s = f.read()
    start = s.index('/// Answers every request with a canned response')
    end = s.index('\n}\n', start) + 3
    block = s[start:end]
    with open('Tests/IronPetTests/StubProtocol.swift', 'w', encoding='utf-8') as f:
        f.write('import Foundation\n\n' + block)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(s[:start] + s[end:].lstrip('\n'))
    git('add', 'Tests/IronPetTests/StubProtocol.swift')


def move_tests():
    os.makedirs('Tests/IronPetCoreTests', exist_ok=True)
    split_stub_protocol()
    for name in TESTS_MOVE:
        git('mv', f'Tests/IronPetTests/{name}', f'Tests/IronPetCoreTests/{name}')
    # A test target cannot see another target's files, so helpers both sides use are copied.
    for name in SHARED_TEST_HELPERS:
        shutil.copy(f'Tests/IronPetTests/{name}', f'Tests/IronPetCoreTests/{name}')
        git('add', f'Tests/IronPetCoreTests/{name}')
    # SegmentFilterTests is the only reader of the fixtures, and it moved.
    git('mv', 'Tests/IronPetTests/Fixtures', 'Tests/IronPetCoreTests/Fixtures')
    for path in swift_files('Tests/IronPetCoreTests'):
        retarget_import(path, core=True)
    for path in swift_files('Tests/IronPetTests'):
        retarget_import(path, core=False)


main()
PY
