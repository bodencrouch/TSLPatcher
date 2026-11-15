# Native console interface

Build the console target as `TSLPatcher` on Linux or `TSLPatcher.exe` on Windows. It runs the original patch engine and does not load VCL forms. The separate `TSLPatcher.dpr` GUI project retains its existing positional INI/RTF overrides.

```sh
mkdir -p build/units build/bin
fpc -B -Mdelphi -dTSLPATCHER_HEADLESS -FUbuild/units -FEbuild/bin -oTSLPatcher TSLPatcherCLI.dpr
```

In Windows PowerShell

```powershell
New-Item -ItemType Directory -Force build/units, build/bin | Out-Null
fpc -B -Mdelphi -dTSLPATCHER_HEADLESS -FUbuild/units -FEbuild/bin -oTSLPatcher.exe TSLPatcherCLI.dpr
```

Use FPC 3.2.x with its RTL and FCL packages. `-Mdelphi` enables Delphi-compatible language syntax. The native subprocess backend uses FPC's `Process` unit and requires FPC. The default Delphi GUI build remains documented in [BUILDING.md](BUILDING.md).

## Unattended actions

```sh
TSLPatcher --tslpatchdata /mods/example --game-dir /games/kotor --namespace-option-index 0 --install
TSLPatcher /games/kotor /mods/example 0 --uninstall
TSLPatcher --tslpatchdata=/mods/example --validate
```

The mod argument accepts the package root or its `tslpatchdata` directory. Namespace indexes start at zero. Two positional arguments mean `GAME MOD`. An optional third supplies the index. Positionals override named values. Long value options also accept `--name=value`. Exactly one action is required. Validation accepts an omitted game directory and rejects an explicitly supplied missing directory.

Validation reads INI syntax, required sections and modifier references, source availability, compiler availability, configured paths and `Required`/`RequiredN` files. Comma-separated required files must all exist. A missing group displays its matching `RequiredMsg` or `RequiredMsgN` message when supplied. With a game argument it checks game and archive destinations. Validation is a static check. Actual patch execution determines binary-format success. Install performs configuration, path and requirement preflight and then invokes the original engine. That engine reports missing operation sources and execution errors.

The selected INI's parent supplies payload and script sources. The native compiler is `nwnnsscomp.exe` in that directory, falling back to the package's top-level `tslpatchdata/nwnnsscomp.exe`. On Linux this must be a host executable or an executable wrapper. A wrapper can explicitly invoke Wine for a Windows PE compiler. Real NWScript compilation requires a real compiler.

## Interactive and information options

Place the console executable beside `tslpatchdata`, then run these commands.

```sh
TSLPatcher --list
TSLPatcher --info --namespace "Variant name"
TSLPatcher --summary -n 0
TSLPatcher --cli --game /games/kotor --namespace 0 --yes
```

`-n`/`--namespace` selects an index or case-insensitive name in interactive mode. `-g`/`--game` and `--game-dir` select the game. `-y`/`--yes` chooses the first namespace and skips confirmation. A usable game directory is still required. Otherwise the console prompts when selection is needed. A valid `LookupGameNumber` setting selects the requested Windows registry installation first. Steam library paths, both games’ registry entries and common install locations provide fallback candidates when no usable game was supplied. Ambiguous detection falls back to the prompt.

`--cli` and `--no-gui` select terminal operation. This separate target is always a console application. `--console` is accepted and does not imply installation. `--log-level 0..4` selects no output, notes, notes and errors, all except verbose, or all output respectively. Complete logs are retained as `installlog.txt` and `installlog.rtf` in the mod root.

`-h`/`--help` wins over `-V`/`--version` after full syntax validation. Explicit actions take precedence over `--list`, `--info` and `--summary`. Mod/index options without an action fail rather than opening a GUI. Interactive `.ini`/`.rtf` arguments override the defaults. Direct actions use `changes.ini` and namespace declarations. Unknown options fail. `--experimental-lowercase-paths` is an explicitly accepted compatibility no-op.

## Backups and restoration

Each install creates a new `backup/cli-NNNNNNNN` generation in the selected package. On Unix, new backup directories are synchronized through their parents before the first game write. Before each engine file mutation, the CLI flushes the original bytes and a game-relative manifest entry. Previously absent files are recorded for deletion. Rename callbacks capture both endpoints. Package source/compiler temporary files and backup metadata are excluded from game-file capture, including when the package lives inside the game tree. Configured destinations that overlap those directories are rejected. Partial failures retain the generation, so `--uninstall` can restore completed changes. A repeated install creates a generation above the highest retained number. Removing an older generation leaves the selection order intact. Every uninstall restores the retained latest generation, including after a successful restoration. Repeated calls reapply that generation's before-images and removals. Earlier snapshots and the latest backup remain retained.

Install and uninstall hold operating-system locks on the game and package roots. The `.tslpatcher.lock` files remain, but ownership is released automatically when the process exits, including after a crash. Concurrent invocations fail promptly.

Selected roots may be symlinks and are resolved once. Managed descendant paths must contain regular files and directories. Capture and restoration reject descendant symlinks and Windows reparse points, including links whose targets remain inside the selected root. This preserves the identity of every recorded file. Source paths stay confined to the selected package. Restoration checks every destination and required before-image before changing any game files. It restores the original bytes even if the installed files were subsequently edited.

Uninstall also recognizes timestamped `YYYY-MM-DD_HH.MM.SS` relative-tree backups and their `remove these files.txt` list, with removals confined to the selected game. Original flattened TSLPatcher backups are supported only when the current instructions provide one unambiguous destination per saved filename. Unknown or ambiguous layouts fail without guessing. Legacy backups do not supply reliable original-existence information beyond their documented removal lists.

## Exit status

| Code | Meaning |
| --- | --- |
| 0 | Success, including warnings-only installation |
| 1 | Interactive cancellation, no selected game, or interactive installation failure |
| 2 | Invalid arguments, game path, or action count |
| 3 | Mod or namespace configuration not found/invalid |
| 4 | Namespace index outside the available choices |
| 5 | Selected instruction missing or outside confinement |
| 6 | Installation blocked by configuration/path/required-file preflight |
| 7 | Engine exception, failed restoration, or blocking validation finding |
| 8 | Installation completed with reported errors |

The startup order is mod, namespaces, selected instruction, action count, game, then action execution. A prior failure therefore takes precedence over a later argument or action error.
