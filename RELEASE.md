# Releasing

Identity (name, bundle id `app.still.macos`, version, build, minimum macOS) lives in `Support/version.env`.

## Checks

```bash
swift run StillCheck            # expect: 146 passed, 0 failed
./Scripts/build-release.sh      # builds dist/Still.app and audits it with Scripts/verify-release.sh
```

## Signed and notarized release

Requires a Developer ID Application certificate and notarization credentials. An ad-hoc build must never be published as a release.

```bash
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./Scripts/build-release.sh
ditto -c -k --keepParent dist/Still.app dist/Still-1.0.0-macOS.zip
xcrun notarytool submit dist/Still-1.0.0-macOS.zip --keychain-profile <profile> --wait
xcrun stapler staple dist/Still.app
rm dist/Still-1.0.0-macOS.zip
ditto -c -k --keepParent dist/Still.app dist/Still-1.0.0-macOS.zip
shasum -a 256 dist/Still-1.0.0-macOS.zip > dist/Still-1.0.0-macOS.zip.sha256
spctl --assess --type execute -vv dist/Still.app
```

Then tag and publish:

```bash
git tag v1.0.0 && git push origin v1.0.0
gh release create v1.0.0 dist/Still-1.0.0-macOS.zip dist/Still-1.0.0-macOS.zip.sha256 --title "Still 1.0.0" --notes-file <notes>
```

Update the Download section of the README at the same time.

## Local install (maintainer)

`./Scripts/install-local.sh` builds, quits the running Still and replaces `/Applications/Still.app`.

## Known limitations

- Apple silicon and macOS 26 only.
- Safari resume depends on Safari producing local audio. AirPlay video that bypasses the Mac is not detected, so nothing is sent.
- AI Work uses transcript activity. A tool call silent for over 3 minutes may let the Mac sleep.
- `pmset disablesleep` is undocumented and may change in future macOS versions.
