// macOS 27 style SwiftUI sidebar icons.
// SwiftUI 27 SidebarRow_Mac.calistogaIconStyle (0x19a670c58): row with a prominent background (backgroundProminence .increased)
// -> Color.primary; inactive window -> Color.secondary (vibrant); active -> Color.accentColor (or ListItemTint).
// SwiftUI 26.6 has none of those fields: the Solarium branch of SidebarRow_Mac (closure 0x7ff916c77480) returns Color.primary.
// We make that closure return a Color built from a ColorProvider (SwiftUICore 26.6 SPI): the color is chosen at resolve time
// from the environment, so it follows window activation like 27 (the 27 body reads @Environment(\.appearsActive)).
import SwiftUI

struct GGSidebarIconColor: ColorProvider {
    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        if environment.backgroundProminence == .increased { return Color.primary.resolve(in: environment) }
        if !environment.appearsActive { return Color.secondary.resolve(in: environment) }
        return Color.accentColor.resolve(in: environment)
    }
    /// The tag is only used when encoding the color (archiving, sending to another process). Color.ProviderTag is a
    /// single-payload enum, 8 bytes; we return the same value SystemColorType.tag returns (0x10, a no-payload case;
    /// getter 0x7ffb189cffe0 in SwiftUICore 26.6).
    var tag: Color.ProviderTag {
        let p = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 16)
        defer { p.deallocate() }
        p.storeBytes(of: UInt64(0x10), as: UInt64.self)
        return p.load(as: Color.ProviderTag.self)
    }
    func serialize(to encoder: any Encoder) throws { throw CocoaError(.featureUnsupported) }
    static func deserialize(from decoder: any Decoder) throws -> Self { throw CocoaError(.featureUnsupported) }
}

// Color.init<P: ColorProvider>(provider:) is declared in the body of struct Color (package) and cannot be redeclared in an
// extension (different mangling): call the symbol directly. The init takes its argument at +1; the Color metatype is thin
// so it takes no register.
@_silgen_name("$s7SwiftUI5ColorV8providerACx_tcAA0C8ProviderRzlufC")
private func colorWithProvider<P: ColorProvider>(_ provider: __owned P) -> Color

private let iconColor = colorWithProvider(GGSidebarIconColor())

/// Called from gg_sidebar_icon_thunk (SidebarIcon.m) in place of Color.primary in the 26.6 Solarium closure. Returns +1
/// like the original getter.
@_silgen_name("gg_sidebar_icon_color") public func ggSidebarIconColor() -> Color { iconColor }
