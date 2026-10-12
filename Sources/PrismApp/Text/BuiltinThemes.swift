// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

/// The four built-in themes, written in the same JSON format that theme
/// files use. Colours were picked for Prism: green for lines added in B,
/// red for lines removed from A, violet for changed lines, or a single blue
/// family for every kind.
enum BuiltinThemes {
    static let all: [Theme] = [multicolorLight, multicolorDark, singleLight, singleDark]

    static let multicolorLight = load(#"""
    {
      "id": "multicolor-light", "name": "Multicolored Light", "dark": false,
      "background": "#FFFFFF", "text": "#232328", "equalText": "#55555C",
      "invisible": "#0000002E", "spacer": "#F6F6F7",
      "gutterBackground": "#FFFFFF", "lineNumber": "#8E8E93", "gutterBorder": "#E4E4E7",
      "divider": "#D1D1D6",
      "insert": { "band": "#E2F7DF", "border": "#5DBF57", "word": "#B5E8AE", "gutter": "#D3F1CE",
                  "selectedBand": "#C2ECBC", "selectedWord": "#8FD886", "selectedGutter": "#4FAE48",
                  "selectedNumber": "#FFFFFF" },
      "delete": { "band": "#FDEBEB", "border": "#DE7272", "word": "#F6C3C3", "gutter": "#F9DADA",
                  "selectedBand": "#F6D0D0", "selectedWord": "#EBA0A0", "selectedGutter": "#CC5050",
                  "selectedNumber": "#FFFFFF" },
      "change": { "band": "#EEE7FD", "border": "#9C86DB", "word": "#D2C1FA", "gutter": "#E4DAFB",
                  "selectedBand": "#D7CBF7", "selectedWord": "#B59CF0", "selectedGutter": "#8C74D2",
                  "selectedNumber": "#FFFFFF" }
    }
    """#)

    static let multicolorDark = load(#"""
    {
      "id": "multicolor-dark", "name": "Multicolored Dark", "dark": true,
      "background": "#17171A", "text": "#E6E6E9", "equalText": "#93939A",
      "invisible": "#FFFFFF33", "spacer": "#0E0E10",
      "gutterBackground": "#17171A", "lineNumber": "#FFFFFF4D", "gutterBorder": "#FFFFFF1F",
      "divider": "#FFFFFF2B",
      "insert": { "band": "#10301A", "border": "#2F7A3C", "word": "#1F5A2C", "gutter": "#143A20",
                  "selectedBand": "#1E4F2A", "selectedWord": "#2C7A3E", "selectedGutter": "#3E9A50",
                  "selectedNumber": "#FFFFFF" },
      "delete": { "band": "#3A1414", "border": "#8A3434", "word": "#6A2424", "gutter": "#451818",
                  "selectedBand": "#5A1E1E", "selectedWord": "#8A3030", "selectedGutter": "#B04545",
                  "selectedNumber": "#FFFFFF" },
      "change": { "band": "#251C3B", "border": "#5E4A9A", "word": "#46367A", "gutter": "#2D2348",
                  "selectedBand": "#3A2D62", "selectedWord": "#5A46A0", "selectedGutter": "#7560C8",
                  "selectedNumber": "#FFFFFF" }
    }
    """#)

    static let singleLight = load(#"""
    {
      "id": "single-light", "name": "Single Color Light", "dark": false,
      "background": "#FFFFFF", "text": "#232328", "equalText": "#55555C",
      "invisible": "#0000002E", "spacer": "#F6F6F7",
      "gutterBackground": "#FFFFFF", "lineNumber": "#8E8E93", "gutterBorder": "#E4E4E7",
      "divider": "#D1D1D6",
      "insert": { "band": "#E4F0FA", "border": "#A9CBE6", "word": "#B8D9F2", "gutter": "#D8E9F7",
                  "selectedBand": "#C9E1F5", "selectedWord": "#92C3EB", "selectedGutter": "#4F95CF",
                  "selectedNumber": "#FFFFFF" },
      "delete": { "band": "#E4F0FA", "border": "#A9CBE6", "word": "#B8D9F2", "gutter": "#D8E9F7",
                  "selectedBand": "#C9E1F5", "selectedWord": "#92C3EB", "selectedGutter": "#4F95CF",
                  "selectedNumber": "#FFFFFF" },
      "change": { "band": "#E4F0FA", "border": "#A9CBE6", "word": "#B8D9F2", "gutter": "#D8E9F7",
                  "selectedBand": "#C9E1F5", "selectedWord": "#92C3EB", "selectedGutter": "#4F95CF",
                  "selectedNumber": "#FFFFFF" }
    }
    """#)

    static let singleDark = load(#"""
    {
      "id": "single-dark", "name": "Single Color Dark", "dark": true,
      "background": "#17171A", "text": "#E6E6E9", "equalText": "#93939A",
      "invisible": "#FFFFFF33", "spacer": "#0E0E10",
      "gutterBackground": "#17171A", "lineNumber": "#FFFFFF4D", "gutterBorder": "#FFFFFF1F",
      "divider": "#FFFFFF2B",
      "insert": { "band": "#0D2533", "border": "#24506A", "word": "#174563", "gutter": "#113040",
                  "selectedBand": "#133D57", "selectedWord": "#1F6290", "selectedGutter": "#2E7DB5",
                  "selectedNumber": "#FFFFFF" },
      "delete": { "band": "#0D2533", "border": "#24506A", "word": "#174563", "gutter": "#113040",
                  "selectedBand": "#133D57", "selectedWord": "#1F6290", "selectedGutter": "#2E7DB5",
                  "selectedNumber": "#FFFFFF" },
      "change": { "band": "#0D2533", "border": "#24506A", "word": "#174563", "gutter": "#113040",
                  "selectedBand": "#133D57", "selectedWord": "#1F6290", "selectedGutter": "#2E7DB5",
                  "selectedNumber": "#FFFFFF" }
    }
    """#)

    private static func load(_ json: String) -> Theme {
        do {
            return try Theme.decode(json)
        } catch {
            preconditionFailure("built-in theme does not decode: \(error)")
        }
    }
}
