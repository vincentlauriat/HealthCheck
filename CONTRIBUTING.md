# Contribuer

HealthCheck est un projet personnel, publié en source ouverte par
souci de transparence — ce n'est pas un produit avec une équipe
dédiée. Les issues et pull requests sont bienvenues, mais peuvent
rester sans réponse : n'y compte pas pour un usage critique.

## Builder et tester

Voir le README : [Compiler depuis les sources](README.md#compiler-depuis-les-sources)
et [Tests](README.md#tests).

`HealthCheck.xcodeproj` est généré par [XcodeGen](https://github.com/yonaskolb/XcodeGen)
à partir de `project.yml` et ne doit **jamais** être committé (il est
gitignored). Après tout ajout ou retrait de fichier, relancer
`xcodegen generate` avant de rouvrir le projet.

## Convention de commit

Conventional commits, sujets en anglais, au présent (`add`, `fix`,
`update`…).

## La règle qui compte le plus

Toute modification d'un moteur d'analyse (scores, zones, corrélations,
plan d'entraînement, etc.) doit venir avec un test qui a été **vu
échouer** contre le bug qu'il prétend attraper — pas seulement écrit
puis passé du premier coup. C'est la règle forte de ce projet, et elle
n'est pas négociable : un test qui n'a jamais échoué ne prouve rien
sur ce qu'il est censé détecter.
