Issue: #<number>

Checklist, matching CI. Run in the repository root:

- [ ] `dart pub get`
- [ ] `dart format --output=none --set-exit-if-changed .`
- [ ] `dart analyze --fatal-infos`
- [ ] `dart test`
- [ ] `dart run example/go_channels_example.dart`
- [ ] `dart run example/select_multiway.dart`
- [ ] `dart test -p chrome`
- [ ] `dart test -p chrome -c dart2wasm`
- [ ] `CHANGELOG.md` entry added
