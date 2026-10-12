// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Darwin
import Foundation
import TextImport

/// Reads a command's input file and imports it as text: encoding and BOM
/// detection, document conversion and binary classification (see
/// `TextImport`). Bytes are read by `FileInput`, so pipes, process
/// substitution and `-` keep working and errors keep their wording.
enum TextInput {

    /// The imported contents of `path`. `.missing` and `.directory` never
    /// come back: those are `FileInput` errors. An RTFD package (a folder)
    /// is the one directory that is imported.
    static func read(_ path: String, standardInput: Int32 = STDIN_FILENO) throws(FileInput.Failure) -> ImportedText {
        let name = path == FileInput.standardInputName ? nil : (path as NSString).lastPathComponent
        if let name, (name as NSString).pathExtension.lowercased() == "rtfd", isDirectory(path) {
            do {
                return try TextImport.load(URL(filePath: path))
            } catch {
                throw FileInput.Failure(path: path, message: error.message)
            }
        }
        let bytes = try FileInput.read(path, standardInput: standardInput)
        do {
            return try TextImport.decode(bytes, fileName: name, path: path)
        } catch {
            throw FileInput.Failure(path: path, message: error.message)
        }
    }

    /// The message for an input that is not text, to follow "<path>: ".
    static let binaryMessage = "binary file; only text files can be compared"

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
