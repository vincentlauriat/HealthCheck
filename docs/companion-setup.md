# Installer l'app compagnon iOS

L'app compagnon lit tes données Santé directement sur l'iPhone
(activité, cœur, sommeil, séances) et les envoie au Mac en réseau
local, sans passer par l'export zip manuel. Elle ne remplace pas
l'API Withings (muscle, eau, os, graisse viscérale) : les deux
sources coexistent.

## 1. Installer via Xcode

L'app n'est pas encore distribuée en dehors du dépôt (pas de
TestFlight). Installation par câble, avec le compte Apple Developer
payant déjà utilisé pour signer HealthCheck côté Mac (équipe
`KFLACS69T9`, pinnée dans `project.yml`) :

1. Cloner le dépôt et générer le projet (voir le README) :
   ```bash
   xcodegen generate
   open HealthCheck.xcodeproj
   ```
2. Sélectionner le scheme **HealthCheckCompanion** dans Xcode.
3. Brancher l'iPhone en USB (ou sur le même Wi-Fi avec le débogage
   sans fil déjà activé), le sélectionner comme destination.
4. Dans les réglages du projet → onglet **Signing & Capabilities** de
   la cible `HealthCheckCompanion` : vérifier que le compte Apple lié à
   l'équipe `KFLACS69T9` est bien connecté (Xcode → Réglages →
   Comptes). La signature automatique (`CODE_SIGN_STYLE: Automatic`)
   génère un profil de provisionnement valable **un an** (avantage de
   l'équipe payante) ; passé ce délai il faudra relancer un build
   depuis Xcode, câble branché, pour le renouveler.
5. Lancer (▶). Si iOS affiche « Développeur non approuvé » au premier
   lancement, aller dans **Réglages → Général → VPN et gestion de
   l'appareil** sur l'iPhone et faire confiance à l'identifiant Apple
   utilisé pour la signature.

## 2. Autoriser l'accès à Santé

Au premier lancement, iOS demande l'autorisation de lire les données
Santé (pas, distance, énergie active, minutes d'exercice, fréquence
cardiaque, FC repos, HRV, VO₂ max, sommeil, séances). Choisir
**Autoriser tout** — l'app ne demande que des autorisations de
lecture, jamais d'écriture.

## 3. Autorisation réseau local

Toujours au premier lancement (ou à la première synchro), iOS affiche
une invite **« HealthCheck Companion aimerait trouver et se connecter
aux appareils sur votre réseau local »** — c'est la permission
`NSLocalNetworkUsageDescription`/`NSBonjourServices` qui permet à
l'app de découvrir le Mac via Bonjour (`_healthcheck._tcp`). Refuser
cette invite empêche tout appairage et toute synchro : si elle a été
refusée par erreur, la réactiver dans **Réglages → HealthCheck
Companion → Réseau local**.

## 4. Appairer avec le Mac

1. Sur le Mac : ouvrir HealthCheck → écran **Données** → carte
   **iPhone** → **Appairer…**. Un code à 6 chiffres s'affiche,
   valable **2 minutes**, 5 tentatives maximum.
2. Sur l'iPhone : ouvrir l'app compagnon, saisir le code à 6 chiffres
   dans le champ de la section **Appairage**, puis **Appairer**.
3. En cas de succès, l'écran bascule sur la section **Synchronisation**
   avec un badge « Appairé ». Le jeton reçu est stocké dans le
   trousseau iOS (Keychain) — il n'est jamais visible ni exportable.

## 5. Synchroniser

- **Manuelle** : bouton **Synchroniser** dans l'app — pousse tout le
  delta HealthKit accumulé depuis la dernière synchro (la toute
  première synchro couvre les 30 derniers jours). Le résumé affiché
  après coup (« N échantillons envoyés, M nouveaux ») distingue le
  nombre d'échantillons transmis du nombre réellement inséré côté
  Mac — un M plus petit que N est normal, la déduplication du Mac
  ignore silencieusement les doublons déjà connus.
- **Arrière-plan** : iOS réveille l'app quand HealthKit note de
  nouvelles données (sommeil, FC repos, HRV, VO₂ max en priorité
  « immédiat » ; pas, distance, énergie, exercice, FC en priorité
  « horaire »). **Ce n'est pas une garantie de fraîcheur en temps
  réel** — iOS choisit librement le moment du réveil selon la
  batterie et l'usage de l'app, et peut le repousser de plusieurs
  heures si l'app n'est jamais ouverte au premier plan. Pour une
  synchro immédiate, utiliser le bouton manuel.
- Le Mac doit être **allumé, l'app HealthCheck ouverte, et l'iPhone
  sur le même réseau local** (Wi-Fi domestique). Aucune synchro n'est
  possible via le réseau cellulaire ou un VPN.

## Validation sur appareil

Les 41 tests XCTest du compagnon tournent en simulateur ; la découverte
Bonjour sur un vrai réseau et le timing du réveil en arrière-plan ne
s'y exercent pas. Après une installation ou une modification touchant
Bonjour, HealthKit ou le réveil en arrière-plan, coche cette liste sur
un iPhone physique :

- [ ] Installation réussie via Xcode (étape 1) sur un iPhone physique.
- [ ] Autorisation Santé accordée (étape 2) — toutes les données
      demandées apparaissent dans **Réglages → Santé → Accès aux
      données et à l'appareil → HealthCheck Companion**.
- [ ] Invite « Réseau local » acceptée (étape 3).
- [ ] Appairage réussi avec le code affiché sur le Mac (étape 4) —
      badge « Appairé » visible dans l'app.
- [ ] Première synchro manuelle effectuée — le compteur d'échantillons
      insérés augmente côté Mac (écran **Données** → carte iPhone).
- [ ] Redémarrage du Mac (nouveau port éphémère) suivi d'une synchro —
      la découverte Bonjour retrouve le Mac sans ré-appairage.
- [ ] Le lendemain matin, sans avoir rouvert l'app au premier plan, la
      date de dernière synchro a avancé toute seule (réveil en
      arrière-plan effectif).
- [ ] Le score de forme du jour est calculable sur le Mac à partir des
      seules données compagnon (sans export zip fait entre-temps).

## Dépannage

| Symptôme | Cause probable |
|---|---|
| « Mac introuvable » lors de l'appairage ou de la synchro | HealthCheck n'est pas ouvert sur le Mac, ou l'iPhone et le Mac ne sont pas sur le même réseau Wi-Fi (ex. l'iPhone est passé en 4G/5G) |
| « Code refusé » | code expiré (> 2 min) ou déjà utilisé 5 fois — relancer **Appairer…** côté Mac pour obtenir un nouveau code |
| « Le Mac ne reconnaît plus cet iPhone » après une synchro qui marchait avant | le jeton a été invalidé côté Mac (réinstallation, nouvel appairage d'un autre iPhone, etc.) — refaire l'appairage depuis l'étape 4 |
| L'invite réseau local n'apparaît jamais / la découverte échoue en boucle | permission réseau local refusée — vérifier **Réglages → HealthCheck Companion → Réseau local** sur l'iPhone |
| Rien ne se synchronise en arrière-plan | attendu par intermittence (voir §5) — utiliser le bouton manuel pour forcer une synchro |
| L'app refuse de se lancer, « Développeur non approuvé » | faire confiance au certificat depuis **Réglages → Général → VPN et gestion de l'appareil** sur l'iPhone |
| L'app cesse de se lancer après ~1 an | profil de provisionnement expiré (validité 1 an même avec l'équipe payante `KFLACS69T9`) — relancer un build depuis Xcode, câble branché |
