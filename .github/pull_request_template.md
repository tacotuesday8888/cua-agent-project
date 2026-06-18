## Summary

-

## Verification

- [ ] `./script/check_public_hygiene.sh`
- [ ] `swift test --package-path AutopilotKit`
- [ ] `xcodebuild -project MacAutopilot.xcodeproj -scheme MacAutopilot -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
- [ ] `cd backend && npm run typecheck && npm test && npm run build`
- [ ] `./script/validate_beta.sh` when relevant

## Safety And Privacy

- [ ] No secrets, `.env` files, certificates, provisioning profiles, local tool state, screenshots, AX dumps, or validation reports are committed.
- [ ] User-facing docs match the actual beta behavior.
- [ ] Write/destructive actions remain approval-gated.
