# Supported languages and tools

[← Back to the README](../README.md) · [Current scope](INSTALL_AND_CONFIG.md#current-scope)

Kyklos judges a story by checks a machine runs, and every one of those checks reads a particular kind of file with a
particular tool. This page is the one place that says which **programming languages**, test frameworks and measuring tools
each check supports, and which **human languages** Kyklos understands. Every other page states only the part that concerns
it and links here. Which host operating systems and which issue tracker are supported is in
[Current scope](INSTALL_AND_CONFIG.md#current-scope).

In short: the full set of checks works for **C# on .NET** and, for line coverage, for **bash scripts**. Other languages
get the checks that do not depend on the language (the [Proof Table](PROOF.md)'s structure, the
[adversarial review](ADVERSARIAL_REVIEW.md), the [risk register](PROOF_DIMENSION_RISK_ASSESSMENT.md), the
[hooks](HOOKS_AND_SKILLS.md) on commands, branches and commits), and their code is not measured. The agent works with you in
English.

## Human languages

| What | Languages | Details |
|------|-----------|---------|
| The agent's instructions: engineering policy, [skills](HOOKS_AND_SKILLS.md#how-the-agent-knows-what-to-do-skills) | English | Written in English; the agent can still talk to you in another language, but the instructions it follows are English. |
| Messages of the [hooks](HOOKS_AND_SKILLS.md#how-a-hook-decides-one-hook-per-event-every-rule-in-the-bridge), the [Bridge](COMPONENTS.md#kyklos-bridge) and the [Launcher](COMPONENTS.md#kyklos-launcher)'s control panel | English | No translation is shipped. |
| Rules that read the agent's own words | English | Two rules read what the agent writes: the stop rule and the rule on questions asked through Claude Code's question tool. Both refuse a question that hands the agent's routine choice back to you ("which one next?", "should I continue?", "do you want me to X or Y?") by matching English phrasing only; the same question in another language is not recognised. The stop rule counts a turn as waiting for your answer when its text ends with a question mark `?`; a question that ends with another mark (for example `？` or `؟`) is not seen as a question. |
| Stories, the [Proof Table](PROOF.md) and the risk register | Fixed English headings and words, any language under them | The tools write and read fixed English headings (`## Requirements`, `## Use cases`, `## Risk assessment`, ...), field names, verdict words (`PROVEN`, `NOT_PERTINENT`, ...) and item numbers (`R1`, `UC2`, `RA-01`). What you write under them may be in any language. |
| Everything else the rules check | Any | Commands, file and branch names, tool calls and commit messages (beyond their fixed type words such as `feat` or `fix` and the `Refs:` footer) work whatever language you write in. |
| The [audience lint](PROOF_DIMENSION_DOCUMENTATION.md) on public documents | Mostly any | Its patterns for addresses, story numbers, dates and secret locations work in any language; a few of its phrase patterns (for example "do not edit") are English. |
| Manuals built by the Bridge (`doc_build`) | Any | One manual per language code (`en`, `it`, `pt-BR`, ...). The cover and contents titles the Bridge adds itself exist in English and Italian; another language gets the English ones. |

## Programming languages at a glance

✅ supported · ⚠️ partly, see the note · ❌ not supported. "Judged" means a gate refuses the close or the merge when the
check fails; "cited" means the agent supplies the evidence and the gate checks that it is present, not that it is true.

| Language | Build and tests on the host | Line coverage of the story's lines | CRAP score | Mutation testing | Spec items named in test names | i18n scan | De-duplication | Script formal check | Test quality hook |
|----------|----------------|----------------|------|----------|----------------|------|----------|----------------|-----------|
| **C#** (.NET) | ✅ | ✅ judged | ✅ judged | ✅ Stryker.NET, run by the Bridge | ✅ | ✅ | ✅ cited | not applicable | ✅ |
| **F#, Visual Basic** (.NET) | ⚠️ ¹ | ❌ | ❌ | ❌ | ❌ | ❌ refused ² | ❌ | not applicable | ❌ |
| **Bash** (`.sh`, `.bash`) | ⚠️ ³ | ✅ judged (bashcov) | ❌ | ❌ | ✅ | not applicable ⁴ | ✅ cited | ✅ | ❌ |
| **PowerShell** (`.ps1`, `.psm1`, `.psd1`) | ❌ | ❌ | ❌ | ❌ | ❌ | not applicable ⁴ | ✅ cited | ✅ | ❌ |
| **Batch** (`.bat`, `.cmd`) | ❌ | ❌ | ❌ | ❌ | ❌ | not applicable ⁴ | ❌ | ✅ | ❌ |
| **JavaScript, TypeScript** | ❌ | ❌ | ❌ | ⚠️ ⁵ | ❌ | ❌ refused ² | ✅ cited | ❌ | ❌ |
| **Scala** | ❌ | ❌ | ❌ | ⚠️ ⁵ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Python, Go, Java, Ruby** | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ refused ² | ✅ cited | ❌ | ❌ |
| **Any other language** | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |

1. The Bridge runs `dotnet build` and `dotnet test` over the whole solution, so F# and Visual Basic projects build and
   their tests run, but the Bridge plans coverage only for C# test projects (`.csproj`) and judges only C# lines.
2. The i18n scanner reads C# only. A changed file in JavaScript, TypeScript, Python, Java, Kotlin, Go, Visual Basic,
   F#, Swift, Ruby, PHP, Razor, `.cshtml` or XAML stops the scan with "no scanner for": the agent first builds a scanner
   for that language, keeps it in the project's tooling and cites it.
3. Bash suites run inside the agent's container (with bashcov for coverage); the Bridge does not run them on the host.
4. Script files are outside the scope of the i18n row.
5. A changed JavaScript, TypeScript or Scala line near a security annotation makes a mutation run due, as for C#, but
   the Bridge runs only Stryker.NET: the agent runs the project's own StrykerJS or Stryker4s and cites the score.

## The checks, one by one

### Builds and test runs on the host

- **Supported:** .NET solutions (`.sln`, `.slnx`) and projects, built and tested with the .NET SDK installed on the host,
  through the Bridge verbs `build`, `run_tests` and `get_coverage`. Windows is the primary platform; Linux is best effort
  (see [Current scope](INSTALL_AND_CONFIG.md#current-scope)).
- **Test frameworks:** NUnit, xUnit and MSTest, on either test platform `dotnet test` offers: VSTest
  (`Microsoft.NET.Test.Sdk`) or Microsoft.Testing.Platform (including `MSTest.Sdk`). A test filter uses the VSTest
  filter syntax; on Microsoft.Testing.Platform only the NUnit and MSTest runners read it, so a filtered run of an xUnit
  project on that platform is refused with the reason.
- **Test results in CI:** the Bridge reads the test reports GitLab shows for a pipeline, which are JUnit XML files; a .NET
  test project writes them with the `JUnitXml.TestLogger` package (see the example pipeline in step 2.3 of the
  [installation guide](INSTALL_AND_CONFIG.md#part-2-your-windows-machine)). Any language whose CI job publishes
  JUnit XML shows in those reports.
- **The failed-test hook:** after a `dotnet test` or a Bridge test run, a failing test stops the agent until it is
  handled. Test runs of other tools are not read by this hook.
- **Not supported:** builds and tests of any other stack (Node.js, Python, Java, Go, ...) on the host.

### Line coverage (Test Discipline)

- **C#:** measured by the Bridge's own test runs on the host. Under VSTest a test project needs the `coverlet.collector`
  package; on Microsoft.Testing.Platform it needs `coverlet.MTP` or `Microsoft.Testing.Extensions.CodeCoverage`. A test
  project with none of them is named and the run is refused, never silently skipped. Coverage reports are read in the
  Cobertura format. The [Test Discipline](PROOF_DIMENSION_TEST_DISCIPLINE.md) row is judged on every changed C#
  statement.
- **Bash:** measured with bashcov (its Cobertura report) inside the agent's container, then handed to the Bridge as a
  coverage receipt. Every changed line that holds a command is judged. A shell test suite cites what it checks through
  the labels of its check calls (`ok`, `bad`, `pass`, `fail`, `assert_*`).
- **Not measured:** every other language, PowerShell included (Pester is not integrated). A change in such a file adds
  no story lines, so the row rests on the evidence the agent cites.

### CRAP score

- **Supported:** C#. The score is computed from the complexity and coverage of each method in a coverlet Cobertura report,
  and the gate applies when the project's source holds .NET code.
- **Not supported:** bash (bashcov reports no method complexity) and every other language; the row then carries no CRAP
  figure.

### Mutation testing

- **Supported:** C# with **Stryker.NET**, run by the Bridge (`get_mutation`, one project per run, the lowest level
  `Basic` by default) or by the project's CI.
- **Partly:** JavaScript and TypeScript (StrykerJS) and Scala (Stryker4s): a run becomes due by the same rule, but Kyklos
  does not run these tools.
- **When a run is due:** only when a changed production line lies within ten lines of a `[CySec]` security annotation
  written as a comment (`//`, `/*`, `*` or `#`). Other languages never make a run due.

### Spec items named by tests (Completeness and Test Discipline)

- **C#:** the names and the `Category`, `Trait` or `Property` tags of methods that carry an NUnit, xUnit or MSTest test
  attribute (`Test`, `TestCase`, `TestCaseSource`, `Fact`, `Theory`, `TestMethod`, `DataTestMethod`, ...), read from the
  C# syntax tree; skipped tests (`Ignore`, `Explicit`, `Skip`) never count.
- **Bash:** the labels of the check calls of a shell suite.
- **Not supported:** tests in any other language name no item for the tools.

### Test quality hook

- **Supported:** C# test files (in a `*.Tests` folder, or named `*Tests.cs` / `*Test.cs`). It refuses `Assert.Ignore`,
  `Assert.Pass` and `Assert.Inconclusive`, skip attributes (`[Ignore]`, `[Explicit]`, `Skip =`) and positional page
  locators (`.Nth(...)`, `:nth-child`), with a recorded escape for the cases where one is legitimate.
- **Not supported:** test files in any other language.

### i18n scan

- **Supported:** C# literals, promoted into RESX resource files (with the generated `Resources` class) or
  `IStringLocalizer`, whichever the project already uses.
- **Refused until a scanner exists:** the languages in note 2 above. Scripts are out of scope.

### De-duplication

- **Supported:** any change that adds source in C#, PowerShell (`.ps1`, `.psm1`), bash (`.sh`), Python, JavaScript,
  TypeScript, Go, Java or Ruby
  needs a fresh de-duplication pass recorded by the agent. Kyklos ships no clone detector of its own: the agent uses one
  that fits the stack (for example jscpd, PMD-CPD, a Roslyn analyzer) or a search it keeps in the project's tooling, and
  then judges each candidate by meaning.
- **Not supported:** other languages do not make the pass required.

### Script formal check

- **Supported:** bash (`.sh`, `.bash`), PowerShell (`.ps1`, `.psm1`, `.psd1`) and batch (`.bat`, `.cmd`) files a pushed branch changes: encoding,
  line endings, quoting and parse errors, checked before the push. It runs with PowerShell (`pwsh`) in the container and
  uses ShellCheck for bash when it is installed; without `pwsh` the check warns and does not run.
- **Not supported:** Python and other scripting languages.

### Configuration hook

- **Supported:** C#: a database connection string with a credential written in the code is refused, because .NET reads
  it from `appsettings.json` through `IConfiguration.GetConnectionString`.
- **Not supported:** other languages.

### Documentation, manual build and audience lint

- **Documentation row:** any document format; the row needs a link to the changed document at a commit.
- **`doc_build`:** a manual written as a folder of Markdown pages, with Mermaid diagrams and PNG, JPEG, GIF, WebP or SVG
  images, built into one HTML file and one PDF per language. It prints with Microsoft Edge on Windows, and Edge, Google
  Chrome or Chromium on Linux.
- **Audience lint:** any text file; see the human-language table above.

### Checks that do not depend on the programming language

The [Proof Table](PROOF.md)'s structure and metrics, the [adversarial review](ADVERSARIAL_REVIEW.md) (a separate agent
session reads the diff, whatever its language), the [risk register](PROOF_DIMENSION_RISK_ASSESSMENT.md), the `[CySec]`
annotation convention (any comment syntax), and the hooks on commands, branches, commits, pushes, merges and secrets.
The judgment rows (for example Robustness or Thread Safety) are argued by the agent for any language; where they cite
tests, only C# and bash tests name items for the tools.

## Related pages

[Current scope](INSTALL_AND_CONFIG.md#current-scope), [The Proof Table](PROOF.md),
[Test Discipline](PROOF_DIMENSION_TEST_DISCIPLINE.md), [Hooks and skills](HOOKS_AND_SKILLS.md), [How the agent uses CI](CI.md),
and [the README](../README.md) for the full list.
