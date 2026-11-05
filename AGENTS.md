# Harmony Bridge repository rules

- Keep the Mac and HarmonyOS version strings in sync for each user-facing update. Increment the Mac build number and HarmonyOS `versionCode`.
- Add a dated entry to `CHANGELOG.md` for every release. Describe behavior, validation, and remaining limitations accurately.
- Publish each completed version with a matching `vX.Y.Z` Git tag and GitHub Release. Follow `docs/RELEASING.md`.
- Never commit local signing files, credentials, session tokens, private files, or a device-bound debug HAP. Review `git status` before pushing.
- Preserve the verified USB/Wi-Fi mirroring and file-transfer behavior unless the task explicitly changes it.
