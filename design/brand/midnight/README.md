# Midnight brand mark

Source artwork for the Midnight app identity. To regenerate the Android
mipmaps and the Windows `app_icon.ico` after editing `icon.svg`, run from the
repository root:

```powershell
node design/brand/midnight/render-icons.cjs
```

The Android adaptive and notification icons are hand-written vectors in
`apps/vault/android/app/src/main/res/drawable/`. Update them when the mark
changes.

- `icon.svg`: full app icon (512 viewBox, rounded square). Source for the
  Windows `.ico` and the Android mipmaps.
- `mark.svg`: crescent and star on transparent. Source for the Android adaptive
  icon foreground and in-app use.
- `lockup.svg`: mark and `midnight` wordmark in Lora (bundled in
  `apps/vault/assets/fonts`).

Palette: sky `#1E2757` to `#060918`, moon `#FBF3D9` to `#D8C38A`.
