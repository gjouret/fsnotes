#!/usr/bin/env bash
# rule7-gate.sh — Phase 7.5.d banned-pattern gate
#
# Enforces two architectural invariants that have repeatedly broken the app
# in the past (see CLAUDE.md Rule 7 and REFACTOR_PLAN.md Phase 7.5):
#
#   1. No marker-hiding tricks in view / renderer code (tiny font, clear
#      foreground color, negative kern, widget-local inline reparse,
#      view-to-model bidirectional data flow).
#   2. No hardcoded presentation values (font sizes, paragraph spacing,
#      hex colors) in the rendering pipeline — everything flows through
#      Theme.shared.
#
# Targets: FSNotes/ and FSNotesCore/ (the production source tree).
# NOT scanned: Tests/, Pods/, Resources/Themes/*.json, ThemeSchema.swift,
#              ThemeAccess.swift (these are the theme definitions themselves).
#
# Usage:
#   ./scripts/rule7-gate.sh              # scan and report
#   echo "exit=$?"                       # 0 = pass, 1 = violations
#
# Escape hatch: a single comment `// rule7-gate:allow` on the line IMMEDIATELY
# above a flagged line will suppress that one match. Use sparingly and always
# with a rationale on the same or next comment line.
#
# This script is pure POSIX + grep/awk/sed; no xcodebuild, no network, no state.
# Safe to run locally or from CI (exit code is the signal).

set -o pipefail

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Directories to scan.
SCAN_DIRS=(
    "FSNotes"
    "FSNotesCore"
)

# Files explicitly excluded from the gate:
#   - Theme schema / color access live here by design.
#   - Source-mode text-storage pipeline (TextStorageProcessor + friends) is
#     scheduled for removal in Phase 4 of the refactor plan. Its literals
#     are tracked there, not here.
#   - NotesTextProcessor is the legacy source-mode highlighter; same deal.
EXCLUDED_FILES=(
    "FSNotesCore/Rendering/ThemeSchema.swift"
    "FSNotesCore/Rendering/ThemeAccess.swift"
    "FSNotesCore/Rendering/Theme.swift"
    "FSNotesCore/TextStorageProcessor.swift"
    "FSNotesCore/NotesTextProcessor.swift"
    "FSNotesCore/NSTextStorage++.swift"
    "FSNotesCore/TextFormatter.swift"
    "FSNotesCore/ImagesProcessor.swift"
)

# Phase 5a: files allowed to call `performEditingTransaction` directly.
# `DocumentEditApplier` is the single canonical WYSIWYG storage-write
# primitive; every other `performEditingTransaction` caller should route
# through it or wrap in a `StorageWriteGuard.performing*` scope.
#
# This list is consulted by the `bypassStorageWrite` pattern below.
PHASE5A_ALLOWED_CALLERS=(
    "FSNotesCore/Rendering/DocumentEditApplier.swift"
)

# --------------------------------------------------------------------------
# Pattern definitions
# --------------------------------------------------------------------------
#
# Each pattern is a (label, regex, scope_glob_or_blank) triple. The scope
# limits the pattern to a subdirectory when that's appropriate (e.g. the
# bidirectional-read pattern is only banned inside table/inline widgets).
#
# Patterns are ERE (extended regex) for compatibility with BSD/GNU grep.

declare -a PATTERN_LABELS=()
declare -a PATTERN_REGEXES=()
declare -a PATTERN_SCOPES=()

add_pattern() {
    PATTERN_LABELS+=("$1")
    PATTERN_REGEXES+=("$2")
    PATTERN_SCOPES+=("$3")
}

# --- Marker-hiding tricks (CLAUDE.md Rule 7 proper) ---
add_pattern "tinyFont"            'systemFont\(ofSize: 0\.[0-9]'                                              ""
add_pattern "zeroFont"            'ofSize: ?0\b[^.]'                                                          ""
add_pattern "clearForeground"     '\.foregroundColor.*NSColor\.clear|NSColor\.clear.*\.foregroundColor'       ""
add_pattern "negativeKern"        'addAttribute\(\.kern'                                                      ""

# --- Widget-local inline reparse (re-implementing InlineRenderer) ---
add_pattern "localInlineParse"    'func[[:space:]]+parseInlineMarkdown\b'                                     ""

