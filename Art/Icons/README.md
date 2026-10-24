# Still icon source

Still.icon is the native document created in Xcode 27 Icon Composer and validated with actool. It includes original SVG vector layers, a graphite/blue automatic gradient, native neutral shadow and restrained translucency. The compiler produces Aqua, Dark Aqua and Tintable/Mono icon stacks, vector layers and system fallback sizes; the bundle carries Assets.car plus Still.icns. Supported target: macOS. No proprietary artwork, font, bitmap illustration or third-party assets are used.

The interrupted ring is centered at 512/512 on a 1024-unit square, radius 280, stroke 74 and seam 66. The activity dot has radius 56. The two horizontal cuts avoid a power-button or moon silhouette. The slightly stronger ring and separated dot remain clear in the inspected 16/32 px native fallback. Menu-bar template images use the same interrupted-ring identity with simplified optical geometry, tinted by macOS.

Open Still.icon in Icon Composer to edit material, color and appearances. The standalone ring.svg and activity.svg are import masters; reimport after editing, or edit the copies in Still.icon/Assets directly. Keep the copies synchronized. Rebuild with Scripts/build-release.sh; verify-release.sh checks the actual compiled three icon appearances.

Finder's installed Get Info icon and preview were visually inspected at version 2.0.0. Still is an LSUIElement utility and intentionally has no persistent Dock tile. The icon is available to About and notifications via bundle metadata; actual notification-center delivery/appearance and the optional Dock context remain manual checks rather than invented verification.
