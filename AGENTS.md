# Project workflow

- Use focused branches with the `codex/` prefix, based on `main`.
- After completing and validating each roadmap step, commit the changes in one or more understandable commits with short, simple messages.
- After completing a milestone, push its branch and open a pull request against `main`. Describe the resulting behavior, validation, and any remaining limitations.
- Keep implementation changes reviewable in the milestone pull request. Merge only when the user requests it.
- Follow the build and test instructions in `README.md`. Run checks appropriate to the change; distinguish test-bundle compilation from behavioral tests.
- Keep `PrivateData/`, `ModelArtifacts/`, build output, Xcode user settings, and signing credentials out of commits. Do not force-add ignored data.
