import Foundation

/// Read-only, known-good rules shipped with the app ("Duplicate to edit" in the UI).
struct BuiltInTemplate: Identifiable, Sendable {
    let id: String
    let summary: String
    /// "Why this works / caveats" shown next to the template.
    let notes: String
    /// SF Symbol and tint for the template's icon tile.
    let symbol: String
    let tint: Tint
    private let make: @Sendable (RuleSettings) -> RuleModel

    enum Tint: Sendable { case blue, indigo, orange, green, gray, red }

    init(id: String, summary: String, notes: String, symbol: String, tint: Tint,
         make: @escaping @Sendable (RuleSettings) -> RuleModel) {
        self.id = id
        self.summary = summary
        self.notes = notes
        self.symbol = symbol
        self.tint = tint
        self.make = make
    }

    func rule(settings: RuleSettings) -> RuleModel { make(settings) }
}

enum BuiltInTemplates {
    static let all: [BuiltInTemplate] = [appleAccount, internetAccounts, freeform, facetime, phone, appStore, fm, usbBlock]

    static func template(id: String) -> BuiltInTemplate? { all.first { $0.id == id } }

    /// The company name is the `{{companyName}}` variable, filled in by the watcher (1.10 or later).
    private static func blocked(_ title: String, _ detail: String) -> String {
        "# \(title)\n\n\(detail)\n\nThis is a policy of \(MessageVariable.companyName.token). If you believe you need access, please contact the Service Desk."
    }

    static let appleAccount = BuiltInTemplate(
        id: "apple-account",
        summary: "Blocks signing in to an Apple Account in System Settings.",
        notes: """
        Kills System Settings (the host) when the sign-in email field gains focus. The predicate fires once, \
        about 35 ms after the click into that field, so an accidental click elsewhere in the pane is not penalised.
        """,
        symbol: "person.crop.circle.fill", tint: .blue
    ) { _ in
        RuleModel(
            name: "apple-account",
            killProcess: "System Settings",
            dialogMessage: blocked(
                "Apple Account Sign-in Blocked",
                "Signing in with an Apple Account isn't permitted on this Mac."),
            predicate: #"process == "AppleIDSettings" AND subsystem == "com.apple.inputmethodkitClient" AND eventMessage CONTAINS "IMKClient subclass""#)
    }

    static let internetAccounts = BuiltInTemplate(
        id: "internet-accounts",
        summary: "Blocks the Internet Accounts pane in System Settings.",
        notes: """
        Fires when System Settings loads InternetAccountsSettingsExtension; click-to-kill measured at about 0.25 s. \
        Kill the host (System Settings), not the extension: killing only the extension makes Settings show \
        “Extension process exited”. The extension exits with the host and a relaunch re-arms the rule.
        """,
        symbol: "at", tint: .indigo
    ) { _ in
        RuleModel(
            name: "internet-accounts",
            killProcess: "System Settings",
            dialogMessage: blocked(
                "Internet Accounts Blocked",
                "Adding internet accounts isn't permitted on this Mac."),
            predicate: #"process == "System Settings" AND subsystem == "com.apple.extensionkit" AND eventMessage CONTAINS "InternetAccountsSettingsExtension""#)
    }

    static let freeform = BuiltInTemplate(
        id: "freeform",
        summary: "Blocks Freeform.",
        notes: "Presence rule: polled every 0.5 s, so the app is closed almost immediately after launch.",
        symbol: "scribble", tint: .orange
    ) { _ in
        RuleModel(
            name: "freeform", killProcess: "Freeform",
            dialogMessage: blocked("Freeform Blocked", "Freeform isn't available on this Mac."))
    }

    static let facetime = BuiltInTemplate(
        id: "facetime",
        summary: "Blocks FaceTime.",
        notes: "Presence rule: polled every 0.5 s.",
        symbol: "video.fill", tint: .green
    ) { _ in
        RuleModel(
            name: "facetime", killProcess: "FaceTime",
            dialogMessage: blocked("FaceTime Blocked", "FaceTime isn't available on this Mac."))
    }

    static let phone = BuiltInTemplate(
        id: "phone",
        summary: "Blocks the Phone app.",
        notes: "Presence rule: polled every 0.5 s.",
        symbol: "phone.fill", tint: .green
    ) { _ in
        RuleModel(
            name: "phone", killProcess: "Phone",
            dialogMessage: blocked("Phone Blocked", "The Phone app isn't available on this Mac."))
    }

    static let appStore = BuiltInTemplate(
        id: "app-store",
        summary: "Blocks the App Store and points people to Self Service.",
        notes: """
        Presence rule with a primary “Self Service” button that opens /Applications/Self Service.app \
        and a “Done” button that only closes the dialog.
        """,
        symbol: "bag.fill", tint: .blue
    ) { _ in
        RuleModel(
            name: "app-store", killProcess: "App Store",
            dialogMessage: "# App Store Blocked\n\nSoftware for this Mac is provided through Self Service by \(MessageVariable.companyName.token).\n\nOpen Self Service to find the app you need.",
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
        """,
        symbol: "terminal.fill", tint: .gray
    ) { _ in
        RuleModel(
            name: "fm", killProcess: "fm",
            dialogMessage: blocked("Foundation Models CLI Blocked", "The fm command-line tool isn't available on this Mac."))
    }

    static let usbBlock = BuiltInTemplate(
        id: "usb-block",
        summary: "Explains why external storage won't mount (notify only; nothing is quit).",
        notes: """
        Notify-only rule: it has a Predicate and no KillProcess, so the watcher shows the dialog and kills nothing. \
        It explains a denial; it does not enforce anything. A rule without KillProcess needs Restricted Item Watcher \
        \(RuleModel.notifyOnlyMinimumWatcherVersion) or later (older watchers skip the rule).

        With a DDM Disk Management policy set to Disallowed, macOS approves the mount callbacks and starts the mount, \
        which then fails with POSIX error 1. diskarbitrationd logs “unable to mount /dev/diskNsM (status code \
        0x00000001).” about 0.3 to 0.5 s after the drive is inserted. The line is logged at both Info and Error \
        level; the watcher's log stream delivers only the Error copy, and the 10 s cooldown gives one dialog per \
        drive even when several partitions are denied.

        Scope this rule in Jamf ONLY to the group that has the DDM Disallowed Blueprint. DDM read-only mode produces \
        the identical line (it denies read-write drives outright), so do NOT scope it to the Jamf Protect read-only group.

        Validated with a FAT drive only (msdos_fskit). APFS, HFS+, exFAT and multi-partition drives are untested.
        """,
        symbol: "externaldrive.badge.xmark", tint: .red
    ) { _ in
        RuleModel(
            name: "usb-block",
            dialogMessage: blocked(
                "External storage is blocked",
                "External drives and other removable storage can't be used on this Mac."),
            predicate: #"process == "diskarbitrationd" AND subsystem == "com.apple.DiskArbitration.diskarbitrationd" AND eventMessage BEGINSWITH "unable to mount" AND eventMessage CONTAINS "status code 0x00000001""#,
            cooldownSeconds: 10)
    }
}
