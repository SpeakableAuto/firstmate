#!/usr/bin/env python3
"""Check brief/PR shape without executing evidence commands or granting release authority.

Usage: fm-pr-lint.py --file BODY [--kind brief|pr] [--changed-path PATH ...]
       fm-pr-lint.py --pr-url https://github.com/OWNER/REPO/pull/NUMBER

The first substantive line must be Goal: <outcome>.
For a scaffolded brief, this means the first line inside # Task.
Required declarations outside fenced code/comments, each appearing exactly once:
  Carve-outs: none | payments, logins-keys-secrets, shared-database-schema
  Staff-facing: yes | no
Staff-facing changes also require Admin Update: https://... | Coming soon (or Live).
## Verification must contain a Markdown Command/Exit table with nonempty backticked
commands and numeric exit codes for every data row. No commands are executed.
Absent Live proof: https://... in Verification, require an early
NOT PROVEN WHERE USERS SEE IT: <missing check and reason> line.
Live proof is a link declaration, not independent verification of the outcome.

Briefs additionally refuse research/study/audit/inventory/review findings caps:
top N, N best/key/most important, best N, and at most/up to N findings. Numeric and
spelled-out numbers through twenty are recognized (one-twelve, fifteen, twenty).
An imperative fix/repair/resolve instruction in Captain's intent exempts only
its capped bugs/errors/failing tests/lint work, not research about those topics.
Only Captain's intent can authorize a research cap of the same subject and no
more than the requested count (a bare request cannot authorize a named subject),
by a direct request: "Zac asked for the top 3", "Zac wants the best five",
or "Zac requested the 3 best". An explicit override in that sentence or the next
(but now, no longer, has since, withdrew/withdrawn, changed his/their mind,
now/instead wants every/all, every item, all of them, full list) cancels it;
ordinary "not" or "instead" wording does not. Subjects use case/spacing and
singular/plural findings-noun normalization, not inferred synonyms.
The first Task preamble and Captain's intent / Firstmate spec are checked, not
Verification or the surrounding worker instructions. An uncapped brief need not
contain coverage/page wording to pass. PR bodies do not use this depth check.

Changed paths and task/change prose flag likely carve-outs, including SQL migrations
whose database ownership cannot be inferred. Added code lines flag only specific
payment APIs, secret-like env names, credential files, JWT/OAuth and schema statements. Declare the category, or record a specific
false-positive explanation: Carve-out review: <category> | <reason>.
For a staff false positive, use Staff-facing review: <reason>.
These explanations and classifications are review inputs, never approvals.
The classifier is conservative and cannot recognize every domain-specific alias.

The GitHub reader uses gh-axi full body/diff output and checks the head before and
after reading. Unknown, missing or truncated output refuses; other forges must
use --file until an adapter is implemented. Exit 0 shape passes, 1 refusal, 2 usage.
The home config and integration boundaries are documented in docs/configuration.md.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit


# Prose describes intent, so retain broad words that are ambiguous in code.
CATEGORIES = {
    'payments': r'\b(?:payments?|stripe|refunds?|billing|checkout|cards?)\b',
    'logins-keys-secrets': r'\b(?:logins?|passwords?|secrets?|credentials?|oauth|auth|authentication|jwt|keys?|tokens?)\b',
    'shared-database-schema': r'\b(?:migrations?|schema|alter\s+table|create\s+table|add\s+column|shared[- ]database)\b',
}
# Changed paths stay conservative: broad words still flag likely carve-outs.
PATH_CATEGORIES = {
    'payments': r'\b(?:payments?|stripe|refunds?|billing|checkout|cards?)\b',
    'logins-keys-secrets': r'\b(?:logins?|passwords?|secrets?|credentials?|oauth|auth|jwt|keys?|tokens?)\b|\.env\b|\.pem$',
    'shared-database-schema': r'\b(?:migrations?|schema)\b|\.sql$',
}
# Added code lines only count through specific APIs, names and statements.
CODE_CATEGORIES = {
    'payments': r'(?i:\bstripe\b|payment[-_]?intents?|checkout\.sessions?|\brefunds\.create)',
    'logins-keys-secrets': r'\b[A-Z0-9_]*(?:SECRET|TOKEN|API_KEY|PASSWORD|PRIVATE_KEY|CREDENTIALS?)[A-Z0-9_]*\b'
                           r'|(?i:\bjwt\b|jsonwebtoken|\boauth2?\b|id_rsa|\.pem\b|credentials\.json|\.netrc\b|(?:^|[\s\'"/])\.env(?:\.\w+)?\b)',
    'shared-database-schema': r'(?i:\b(?:alter|create|drop)\s+table\b|\badd\s+column\b|prisma\s+(?:db\s+push|migrate)|^\s*model\s+\w+\s*\{)',
}

# Mirror the numbered cap patterns and non-findings count exclusions linked by rule 23:
# https://github.com/SpeakableAuto/claude-config/pull/81
# Firstmate scopes authorization and imperative fix-task exemptions to captain intent.
# Requests must match the subject/count and not be withdrawn in the same or next sentence.
NUMBER = r'(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty)'
FINDINGS = r'(?:ideas?|items?|findings?|options?|techniques?|recommendations?|points?|things?|tips?|ways?|lessons?|picks?|examples?|sources?|tools?|competitors?|features?|takeaways?|insights?)'
RESEARCH = re.compile(
    r'\b(?:research\w*|stud(?:y|ying|ies)|audit(?:ing)?|inventor(?:y|ies)|investigat\w*|analy[sz]\w*'
    r'|deep[\s-]dive|survey\w*|learn(?:ing)?(?: from)?|compare|evaluat\w*|review of|look into)\b', re.I)
FIX_TASK = re.compile(r'^\s*(?:>\s*)?[\"“]?(?:please\s+)?(?:fix|repair|resolve)\s+(?:the\s+)?$', re.I)
FIX_SUBJECT = re.compile(r'^(?:(?:lint|regression)\s+)?(?:bugs?|errors?|failures?)$|^failing\s+tests?$|^lint$', re.I)
CAP = re.compile(
    r'\btop[\s-]*' + NUMBER + r'\b'
    r'|\b' + NUMBER + r'\s+(?:best|most\s+\w+|key|biggest)\b'
    r'|\bbest[\s-]*' + NUMBER + r'\b'
    r'|\b(?:no more than|at most|up to|max(?:imum)?(?: of)?)\s+' + NUMBER + r'\s+(?:\w+\s+){0,2}' + FINDINGS + r'\b', re.I)
CAP_REQUEST = re.compile(
    r'\bzac (?:asked|wants|requested)\s+(?:for\s+)?(?:only\s+)?(?:the\s+)?'
    r'(?:\btop[\s-]*' + NUMBER + r'|\b' + NUMBER + r'\s+best|\bbest[\s-]*' + NUMBER + r')\b', re.I)
CAP_WITHDRAWAL = re.compile(
    r'\b(?:but\s+now|no\s+longer|has\s+since|withdr[ea]w\w*|changed\s+(?:his|their)\s+mind'
    r'|(?:now|instead)\s+wants\s+(?:every|all)|every\s+item|all\s+of\s+them|full\s+list)\b', re.I)


def cap_value(sentence, match):
    """Normalize a count and its explicit subject; an unnamed subject stays unnamed."""
    number = re.search(NUMBER, match[0], re.I)
    value = number[0].lower()
    words = ('one two three four five six seven eight nine ten eleven twelve').split()
    counts = dict(zip(words, range(1, 13)), fifteen=15, twenty=20)
    count = int(value) if value.isdigit() else counts[value]
    # Include the object inside an "at most N findings" match as well as after top N.
    tail = sentence[match.start() + number.end():].lower()
    tail = re.sub(r'^\s*(?:best|key|biggest|most\s+\w+)\b', '', tail)
    tail = re.split(r'[,;:.!?()\n]|\b(?:and|or|only|please|from|for|that|which|we|to|last|but|not)\b', tail, maxsplit=1)[0]
    tokens = re.findall(r"[a-z]+(?:'[a-z]+)?", tail)
    # Normalize singular/plural findings nouns, without guessing domain synonyms.
    if tokens and re.fullmatch(FINDINGS, tokens[-1]) and tokens[-1].endswith('s'):
        tokens[-1] = tokens[-1][:-1]
    return count, ' '.join(tokens)


def current_cap_requests(intent):
    """Return each attributed cap, excluding adjacent withdrawals."""
    sentences = re.split(r'(?<=[.!?])\s+|\n+', intent)
    requests = []
    for index, sentence in enumerate(sentences):
        if CAP_WITHDRAWAL.search(' '.join(sentences[index:index + 2])):
            continue
        for request in CAP_REQUEST.finditer(sentence):
            cap = CAP.search(sentence, request.start(), request.end())
            if cap:
                requests.append(cap_value(sentence, cap))
    return requests


def research_depth_capped(text):
    """Every capped deliverable needs its own authority; spec cannot grant it."""
    clean = prose(text, keep_quotes=True)
    parts = re.split(r'^##\s+([^\n]+)\n', clean, flags=re.M)
    task, intent = [(parts[0], False)], []
    for heading, body in zip(parts[1::2], parts[2::2]):
        heading = heading.strip().lower().replace('\u2019', "'")
        if heading in ("captain's intent", 'firstmate spec'):
            task.append((body, heading == "captain's intent"))
        if heading == "captain's intent":
            intent.append(body)
    if not RESEARCH.search('\n'.join(body for body, _ in task)):
        return False
    requests = current_cap_requests('\n'.join(intent))
    for body, is_intent in task:
        for clause in re.split(r'(?<=[.!?;:])\s+|\n+', body):
            for cap in CAP.finditer(clause):
                count, subject = cap_value(clause, cap)
                if (is_intent and FIX_TASK.fullmatch(clause[:cap.start()])
                        and FIX_SUBJECT.fullmatch(subject)):
                    continue
                if not any(count <= allowed and subject == target for allowed, target in requests):
                    return True
    return False


def code_span(cell):
    match = re.fullmatch(r'(`+)(?!`)([^\n]+?)(?<!`)\1', cell)
    return bool(match and match[2].strip()
                and len(match[1]) not in {len(run) for run in re.findall(r'`+', match[2])})


def prose(text, keep_quotes=False):
    """Keep declarations outside quoted/fenced examples and HTML comments."""
    text = re.sub(r'<!--.*?-->', '', text, flags=re.S)
    result, fence = [], None
    for line in text.splitlines():
        match = re.match(r'^\s*(`{3,}|~{3,})', line)
        if match:
            marker = match[1]
            if fence is None:
                fence = marker
            elif marker[0] == fence[0] and len(marker) >= len(fence):
                fence = None
            continue
        if fence is None and (keep_quotes or not line.lstrip().startswith('>')):
            result.append(line)
    return '\n'.join(result)


def meaningful(value):
    return (len(value.strip()) >= 12 and
            not re.search(r'\b(?:TODO|TBD|PLACEHOLDER)\b|\{[^}]+\}|\[insert', value, re.I))


def url_valid(value):
    try:
        p = urlsplit(value)
        return (p.scheme == 'https' and bool(p.hostname) and not p.username
                and not p.password and not re.search(r'[\s<>`]', value))
    except ValueError:
        return False


def carve_out_signals(text, paths=(), diff=''):
    """Shared conservative classifier; declarations and evidence are not signals."""
    clean = prose(text)
    narrative = '\n'.join(line for line in clean.splitlines() if not line.lstrip().startswith('|'))
    narrative = re.sub(r'^(?:Carve-outs|Carve-out review|Staff-facing|Staff-facing review|Admin Update):[^\n]*', '', narrative, flags=re.M | re.I)
    return {category for category in CATEGORIES
            if (re.search(CATEGORIES[category], narrative.replace('_', '-'), re.I)
                or any(re.search(PATH_CATEGORIES[category], path.replace('_', '-'), re.I) for path in paths)
                or any(re.search(CODE_CATEGORIES[category], line) for line in diff.splitlines()))}


def lint(text, kind='pr', paths=(), diff=''):
    errors = []

    def refuse(code, fix):
        errors.append(f'refuse: {code}; fix: {fix}')

    if kind == 'brief':
        task = re.search(r'^# Task\s*\n(.*?)(?=^# |\Z)', text, re.M | re.S)
        if task:
            text = task[1]
        if research_depth_capped(text):
            refuse('research-depth', 'cover every item; say "complete coverage" and name the deliverable page '
                   '(three-line chat headline plus the full page), or quote the explicit cap request '
                   'with matching subject and count in Captain\'s intent ("Zac asked for the top 5 ideas")')
    clean = prose(text)
    lines = [line.strip() for line in clean.splitlines() if line.strip()]
    if not lines or not re.fullmatch(r'Goal:\s*.+', lines[0], re.I) or not meaningful(lines[0][5:]):
        refuse('goal', 'put Goal: followed by a concrete outcome on the first substantive line')

    verification = re.search(r'^## Verification\s*\n(.*?)(?=^#{1,2} |\Z)', clean, re.M | re.S)
    evidence = verification[1] if verification else ''
    if not verification:
        refuse('verification', 'add a ## Verification section with recorded commands and numeric exit codes')
    header, recorded, invalid, first = None, 0, False, True
    for line in evidence.splitlines():
        if not line.strip().startswith('|'):
            first = True
            continue
        row = [cell.strip() for cell in re.split(r'(?<!\\)\|', line.strip().strip('|'))]
        if first:
            lowered = [cell.lower() for cell in row]
            header = (lowered.index('command'), lowered.index('exit')) if 'command' in lowered and 'exit' in lowered else None
            first = False
            continue
        if not header or all(re.fullmatch(r'[-: ]+', cell) for cell in row):
            continue
        cmd, code = header
        if (len(row) <= max(header) or not code_span(row[cmd])
                or not re.fullmatch(r'-?\d+', row[code])
                or re.search(r'\b(?:TODO|TBD|PLACEHOLDER)\b', row[cmd], re.I)):
            invalid = True
        else:
            recorded += 1
    if recorded == 0 or invalid:
        refuse('verification-command', 'record each check in a Command | Exit table, with a backticked command and its actual integer exit code')

    live = re.findall(r'^Live proof:\s*(\S+)\s*$', evidence, re.M | re.I)
    disclosed = False
    for index, line in enumerate(lines[:4]):
        marker = re.fullmatch(r'NOT PROVEN WHERE USERS SEE IT(?:[.:]\s*(.*))?', line.replace('**', ''))
        if marker:
            reason = marker[1] or (lines[index+1] if index+1 < len(lines) else '')
            disclosed = meaningful(reason) and not reason.startswith('#')
            if disclosed:
                break
    if not (len(live) == 1 and url_valid(live[0])) and not disclosed:
        refuse('live-proof', 'add NOT PROVEN WHERE USERS SEE IT: <missing check and reason> immediately after the goal, or a Live proof: https://... evidence link in Verification')

    def field(name):
        values = re.findall(r'^'+re.escape(name)+r':\s*([^\n]*)$', clean, re.M | re.I)
        return values[0].strip() if len(values) == 1 else None

    classification = field('Carve-outs')
    categories = set(x.strip().lower() for x in classification.split(',')) if classification else set()
    if not categories or not categories <= set(CATEGORIES) | {'none'} or ('none' in categories and len(categories) != 1):
        refuse('carve-outs', 'declare exactly one Carve-outs: line listing payments, logins-keys-secrets, shared-database-schema, or none')

    # Exclude evidence tables, policy declarations and quoted transcripts from
    # prose classification. Diff paths/content remain independent input.
    narrative = '\n'.join(line for line in clean.splitlines() if not line.lstrip().startswith('|'))
    narrative = re.sub(r'^(?:Carve-outs|Carve-out review|Staff-facing|Staff-facing review|Admin Update):[^\n]*', '', narrative, flags=re.M | re.I)
    signals = narrative + '\n' + '\n'.join(paths) + '\n' + diff
    flagged_categories = carve_out_signals(text, paths, diff)
    for category in CATEGORIES:
        if category in flagged_categories and category not in categories:
            reviews = re.findall(r'^Carve-out review:\s*'+re.escape(category)+r'\s*\|\s*(.+)$', clean, re.M | re.I)
            if len(reviews) != 1 or not meaningful(reviews[0]):
                refuse('carve-outs/'+category, f'include {category} in Carve-outs, or add Carve-out review: {category} | <specific false-positive reason>; classification does not authorize release')

    staff = field('Staff-facing')
    if staff is None or staff.lower() not in ('yes', 'no'):
        refuse('staff-facing', 'declare exactly one Staff-facing: yes or Staff-facing: no line')
    likely_staff = re.search(r'\b(?:staff[- ](?:facing|portal|release|feature)|admin[-_/ ](?:portal|app)|staff/|employee/)', signals, re.I)
    if likely_staff and staff and staff.lower() == 'no' and not meaningful(field('Staff-facing review') or ''):
        refuse('staff-facing', 'declare Staff-facing: yes or add Staff-facing review: <specific internal-only explanation>')
    if staff and staff.lower() == 'yes':
        update = field('Admin Update') or ''
        bits = [part.strip() for part in update.split('|')]
        if len(bits) != 2 or not url_valid(bits[0]) or bits[1].lower() not in ('coming soon', 'live'):
            refuse('admin-update', 'add Admin Update: https://<published-admin-update> | Coming soon (or Live); publish and verify the Update before release')
    return errors


def run_axi(*args):
    result = subprocess.run(['gh-axi', *args], text=True, capture_output=True, timeout=60)
    if result.returncode or re.search(r'^\s*(?:error:|truncated: true)', result.stdout, re.M):
        raise ValueError('forge read failed or was truncated; repair gh-axi access and retry')
    return result.stdout


def toon_scalar(output, name, indent):
    """Read the specific scalar contract emitted by gh-axi, never generic YAML."""
    matches = re.findall(r'^'+' '*indent+re.escape(name)+r': (.*)$', output, re.M)
    if len(matches) != 1:
        raise ValueError(f'forge response missing unique {name}; use a compatible gh-axi and retry')
    raw = matches[0]
    value = json.loads(raw) if raw.startswith('"') else raw
    if not isinstance(value, str) or value.endswith('... (truncated)'):
        raise ValueError(f'forge {name} is not complete; retry with full output')
    return value


def read_pr(url):
    match = re.fullmatch(r'https://([^/]+)/([^/]+/[^/]+)/pull/([1-9]\d*)', url)
    if not match or not re.fullmatch(r'[A-Za-z0-9.-]+', match[1]) or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', match[2]):
        raise ValueError('unsupported PR URL; use a GitHub pull URL or lint an exported body with --file')
    host, repo, number = match.groups()
    def head():
        output = run_axi('api', f'/repos/{repo}/pulls/{number}', '--hostname', host, '--jq', '.head.sha')
        value = toon_scalar(output, 'body', 2)
        if not re.fullmatch(r'[a-f0-9]{40}', value):
            raise ValueError('forge head unavailable; retry the complete read')
        return value
    before = head()
    body = toon_scalar(run_axi('pr', 'view', number, '-R', repo, '--hostname', host, '--full'), 'body', 2)
    diff = toon_scalar(run_axi('pr', 'diff', number, '-R', repo, '--hostname', host, '--full'), 'diff', 2)
    if before != head():
        raise ValueError('PR head changed while reading; retry on the final head')
    paths = re.findall(r'^(?:diff --git|---|\+\+\+|rename from|rename to) ([^\n]+)', diff, re.M)
    # Include new lines only, plus both old/new paths for renames and removals.
    changes = '\n'.join(line[1:] for line in diff.splitlines() if line.startswith('+') and not line.startswith('+++'))
    return body, paths, changes, before


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--file', type=Path)
    source.add_argument('--pr-url')
    parser.add_argument('--kind', choices=('brief', 'pr'), default='pr')
    parser.add_argument('--changed-path', action='append', default=[])
    args = parser.parse_args()
    try:
        head = ''
        if args.pr_url:
            body, paths, changes, head = read_pr(args.pr_url)
        else:
            body, paths, changes = args.file.read_text(), args.changed_path, ''
        errors = lint(body, args.kind, paths, changes)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        errors = [f'refuse: input; fix: {exc}']
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print('pass: brief/PR shape' + (f' head={head}' if head else '') + '; release evidence and approvals still require review')
    return 0


if __name__ == '__main__':
    sys.exit(main())
