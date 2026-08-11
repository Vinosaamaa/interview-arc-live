#!/usr/bin/env swift

import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("Usage: assemble-icns.swift <input.iconset> <output.icns>\n".utf8)
    )
    exit(64)
}

let inputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: arguments[2])
let chunks: [(type: String, file: String)] = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
]

func bigEndianData(_ value: UInt32) -> Data {
    var encoded = value.bigEndian
    return withUnsafeBytes(of: &encoded) { Data($0) }
}

var body = Data()
for chunk in chunks {
    let fileURL = inputDirectory.appendingPathComponent(chunk.file)
    guard let type = chunk.type.data(using: .ascii),
          type.count == 4,
          let payload = try? Data(contentsOf: fileURL),
          payload.count <= Int(UInt32.max) - 8 else {
        FileHandle.standardError.write(
            Data("Invalid iconset input: \(fileURL.path)\n".utf8)
        )
        exit(66)
    }
    body.append(type)
    body.append(bigEndianData(UInt32(payload.count + 8)))
    body.append(payload)
}

guard body.count <= Int(UInt32.max) - 8 else {
    FileHandle.standardError.write(Data("Iconset is too large.\n".utf8))
    exit(65)
}

var output = Data("icns".utf8)
output.append(bigEndianData(UInt32(body.count + 8)))
output.append(body)
try output.write(to: outputURL, options: .atomic)
