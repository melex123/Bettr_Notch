#!/bin/bash
set -euo pipefail

OUTPUT_ICNS="${1:?Usage: create-icns.sh <output.icns>}"

TMPDIR_BASE=$(mktemp -d)
ICONSET_DIR="$TMPDIR_BASE/AppIcon.iconset"
SWIFT_SRC="$TMPDIR_BASE/gen_icon.swift"

mkdir -p "$ICONSET_DIR"

# Write a Swift program that generates icon PNGs using AppKit
cat > "$SWIFT_SRC" << 'SWIFT_EOF'
import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    print("Usage: gen_icon <iconset_dir>")
    exit(1)
}
let iconsetDir = args[1]

let baseSize = NSSize(width: 1024, height: 1024)
let image = NSImage(size: baseSize, flipped: false) { rect in
    // Dark purple gradient background
    let gradient = NSGradient(colors: [
        NSColor(red: 0.35, green: 0.15, blue: 0.65, alpha: 1.0),
        NSColor(red: 0.20, green: 0.08, blue: 0.45, alpha: 1.0)
    ])!
    let inset = rect.insetBy(dx: 40, dy: 40)
    let path = NSBezierPath(roundedRect: inset, xRadius: 220, yRadius: 220)
    gradient.draw(in: path, angle: -45)

    // "NN" text
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 420, weight: .bold),
        .foregroundColor: NSColor.white
    ]
    let str = NSAttributedString(string: "NN", attributes: attrs)
    let strSize = str.size()
    str.draw(at: NSPoint(
        x: (1024 - strSize.width) / 2,
        y: (1024 - strSize.height) / 2 + 20
    ))
    return true
}

let sizes: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (px, name) in sizes {
    let sz = NSSize(width: px, height: px)
    let resized = NSImage(size: sz)
    resized.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: sz),
               from: NSRect(origin: .zero, size: baseSize),
               operation: .sourceOver, fraction: 1.0)
    resized.unlockFocus()

    guard let tiff = resized.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("Failed to render \(name)")
        exit(1)
    }
    let url = URL(fileURLWithPath: iconsetDir).appendingPathComponent(name)
    try! png.write(to: url)
}

print("Generated \(sizes.count) icon sizes")
SWIFT_EOF

# Compile and run the Swift icon generator
echo "Generating icon set..."
swiftc -o "$TMPDIR_BASE/gen_icon" "$SWIFT_SRC" -framework AppKit
"$TMPDIR_BASE/gen_icon" "$ICONSET_DIR"

# Convert iconset to icns
echo "Converting to .icns..."
iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"

# Cleanup
rm -rf "$TMPDIR_BASE"

echo "Icon created: $OUTPUT_ICNS"
