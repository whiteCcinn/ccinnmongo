/// Allocation-light ISO-8601 parsing/formatting for BSON datetimes using proleptic Gregorian
/// calendar arithmetic (Howard Hinnant's civil-days algorithms). Thread-safe and much faster
/// than `DateFormatter`, and it supports the full year range 0000-9999.
public enum ISO8601 {
    public enum MillisecondsStyle: Sendable {
        case always
        case whenNonZero
    }

    /// Formats milliseconds since the epoch as `YYYY-MM-DDTHH:MM:SS(.mmm)Z`; returns `nil` outside years 0-9999.
    public static func format(milliseconds: Int64, style: MillisecondsStyle = .always) -> String? {
        guard milliseconds >= minimumMilliseconds, milliseconds <= maximumMilliseconds else { return nil }
        let (days, msOfDay) = floorDivide(milliseconds, 86_400_000)
        let (year, month, day) = civil(fromDays: days)
        let hour = msOfDay / 3_600_000
        let minute = msOfDay / 60_000 % 60
        let second = msOfDay / 1000 % 60
        let millis = msOfDay % 1000

        var out = pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2)
        out += "T" + pad(hour, 2) + ":" + pad(minute, 2) + ":" + pad(second, 2)
        if style == .always || millis != 0 {
            out += "." + pad(millis, 3)
        }
        return out + "Z"
    }

    /// Parses `YYYY-MM-DD[(T| )HH:MM[:SS[.fff]]][Z|±HH[:MM]]`. Missing zone means UTC.
    public static func parse(_ string: String) -> Int64? {
        let chars = Array(string.utf8)
        var index = 0

        func number(_ digits: Int) -> Int? {
            guard index + digits <= chars.count else { return nil }
            var value = 0
            for offset in 0..<digits {
                let c = chars[index + offset]
                guard c >= 0x30, c <= 0x39 else { return nil }
                value = value * 10 + Int(c - 0x30)
            }
            index += digits
            return value
        }

        func expect(_ char: UInt8) -> Bool {
            guard index < chars.count, chars[index] == char else { return false }
            index += 1
            return true
        }

        guard let year = number(4), expect(0x2D), let month = number(2), expect(0x2D), let day = number(2) else { return nil }
        guard (1...12).contains(month), day >= 1, day <= daysInMonth(year: year, month: month) else { return nil }

        var hour = 0, minute = 0, second = 0, millis = 0
        var offsetMinutes = 0

        if index < chars.count, chars[index] == 0x54 || chars[index] == 0x74 || chars[index] == 0x20 {
            index += 1
            guard let h = number(2), expect(0x3A), let m = number(2) else { return nil }
            hour = h
            minute = m
            if index < chars.count, chars[index] == 0x3A {
                index += 1
                guard let s = number(2) else { return nil }
                second = s
                if index < chars.count, chars[index] == 0x2E {
                    index += 1
                    var digits = 0
                    var fraction = 0
                    while index < chars.count, chars[index] >= 0x30, chars[index] <= 0x39 {
                        if digits < 3 { fraction = fraction * 10 + Int(chars[index] - 0x30) }
                        digits += 1
                        index += 1
                    }
                    guard digits > 0 else { return nil }
                    var scale = digits
                    while scale < 3 {
                        fraction *= 10
                        scale += 1
                    }
                    millis = fraction
                }
            }
            guard hour < 24, minute < 60, second < 60 else { return nil }

            if index < chars.count {
                let sign = chars[index]
                if sign == 0x5A || sign == 0x7A {
                    index += 1
                } else if sign == 0x2B || sign == 0x2D {
                    index += 1
                    guard let oh = number(2) else { return nil }
                    var om = 0
                    if index < chars.count {
                        _ = expect(0x3A)
                        guard let parsed = number(2) else { return nil }
                        om = parsed
                    }
                    guard oh < 24, om < 60 else { return nil }
                    offsetMinutes = (oh * 60 + om) * (sign == 0x2D ? -1 : 1)
                } else {
                    return nil
                }
            }
        }
        guard index == chars.count else { return nil }

        let days = Int64(daysFromCivil(year: year, month: month, day: day))
        let msOfDay = Int64(((hour * 60 + minute) * 60 + second) * 1000 + millis)
        return days * 86_400_000 + msOfDay - Int64(offsetMinutes) * 60_000
    }

    // MARK: Calendar arithmetic

    static let minimumMilliseconds: Int64 = -62_167_219_200_000 // 0000-01-01T00:00:00Z
    static let maximumMilliseconds: Int64 = 253_402_300_799_999 // 9999-12-31T23:59:59.999Z

    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(fromDays days: Int64) -> (year: Int, month: Int, day: Int) {
        let z = Int(days) + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    static func floorDivide(_ value: Int64, _ divisor: Int64) -> (Int64, Int) {
        var quotient = value / divisor
        var remainder = value % divisor
        if remainder < 0 {
            quotient -= 1
            remainder += divisor
        }
        return (quotient, Int(remainder))
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}
