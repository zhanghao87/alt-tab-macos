You can [suggest an enhancement or discuss an issue on github](https://github.com/lwouis/alt-tab-macos/issues), or use the feedback form in the app.

## Technical overview

This document gives a technical overview of the project, for newcomers who want to contribute.

## Building the project

This project has minimal dependency on Xcode-only features (e.g. InterfaceBuilder, Playgrounds). You can build it by doing:

* Set up a local code-signing certificate once, then reuse it for subsequent builds. See [Stable local signing and macOS permissions](#stable-local-signing-and-macos-permissions); do not regenerate the certificate before every build.
* Either open `alt-tab-macos.xcodeproj` with Xcode, or use the CLI: `xcodebuild -project alt-tab-macos.xcodeproj -scheme Debug` to build the .app with the `Debug` build configuration

### Isolated local full-feature build

Run this single command from the project root:

```bash
bash ai/build-local.sh
```

The Bash entrypoint uses the project's **Debug** scheme with `xcodebuild`, not the Xcode GUI or
a Python packaging wrapper. It builds a separate **AltTab (Developer)** app with
`LOCAL_FULL_FEATURES`. The app grants every feature through an explicit `.local` state, not a
purchased Pro license or a persisted QA override. It does not start a trial, read or write license
keys, activate/deactivate licenses, revalidate with the licensing server, or run the official
updater. Settings identifies it as **Local build / All features enabled**. Ordinary builds without
this flag retain normal licensing.

Outputs:

* `DerivedData/XcodeLocal/AltTab (Developer).app`
* `DerivedData/XcodeLocal/AltTab-Developer-xcode.zip`

The script does not install or modify any application. The bundle identifier is
`com.lwouis.alt-tab-macos.developer`; preferences, URL scheme and license storage are separate from
the official app. Local builds refuse to run with the official bundle identifier.

#### Xcode and resource handling

Full Xcode and its macOS build components must be installed and ready to use. The script respects
`DEVELOPER_DIR`; otherwise it uses the selected full Xcode, falling back to
`/Applications/Xcode.app/Contents/Developer` when the system selection is Command Line Tools.
This selection only affects the script process, not the global `xcode-select` setting.

Xcode builds the project and vendored packages and compiles their resource catalogs. No installed
official app is needed as a resource donor. Before packaging, the script removes the Debug
executable's build-tree framework search paths so the portable app uses its embedded frameworks.

The app-only `ALTTAB_BUNDLE_IDENTIFIER` setting selects the developer identity. Do not pass
`PRODUCT_BUNDLE_IDENTIFIER` on the `xcodebuild` command line: it also overrides Swift package resource
bundle IDs. Giving ShortcutRecorder's resource bundle the app's ID makes AppKit fail to resolve its
compiled assets (`Missing sr-mojave-info` when opening Settings). Resource probes deliberately use
the same main-bundle ID as the packaged app so this collision fails packaging rather than escaping
as a Settings crash.

Language selection uses the packaged `.lproj` directories, including local-build status and update
notices. The root `resources/l10n/Localizable.strings` is extraction input, not an app resource:
shipping it at the Resources root overrides the selected language with English. Packaging rejects
that file. Temporary native Swift probes check every translated app string in each supported
language and verify compiled ShortcutRecorder images and style data. The ZIP is unpacked and its
nested signatures, developer bundle identifier and selected signing certificate are verified
before the final output files are replaced.

On SDKs older than macOS 26, the script defines `LEGACY_MACOS_SDK` and uses the existing
NSVisualEffectView, large search field and sample-buffer capture paths. These builds do not include
Liquid Glass or the macOS 26 screenshot API; prefer an up-to-date SDK when building for macOS 26.

#### Stable local signing and macOS permissions

The default identity is **AltTab Local Development**, the long-lived local certificate used for
this workflow. It and its matching private key must exist in your Keychain and appear as a valid
code-signing identity. The script fails before building if the selection is missing or ambiguous;
it never silently falls back to ad-hoc signing.

Check available identities or select another existing certificate by name or its SHA-1 fingerprint:

```bash
security find-identity -v -p codesigning
LOCAL_CODESIGN_IDENTITY="Your existing signing identity" bash ai/build-local.sh
```

Trust a local self-signed certificate for code signing in your user account; no paid Apple developer
account is required for local use. Keep the same certificate and private key; never commit private
keys, PKCS#12 exports, or their passwords. Do not run `scripts/codesign/setup_local.sh` before every
build: it generates a new private key and certificate each time, and its generation command does
not request a long validity period. Recreating a certificate with the same name does not preserve
its identity. The builder itself never creates certificates or changes Keychains.

Ad-hoc signatures depend on the current code hash, so rebuilding changed code can invalidate macOS
Accessibility/Screen Recording authorization. Reusing the same certificate allows the designated
requirement to remain stable across code changes. Keep the developer bundle identifier and the
installation path `/Applications/AltTab (Developer).app` unchanged as well.

Switching from ad-hoc signing to this certificate can require permission to be granted once again.
Reusing the certificate avoids this code-identity change on subsequent builds, but does not
guarantee macOS will never ask again. Self-signed builds are not Apple-notarized distribution builds.
A local self-signed certificate may have no Apple Team ID; do not change the official app's signing
identity or bundle identifier to work around it.

Packaging does not install the app: quit the developer app before replacing its bundle. Keep the
official app in place and install only the separately named developer app. This local build does
not create an official transferable license and must be rebuilt manually for source updates.

## Mac development

Mac development ecosystem is pretty terrible in general. They keep piling on the tech stacks on top of each other, so you have C APIs, ObjC APIs, Swift APIs, Interface builder, Playgrounds, Swift UI, Mac Catalyst. All these are bridging with each other with a bunch of macros, SDKs glue, compiler flags, compatibility mode, XCode legacy build system, etc. For alt-tab, we are on Swift 5.0. Note that swift just recently started being stable, but overall any change of version breaks a lot of stuff. Swift itself is the mainstream language with the worst governance I’ve seen in modern times.

Regarding SDKs, it’s very different from other (better) ecosystems like Java. Here the SDK is bundled with XCode, and XCode is bundled with the OS. This means that from a machine running let’s say macOS 10.10, you have access to only a specific range of XCode versions (you can’t run the latest for instance), and these give you access to a specific range of SDKs (i.e. Swift + objc + c + bridges + compiler + toolchain + etc)

Documentation is abysmal. Very simple things are not documented at all, and good information is hard to find. Compared to other ecosystem I’ve worked on in the past like Android, nodejs, Java, rust, this is really a bad spot. You can truly tell Apple doesn’t care about supporting third-parties. They are in such a good position that people will struggle and just push through to deliver on their ecosystem because it is so valuable, and because they don’t have to care, they don’t. They could pay an intern to update the docs over the summer for instance, just to give you context of the lack of care we are talking about here.

Dependencies in this project are vendored under `vendor/` and consumed as local Swift Package Manager packages. Each dependency has an `update_*.sh` script under `vendor/scripts/` that re-fetches it from upstream, strips unused files, and regenerates its `Package.swift`. There is no remote dependency resolution at build time — `git clone && xcodebuild` is the full bootstrap.

OS APIs are quite limited for the kind of low-level, system-wide app AltTab is. This means often we just don’t have an API to do something. For instance, there is no API to ask the OS “how many Spaces does the user have?” or “Can you focus the window on Space 2?”. There are however, retro-engineered private APIs which you can call. These are not documented at all, not guaranteed to be there in future macOS releases, and prevent us from releasing AltTab on the Mac AppStore. We have tried our best to [document the ones we are using](https://github.com/lwouis/alt-tab-macos/tree/master/src/macos/api-wrappers), next to the code that calls them.

## Project architecture

To mitigate the issues listed above, we took some measures.

The project uses Xcode to compile dependency resources and assemble the app, including the local developer build above. The app's own UI is built in code. Currently, the project has these files:

* `alt-tab-macos.xcodeproj` file describing AltTab itself. It contains some settings for the app
* `alt_tab_macos.entitlements` and `Info.plist` which are static files describing some app config for XCode
* `vendor/` holds vendored open-source libraries (Sparkle, ShortcutRecorder, AppCenter) as local SPM packages. `vendor/scripts/update_*.sh` refresh them from upstream
* Some `.xcconfig` files in `config/` which contain XCode settings that people typically change using XCode UI, but that I want to be version controlled

The project directory is organized in the following way:

| Path | Role |
|------|-------|
| `config/`    | XCode build settings (`.xcconfig` files) |
| `docs/`      | supporting material to document the project |
| `resources/` | files that are shipped inside the final `.app` (e.g. icons) |
| `scripts/`   | bash scripts useful for CI and local workflows |
| `vendor/`    | vendored open-source libraries, consumed as local SPM packages |
| `src/`       | Swift source code |

The `src/` folder groups files by feature, so files that change together live together. Each folder typically contains the implementation, and for the parts we want to pin down, a triad of `Foo.swift` + `FooSpecs.md` (specs) + `FooTests.swift` (unit tests):

| Path | Role |
|------|-------|
| `src/switcher/`         | the switcher itself: its window, tiles, state, appearance, shortcuts (the core feature) |
| `src/windowserver/`     | the WindowServer event pipeline feeding the list of windows |
| `src/events/`           | incoming events we listen to (keyboard, mouse, cursor, Dock, AX queries, etc.) |
| `src/macos/`            | wrappers around macOS APIs (AX/CGS call schedulers, permissions, login item); `src/macos/api-wrappers/` holds the retro-engineered private-API signatures |
| `src/preferences/`      | user settings: storage, migrations, and the Settings window |
| `src/pro/`              | the paid "Pro" features (license, scheduling, related UI) |
| `src/secondary-windows/`| windows other than the switcher (feedback, permission, debug) |
| `src/kit/`              | reusable AppKit building blocks (custom buttons, views, controls) |
| `src/util/`             | generic helpers (background work, throttling, scheduling policy) |
| `src/api/`              | client for our backend (license and feedback endpoints) |
| `src/vendors/`          | glue code for vendored libraries (AppCenter, Sparkle, ObjC exception catcher) |
| `src/debug/`            | benchmarking and QA tooling |
| `src/_test-support/`    | mocks and helpers shared by the unit tests |

Other folders/files are either tooling or auto-generated (e.g. `DerivedData/` is generated by Xcode builds).

## QA

**alt-tab-macos** is deeply integrated with the OS and other apps. Thus doing end-to-end automated QA would be a nightmare. For the time being QA is done manually.

In an attempt to not have too many regressions, this documents will list OS interactions. This should be useful as some of them are very exotic and not many people know about them.

## List of use-cases

### Which windows to list, and be able to focus

* Minimized windows
* Windows from hidden apps
* Windows of fullscreen apps
* Windows of fullscreen apps with split-screen
* Windows merged into 1 as tabs (e.g. Finder "Merge All Windows", drag-and-drop a window onto an existing window, etc) 
* Windows on multiple monitors
* Windows on multiple Spaces
* Should not show: dialogs, pop-overs, context menus (e.g. Outlook meeting reminder, iStats Pro menus)

### App is summoned during an OS animation

* The UI should only appear after the animation completes for:
  * Space transition
  * an app going fullscreen
* The UI should not show at all (i.e. ignore the shortcut) if Mission Control is open
* The UI should show instantly during:
  * Window minimizing/de-minimizing
  * Window maximizing (i.e. double-click the titlebar)
  * An app is launching/quitting

### Thumbnail layout corner-cases

* Very small windows (i.e. smaller than the thumbnail min size)
* Very wide/tall windows
* Should show the app name for windows without a title
* Long titles should be truncated
* Many windows are opened
* There is no open window
* AltTab should appear on top of all windows, dialogs, pop-overs, the Dock, etc

### OS events to handle while AltTab’s UI is shown

* An app is launching/quitting
* A new window opens
* An existing window is closed

### Drag-and-drop on top of the thumbnails

* Drag-and-dropping a URL onto a window thumbnail should open it with that window’s app
* Drag-and-dropping a file onto a window thumbnail should open it with that window’s app

### System Preferences

* General > Appearance > "Dark": switches to Dark Mode
* General > Accent color > "Graphite": traffic lights on thumbnails should be gray
* Accessibility > Display > Reduce transparency: AltTab background should be a solid color
* General > Show scroll bars > "Always": regenerates all scrollbars
* Display > Resolution > Scaled: changes DPI and rescale AltTab
* Mission Control > "Displays have separate Spaces": changes Spaces behavior on multi-displays setups

### Spaces

* Spaces get created/destroyed
* A window is moved to another space by drag-and-dropping on the Spaces thumbnails at the top of the Mission Control UI
* A window is moved to another space by dragging it on the side of the current Space, and waiting for a Space transition, then dropping it
* A window is moved to another space by destroying the Space it is in
* An app is assigned to a specific space or all spaces by clicking its Dock icon > Options > Assign to

### Shortcuts

* The hold "key" can be multiple modifiers (e.g. `⌥⇧`)
* Shortcuts should have priority over system shortcuts such as `cmd+tab`, so the user can replace these
* The "select next window" shortcut can be modifiers, modifiers+key, or just key; it can also contain the same modifiers as the hold "key"
* All shortcuts, except the hold key, can be disabled by the user
* Shortcuts can include the `escape` and `delete` key; these should not stop recording shortcuts
* [Secure Input](https://github.com/lwouis/alt-tab-macos/issues/157#issuecomment-659170293) can prevent AltTab from listening to the keyboard
* Some shortcuts should only work when AltTab is open
  * These shortcuts should active whether the hold shortcut is held or not
* Shortcuts should work with capslock active or inactive
* Shortcuts should repeat if kept pressed
  * Repeat rate and initial delay should match the values set in `System Preference` > `Keyboard`
  * when navigating left/right/up/down, the repeating behavior should stop when hitting the last window in the list. The user can then manually do the shortcut once more to cycle to the other side; it then repeats again
* The shortcut sets 1 and 2 should not interact with each other (e.g. opening AltTab with one, then using the other to navigate)
* Shortcuts can focus the window on release, or be pressing a key or using the mouse
* Keyboards from other countries have different layout which impact shortcuts
  * e.g. the default ``` ⌥` ``` shortcut should become `⌥<` on a Spanish ISO keyboard

### Localization

* Right-to-left languages (e.g. arabic) have the whole layout reversed
  * For the main window, even navigation is reversed
  * For preferences and feedback windows, all layout is reversed
* Text length can vary per languages which can create layout issues

### Misc

* AltTab is launched after some apps/windows are already opened
* Displays/mouses/trackpads/keyboards get connected/disconnected while AltTab is used
* Sudden Termination
