# How to Release a NotchNook Update

## First Time Setup (do once)

1. Generate your signing keys:
   ```
   make generate-keys
   ```
2. It will print a public key — copy it and save it somewhere safe
3. The private key is stored in your Keychain automatically

## Releasing an Update

### Step 1 — Bump the version
Open `VERSION` file and change the number:
```
1.1.0
```

### Step 2 — Build and release
```
make release SPARKLE_ED_KEY="your-public-key-here"
```

This will:
- Build the app
- Create a signed DMG
- Create a GitHub Release with the DMG
- Update `appcast.xml` with the new version

### Step 3 — Push the appcast
```
git add appcast.xml
git commit -m "Update appcast for v1.1.0"
git push
```

That's it. Existing users will get a notification next time they open the app.

## Quick Reference

| What                  | Command                                          |
|-----------------------|--------------------------------------------------|
| Build DMG only        | `make dmg`                                       |
| Full release          | `make release SPARKLE_ED_KEY="..."`              |
| Generate keys         | `make generate-keys`                             |
| Clean build           | `make clean`                                     |