# --- Phase 4.7: legacy NoteSerializer.prepareForSave / Note.save(content:) ---
# retired. All saves route through Note.save(markdown:). Any reappearance
# of either token indicates the source-mode save path is being resurrected.
add_pattern "legacySaveContent"   '\.save\(content:|prepareForSave\b'                                          ""

# --- Phase 4.6: legacy TextStorageProcessor.blocks peer + syncBlocksFromProjection ---
# retired. Fold/unfold and gutter-draw now consume `Document.blocks` via the
# `documentProjection` setter's auto-sync. No app-layer caller should invoke
# `syncBlocksFromProjection` directly (it doesn't exist) nor reach into the
# processor's `blocks` array from outside the processor.
add_pattern "legacyBlocksPeer"        '\.syncBlocksFromProjection\b'                                          ""

# --- Phase 4.5: legacy TK1 NSLayoutManager subclass retired ---
# The custom `LayoutManager: NSLayoutManager` subclass (fold-gate drawGlyphs,
# drawBackground attribute drawers, cursorCharIndex gutter cache) was deleted
# with the app flipped to TK2-only. The TK1-safe accessor `layoutManagerIfTK1`
# was removed alongside it — any reappearance indicates the TK1 stack is
# being resurrected outside the explicit block-model / SourceRenderer TK2
# paths. Comments referencing these tokens are filtered by `is_comment_line`.
add_pattern "tk1LayoutManager"        'class[[:space:]]+LayoutManager[[:space:]]*:[[:space:]]*NSLayoutManager|layoutManagerIfTK1' ""

# --- View-to-model bidirectional data flow (read cell state into model) ---
# The InlineTableView.swift / TableRenderController.swift widget files that
# historically held the bidirectional-flow bug were deleted 2026-04-23 in
# Phase 2e T2-h (commit de1f146). Native TableElement has no widget state
# to read back from. Pattern retired, kept commented as a regression anchor
# so any future widget-style table/cell renderer inherits the prohibition:
#   add_pattern "cellReadBack" \
#     'headers\[[^]]*\][[:space:]]*=[[:space:]]*.*\.stringValue|rows\[[^]]*\]\[[^]]*\][[:space:]]*=[[:space:]]*.*\.stringValue' \
#     "FSNotes/Helpers/InlineTableView.swift FSNotes/TableRenderController.swift"

# --- Hardcoded presentation literals in the rendering pipeline ---
# These are the Phase 7.5 "no hardcoded values" invariant. Variable sizes
# are fine: `NSFont.systemFont(ofSize: someVar)` doesn't match.
add_pattern "literalSystemFont"   'NSFont\.systemFont\(ofSize:[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]*[,)]'    "FSNotesCore/Rendering"
add_pattern "literalParaSpacing"  'paragraphSpacing[[:space:]]*=[[:space:]]*[0-9]+(\.[0-9]+)?\b'                "FSNotesCore/Rendering"
# Hex color literals in fragment / element rendering code. Theme schema is
# excluded at the file level. Comments (lines starting with `//` or `///`,
# allowing leading whitespace) are filtered in the scanner below.
add_pattern "hexColorLiteral"     '#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?'                                          "FSNotesCore/Rendering/Fragments FSNotesCore/Rendering/Elements"

# --- Phase 5a: single-write-path enforcement ---
# `NSTextContentStorage.performEditingTransaction` is the TK2 primitive
# that batches character replacements + delegate callbacks. Only
# `DocumentEditApplier.applyDocumentEdit` should call it directly; any
# other call site indicates storage being mutated outside the Phase 3
# element-level edit primitive. Exempt callers are whitelisted via
# `PHASE5A_ALLOWED_CALLERS`.
add_pattern "bypassStorageWrite"  'performEditingTransaction'                                                 ""

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

# Return 0 if $1 is in the excluded list, 1 otherwise.
is_excluded() {
    local file="$1"
    for ex in "${EXCLUDED_FILES[@]}"; do
        if [[ "$file" == "$ex" ]]; then
            return 0
        fi
    done
    return 1
}

