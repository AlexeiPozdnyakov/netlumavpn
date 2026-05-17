import CoreGraphics
import Testing
@testable import QuickVPN

struct HomeConnectLogicTests {
    @Test func homeSessionStyleSeparatesInactiveAndActiveStates() {
        #expect(VPNConnectionStatus.disconnected.isHomeSessionActive == false)
        #expect(VPNConnectionStatus.failed.isHomeSessionActive == false)
        #expect(VPNConnectionStatus.disconnecting.isHomeSessionActive)
        #expect(VPNConnectionStatus.connecting.isHomeSessionActive)
        #expect(VPNConnectionStatus.connected.isHomeSessionActive)
    }

    @Test func hiddenTabsAreNotIncludedInVisibleTabSet() {
        #expect(QuickVPNTab.visibleTabs == [.home, .settings])
        #expect(QuickVPNTab.visibleTabs.contains(.servers) == false)
        #expect(QuickVPNTab.visibleTabs.contains(.protocols) == false)
    }

    @Test func profileSwipeStateClampsOffsetToActionWidth() {
        #expect(ProfileSwipeState.offset(baseOffset: 0, dragTranslation: 20) == 0)
        #expect(ProfileSwipeState.offset(baseOffset: 0, dragTranslation: -300) == -ProfileSwipeState.actionWidth)
        #expect(ProfileSwipeState.offset(baseOffset: -ProfileSwipeState.actionWidth, dragTranslation: 300) == 0)
    }

    @Test func profileSwipeStateRevealsActionsOnlyAfterRowStartsMoving() {
        #expect(ProfileSwipeState.revealsActions(rowOffset: 0) == false)
        #expect(ProfileSwipeState.revealsActions(rowOffset: -0.5) == false)
        #expect(ProfileSwipeState.revealsActions(rowOffset: -2))
    }

    @Test func profileSwipeStateTracksOnlyHorizontalSwipes() {
        #expect(ProfileSwipeState.horizontalTranslation(from: CGSize(width: -80, height: 10)) == -80)
        #expect(ProfileSwipeState.horizontalTranslation(from: CGSize(width: -20, height: 60)) == nil)
        #expect(ProfileSwipeState.horizontalTranslation(from: CGSize(width: -30, height: 28)) == nil)
    }

    @Test func profileSwipeStateOpensAndClosesFromThresholds() {
        #expect(ProfileSwipeState.shouldOpen(isOpen: false, translation: -60, predictedEndTranslation: -60))
        #expect(ProfileSwipeState.shouldOpen(isOpen: false, translation: -12, predictedEndTranslation: -120))
        #expect(ProfileSwipeState.shouldOpen(isOpen: false, translation: -12, predictedEndTranslation: -20) == false)
        #expect(ProfileSwipeState.shouldOpen(isOpen: true, translation: 60, predictedEndTranslation: 60) == false)
        #expect(ProfileSwipeState.shouldOpen(isOpen: true, translation: 8, predictedEndTranslation: -ProfileSwipeState.actionWidth))
    }

    @Test func globalServerRowStateTitlesReflectConnectionAction() {
        #expect(GlobalServerRowState.idle.trailingTitle == "SELECT")
        #expect(GlobalServerRowState.selected.trailingTitle == "SELECTED")
        #expect(GlobalServerRowState.connecting.trailingTitle == "...")
        #expect(GlobalServerRowState.connected.trailingTitle == "ON")
        #expect(GlobalServerRowState.unavailable.trailingTitle == "OFF")
    }

    @Test func quickVPNManagedProfilesAreRecognized() {
        let localProfile = VPNProfile(
            protocolType: .vless,
            host: "local.example.com",
            port: 443,
            security: VPNTransportSecurity.tls,
            networkType: VPNNetworkType.tcp,
            remarks: "Local"
        )
        let globalProfile = VPNProfile(
            protocolType: .vless,
            host: "192.0.2.10",
            port: 443,
            security: VPNTransportSecurity.reality,
            networkType: VPNNetworkType.tcp,
            origin: VPNProfileOrigin.quickVPNGlobal,
            managedServerID: "quickvpn-mvp-eu-1",
            remarks: "QuickVPN Global"
        )

        #expect(localProfile.isQuickVPNManaged == false)
        #expect(globalProfile.isQuickVPNManaged)
        #expect(globalProfile.managedServerID == "quickvpn-mvp-eu-1")
    }
}
