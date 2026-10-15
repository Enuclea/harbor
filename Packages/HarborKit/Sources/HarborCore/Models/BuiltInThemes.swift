import Foundation

/// Themes that ship with Harbor. Third-party palettes are the authors' published values.
public enum BuiltInThemes {
    public static let defaultDarkID = "harbor-midnight"
    public static let defaultLightID = "harbor-daylight"

    public static func theme(id: String) -> TerminalTheme? {
        all.first { $0.id == id }
    }

    public static func themeOrDefault(id: String?) -> TerminalTheme {
        id.flatMap(theme(id:)) ?? harborMidnight
    }

    public static let all: [TerminalTheme] = [
        harborMidnight, harborDaylight, basic, pro, homebrew, ocean,
        solarizedDark, solarizedLight, dracula, nord, gruvboxDark, tokyoNight, catppuccinMocha, oneDark,
    ]

    /// Classic xterm-like palette used by Terminal.app's Basic/Pro/Homebrew/Ocean profiles.
    private static let terminalAppANSI = [
        "#000000", "#990000", "#00A600", "#999900", "#0000B2", "#B200B2", "#00A6B2", "#BFBFBF",
        "#666666", "#E50000", "#00D900", "#E5E500", "#0000FF", "#E500E5", "#00E5E5", "#E5E5E5",
    ]

    public static let harborMidnight = TerminalTheme(
        id: "harbor-midnight", name: "Harbor Midnight",
        foreground: "#D7DCE5", background: "#0E1117", cursor: "#7AA2F7", selection: "#2A3550",
        ansi: ["#1B1F2A", "#F2777A", "#8BD49C", "#F1C27D", "#7AA2F7", "#C397F2", "#6FD3E3", "#C8CFDA",
               "#4B5468", "#FF8E8E", "#A6E3B0", "#FFD59A", "#9DB8FF", "#D6B4FF", "#93E4F0", "#F4F6FA"])

    public static let harborDaylight = TerminalTheme(
        id: "harbor-daylight", name: "Harbor Daylight",
        foreground: "#2B2F36", background: "#FAFAF7", cursor: "#2F6FEB", selection: "#CFE0FF",
        ansi: ["#2B2F36", "#C9353A", "#2E8B48", "#A56A00", "#2F6FEB", "#8A4BD8", "#1B8A9B", "#D9DCE1",
               "#6B7280", "#E5484D", "#3BA55C", "#C78A00", "#4C8DFF", "#A66BFF", "#2AAFC2", "#FFFFFF"])

    public static let basic = TerminalTheme(
        id: "basic", name: "Basic",
        foreground: "#000000", background: "#FFFFFF", cursor: "#7F7F7F", selection: "#A4CDFF",
        ansi: terminalAppANSI)

    public static let pro = TerminalTheme(
        id: "pro", name: "Pro",
        foreground: "#F2F2F2", background: "#000000", cursor: "#4D4D4D", selection: "#414141",
        ansi: terminalAppANSI)

    public static let homebrew = TerminalTheme(
        id: "homebrew", name: "Homebrew",
        foreground: "#28FE14", background: "#000000", cursor: "#23FF18", selection: "#083905",
        ansi: terminalAppANSI)

    public static let ocean = TerminalTheme(
        id: "ocean", name: "Ocean",
        foreground: "#FFFFFF", background: "#224FBC", cursor: "#7F7F7F", selection: "#216DFF",
        ansi: terminalAppANSI)

    public static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: "Solarized Dark",
        foreground: "#839496", background: "#002B36", cursor: "#93A1A1", selection: "#073642",
        ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
               "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"])

    public static let solarizedLight = TerminalTheme(
        id: "solarized-light", name: "Solarized Light",
        foreground: "#657B83", background: "#FDF6E3", cursor: "#586E75", selection: "#EEE8D5",
        ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
               "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"])

    public static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula",
        foreground: "#F8F8F2", background: "#282A36", cursor: "#F8F8F2", selection: "#44475A",
        ansi: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
               "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"])

    public static let nord = TerminalTheme(
        id: "nord", name: "Nord",
        foreground: "#D8DEE9", background: "#2E3440", cursor: "#D8DEE9", selection: "#434C5E",
        ansi: ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
               "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"])

    public static let gruvboxDark = TerminalTheme(
        id: "gruvbox-dark", name: "Gruvbox Dark",
        foreground: "#EBDBB2", background: "#282828", cursor: "#EBDBB2", selection: "#504945",
        ansi: ["#282828", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#A89984",
               "#928374", "#FB4934", "#B8BB26", "#FABD2F", "#83A598", "#D3869B", "#8EC07C", "#EBDBB2"])

    public static let tokyoNight = TerminalTheme(
        id: "tokyo-night", name: "Tokyo Night",
        foreground: "#C0CAF5", background: "#1A1B26", cursor: "#C0CAF5", selection: "#283457",
        ansi: ["#15161E", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
               "#414868", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5"])

    public static let catppuccinMocha = TerminalTheme(
        id: "catppuccin-mocha", name: "Catppuccin Mocha",
        foreground: "#CDD6F4", background: "#1E1E2E", cursor: "#F5E0DC", selection: "#585B70",
        ansi: ["#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
               "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8"])

    public static let oneDark = TerminalTheme(
        id: "one-dark", name: "One Dark",
        foreground: "#ABB2BF", background: "#282C34", cursor: "#528BFF", selection: "#3E4451",
        ansi: ["#282C34", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF",
               "#5C6370", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#FFFFFF"])
}
