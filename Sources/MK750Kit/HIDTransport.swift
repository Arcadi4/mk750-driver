import Foundation
import IOKit
import IOKit.hid

/// Byte transport for the 64-byte vendor feature reports.
///
/// The protocol layer above this protocol only ever deals in the exact 64-byte
/// payload: opcode at index 0 and no leading report-ID byte. The real IOKit
/// implementation passes report ID 0 separately, which is what an unnumbered
/// feature report needs. Internal so the only public command path is `Keyboard`.
protocol MK750Transport: AnyObject {
  /// Enumerates and opens the vendor collection. Called once per connect.
  func open() throws
  /// Closes the current handle. Safe to call repeatedly.
  func close()
  /// Sends exactly 64 protocol bytes as a feature report with report ID 0.
  func send(_ report: [UInt8]) throws
  /// Reads exactly 64 protocol bytes from the feature report with report ID 0.
  func receive() throws -> [UInt8]
}

/// Real macOS transport: IOKit HID, synchronous feature reports, no seizing.
///
/// Internal by design: the only public way to drive the device is `Keyboard`,
/// whose allowlist builds every packet. Tests inject their own `MK750Transport`.
final class IOKitHIDTransport: MK750Transport {
  private var manager: IOHIDManager?
  private var device: IOHIDDevice?

  init() {}

  deinit {
    close()
  }

  func open() throws {
    close()

    let created = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    let matching: [String: Any] = [
      kIOHIDVendorIDKey: Protocol.vendorID,
      kIOHIDProductIDKey: Protocol.productID,
      kIOHIDDeviceUsagePageKey: Protocol.vendorUsagePage,
      kIOHIDDeviceUsageKey: Protocol.vendorUsage,
    ]
    IOHIDManagerSetDeviceMatching(created, matching as CFDictionary)
    let managerResult = IOHIDManagerOpen(created, 0)
    guard managerResult == kIOReturnSuccess else {
      throw MK750Error.transport(
        "could not open the HID manager (IOReturn 0x\(String(managerResult, radix: 16)))"
      )
    }

    guard let rawDevices = IOHIDManagerCopyDevices(created) else {
      IOHIDManagerClose(created, 0)
      throw MK750Error.deviceNotFound
    }
    var rawValues = [UnsafeRawPointer?](repeating: nil, count: CFSetGetCount(rawDevices))
    CFSetGetValues(rawDevices, &rawValues)
    let devices = rawValues.compactMap { raw -> IOHIDDevice? in
      guard let raw else { return nil }
      let value = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
      guard CFGetTypeID(value) == IOHIDDeviceGetTypeID() else { return nil }
      return Unmanaged<IOHIDDevice>.fromOpaque(raw).takeUnretainedValue()
    }
    guard !devices.isEmpty else {
      IOHIDManagerClose(created, 0)
      throw MK750Error.deviceNotFound
    }

    var lastOpenResult: IOReturn = kIOReturnSuccess
    for candidate in devices where deviceMatches(candidate) {
      let result = IOHIDDeviceOpen(candidate, 0)
      if result == kIOReturnSuccess {
        manager = created
        device = candidate
        return
      }
      lastOpenResult = result
    }

    IOHIDManagerClose(created, 0)
    if lastOpenResult != kIOReturnSuccess {
      throw MK750Error.transport(
        "could not open the vendor collection (IOReturn 0x\(String(lastOpenResult, radix: 16)))"
      )
    }
    throw MK750Error.identityFailed(
      "VID 0x3151 / PID 0x4015 is present, but no 0xFFFF:2 collection on "
        + "interface 2 with a 64-byte feature report could be verified"
    )
  }

  func close() {
    if let device {
      IOHIDDeviceClose(device, 0)
      self.device = nil
    }
    if let manager {
      IOHIDManagerClose(manager, 0)
      self.manager = nil
    }
  }

  func send(_ report: [UInt8]) throws {
    guard let device else {
      throw MK750Error.notConnected
    }
    guard report.count == Protocol.reportLength else {
      throw MK750Error.invalidArgument(
        "feature report must be \(Protocol.reportLength) bytes, got \(report.count)"
      )
    }

    let result: IOReturn = report.withUnsafeBufferPointer { buffer in
      IOHIDDeviceSetReport(
        device,
        kIOHIDReportTypeFeature,
        0,
        buffer.baseAddress!,
        CFIndex(report.count)
      )
    }
    guard result == kIOReturnSuccess else {
      throw MK750Error.transport(
        "feature report send failed (IOReturn 0x\(String(result, radix: 16)))"
      )
    }
  }

  func receive() throws -> [UInt8] {
    guard let device else {
      throw MK750Error.notConnected
    }

    var buffer = [UInt8](repeating: 0, count: Protocol.reportLength)
    var length = CFIndex(buffer.count)
    let result: IOReturn = buffer.withUnsafeMutableBufferPointer { pointer in
      IOHIDDeviceGetReport(
        device,
        kIOHIDReportTypeFeature,
        0,
        pointer.baseAddress!,
        &length
      )
    }
    guard result == kIOReturnSuccess else {
      throw MK750Error.transport(
        "feature report read failed (IOReturn 0x\(String(result, radix: 16)))"
      )
    }
    guard length == CFIndex(Protocol.reportLength) else {
      throw MK750Error.transport(
        "feature report read returned \(length) bytes, expected \(Protocol.reportLength)"
      )
    }
    return buffer
  }

