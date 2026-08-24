# Conventions du dépôt

Notes techniques pour quiconque travaille sur ce code — humain ou assistant.

## Tests : les deux cibles n'ont pas la même convention

Elles sont **opposées**, et c'est voulu.

```bash
# macOS — AVEC le drapeau : le projet construit non signé et la signature
# se fait à part dans Scripts/release.sh (xcodebuild en Release échoue sur
# les xattrs com.apple.provenance posées par lsregister).
xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

# iOS — SANS le drapeau : le passer laisse l'app hôte non signée, donc
# privée d'accès au trousseau, et tous les tests qui touchent le Keychain
# échouent en errSecMissingEntitlement (-34018).
xcodebuild test -scheme HealthCheckCompanion \
    -destination 'platform=iOS Simulator,name=<un simulateur qui existe>'
```

Lister les simulateurs disponibles plutôt qu'en supposer un :
`xcrun simctl list devices available`.

Un premier lancement après suppression de `build/` peut échouer pour des
raisons d'environnement (réinstallation dans le simulateur, dépendances à
re-résoudre). Relancer avant de conclure à une régression.

## Le projet Xcode est généré

`HealthCheck.xcodeproj` est produit par XcodeGen depuis `project.yml` et
**gitignoré** — ne jamais le committer. Après toute modification de
`project.yml`, ou après avoir ajouté un fichier source, lancer `xcodegen
generate`. Les sources sont déclarées par chemin, donc un fichier ajouté dans
un répertoire déjà déclaré est repris automatiquement.

Conséquence à connaître : le `Package.resolved` de SwiftPM vit à l'intérieur du
`.xcodeproj`, donc il n'est pas versionné. Sparkle est pour cette raison épinglé
en version **exacte** (`exactVersion`) et non en plancher : c'est la dépendance
dont le métier est de télécharger et d'installer du code.

## Un test de non-régression doit avoir été vu échouer

C'est la règle forte de ce dépôt. Un test censé attraper un bug précis n'est
accepté qu'après l'avoir **vu échouer** contre ce bug : muter le code pour le
réintroduire, constater l'échec, restaurer, constater le succès.

Ce n'est pas de la cérémonie. Cinq gardes de ce dépôt se lisaient correctement
et ne surveillaient rien ; aucune n'a été trouvée par relecture, les cinq l'ont
été en essayant de casser le code. Corollaire utile : quand une garde ne peut
pas être falsifiée par une mutation unique, c'est presque toujours que le test
l'atteint par un chemin dont les valeurs réelles ne franchissent jamais la
condition. Tester la fonction directement plutôt que de bâtir un scénario
bout-en-bout.

## Moteurs d'analyse

`HealthCheck/Analysis/` : des `enum` de `static func`, purs, sans état. `today:
Date` et `calendar: Calendar` sont **toujours** des paramètres, jamais lus dans
l'environnement — c'est ce qui rend les tests déterministes. Ne jamais appeler
`Date()` dans un test : ce dépôt a déjà connu des échecs à minuit et le lundi.

`docs/METHODOLOGY.md` documente chaque formule avec sa ligne source. Une
modification d'un seuil ou d'une fenêtre doit s'y refléter.

## Langue

Interface et messages utilisateur en **français**, avec les accents complets.
Identifiants de code, messages de commit et fichiers de documentation en
**anglais**. Commits conventionnels, sujets courts.
