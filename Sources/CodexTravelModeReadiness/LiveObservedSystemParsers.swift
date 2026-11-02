import Foundation

public enum LiveObservedSystemParsers {
    public static func sleepDisabled(_ output: String) throws -> Bool {
        let values = matchingValues(key: "SleepDisabled", output: output)
        guard values.count == 1, values[0] == "0" || values[0] == "1" else {
            throw LiveObservedSystemError.malformedOutput("pmset SleepDisabled is ambiguous")
        }
        return values[0] == "1"
    }

    public static func battery(_ output: String) throws -> LiveObservedBattery {
        let source: LiveObservedPowerSource
        if output.contains("Now drawing from 'Battery Power'") {
            source = .battery
        } else if output.contains("Now drawing from 'AC Power'") {
            source = .ac
        } else {
            throw LiveObservedSystemError.malformedOutput("power source is unavailable")
        }
        let percentages = output
            .split(whereSeparator: \.isWhitespace)
            .compactMap { token -> Int? in
                let stripped = token.trimmingCharacters(in: CharacterSet(charactersIn: ";,"))
                guard stripped.hasSuffix("%") else { return nil }
                return Int(stripped.dropLast())
            }
        guard percentages.count == 1 else {
            throw LiveObservedSystemError.malformedOutput("battery percent is ambiguous")
        }
        return try LiveObservedBattery(source: source, percent: percentages[0])
    }

    public static func lidClosed(_ output: String) throws -> Bool {
        let values = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix(#""AppleClamshellState""#),
                  let separator = text.firstIndex(of: "=") else { return nil }
            return text[text.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
        }
        guard values.count == 1, values[0] == "Yes" || values[0] == "No" else {
            throw LiveObservedSystemError.malformedOutput("clamshell state is ambiguous")
        }
        return values[0] == "Yes"
    }

    public static func wifiPower(_ output: String, device: String) throws -> Bool {
        let line = try singleNonemptyLine(output)
        let prefix = "Wi-Fi Power (\(device)): "
        guard line.hasPrefix(prefix) else {
            throw LiveObservedSystemError.malformedOutput("Wi-Fi power device changed")
        }
        let value = String(line.dropFirst(prefix.count))
        guard value == "On" || value == "Off" else {
            throw LiveObservedSystemError.malformedOutput("Wi-Fi power is ambiguous")
        }
        return value == "On"
    }

    public static func ssid(_ output: String) throws -> String {
        let line = try singleNonemptyLine(output)
        let prefix = "Current Wi-Fi Network: "
        guard line.hasPrefix(prefix) else {
            throw LiveObservedSystemError.malformedOutput("Wi-Fi is not associated")
        }
        let value = String(line.dropFirst(prefix.count))
        guard !value.isEmpty else {
            throw LiveObservedSystemError.malformedOutput("SSID is empty")
        }
        return value
    }

    public static func usableInterfaceAddresses(
        _ output: String,
        device: String
    ) throws -> [LiveObservedIPAddress] {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.first?.hasPrefix("\(device): ") == true,
              !lines.contains(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "status: inactive"
              }) else {
            throw LiveObservedSystemError.malformedOutput("interface is absent or inactive")
        }
        let addresses = try lines.compactMap { line -> LiveObservedIPAddress? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] == "inet" || fields[0] == "inet6" else {
                return nil
            }
            return try LiveObservedIPAddress(String(fields[1]))
        }.filter(\.isUsable)
        guard !addresses.isEmpty else {
            throw LiveObservedSystemError.malformedOutput("interface has no usable address")
        }
        return addresses
    }

    public static func routeDevice(_ output: String) throws -> String {
        let values = matchingValues(key: "interface:", output: output)
        guard values.count == 1, !values[0].isEmpty,
              !values[0].contains(where: \.isWhitespace) else {
            throw LiveObservedSystemError.malformedOutput("route device is ambiguous")
        }
        return values[0]
    }

    public static func processStartIdentity(_ output: String) throws -> String {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else {
            throw LiveObservedSystemError.malformedOutput("process start is ambiguous")
        }
        return value
    }

    public static func platformUUID(_ output: String) throws -> String {
        let prefix = #""IOPlatformUUID" = ""#
        let values = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix(prefix), value.hasSuffix(#"""#) else { return nil }
            return String(value.dropFirst(prefix.count).dropLast())
        }
        guard values.count == 1,
              let uuid = UUID(uuidString: values[0]),
              values[0].lowercased() == uuid.uuidString.lowercased() else {
            throw LiveObservedSystemError.malformedOutput("platform UUID is ambiguous")
        }
        return uuid.uuidString.lowercased()
    }

    public static func hardwareModel(_ output: String) throws -> String {
        let value = try singleNonemptyLine(output)
        guard (1...128).contains(value.utf8.count),
              value.utf8.allSatisfy(isHardwareModelByte) else {
            throw LiveObservedSystemError.malformedOutput("hardware model is invalid")
        }
        return value
    }

    public static func processPIDs(_ output: String) throws -> [Int32] {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard (1...64).contains(lines.count) else {
            throw LiveObservedSystemError.malformedOutput("process PID list is empty or too large")
        }
        let pids = try lines.map { value -> Int32 in
            guard let pid = Int32(value), pid > 0, String(pid) == value else {
                throw LiveObservedSystemError.malformedOutput("process PID is invalid")
            }
            return pid
        }
        guard Set(pids).count == pids.count else {
            throw LiveObservedSystemError.malformedOutput("process PID list contains duplicates")
        }
        return pids
    }

    public static func runningHelperPID(_ output: String, serviceName: String) throws -> Int32 {
        guard output.utf8.count <= 64 * 1_024 else {
            throw LiveObservedSystemError.malformedOutput(
                "helper registration output is too large"
            )
        }
        let lines = output.split(whereSeparator: \.isNewline)
        guard (1...2_048).contains(lines.count),
              lines[0].trimmingCharacters(in: .whitespaces)
                == "system/\(serviceName) = {" else {
            throw LiveObservedSystemError.malformedOutput(
                "helper registration label is invalid"
            )
        }
        let states = assignmentValues(key: "state", output: output)
        let pids = assignmentValues(key: "pid", output: output)
        guard states == ["running"], pids.count == 1,
              let pid = Int32(pids[0]), pid > 0, String(pid) == pids[0] else {
            throw LiveObservedSystemError.malformedOutput(
                "helper is not one exact running service"
            )
        }
        return pid
    }

    private static func matchingValues(key: String, output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[0] == Substring(key) else { return nil }
            return String(fields[1])
        }
    }

    private static func assignmentValues(key: String, output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, fields[0] == Substring(key), fields[1] == "=" else {
                return nil
            }
            return String(fields[2])
        }
    }

    private static func singleNonemptyLine(_ output: String) throws -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count == 1 else {
            throw LiveObservedSystemError.malformedOutput("expected one output line")
        }
        return lines[0]
    }

    private static func isHardwareModelByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte)
            || (97...122).contains(byte)
            || (48...57).contains(byte)
            || [44, 45, 46, 95].contains(byte)
    }
}
