import Foundation
import Testing

struct AppStoreSubmissionTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func shippingBundlesDeclareExportComplianceCodeBuildSetting() throws {
        let plistPaths = [
            "NetlumaVPN/Info.plist",
            "NetlumaVPNTunnelExtension/Info.plist",
            "NetlumaVPNWireGuardExtension/Info.plist",
            "NetlumaVPNWidget/Info.plist"
        ]

        for plistPath in plistPaths {
            let plist = try #require(try NSDictionary(
                contentsOf: Self.repoRoot.appendingPathComponent(plistPath),
                error: ()
            ))

            #expect(plist["ITSAppUsesNonExemptEncryption"] as? Bool == true)
            #expect(plist["ITSEncryptionExportComplianceCode"] as? String == "$(APP_STORE_EXPORT_COMPLIANCE_CODE)")
        }
    }

    @Test func appSupportsAllIPadOrientationsForMultitasking() throws {
        let plist = try #require(try NSDictionary(
            contentsOf: Self.repoRoot.appendingPathComponent("NetlumaVPN/Info.plist"),
            error: ()
        ))

        let expectedIPadOrientations = [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight"
        ]

        #expect(plist["UISupportedInterfaceOrientations~ipad"] as? [String] == expectedIPadOrientations)
    }

    @Test func projectGeneratesVendorFrameworkDSYMsDuringArchive() throws {
        let projectSpec = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        #expect(projectSpec.contains("Generate vendor framework dSYMs for archive"))
        #expect(projectSpec.contains("dsymutil"))
        #expect(projectSpec.contains("${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"))
        #expect(projectSpec.contains("${DWARF_DSYM_FOLDER_PATH}"))
    }

    @Test func projectLoadsLocalExportComplianceXCConfigWithoutCommittingCode() throws {
        let projectSpec = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let wrapperConfig = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Config/AppStoreExportCompliance.xcconfig"),
            encoding: .utf8
        )
        let exampleConfig = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Config/AppStoreExportCompliance.local.xcconfig.example"),
            encoding: .utf8
        )
        let gitIgnore = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(".gitignore"),
            encoding: .utf8
        )

        #expect(projectSpec.contains("Debug: Config/AppStoreExportCompliance.xcconfig"))
        #expect(projectSpec.contains("Release: Config/AppStoreExportCompliance.xcconfig"))
        #expect(wrapperConfig.contains("APP_STORE_EXPORT_COMPLIANCE_CODE ="))
        #expect(wrapperConfig.contains("#include? \"AppStoreExportCompliance.local.xcconfig\""))
        #expect(exampleConfig.contains("REPLACE_WITH_CODE_FROM_APP_STORE_CONNECT"))
        #expect(gitIgnore.contains("Config/AppStoreExportCompliance.local.xcconfig"))
    }

    @Test func helperWritesLocalExportComplianceXCConfig() throws {
        let helper = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("ops/set-app-store-export-compliance-code.sh"),
            encoding: .utf8
        )

        #expect(helper.contains("Config/AppStoreExportCompliance.local.xcconfig"))
        #expect(helper.contains("APP_STORE_EXPORT_COMPLIANCE_CODE = $code"))
        #expect(helper.contains("REPLACE_WITH_CODE_FROM_APP_STORE_CONNECT"))
        #expect(helper.contains("chmod 600"))
    }
}
