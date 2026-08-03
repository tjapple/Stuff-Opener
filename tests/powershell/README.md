# PowerShell Test Harness

This folder contains Pester tests for the generated PowerShell automation scripts and shared helper partials.

The goal is to catch regressions without needing a live AD, Entra ID, Graph, or Exchange Online environment for every test run. Tests use mocks and fake objects for Microsoft commands, then assert that our logic prompts, selects, writes, verifies, and logs the way we expect.

## Run All Tests

From the `stuff-opener` repo root:

```powershell
.\tests\powershell\Run-PesterTests.ps1
```

## Run By Tag

```powershell
.\tests\powershell\Run-PesterTests.ps1 -Tag AD
.\tests\powershell\Run-PesterTests.ps1 -Tag Graph
.\tests\powershell\Run-PesterTests.ps1 -Tag Exchange
.\tests\powershell\Run-PesterTests.ps1 -Tag License
.\tests\powershell\Run-PesterTests.ps1 -Tag Simulation
.\tests\powershell\Run-PesterTests.ps1 -Tag Static
```

## Folder Layout

- `shared/`: Unit tests for reusable helper partials.
- `simulations/`: Transcript-style tests with queued terminal input.
- `builders/`: Static and generated-script checks for script-builder templates.
- `fixtures/`: Fake AD, Graph, Exchange, and license objects.
- `harness/`: Common loader and input-queue helpers.

## Notes

- These tests do not install Pester. If Pester is not present, the runner stops with instructions.
- The tests are written in a Pester 3-compatible style because Windows PowerShell commonly ships with Pester 3.4.
- Live tenant/lab checks should be added later as manual integration smoke tests, separate from these simulated tests.
