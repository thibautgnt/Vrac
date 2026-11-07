<h1 align="center">Vrac</h1>

Vrac montre où est passé l'espace du Mac et aide à en récupérer, sans jamais
rien supprimer d'autorité : tout passe par une liste à relire puis par la
Corbeille.

C'est un fork personnel de [Radix](https://github.com/colinvkim/Radix)
(licence MIT, voir `LICENSE`), qui apporte le scan rapide, la carte du disque
(sunburst et treemap), l'inspecteur, la recherche et la comparaison de scans.
Vrac y ajoute des salles inspirées de DiskBuddy :

- **Vue d'ensemble** : le disque d'un coup d'œil, ce qui est gardé en gris,
  ce qui est récupérable en couleur.
- **Nettoyage** : caches, journaux, fichiers de build, vieux installeurs et
  téléchargements.
- **Doublons** : fichiers identiques, comparés octet par octet.
- **Applications** : chaque app avec ses données, désinstallation complète,
  restes d'apps supprimées, éléments lancés au démarrage.
- **Compression** : vidéos en HEVC et photos en HEIC plutôt que supprimées.
- **Moniteur** : processeur, mémoire, ports et batterie en direct.

## Installer

```sh
make install   # compile en Release, signe avec le certificat perso, copie dans /Applications
```

La signature stable évite de redonner l'accès complet au disque à chaque
version. Mises à jour de l'amont : `git fetch upstream && git merge upstream/main`.

## Developer Documentation

<details>
<summary>View build instructions, project structure, and architecture</summary>

## Building from Source

Building Radix requires **Xcode 26 or later** with a Swift 6.2 toolchain.

Clone the repository and run the Swift package tests:

```bash
git clone https://github.com/colinvkim/Radix.git
cd Radix
swift test
```

Open `Radix.xcodeproj` in Xcode to build and run the complete app, or build it from the command line:

```bash
xcodebuild \
  -project Radix.xcodeproj \
  -scheme Radix \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

The SwiftPM package contains `RadixCore` and its Swift Testing suite. The shared Xcode scheme runs the same core tests: use **Product → Test** (Cmd-U), or replace `build` with `test` in the command above.

## Project Structure

```text
Radix/
├── Radix/                    # App and core source code
│   ├── App/                  # App entry point, commands, and window management
│   ├── Models/               # Scan targets, node records, snapshots, and safety models
│   ├── Services/             # Scanning, archives, comparison, geometry, and formatting
│   ├── ViewModels/           # Application state and UI coordination
│   ├── Features/
│   │   ├── Comparison/       # Scan comparison setup and results
│   │   ├── DiscardPile/      # Cleanup candidate review
│   │   ├── FileList/         # Sortable file browser
│   │   ├── Inspector/        # Single- and multiple-selection details and actions
│   │   ├── Onboarding/       # Welcome flow, permission guidance, and workspace tour
│   │   ├── Settings/         # Scan, visualization, and app preferences
│   │   ├── Sidebar/          # Smart Locations, recent scans, and Discard Pile
│   │   ├── Visualization/    # Sunburst and treemap views
│   │   └── Workspace/        # Main scanning and exploration interface
│   └── Shared/               # Reusable SwiftUI components and helpers
├── RadixCoreTests/           # Unit, integration, and benchmark-style tests
├── Package.swift             # RadixCore Swift package definition
└── Radix.xcodeproj/          # Complete macOS app project
```

## Architecture

- `ScanEngine` is an actor-based asynchronous scanner that uses iterative file-system traversal. `ScanCoordinator` owns scan state, while `IncrementalScanService` reuses prior results when it can safely reconcile filesystem changes.
- `AppModel` is the central `@MainActor` state and coordination layer for the application.
- `ScanSnapshot` and `FileTreeStore` represent scan results using flat tree storage and indexed lookups.
- Archive and comparison services stream, validate, and compare `.radixscan`
  snapshots. Format v5 losslessly compresses the large node and topology
  sections with LZFSE while retaining v3/v4 import compatibility.
- Sunburst and treemap services separate layout and interaction models from their SwiftUI presentation.
- `RadixCore` has no external Swift package dependencies. The app uses Sparkle for updates.

</details>

## Contributing

Contributions are welcome! Here's how to get started:

1. Fork the repository and create a feature branch. Before getting started, consider reviewing the developer documentation above for build instructions and an overview of the project’s structure and architecture.
2. Make your changes and add or update tests where appropriate. Keep them focused and well-documented.
3. Run `swift test`.
4. Open a pull request explaining what changed and why.

Use [Conventional Commits](https://www.conventionalcommits.org/) for commit messages and PR titles. If you're tackling something big, consider opening an issue first so the approach can be discussed.

## License

Radix is available under the [MIT License](LICENSE).
