# Politique de sécurité

HealthCheck stocke l'historique de santé complet d'une personne dans
une base SQLite locale et ouvre un serveur HTTP sur le réseau local
pour synchroniser avec l'app compagnon iOS. Ce document décrit ce qui
est couvert et comment signaler un problème.

## Signaler une vulnérabilité

Ouvrir une [issue GitHub](https://github.com/vincentlauriat/HealthCheck/issues) —
c'est un projet personnel, ce niveau suffit. Décrire le problème et,
si possible, comment le reproduire. Ce dépôt n'a pas de politique de
divulgation avec délai garanti : l'auteur traite les signalements de
son mieux, sans engagement de temps de réponse.

## Périmètre

- L'import de l'export Apple Santé (zip), le parseur GPX et le client
  Withings, qui traitent tous des fichiers ou réponses réseau
  potentiellement mal formés.
- Le serveur de synchro compagnon (`HealthCheck/Import/SyncServer.swift`,
  `CompanionRouter.swift`, `SyncHTTP.swift`) et son protocole
  d'appairage (`CompanionPairing.swift`).
- Le stockage local (base SQLite, jetons Withings et compagnon dans
  `~/Library/Application Support/HealthCheck/`).

Est hors périmètre tout ce qui suppose un accès physique ou
administrateur déjà acquis à la machine — HealthCheck ne prétend pas
protéger des données contre quelqu'un qui contrôle déjà le Mac.

## Appairage et synchro compagnon

L'app compagnon iOS s'appaire au Mac via un code à 6 chiffres, valable
2 minutes et limité à 5 tentatives (`PairingManager`). Un appairage
réussi émet un jeton Bearer persistant, stocké :

- côté iPhone, dans le trousseau iOS (Keychain), via
  `Companion/Sync/KeychainTokenStore.swift` ;
- côté Mac, dans un fichier JSON (`companion-token.json`) sous
  `~/Library/Application Support/HealthCheck/`, avec les permissions
  restreintes à l'utilisateur (`chmod 600`) — pas dans le trousseau
  macOS.

Le serveur de synchro (`SyncServer`, basé sur `NWListener`) écoute sur
un port éphémère et s'annonce uniquement en Bonjour sur le réseau
local (`_healthcheck._tcp`) ; l'app Mac est sandboxée
(`com.apple.security.app-sandbox`) avec les seules entitlements
réseau `network.client` et `network.server`. Il n'y a aucune exposition
volontaire au-delà du réseau local, aucun compte, aucune télémétrie.

## Ce qui n'est pas garanti

Ce projet n'a pas d'audit de sécurité formel ni de tests de pénétration
réguliers. Le parsing HTTP du serveur compagnon assume explicitement
qu'une seule requête est traitée par connexion (`Connection: close`) ;
tout changement vers du keep-alive nécessiterait de revoir cette
hypothèse (voir le commentaire dans `SyncHTTP.swift`).
