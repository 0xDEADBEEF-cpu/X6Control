import Foundation
import IOKit.hid

private let supportedProducts: Set<Int> = [0xfa60, 0xfa61]
private var expectedAck = -1
private var receivedAck = false
private var receivedAckBytes: [UInt8] = []

private func numberProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
    (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
}

private func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
    IOHIDDeviceGetProperty(device, key as CFString) as? String
}

private func jsonLine(_ value: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else {
        print("{\"ok\":false,\"error\":\"Could not encode bridge response\"}")
        return
    }
    print(line)
}

private func devicesForManager(_ manager: IOHIDManager) -> [IOHIDDevice] {
    Array(IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [])
}

private func eligibleDevices(_ manager: IOHIDManager) -> [IOHIDDevice] {
    devicesForManager(manager).filter { device in
        guard let vendor = numberProperty(device, kIOHIDVendorIDKey as String),
              let product = numberProperty(device, kIOHIDProductIDKey as String),
              vendor == 0x1d57,
              supportedProducts.contains(product),
              numberProperty(device, "bInterfaceNumber") == 2 else { return false }
        return (numberProperty(device, kIOHIDMaxFeatureReportSizeKey as String) ?? 0) >= 52
    }
}

private func makeManager() -> IOHIDManager? {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, [
        kIOHIDVendorIDKey as String: 0x1d57,
    ] as CFDictionary)
    guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
        return nil
    }
    return manager
}

private func listDevices() {
    guard let manager = makeManager() else {
        jsonLine(["ok": false, "error": "macOS could not open the USB HID manager"])
        exit(2)
    }
    defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

    let values: [[String: Any]] = eligibleDevices(manager).compactMap { device in
        guard let location = numberProperty(device, "locationID"),
              let vendor = numberProperty(device, kIOHIDVendorIDKey as String),
              let product = numberProperty(device, kIOHIDProductIDKey as String) else { return nil }
        return [
            "locationID": location,
            "vendorID": String(format: "%04x", vendor),
            "productID": String(format: "%04x", product),
            "product": "Attack Shark X6",
            "hardwareProduct": stringProperty(device, kIOHIDProductKey as String) ?? "USB Gaming Mouse",
            "manufacturer": stringProperty(device, kIOHIDManufacturerKey as String) ?? "Attack Shark",
            "serial": stringProperty(device, kIOHIDSerialNumberKey as String) ?? "",
            "interface": 2,
            "maxFeatureReportSize": numberProperty(device, kIOHIDMaxFeatureReportSizeKey as String) ?? 0,
            "transport": product == 0xfa61 ? "USB кабель" : "2.4 ГГц приёмник",
        ]
    }
    jsonLine(["ok": true, "devices": values])
}

private let inputCallback: IOHIDReportCallback = { _, result, _, _, _, report, length in
    guard result == kIOReturnSuccess, length >= 5 else { return }
    let bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
    guard bytes[0] == 0x03, bytes[1] == 0x10, bytes[2] == 0x50,
          Int(bytes[4]) == expectedAck else { return }
    receivedAck = true
    receivedAckBytes = bytes
    CFRunLoopStop(CFRunLoopGetCurrent())
}

private func parseHex(_ value: String) -> [UInt8]? {
    let compact = value.filter { !$0.isWhitespace }
    guard compact.count % 2 == 0 else { return nil }
    var bytes: [UInt8] = []
    var index = compact.startIndex
    while index < compact.endIndex {
        let next = compact.index(index, offsetBy: 2)
        guard let byte = UInt8(compact[index..<next], radix: 16) else { return nil }
        bytes.append(byte)
        index = next
    }
    return bytes
}

private func sendReport(locationID: Int, report: [UInt8]) {
    let requiredLengths: [UInt8: Int] = [0x04: 52, 0x05: 13, 0x06: 9, 0x08: 59]
    guard let reportID = report.first, requiredLengths[reportID] == report.count else {
        jsonLine(["ok": false, "error": "Unsupported X6 report or incorrect report length"])
        exit(3)
    }
    guard let manager = makeManager() else {
        jsonLine(["ok": false, "error": "macOS could not open the USB HID manager"])
        exit(2)
    }
    defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

    let matches = eligibleDevices(manager).filter { numberProperty($0, "locationID") == locationID }
    guard matches.count == 1, let device = matches.first else {
        jsonLine(["ok": false, "error": "Selected X6 configuration interface is unavailable; no report sent"])
        exit(4)
    }
    let maximum = numberProperty(device, kIOHIDMaxFeatureReportSizeKey as String) ?? 0
    guard report.count <= maximum else {
        jsonLine(["ok": false, "error": "The report is larger than the device feature-report limit; no report sent"])
        exit(5)
    }
    let openStatus = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    guard openStatus == kIOReturnSuccess else {
        jsonLine(["ok": false, "error": "Could not open the X6 configuration interface (\(openStatus)); no report sent"])
        exit(6)
    }
    defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

    expectedAck = Int(reportID)
    receivedAck = false
    receivedAckBytes = []
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    var inputBuffer = [UInt8](repeating: 0, count: 64)
    inputBuffer.withUnsafeMutableBufferPointer { pointer in
        guard let base = pointer.baseAddress else { return }
        IOHIDDeviceRegisterInputReportCallback(device, base, CFIndex(pointer.count), inputCallback, nil)
    }

    let sendStatus = report.withUnsafeBufferPointer { pointer -> IOReturn in
        guard let base = pointer.baseAddress else { return kIOReturnBadArgument }
        return IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), base, CFIndex(pointer.count))
    }
    guard sendStatus == kIOReturnSuccess else {
        jsonLine(["ok": false, "sent": false, "error": "macOS rejected the X6 feature report (\(sendStatus))"])
        exit(7)
    }

    _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 1.75, false)
    jsonLine([
        "ok": true,
        "sent": true,
        "acknowledged": receivedAck,
        "reportID": Int(reportID),
        "length": report.count,
        "ack": receivedAckBytes.map { String(format: "%02x", $0) }.joined(separator: " "),
    ])
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "list":
    listDevices()
case "send" where arguments.count == 3:
    guard let location = Int(arguments[1]), let report = parseHex(arguments[2]) else {
        jsonLine(["ok": false, "error": "Invalid location ID or hex report"])
        exit(3)
    }
    sendReport(locationID: location, report: report)
default:
    jsonLine(["ok": false, "error": "Usage: X6Bridge list | send <locationID> <hex-report>"])
    exit(64)
}
