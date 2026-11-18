/// Where the two screens show on the Mac.
public enum ScreenLayout: Equatable, Sendable {
    case oneWindow      // the two screens in the main window
    case topOnly        // the lower screen is on the phone
    case twoWindows     // the top screen in the main window, the lower screen in its own window

    /// The phone wins: while it shows the lower screen, the Mac does not show it a second time.
    public static func resolve(gameRuns: Bool, phoneHasLower: Bool, wantsSplit: Bool) -> ScreenLayout {
        guard gameRuns else { return .oneWindow }
        return phoneHasLower ? .topOnly : (wantsSplit ? .twoWindows : .oneWindow)
    }
}
