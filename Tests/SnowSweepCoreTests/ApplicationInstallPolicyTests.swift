import Foundation
import Testing
@testable import SnowSweepCore

@Test func nestedAppPolicyAcceptsAdobeMainApps() {
    #expect(ApplicationInstallPolicy.isNestedMainApp(
        appName: "Adobe Photoshop 2027", folderName: "Adobe Photoshop 2027"))
    #expect(ApplicationInstallPolicy.isNestedMainApp(
        appName: "Adobe Lightroom Classic", folderName: "Adobe Lightroom Classic"))
    #expect(ApplicationInstallPolicy.isNestedMainApp(
        appName: "Adobe Acrobat", folderName: "Adobe Acrobat DC"))
    #expect(ApplicationInstallPolicy.isNestedMainApp(
        appName: "DaVinci Resolve", folderName: "DaVinci Resolve"))
}

@Test func nestedAppPolicyRejectsHelpersAndShortNames() {
    #expect(!ApplicationInstallPolicy.isNestedMainApp(
        appName: "AdobeCrashReport", folderName: "Adobe Photoshop 2027"))
    #expect(!ApplicationInstallPolicy.isNestedMainApp(
        appName: "Acrobat Distiller", folderName: "Adobe Acrobat DC"))
    #expect(!ApplicationInstallPolicy.isNestedMainApp(
        appName: "Uninstaller", folderName: "Adobe Photoshop 2027"))
    #expect(!ApplicationInstallPolicy.isNestedMainApp(
        appName: "Adobe", folderName: "Adobe Photoshop 2027"))
}

@Test func nestedAppPolicyNormalizesCaseSpacesAndPunctuation() {
    #expect(ApplicationInstallPolicy.normalized("Adobe Photoshop 2027") == "adobephotoshop2027")
    #expect(ApplicationInstallPolicy.isNestedMainApp(
        appName: "adobe-photoshop 2027", folderName: "Adobe Photoshop 2027"))
    #expect(ApplicationInstallPolicy.isNestedMainApp(
        appName: "Final Cut Pro", folderName: "Final Cut Pro"))
}
