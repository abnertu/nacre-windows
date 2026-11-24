# AGENTS Instructions

## Git

- Write commits in [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/) format.
- Start the type, the scope and the description in lowercase. Keep the case of code identifiers and proper nouns.
- For a non-trivial change, write a commit body that explains why.
- Mark a breaking change with `!` and a `BREAKING CHANGE:` footer.
- Author commits as the user alone. Add no agent trailers or links, such as `Co-Authored-By` or a session URL.
- Commit as the plan progresses.
- Before you push, squash related commits into one commit to keep the history clean.
- Push only after the user approves that push.

## Releases

- Version releases with [Semantic Versioning 2.0.0](https://semver.org/). `VERSION` holds the version.
- Name each release tag with the bare version, such as `1.2.3`. If the repo already uses a tag prefix, such as `v`, keep it.
- When you create a changelog, use [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) format. Keep the format of an existing changelog.
- Release in this order:
  1. Update the version files and the changelog in one commit, such as `chore(release): prepare 1.2.3`.
  2. Push the commit to the default branch.
  3. Wait until the branch pipeline of that commit passes.
  4. Tag that commit with an annotated tag: `git tag -a 1.2.3 -m "Release 1.2.3" <commit>`. Tag a release candidate as `1.2.3-rc.1`.
  5. Push the tag alone: `git push origin 1.2.3`. The tag pipeline creates the release and publishes any package.
- Push the commit and the tag in separate pushes. Do not use `git push --follow-tags`. One push starts two overlapping pipelines, and a single runner queues the tag pipeline.

## Tests

- Add a test to the repo only when it guards behavior that no existing test covers.
- The test must fail when that behavior breaks. Weigh this before you add each test.
- Run throwaway tests freely to check your work.
- Keep throwaway tests out of the repo unless they meet the bar above.
- Never touch the live home, registry, PATH, packages or `%LOCALAPPDATA%\nacre-windows` in a test. Use temporary roots and fake native commands.
- Run the suite under both hosts, then check the format and whitespace:

  ```powershell
  pwsh -NoProfile -File tests/run-tests.ps1
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1
  pwsh -NoProfile -File scripts/format.ps1 -Check
  git diff --check
  ```

## CI

- Keep a CI check only when it catches a concrete failure that no existing check covers.
- Identify that failure before you add or keep the check.
- Apply the test rules to CI checks too.
- Run the repo's entry points against real inputs or isolated fixtures.
- Reject duplicate checks, source-text assertions, copied inventories and checks that only prove that a command or file exists.
- Propagate command failures.
- Count a missing prerequisite or skipped required coverage as a failure.
- Run the checks in branch and pull request pipelines, never in tag pipelines. A tag pipeline builds and smoke-tests any package, publishes it, and then creates the release.
- Start each release job with a check that the tagged commit is on the default branch.
- Match release jobs to the tag format of the version, such as `/^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$/`.
- Protect the release tags. Only protected refs can read the release credentials.
- A tag pipeline uses the CI config of the tagged commit. Merge a CI change to the default branch before you tag.
- After you change these rules, audit the repo against them.
- Validate changes locally. Then verify the required CI on the pushed commit.
- Report each uncovered contract and each unavailable check.
- Name CI files in kebab-case by purpose, such as `deploy-production.yml`.
- Keep reserved host filenames, including `.gitlab-ci.yml`.
- Name workflows in Title Case, such as `Deploy Production`.
- Keep the repository name out of workflow names.
- Name the workflow that validates the whole repository by its action alone, such as `Validate`.
- Name job IDs in snake_case, such as `build_image`.
- Start each GitHub step name with a verb, such as `Install Dependencies` or `Run Tests`.
- Preserve proper nouns and code identifiers when applying case.
- Prefer a specific purpose, such as `deploy-production.yml`, over a vague name, such as `production.yml`.
- Omit redundant host or artifact words, as in `github-action-build.yml` and `build-workflow.yml`.
- Name each workflow, job and step by its target and action.
- Keep job display names unique within the repository.
- Update dispatch references, dependencies, release gates, required check contexts and badges together when renaming CI artifacts.
- Run the checks in a workflow on `pull_request` and on `push` to branches.
- Run the release in a separate workflow on `push` of tags that match `[0-9]+.[0-9]+.[0-9]+` and `[0-9]+.[0-9]+.[0-9]+-*`.
- Check out release jobs with `fetch-depth: 0`, so that the ancestry check sees the default branch.
- Keep release secrets in an environment that allows only the release tags. Protect the tags with a tag ruleset.

## Docs

- Keep each doc concise and plain. Each sentence must carry information.
- Write only standing rules in `AGENTS.md`. A standing rule changes how an agent does later, unrelated tasks.
- Record a fact about one place or one failure at its source: a code comment, a test, a commit body, an ADR or an issue.
- Write English docs in US English, to the [ASD-STE100](https://www.asd-ste100.org/) writing rules:
  - Give one instruction in each sentence.
  - Write instructions in the imperative and in the active voice.
  - Use one word for one meaning, and one meaning for one word.
  - An instruction has 20 words or fewer. A description has 25 words or fewer.
- Review each sentence over these limits. Split it if it holds more than one instruction or fact.
- Use a numbered list for three or more instructions in a fixed order, also across sentences.
- Write a set of full-sentence items, or of more than five items, as a bullet list. Otherwise, the set can stay in one sentence, even when the sentence is over the limits.
- Write a non-English doc in two passes:
  1. Write an English draft to these rules.
  2. Translate the draft:
     1. Keep its sentence boundaries and one term for each concept.
     2. Keep commands, paths and code unchanged.
     3. Use the natural word order of the target language.
- Read [CONTEXT.md](CONTEXT.md) before you change composition, ownership or the deployment flow.

## Secrets

- Never read or print secrets or mutable application data. Secrets include credentials, private keys, tokens and local identity.
- Keep secrets out of Git, artifacts, command arguments and logs.

## Code

- Support Windows PowerShell 5.1 and PowerShell 7. A new Windows host has only 5.1.
- Name files in lowercase kebab-case, such as `run-tests.ps1`. Keep chezmoi source attributes, such as `dot_`, and reserved tool filenames.
- Format PowerShell files with `scripts/format.ps1`. It needs PSScriptAnalyzer 1.25.0.
- Edit formatter rules in `PSScriptAnalyzerSettings.psd1`. Edit blank-line rules in `scripts/format.ps1`.
- Keep each `.ps1` and `.psd1` file ASCII with LF line endings. Windows PowerShell 5.1 reads a BOM-less script as the ANSI code page.
- Hash JSON from `ConvertTo-NwJson` only. `ConvertTo-Json` output differs between 5.1 and 7, so artifact identifiers would differ.
- Keep the build static. Read host state only in `switch` and `doctor`.
- Key each collection by identifier, so that a later layer can withdraw an entry.

## Ownership and deployment

- WinGet DSC owns packages. chezmoi owns home files and source directories.
- nacre-windows owns `XDG_CONFIG_HOME`, the Development junctions and its state in `%LOCALAPPDATA%\nacre-windows`.
- Leave PATH entries to package installers. Leave `$PROFILE` lines, Git identity and credentials to the operator.
- Give each target one owner. Make a conflict a build error.
- Never apply a source archive through a link. The archive owns its directory exactly, so it would delete the worktree.
- Record intent in `pending.json` before a mutation. Clear it only after success.
- Make a disabled declaration withdraw management only. Never uninstall or delete as cleanup.
- Never capture host state into a machine repository automatically.
- Get the user's go-ahead before you deploy, install packages or change the live environment.
