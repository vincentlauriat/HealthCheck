# Configurer la synchro Withings

La synchro directe lit le cloud Withings, y compris les métriques que
HealthKit ne connaît pas (muscle, eau, os, graisse viscérale) et les
pesées plus récentes que le dernier export Apple Santé.

## 1. Créer l'app développeur (une seule fois)

1. Aller sur [developer.withings.com](https://developer.withings.com)
   → « Log In to Withings Partner Hub » avec ton compte Withings
   habituel (gratuit).
2. Créer une application de type **Public API integration**.
3. Renseigner comme **callback URL**, exactement :
   `http://localhost:8723/callback`
4. Noter le **Client ID** et le **Client Secret**.

## 2. Installer les identifiants

Créer le fichier
`~/Library/Application Support/HealthCheck/withings.json` :

```json
{
  "clientId": "<ton client id>",
  "clientSecret": "<ton client secret>",
  "redirectURI": "http://localhost:8723/callback"
}
```

```bash
chmod 600 "~/Library/Application Support/HealthCheck/withings.json"
```

Ce fichier ne doit jamais entrer dans un dépôt git.

## 3. Connecter et synchroniser

Dans l'app : **Données** → carte **Withings** → **Connecter Withings**.
Le navigateur s'ouvre sur la page d'autorisation Withings ; après
accord, une page « Withings connecté ✅ » confirme et l'app récupère
les jetons. Cliquer ensuite **Synchroniser** (la première synchro tire
tout l'historique de la balance).

Ensuite, l'app se synchronise toute seule au lancement (au plus une
fois par 12 h). Resynchroniser ne crée jamais de doublons.

## Dépannage

| Symptôme | Cause probable |
|---|---|
| Carte « Non configuré » | `withings.json` absent ou JSON invalide |
| La page d'autorisation affiche une erreur | callback URL de l'app développeur ≠ `http://localhost:8723/callback` |
| « Autorisation échouée : state inattendu » | retour d'une vieille tentative — recliquer Connecter |
| Erreur API statut 401 après longtemps sans lancer l'app | refresh token expiré (1 an) — Déconnecter puis reconnecter |

Les jetons vivent dans
`~/Library/Application Support/HealthCheck/withings-tokens.json` ;
supprimer ce fichier équivaut à « Déconnecter ».
