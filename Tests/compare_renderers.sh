#!/bin/bash
# Visual comparison: MPreview (WebKit) vs NSTextView WYSIWYG rendering
#
# Usage: ./Tests/compare_renderers.sh [note_name]
# Default: "10. Markdown formatting"
#
# This script:
# 1. Reads a note's markdown via FSNotes MCP (or a file)
# 2. Renders it through MPreview's CSS in a local HTML page
# 3. Opens both the HTML page and FSNotes side-by-side for visual comparison
# 4. Optionally captures screenshots for automated diffing
#
# Prerequisites:
# - cmark-gfm installed (brew install cmark-gfm)
# - MPreview.bundle in Resources/

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE="$PROJECT_DIR/Resources/MPreview.bundle"
OUTPUT_DIR="/tmp/fsnotes_renderer_compare"
NOTE_NAME="${1:-10. Markdown formatting}"

mkdir -p "$OUTPUT_DIR"

# Check dependencies
if ! command -v cmark-gfm &>/dev/null; then
    echo "Error: cmark-gfm not found. Install with: brew install cmark-gfm"
    exit 1
fi

if [ ! -d "$BUNDLE" ]; then
    echo "Error: MPreview.bundle not found at $BUNDLE"
    exit 1
fi

echo "=== FSNotes Renderer Comparison ==="
echo "Note: $NOTE_NAME"
echo ""

# Copy MPreview bundle to output dir for serving
cp -R "$BUNDLE" "$OUTPUT_DIR/MPreview.bundle" 2>/dev/null || true

# Find the note file
NOTE_FILE=""
# Search common locations
for dir in \
    ~/Library/Containers/co.fluder.FSNotes/Data/Documents \
    ~/Library/Group\ Containers/co.fluder.FSNotes/Documents \
    ~/Documents/FSNotes \
    ~/iCloud~co~fluder~FSNotes/Documents; do
    if [ -d "$dir" ]; then
        found=$(find "$dir" -name "text.md" -path "*${NOTE_NAME}*" 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            NOTE_FILE="$found"
            break
        fi
        # Also check .md files directly
        found=$(find "$dir" -name "${NOTE_NAME}.md" 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            NOTE_FILE="$found"
            break
        fi
    fi
done

if [ -z "$NOTE_FILE" ]; then
    echo "Note file not found on disk. Using embedded test content."
    # Fallback: use a comprehensive test markdown
    cat > "$OUTPUT_DIR/test_note.md" << 'MARKDOWN'
# Test Note: Renderer Comparison

This tests all markdown elements for visual parity.

## Headers

### Third level header

#### Fourth level header

## Horizontal Rules

---

***

## Text Formatting

This is **bold text** and *italic text* and ***bold italic***.

This is ~~strikethrough~~ and <u>underlined</u> text.

## Blockquotes

> A single blockquote paragraph
> that spans multiple lines.

> Level one
>> Level two
>>> Level three

## Lists

- Bullet one
- Bullet two
  - Nested bullet
- Bullet three

1. Numbered one
2. Numbered two
   - Mixed nesting
3. Numbered three

- [ ] Todo item unchecked
- [x] Todo item checked

## Links

[FSNotes](https://fsnot.es)

https://github.com/glushchenko/fsnotes

## Code

Inline `code` in a sentence.

```python
def hello():
    print("Hello, World!")
    return 42
```

```mermaid
graph TD
    A --> B
    B --> C
```

## Tables

| Left | Center | Right |
|:-----|:------:|------:|
| L1   | C1     | R1    |
| L2   | C2     | R2    |

## Inline HTML

<kbd>Cmd</kbd> + <kbd>Shift</kbd> + <kbd>P</kbd>

<mark>Highlighted text</mark>

## Emoji

Native emoji: 🚀 ✅ ⚠️
MARKDOWN
    NOTE_FILE="$OUTPUT_DIR/test_note.md"
fi

echo "Source: $NOTE_FILE"

# Convert markdown to HTML
HTML_CONTENT=$(cmark-gfm --extension table --extension strikethrough --extension autolink --extension tasklist --unsafe < "$NOTE_FILE")

# Generate the MPreview comparison HTML
cat > "$OUTPUT_DIR/mpreview_render.html" << HTMLEOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="initial-scale=1.0" />
    <title>MPreview Rendering — $NOTE_NAME</title>
    <link href="MPreview.bundle/main.css?v=1.0.7" rel="stylesheet">
    <link href="MPreview.bundle/styles/github-light.min.css" rel="stylesheet">
    <style>
        code { white-space: pre-wrap !important; overflow-x: hidden; }
        pre { overflow-x: hidden; }
        body { padding: 15px 20px; max-width: 800px; font-size: 14px; }
        .comparison-header {
            position: fixed; top: 0; left: 0; right: 0;
            background: #f0f0f0; padding: 8px 20px; border-bottom: 1px solid #ccc;
            font-family: -apple-system, sans-serif; font-size: 12px; color: #666;
            z-index: 1000;
        }
        .content { margin-top: 40px; }
    </style>
</head>
<body>
    <div class="comparison-header">
        MPreview (WebKit HTML/CSS) — Reference Rendering
    </div>
    <div class="content">
$HTML_CONTENT
    </div>
</body>
</html>
HTMLEOF

echo "Generated: $OUTPUT_DIR/mpreview_render.html"

# Kill any existing server on port 8899
lsof -ti:8899 2>/dev/null | xargs kill -9 2>/dev/null || true
sleep 0.5

# Start a local server
cd "$OUTPUT_DIR"
python3 -m http.server 8899 &>/dev/null &
SERVER_PID=$!
sleep 1

echo ""
echo "=== Comparison Ready ==="
echo ""
echo "MPreview (reference): http://127.0.0.1:8899/mpreview_render.html"
echo "NSTextView (actual):  Open FSNotes app and navigate to '$NOTE_NAME'"
echo ""
echo "Place them side-by-side to compare."
echo ""
echo "Server PID: $SERVER_PID (kill with: kill $SERVER_PID)"
echo ""

# Open the MPreview rendering in default browser
open "http://127.0.0.1:8899/mpreview_render.html"

echo "Press Ctrl+C to stop the server."
wait $SERVER_PID 2>/dev/null
