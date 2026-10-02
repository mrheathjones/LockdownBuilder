import Foundation

/// Read-only, known-good rules shipped with the app ("Duplicate to edit" in the UI).
struct BuiltInTemplate: Identifiable, Sendable {
    let id: String
    let summary: String
    /// "Why this works / caveats" shown next to the template.
    let notes: String
    private let make: @Sendable (RuleSettings) -> RuleModel

    init(id: String, summary: String, notes: String, make: @escaping @Sendable (RuleSettings) -> RuleModel) {
        self.id = id
        self.summary = summary
        self.notes = notes
        self.make = make
    }

    func rule(settings: RuleSettings) -> RuleModel { make(settings) }
}

enum BuiltInTemplates {
    static let all: [BuiltInTemplate] = [appleAccount, internetAccounts, freeform, facetime, phone, appStore, fm]

    static func template(id: String) -> BuiltInTemplate? { all.first { $0.id == id } }

    private static func blocked(_ title: String, _ detail: String, org: String) -> String {
        "# \(title)\n\n\(detail)\n\nThis is a policy of \(org). If you believe you need access, please contact the Service Desk."
    }

    static let appleAccount = BuiltInTemplate(
        id: "apple-account",
        summary: "Blocks signing in to an Apple Account in System Settings.",
        notes: """
        Kills System Settings (the host) when the sign-in email field gains focus. The predicate fires once, \
        about 35 ms after the click into that field, so an accidental click elsewhere in the pane is not penalised.
        """
    ) { s in
        RuleModel(
            name: "apple-account",
            killProcess: "System Settings",
            dialogMessage: blocked(
                "Apple Account Sign-in Blocked",
                "Signing in with an Apple Account isn't permitted on this Mac.", org: s.orgNameFriendly),
            predicate: #"process == "AppleIDSettings" AND subsystem == "com.apple.inputmethodkitClient" AND eventMessage CONTAINS "IMKClient subclass""#)
    }

    static let internetAccounts = BuiltInTemplate(
        id: "internet-accounts",
        summary: "Blocks the Internet Accounts pane in System Settings.",
        notes: """
        Fires when System Settings loads InternetAccountsSettingsExtension; click-to-kill measured at about 0.25 s. \
        Kill the host (System Settings), not the extension: killing only the extension makes Settings show \
        “Extension process exited”. The extension exits with the host and a relaunch re-arms the rule.
        """
    ) { s in
        RuleModel(
            name: "internet-accounts",
            killProcess: "System Settings",
            dialogMessage: blocked(
                "Internet Accounts Blocked",
                "Adding internet accounts isn't permitted on this Mac.", org: s.orgNameFriendly),
            predicate: #"process == "System Settings" AND subsystem == "com.apple.extensionkit" AND eventMessage CONTAINS "InternetAccountsSettingsExtension""#)
    }

    static let freeform = BuiltInTemplate(
        id: "freeform",
        summary: "Blocks Freeform.",
        notes: "Presence rule: polled every 0.5 s, so the app is closed almost immediately after launch."
    ) { s in
        RuleModel(
            name: "freeform", killProcess: "Freeform",
            dialogMessage: blocked("Freeform Blocked", "Freeform isn't available on this Mac.", org: s.orgNameFriendly))
    }

    static let facetime = BuiltInTemplate(
        id: "facetime",
        summary: "Blocks FaceTime.",
        notes: "Presence rule: polled every 0.5 s."
    ) { s in
        RuleModel(
            name: "facetime", killProcess: "FaceTime",
            dialogMessage: blocked("FaceTime Blocked", "FaceTime isn't available on this Mac.", org: s.orgNameFriendly))
    }

    static let phone = BuiltInTemplate(
        id: "phone",
        summary: "Blocks the Phone app.",
        notes: "Presence rule: polled every 0.5 s."
    ) { s in
        RuleModel(
            name: "phone", killProcess: "Phone",
            dialogMessage: blocked("Phone Blocked", "The Phone app isn't available on this Mac.", org: s.orgNameFriendly))
    }

    static let appStore = BuiltInTemplate(
        id: "app-store",
        summary: "Blocks the App Store and points people to Self Service.",
        notes: """
        Presence rule with a primary “Self Service” button that opens /Applications/Self Service.app \
        and a “Done” button that only closes the dialog.
        """
    ) { s in
        RuleModel(
            name: "app-store", killProcess: "App Store",
            dialogMessage: "# App Store Blocked\n\nSoftware for this Mac is provided through Self Service by \(s.orgNameFriendly).\n\nOpen Self Service to find the app you need.",
            buttonText: "Self Service",
            buttonAction: "/Applications/Self Service.app",
            dismissButtonText: "Done")
    }

    static let fm = BuiltInTemplate(
        id: "fm",
        summary: "Blocks the Foundation Models command-line tool (macOS 27+, /usr/bin/fm).",
        notes: """
        Presence rule on the process name “fm”. Caveat: a one-shot command can exit before the 0.5 s poll sees it. \
        If you can find a log line unique to the command, an event rule (with a Predicate) is more reliable.
        """
    ) { s in
        RuleModel(
            name: "fm", killProcess: "fm",
            dialogMessage: blocked("Foundation Models CLI Blocked", "The fm command-line tool isn't available on this Mac.", org: s.orgNameFriendly))
    }
}
