import Foundation

// Every byte figure in the UI goes through here so the mono column actually aligns: one decimal
// place, a space before the unit, MB not MiB (Finder's convention — the user compares against it).
enum Bytes {
    static func format(_ count: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, count))
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        // Whole bytes have no meaningful decimal; everything else gets exactly one.
        if index == 0 { return "\(Int64(value)) B" }
        return String(format: "%.1f %@", value, units[index])
    }

    /// `138.6 MB → 73.5 MB`. The arrow is U+2192 with hair spaces so it does not crowd the numbers.
    static func pair(from before: Int64, to after: Int64) -> String {
        "\(format(before)) → \(format(after))"
    }

    /// Percentage saved, rounded to whole. Negative (the file grew) returns nil — a growth is not
    /// a saving and must not render in the accent pill.
    static func savings(from before: Int64, to after: Int64) -> Int? {
        guard before > 0, after < before else { return nil }
        return Int((Double(before - after) / Double(before) * 100).rounded())
    }

    static func selfCheck() {
        assert(format(0) == "0 B")
        assert(format(999) == "999 B")
        assert(format(1000) == "1.0 KB")
        assert(format(145_300_000) == "145.3 MB")
        assert(format(-5) == "0 B", "negative sizes clamp rather than print a minus")
        assert(pair(from: 138_600_000, to: 73_500_000) == "138.6 MB → 73.5 MB")

        assert(savings(from: 100, to: 47) == 53)
        assert(savings(from: 145_300_000, to: 73_800_000) == 49)
        // The zip-got-bigger case: 145.3 MB → 146.7 MB is not a saving.
        assert(savings(from: 145_300_000, to: 146_700_000) == nil)
        assert(savings(from: 100, to: 100) == nil, "unchanged is not a saving")
        assert(savings(from: 0, to: 0) == nil)
    }
}