# Is $1 a comment line (leading `//` after optional whitespace)?
is_comment_line() {
    local line="$1"
    [[ "$line" =~ ^[[:space:]]*// ]]
}

# Check the line immediately above $file:$lineno for a `rule7-gate:allow`
# escape-hatch tag. Returns 0 (allowed) if present, 1 otherwise.
has_allow_tag() {
    local file="$1"
    local lineno="$2"
    if (( lineno <= 1 )); then
        return 1
    fi
    local prev
    prev="$(sed -n "$((lineno - 1))p" "$file" 2>/dev/null)"
    [[ "$prev" == *"rule7-gate:allow"* ]]
}

# Walk every .swift file in the configured scan dirs, filtered by scope glob.
# If scope is empty, scan all SCAN_DIRS. Otherwise, scope is a space-separated
# list of path prefixes (files OR directories); only files under those prefixes
# match.
list_files_for_scope() {
    local scope="$1"
    if [[ -z "$scope" ]]; then
        for dir in "${SCAN_DIRS[@]}"; do
            find "$dir" -type f -name '*.swift' 2>/dev/null
        done
        return
    fi
    for prefix in $scope; do
        if [[ -f "$prefix" ]]; then
            echo "$prefix"
        elif [[ -d "$prefix" ]]; then
            find "$prefix" -type f -name '*.swift' 2>/dev/null
        fi
    done
}

# --------------------------------------------------------------------------
# Scan
# --------------------------------------------------------------------------

VIOLATIONS=0
SEEN_FILES_LIST=""

# Append $1 to SEEN_FILES_LIST if not already present (bash 3.2 compat — no
# associative arrays).
mark_seen() {
    case ":$SEEN_FILES_LIST:" in
        *":$1:"*) ;;
        *)        SEEN_FILES_LIST="${SEEN_FILES_LIST}:$1" ;;
    esac
}

# Per-pattern file whitelist. Currently only `bypassStorageWrite` uses it:
# the Phase 5a invariant that `performEditingTransaction` lives exclusively
# in `DocumentEditApplier.swift`.
is_pattern_whitelisted() {
    local label="$1"
    local file="$2"
    case "$label" in
        bypassStorageWrite)
            for allowed in "${PHASE5A_ALLOWED_CALLERS[@]}"; do
                if [[ "$file" == "$allowed" ]]; then
                    return 0
                fi
            done
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

for i in "${!PATTERN_LABELS[@]}"; do
    label="${PATTERN_LABELS[$i]}"
    regex="${PATTERN_REGEXES[$i]}"
    scope="${PATTERN_SCOPES[$i]}"

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        if is_excluded "$file"; then
            continue
        fi
        if is_pattern_whitelisted "$label" "$file"; then
            continue
        fi
        mark_seen "$file"

        # grep -nE gives `line:text`. Handle trailing CR from any
        # Windows-lineending strays defensively.
        while IFS=: read -r lineno content; do
            [[ -z "$lineno" ]] && continue
            # Strip CR if present.
            content="${content%$'\r'}"
            # Skip comment lines — documentation can reference banned
            # tokens (hex codes, font sizes) without being a violation.
            if is_comment_line "$content"; then
                continue
            fi
            # Escape-hatch: inline allow tag on the prior line.
            if has_allow_tag "$file" "$lineno"; then
                continue
            fi
            # Trim leading whitespace for the report.
            trimmed="${content#"${content%%[![:space:]]*}"}"
            printf '%s:%s: %s: %s\n' "$file" "$lineno" "$label" "$trimmed"
            VIOLATIONS=$((VIOLATIONS + 1))
        done < <(grep -nE "$regex" "$file" 2>/dev/null || true)
    done < <(list_files_for_scope "$scope")
done

# Count unique seen files by splitting the colon-separated list.
if [[ -z "$SEEN_FILES_LIST" ]]; then
    FILES_SCANNED=0
else
    FILES_SCANNED=$(printf '%s\n' "$SEEN_FILES_LIST" | tr ':' '\n' | grep -c .)
fi

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------

if (( VIOLATIONS == 0 )); then
    printf 'rule7-gate: OK (scanned %d files)\n' "$FILES_SCANNED"
    exit 0
else
    printf 'rule7-gate: FAIL (%d violation(s) across %d files)\n' "$VIOLATIONS" "$FILES_SCANNED" >&2
    exit 1
fi
