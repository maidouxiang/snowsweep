import Foundation
import Testing
@testable import SnowSweepCore

@Test func parsesPresentAccessoryBatteryAndFlipsInternalSign() {
    let text = """
    bluetoothd: (CoreUtils) [com.apple.bluetooth:CBPowerSource] Power source updated CBPowerSource Nm 'UGREEN BLE Mouse', SID 51450917, AcCa Mouse, Present yes, MaxC 100%, Battery -90%
    """
    let readings = BluetoothPowerSourceLog.parse(text)
    #expect(readings["UGREEN BLE Mouse"]?.percent == 90)
    #expect(readings["UGREEN BLE Mouse"]?.isPresent == true)
}

@Test func ignoresAbsentAndMalformedRecordsAndKeepsLatest() {
    let text = """
    CBPowerSource Nm 'UGREEN BLE Mouse', Present yes, Battery -80%
    CBPowerSource Nm 'UGREEN BLE Mouse', Present no, Battery -88%
    CBPowerSource Nm 'Broken', Present yes, Battery nope%
    unrelated line
    """
    let readings = BluetoothPowerSourceLog.parse(text)
    #expect(readings["UGREEN BLE Mouse"]?.percent == 88)
    #expect(readings["UGREEN BLE Mouse"]?.isPresent == false)
    #expect(readings["Broken"] == nil)
}

@Test func fillsOnlyConnectedMissingBatteryWithinRange() {
    let readings = ["Mouse": BluetoothPowerSourceLog.Reading(name: "Mouse", percent: 90, isPresent: true)]
    #expect(BluetoothPowerSourceLog.fillMissing(deviceName: "Mouse", currentBattery: nil, readings: readings) == 90)
    #expect(BluetoothPowerSourceLog.fillMissing(deviceName: "Mouse", currentBattery: 55, readings: readings) == nil)
    #expect(BluetoothPowerSourceLog.fillMissing(deviceName: "Other", currentBattery: nil, readings: readings) == nil)
}
