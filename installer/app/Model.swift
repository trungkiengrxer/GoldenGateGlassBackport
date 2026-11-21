import Foundation

struct Effect {
    let key: String
    let title: String
    let detail: String
    let defaultOn: Bool
}

let effects = [
    Effect(key: "flex", title: "Interactive Glass Buttons", detail: "Let glass buttons flex when pressed.", defaultOn: true),
    Effect(key: "flexGlassButton", title: "Interactive Glass Button Styles", detail: "Apply the interaction to glass-styled buttons.", defaultOn: true),
    Effect(key: "trafficLights", title: "Window Controls", detail: "Animate the close, minimize, and zoom buttons.", defaultOn: true),
    Effect(key: "toolbarPress", title: "Toolbar Button Press", detail: "Show a highlight when you press a toolbar button.", defaultOn: true),
    Effect(key: "pocket", title: "Scroll Edge Effect", detail: "Show a glass edge where content scrolls under controls.", defaultOn: true),
    Effect(key: "sidebar", title: "Sidebar", detail: "Apply the updated glass appearance to supported sidebars.", defaultOn: true),
    Effect(key: "sidebarGlass", title: "Sidebar Glass Recipe", detail: "Use the macOS 27 glass recipe for supported sidebars.", defaultOn: false),
    Effect(key: "windowCorners", title: "Window Corners", detail: "Apply the macOS 27 corner shape to supported windows.", defaultOn: true),
    Effect(key: "menuGlass", title: "Interactive Menus", detail: "Animate glass highlights as you move through menus.", defaultOn: true),
    Effect(key: "appex", title: "App Extensions", detail: "Extend the effects to supported app extensions.", defaultOn: true),
    Effect(key: "settingsSlider", title: "Liquid Glass Slider in System Settings", detail: "Show the glass transparency slider in System Settings.", defaultOn: true),
    Effect(key: "legibility", title: "Glass Transparency in Apps", detail: "Apply the glass transparency setting to supported apps.", defaultOn: true),
    Effect(key: "systemUI", title: "Glass Transparency in Dock and Control Center", detail: "Apply the glass transparency setting to supported system interfaces.", defaultOn: true),
    Effect(key: "appRecipes", title: "Per-Glass Recipes", detail: "Use the macOS 27 appearance for supported glass surfaces.", defaultOn: true),
]

func machineProblem(checkExitCode: Int32) -> String? {
    switch checkExitCode {
    case 0: nil
    case 1: "This Mac is not running macOS 26.6 (25G72)."
    case 2: "Golden Gate Glass requires an Intel Mac."
    case 3: "System Integrity Protection (filesystem) must be disabled."
    case 4: "AMFI must be disabled (amfi_get_out_of_my_way=1 in boot-args)."
    default: "Could not check this Mac."
    }
}

func glassLoaded(log: String, windowServerPID: Int32) -> Bool {
    let event = "[\(windowServerPID)] enabled"
    return log.split(whereSeparator: \.isNewline).contains {
        $0.hasSuffix(event) || $0.contains(event + " (")
    }
}

func excludedBundleIDs(guardDirs: [String], list: (String) -> [String]) -> [String] {
    let suffix = ".excluded"
    return Set(guardDirs.flatMap(list).compactMap { name in
        name.hasSuffix(suffix) && name.count > suffix.count ? String(name.dropLast(suffix.count)) : nil
    }).sorted()
}