  // MARK: - Enumeration checks

  private func deviceMatches(_ device: IOHIDDevice) -> Bool {
    guard intProperty(device, kIOHIDVendorIDKey) == Protocol.vendorID else { return false }
    guard intProperty(device, kIOHIDProductIDKey) == Protocol.productID else { return false }
    guard intProperty(device, kIOHIDPrimaryUsagePageKey) == Protocol.vendorUsagePage else {
      return false
    }
    guard intProperty(device, kIOHIDPrimaryUsageKey) == Protocol.vendorUsage else {
      return false
    }
    if let featureSize = intProperty(device, kIOHIDMaxFeatureReportSizeKey),
      featureSize != Protocol.featureReportSize
    {
      return false
    }
    // The descriptor check below is authoritative for 64-byte feature
    // reports; the property is an additional fast rejection when present.
    guard reportDescriptorIsVendorCollection(device) else { return false }
    // Fail closed when the interface number cannot be established. The
    // vendor collection lives on interface 2; another interface with the
    // same usage pair is not a command path.
    guard interfaceNumber(device) == Protocol.vendorInterface else { return false }
    return true
  }

  private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
    guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
    return (value as? NSNumber)?.intValue
  }

  private func reportDescriptorIsVendorCollection(_ device: IOHIDDevice) -> Bool {
    guard let property = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString)
    else {
      return false
    }
    let data: Data?
    if let bridged = property as? Data {
      data = bridged
    } else if let bridged = property as? NSData {
      data = Data(referencing: bridged)
    } else {
      data = nil
    }
    guard let descriptor = data else { return false }
    return ReportDescriptorVerifier.isMK750VendorCollection(descriptor)
  }

  /// The USB interface node carries `InterfaceNumber`; also search the
  /// parent chain for `bInterfaceNumber` because the IOHIDDevice itself does
  /// not always expose it.
  private func interfaceNumber(_ device: IOHIDDevice) -> Int? {
    // IOKit exposes the USB interface number on the HID device entry on
    // current macOS releases; fall back to the registry parent chain.
    if let direct = intProperty(device, "InterfaceNumber") {
      return direct
    }

    let service = IOHIDDeviceGetService(device)
    guard service != 0 else { return nil }

    for key in ["bInterfaceNumber", "InterfaceNumber", "interface-number"] {
      let value: CFTypeRef? = "IOService".withCString { plane in
        IORegistryEntrySearchCFProperty(
          service,
          plane,
          key as CFString,
          kCFAllocatorDefault,
          IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
      }
      guard let value else { continue }
      if let number = value as? NSNumber {
        return number.intValue
      }
      if let data = value as? Data, data.count == 1 {
        return Int(data[data.startIndex])
      }
      if let data = value as? NSData, data.length == 1 {
        var byte: UInt8 = 0
        data.getBytes(&byte, length: 1)
        return Int(byte)
      }
    }
    return nil
  }
}

/// Minimal HID report-descriptor reader for the vendor feature collection.
///
/// The MK750 descriptor is:
/// `06 FF FF 09 02 A1 01 09 02 15 80 25 7F 95 40 75 08 B1 02 C0`.
/// Instead of matching that byte string, require the semantic shape: usage
/// page 0xFFFF, usage 2, report count 64, report size 8, a Feature main item,
/// and no Report ID item. A report ID would change the wire report ID from 0.
enum ReportDescriptorVerifier {
  static func isMK750VendorCollection(_ descriptor: Data) -> Bool {
    let bytes = [UInt8](descriptor)
    var index = 0
    var usagePage: UInt32 = 0
    var reportSize = 0
    var reportCount = 0
    var sawReportID = false
    var localUsages: [UInt32] = []
    var foundVendorFeature = false

    while index < bytes.count {
      let prefix = bytes[index]
      index += 1

      if prefix == 0xFE {
        // Long item: 0xFE, data size, long-item tag, then data.
        guard index + 2 <= bytes.count else { return false }
        let size = Int(bytes[index])
        index += 2
        guard index + size <= bytes.count else { return false }
        index += size
        continue
      }

      let sizeCode = Int(prefix & 0x03)
      let type = (prefix >> 2) & 0x03
      let tag = prefix >> 4
      let length = sizeCode == 3 ? 4 : sizeCode
      guard index + length <= bytes.count else { return false }

      var value: UInt32 = 0
      for offset in 0..<length {
        value |= UInt32(bytes[index + offset]) << (8 * offset)
      }
      index += length

      switch type {
      case 1:  // Global item
        switch tag {
        case 0: usagePage = value
        case 7: reportSize = Int(value)
        case 8: sawReportID = true
        case 9: reportCount = Int(value)
        default: break
        }

      case 2:  // Local item
        if tag == 0 {
          localUsages.append(value)
        }

      case 0:  // Main item
        if tag == 0xB {  // Feature
          if usagePage == UInt32(Protocol.vendorUsagePage),
            localUsages.contains(UInt32(Protocol.vendorUsage)),
            reportSize == 8,
            reportCount == Protocol.featureReportSize
          {
            foundVendorFeature = true
          }
        }
        localUsages.removeAll(keepingCapacity: true)

      default:
        break
      }
    }

    return foundVendorFeature && !sawReportID
  }
}
