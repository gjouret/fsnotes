#!/bin/bash
# Visual Renderer Comparison Test
# Compares MPreview (WKWebView HTML) vs NSTextView (WYSIWYG) rendering
#
# Usage: ./Tests/run_comparison.sh [note-title]
# Output: /tmp/fsnotes_compare/{mpreview.png, nstextview.png, diff.png}

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="/tmp/fsnotes_compare"
APP_PATH="$HOME/Applications/FSNotes.app"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

echo "=== FSNotes Renderer Comparison Test ==="
echo ""

# Step 1: Build
echo "Step 1: Building FSNotes..."
cd "$PROJECT_DIR"
xcodebuild build -workspace FSNotes.xcworkspace -scheme FSNotes -configuration Debug -destination 'platform=macOS' 2>&1 | tail -1

# Step 2: Deploy
echo "Step 2: Deploying..."
osascript -e 'tell application "FSNotes" to quit' 2>/dev/null || true
sleep 1
rm -rf "$APP_PATH"
DERIVED=$(ls -d ~/Library/Developer/Xcode/DerivedData/FSNotes-*/Build/Products/Debug/FSNotes.app 2>/dev/null | head -1)
if [ -z "$DERIVED" ]; then
    echo "ERROR: Build product not found"
    exit 1
fi
cp -R "$DERIVED" "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH" 2>/dev/null

# Step 3: Run in comparison mode
echo "Step 3: Running render comparison..."
"$APP_PATH/Contents/MacOS/FSNotes" --render-comparison &
APP_PID=$!

# Wait for it to finish (max 30 seconds)
for i in $(seq 1 30); do
    if ! kill -0 $APP_PID 2>/dev/null; then
        break
    fi
    sleep 1
done

# Kill if still running
kill $APP_PID 2>/dev/null || true

# Step 4: Check results
echo ""
echo "=== Results ==="
if [ -f "$OUTPUT_DIR/nstextview.png" ] && [ -f "$OUTPUT_DIR/mpreview.png" ]; then
    echo "NSTextView:  $OUTPUT_DIR/nstextview.png"
    echo "MPreview:    $OUTPUT_DIR/mpreview.png"

    if [ -f "$OUTPUT_DIR/diff.png" ]; then
        echo "Diff:        $OUTPUT_DIR/diff.png"
        echo ""
        # Extract the comparison result from system log
        log show --last 1m 2>/dev/null | grep "RenderComparison.*Pixel" | tail -1
        log show --last 1m 2>/dev/null | grep "RenderComparison.*Threshold" | tail -1
    fi

    echo ""
    echo "Opening comparison images..."
    open "$OUTPUT_DIR/nstextview.png" "$OUTPUT_DIR/mpreview.png" "$OUTPUT_DIR/diff.png" 2>/dev/null
else
    echo "ERROR: Rendering failed. Check if FSNotes has a note selected."
    ls -la "$OUTPUT_DIR/" 2>/dev/null
fi
