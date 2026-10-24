# Still 2.0.0 RC 2 — build 7 public source and binary distribution

The official source repository is [sachawicky/still](https://github.com/sachawicky/still), on `main`. Release identity: `app.still.macos`, version `2.0.0`, build `7`, channel `rc.2`, macOS 26+, Apple silicon. `Support/version.env` is the source of bundle identity.

Publishing these sources does not provide a notarized installer. Build outputs, local previews, signing material, account identifiers, machine diagnostics, preferences and backups are excluded from the source commit. Local build and installation records are not distribution evidence for build 7.

## Source validation

Follow [build 7 validation](RELEASE-CANDIDATE.md) and [release procedure](../RELEASE.md). Run tests, check the complete staged tree for secrets and personal data, and verify bundle identity before pushing. Use the existing public repository and a normal fast-forward push; never rewrite public history to publish a release.

## Binary preparation

The maintainer needs a valid Developer ID Application identity in the macOS Keychain and a separately configured notarization profile. Keep account information, certificate identifiers, private keys and authentication data outside Git. Example placeholders below must be replaced locally; never put passwords on the command line.

```sh
SIGN_IDENTITY='Developer ID Application: NAME (TEAM_ID)' REQUIRE_DEVELOPER_ID=1 Scripts/build-release.sh
Scripts/verify-release.sh dist/Still.app --signed
```

The script checks the requested signing identity before replacing a bundle, enables Hardened Runtime and adds a secure timestamp. `--signed` verifies the signature, signing team and timestamp. It does not establish notarization. `--distribution` also requires a stapled ticket, Gatekeeper and system distribution-policy acceptance. Packaging refuses bundles that fail the relevant gates. CI contains no signing credentials or automatic binary publisher.

## Notarization and public installer checklist

Apple uploads and GitHub binary releases require separate authorization for the exact artifacts. This is a procedure, not a claim that these steps passed for build 7.

1. Build and verify the Developer ID signed app. Create a submission ZIP with `ditto -c -k --keepParent dist/Still.app dist/Still-app-notary.zip` and record its SHA-256 locally.
2. After upload authorization, submit with `xcrun notarytool submit dist/Still-app-notary.zip --keychain-profile PROFILE --wait`. Require **Accepted** and inspect the notarization log locally.
3. Staple the app with `xcrun stapler staple dist/Still.app`, then run `Scripts/verify-release.sh dist/Still.app --distribution`.
4. Build a signed image using `Scripts/build-dmg.sh --signed`. The build 7 filename uses `Still-2.0.0-rc.2-macOS-arm64.dmg`. Verify with `Scripts/verify-dmg.sh <DMG> --signed` and record its hash.
5. After authorization for that image, submit it to Apple, require **Accepted**, staple it and run `Scripts/verify-dmg.sh <DMG> --distribution`.
6. Recompute the `.sha256` file after stapling, using the image basename from inside `dist`. Verify it with `shasum -a 256 -c <DMG-BASENAME>.sha256`.
7. Test a quarantined download on a fresh Mac, including offline first launch, permissions, upgrade, uninstall and physical sleep/display behavior. Never disable Gatekeeper or strip quarantine to obtain a pass.
8. Publish only the verified installer and its final checksum to the official repository's Releases page after explicit release authorization. Never publish `LOCAL-PREVIEW` images.

See [distribution feasibility](DISTRIBUTION-AUDIT.md), [power safety](POWER-SAFETY.md) and [privacy](PRIVACY.md). Still Focus is an ambient display cover, not a lock screen. Closed-lid operation without an external display is not guaranteed. Legacy global-setting recovery remains distinct from current process-owned assertions.

References: [Apple Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/), [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
