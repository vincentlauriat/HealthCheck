# Méthodologie — comment les chiffres sont calculés

Ce document explique, pour chaque calcul de HealthCheck, quelle question il
répond, quelles données il consomme, quelle formule il applique — avec les
constantes réelles recopiées du code — et ce qu'il ne fait délibérément pas.

Il s'adresse à quiconque envisage de faire confiance à l'application ou de la
forker : un lecteur compétent mais nouveau sur le projet. Les sigles du
domaine (ACWR, charge aiguë/chronique, HRV, affûtage…) sont expliqués à leur
première apparition.

**Principe de rédaction : le code fait foi.** Chaque formule ci-dessous est
recopiée du fichier source cité entre parenthèses (`Fichier.swift:ligne`). En
cas de divergence entre ce document et le code, c'est le code qui a raison —
et si vous la repérez, ouvrez une issue. Les moteurs vivent dans
`HealthCheck/Analysis/` ; ce sont des `enum` de fonctions statiques pures :
aucune ne lit l'horloge ni le calendrier système, `today`/`now` et `calendar`
sont toujours des paramètres explicites, ce qui les rend testables au
centième et déterministes (mêmes entrées → même résultat, toujours).

Ce document ne décrit pas l'architecture de l'application (base de données,
import, synchro compagnon, écrans) — voir `ARCHITECTURE.md` pour cela. Il
décrit uniquement *comment les nombres affichés sont obtenus*.

---

## 1. Avant tout : la déduplication des sources

**Question :** quand la même mesure existe deux fois — captée par l'Apple
Watch et par l'iPhone au même moment — laquelle l'application garde-t-elle,
pour ne pas compter un pas ou une minute d'effort deux fois ?

**Entrées.** Tous les enregistrements HealthKit d'un même `type` (fréquence
cardiaque, sommeil, énergie active…), avant tout regroupement par jour. La
priorité entre sources est configurée une seule fois, au démarrage de
l'application :

```swift
let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])
```
(`HealthCheckApp.swift:41`)

**Calcul.** `SourcePriorityResolver.resolve` (`SourcePriorityResolver.swift`)
trie les enregistrements par date de début puis balaie la liste en ne
conservant, à tout instant, que les enregistrements « encore ouverts »
(dont la date de fin est postérieure au début du candidat courant) —
c'est ce qui rend l'algorithme linéaire plutôt que quadratique : un scan
naïf comparant chaque nouvel enregistrement à tous ceux déjà retenus gelait
plusieurs secondes sur les ~30 000 échantillons d'énergie d'un semestre. Pour
chaque nouvel enregistrement qui chevauche un enregistrement déjà retenu du
même `type`, l'arbitrage suit ces règles :

| Enregistrement existant | Candidat | Résultat |
|---|---|---|
| classé (rang *e* dans la liste de priorité) | classé, rang *c* < *e* (donc plus prioritaire) | le candidat remplace l'existant |
| non classé | classé | le candidat remplace l'existant |
| classé | non classé, ou classé mais rang ≥ *e* | l'existant reste |
| non classé | non classé | l'existant reste — c'est-à-dire le premier rencontré dans l'ordre de tri par date de début, un choix arbitraire, pas une mesure de qualité |

**Ce que la priorité couvre réellement.** Elle ne s'applique qu'aux
enregistrements dont l'intervalle `[startDate, endDate]` a une durée non
nulle et peut donc chevaucher un autre enregistrement : sommeil, énergie
active, distance, minutes d'exercice. Les mesures ponctuelles — fréquence
cardiaque continue, poids, composition corporelle — ont `startDate ==
endDate` ; deux échantillons ponctuels au même instant ne se « chevauchent »
jamais au sens de cet algorithme, donc l'arbitrage de priorité ne les
concerne pas en pratique (voir le commentaire à ce sujet dans
`ActivityViewModel.swift:43-46`). Sur ces séries, un doublon n'est pas
supprimé par ce mécanisme ; il n'a simplement aucun effet notable sur les
calculs en aval, qui font des moyennes ou des sommes par jour (§2).

**Ce qui n'est délibérément pas couvert.** La liste de priorité ne contient
que `"Watch"` et `"iPhone"`. Les mesures Withings (poids, % de graisse, masse
maigre, IMC — voir §7) arrivent avec `sourceName: "Withings"`
(`WithingsModels.swift:122`), qui n'apparaît dans aucune liste de priorité :
elles sont donc toujours « non classées ». Comme elles sont ponctuelles
(`startDate == endDate`, voir ci-dessus), ce n'est pas un problème observé en
pratique — mais si l'app venait à recevoir des plages Withings avec une
vraie durée, deux mesures Withings qui se chevauchent seraient départagées
arbitrairement, pas par qualité de la source.

---

## 2. Agrégation quotidienne — `DailyAggregator`

**Question :** comment transformer des centaines d'échantillons épars en un
point par jour, pour tracer une courbe ?

**Entrées.** Des `HealthRecord` déjà résolus par priorité de source
(l'appelant est censé avoir passé les enregistrements dans
`SourcePriorityResolver.resolve` avant — l'agrégateur lui-même ne
dédoublonne rien, voir le commentaire en tête du fichier).

**Calcul.** Deux fonctions, regroupant par jour calendaire
(`calendar.startOfDay`) :

```swift
averages: moyenne des valeurs du jour   // FC, poids, HRV — mesures ponctuelles
totals:   somme des valeurs du jour     // énergie, pas — mesures cumulatives
```
(`DailyAggregator.swift:7-21`)

**Seuils.** Aucun — c'est une pure fonction de regroupement, sans jugement de
qualité sur le nombre d'échantillons par jour (un jour avec un seul
échantillon de FC produit une « moyenne » sur cet unique point).

**Ce que ça ne fait pas.** Pas de pondération temporelle (un échantillon à
3 h du matin compte autant qu'un échantillon à 15 h dans la moyenne), pas de
filtrage des valeurs aberrantes.

---

## 3. Agrégation des nuits — `SleepAggregator`

**Question :** combien d'heures une nuit a-t-elle duré, à partir de segments
de sommeil bruts ?

**Entrées.** Des `SleepRecord` (déjà résolus par priorité de source, même
convention que `DailyAggregator`).

**Calcul.** Une « nuit » est définie comme le jour calendaire de
`startDate - 12 h` (`SleepAggregator.swift:12`) : un segment commençant à
23 h ou à 7 h du matin tombe dans la même nuit, ce qui évite qu'une session
23 h→7 h soit coupée en deux nuits par le changement de date à minuit. Seuls
les segments dont la valeur commence par `HKCategoryValueSleepAnalysisAsleep`
comptent — c'est-à-dire `Core`, `Deep`, `REM`, `Unspecified` (l'ancienne
valeur générique `Asleep` des exports pré-watchOS 9) — `InBed` et `Awake`
sont exclus de la durée. Les heures dormies d'une nuit sont la somme des
durées de ces segments.

**Seuils.** Aucun.

**Ce que ça ne fait pas.** Ne distingue pas les phases de sommeil (c'est le
rôle de `SleepScoreEngine`, §5) ; ne filtre pas les siestes — une sieste
l'après-midi tombe dans sa propre « nuit » (jour de son `startDate - 12 h`)
et apparaît comme un point à part dans la série, ce qui peut fausser une
moyenne glissante si elle est courte et isolée.

---

### Distance des séances : d'où elle vient

L'export d'Apple **ne porte pas** `totalDistance` en attribut de `<Workout>` —
vérifié le 2026-09-04 sur un export de 1 625 séances, aucune ne l'avait.
L'information vit dans des enfants
`<WorkoutStatistics type="HKQuantityTypeIdentifierDistanceWalkingRunning"
sum="…" unit="…"/>`, avec quatre variantes selon l'activité : marche/course
(1 262, km), vélo (40, km), natation (26, **m**), ski (1, km).

`HealthExportParser` ne lisait que l'attribut. Conséquence mesurée sur la base
réelle : **1 551 séances sur 1 582 sans distance** (98 %), dont 219 des 227
séances de course de l'Apple Watch. Ces séances-là ne comptent pas pour zéro —
`TrainingPlanner.distanceKm` retombe sur la durée à
`fallbackPaceMinutesPerKm = 7.0`, une allure fixe. La charge d'entraînement
courante n'était pas touchée (les 28 derniers jours viennent de la synchro
iPhone, qui porte la distance), mais toute analyse remontant avant août 2026
reposait sur cette allure supposée.

Corollaire important : la clé de dédoublonnage d'une séance
(`Workout.dedupKey`) ne dépend **ni** de la distance **ni** de l'énergie, et
`insertWorkouts` faisait un `INSERT OR IGNORE` — réimporter n'aurait donc rien
réparé. `insertWorkouts` complète désormais, en `COALESCE(existant, nouveau)`,
ce qui manque à une séance déjà connue : un import ne peut qu'ajouter de
l'information, jamais en effacer.

### Une distance ne se lit jamais sans son unité

Les quatre variantes ci-dessus ne partagent pas la même unité : **les nages
sont en mètres**, tout le reste en kilomètres (relevé le 2026-09-04 : 1 303
séances en km, 26 en m). Lire `totalDistance` brut afficherait un 1 500 m
comme « 1 500 km ».

`WorkoutStatsEngine.distanceKilometres` normalise, et c'est le seul chemin :
`TrainingPlanner.distanceKm` et `WorkoutsViewModel` passent par lui. Comme
`durationMinutes`, il rend `nil` sur une unité non reconnue plutôt qu'un
nombre dont on ignore l'échelle.

Le défaut était **latent** : les 31 séances qui portaient une distance avant
ce correctif venaient toutes de la synchro iPhone, que `HKMapper` convertit
en kilomètres. Il ne serait devenu visible qu'au premier réimport, sur les 25
nages de la base.

## 4. Score de forme quotidien — `HealthScoreEngine`

**Question :** « suis-je en forme aujourd'hui ? » — un score 0-100 façon
« recovery » (Whoop, Oura), qui compare chaque mesure du jour à la normale
personnelle plutôt qu'à un barème universel.

**Entrées.** Pour chaque composante, une valeur du jour et une **baseline** :
une fenêtre glissante d'environ 30 jours de valeurs passées (le choix de la
fenêtre et son contenu exact — quels jours, quelle source — sont décidés par
l'appelant, `DashboardViewModel.loadWellness()`, pas par le moteur lui-même,
qui reste agnostique de la fenêtre). Dans l'application telle qu'elle
tourne aujourd'hui : la baseline est la moyenne 30 jours (hors la valeur du
jour même), avec un minimum de 5 points pour être jugée significative
(`minimumBaselineCount = 5`, `HealthScoreEngine.swift:22`) — sous ce seuil,
la composante est absente plutôt que trompeuse.

**Calcul.** Quatre composantes, chacune une déviation à la baseline
transformée en score 0-100 (borné aux deux extrémités) :

```swift
// FC repos : au-dessus de la normale = mauvais signe
deviation = (aujourd'hui − moyenne) / moyenne
score = clamp(100 − deviation × 600, 0...100)     // +5 % → 70 ; +10 % → 40

// HRV (variabilité de la fréquence cardiaque, parfois abrégée VFC en
// français — l'app et ce document utilisent HRV, l'abréviation anglaise) :
// au-dessus de la normale = bon signe
score = clamp(100 + deviation × 300, 0...100)     // −10 % → 70

// Sommeil : la nuit dernière rapportée à la durée habituelle
score = clamp((nuit / moyenne) × 100, 0...100)    // nuit = baseline → 100

// Équilibre d'activité : écart absolu, dans les deux sens, à l'habitude
deviation = |(hier − moyenne) / moyenne|
score = clamp(100 − deviation × 120, 0...100)     // ±25 % → 70
```
(`HealthScoreEngine.swift:26-86`)

Le score global est la **moyenne pondérée des composantes disponibles**,
renormalisée sur les poids réellement présents — une métrique absente réduit
le panier de calcul, elle ne fait pas baisser la note :

| Composante | Poids |
|---|---|
| Sommeil | 0,35 |
| FC repos | 0,30 |
| HRV | 0,25 |
| Équilibre d'activité | 0,10 |

(`HealthScoreEngine.swift:88-107`)

Cette redistribution est **défendable mais invisible**, et c'est ce qui la rend
dangereuse : le 2026-09-03, faute de nuit enregistrée depuis le 25 août, le
score affichait 97/100 « Excellente forme » alors que sa composante la plus
lourde manquait et que son poids de 0,35 avait été réparti sur les trois
autres. `ReadinessScore` porte donc `missing` — les composantes non mesurées,
leur poids nominal et la raison de leur absence — et `ScoreComponent.share`,
la part réelle après redistribution. Les deux applications les affichent.

**Sensibilité à une journée incomplète.** « Aujourd'hui » est le dernier point
quotidien, c'est-à-dire la moyenne des échantillons *connus à cet instant*
(`WellnessOrchestrator.split`). Le score bouge donc au fil de la journée. Sur
les données réelles du 2026-09-02, avec un seul échantillon de VFC connu le
matin contre les neuf de la journée complète : **57,0 contre 95,4** — de
« Récupération conseillée » à « Excellente forme », mêmes données, même jour.
La cause est la saturation : la VFC matinale (17,4 ms) s'écarte tellement de la
normale (32,9) que sa composante tombe à 0, et sur un panier amputé du sommeil
elle pèse 38 %.

**Ce n'est pas, en revanche, la cause principale de l'écart Mac/iPhone.**
Mesuré le 2026-09-04 en faisant tourner `WellnessOrchestrator.compute` sur la
base réelle du Mac : **13,8 / « Récupération conseillée »**, avec *trois*
composantes absentes — sommeil (rien depuis le 25 août), FC repos et VFC
(rien depuis le 3 septembre au matin). La seule survivante est l'équilibre
d'activité, dont le poids nominal de **0,10 est redistribué à 100 %**.

Elle vaut 13,8 parce que « hier » (le 3) totalise 231 kcal contre 820
habituels — mais la base du Mac s'arrête au **3 septembre à 10 h 28**. Cette
journée n'est complète que dans le calendrier, pas dans les données :
`WellnessOrchestrator` retient « la veille, seul jour complet » par
`completeDays.filter { $0.date < startOfToday }`, un test de date qui ne
regarde pas l'heure du dernier échantillon. `DailyAggregator.totals` ne
renseigne pas `sampleCount` (à raison : sur un total il ne dit rien de la
fiabilité), donc **rien dans le chemin du score ne permet de distinguer une
vraie journée à 231 kcal d'une matinée tronquée**.

Le Mac n'affiche donc pas un score périmé mais plausible : il affiche un
verdict assuré fabriqué à partir d'une synchro interrompue en cours de
matinée. C'est un défaut de code, pas une simple péremption de données.

**Les deux correctifs, arrêtés le 2026-09-04.**

*Une journée n'est notée que si elle est close.* `WellnessOrchestrator`
retenait la veille sur le seul test `$0.date < startOfToday`. Il exige
désormais que la base connaisse quelque chose de **postérieur** à cette
journée — sans quoi rien ne dit où elle a été coupée. Le critère est factuel
et ne fixe aucune heure limite : un seuil horaire se tromperait sur une
journée qui finit tôt, et serait arbitraire là où celui-ci est vérifiable.

*Un score n'est annoncé que si la moitié du panier a été mesurée.*
`ReadinessScore.measuredWeight` porte `totalWeight` avant renormalisation —
la grandeur même que la redistribution effaçait, et dont l'effacement rendait
un panier de 0,10 indiscernable d'un panier complet.
`HealthScoreEngine.minimumMeasuredWeight = 0,50` en fixe le plancher.

En deçà, `isConclusive` est faux et **trois consommateurs se taisent** plutôt
qu'un seul : les deux vues affichent « Score indisponible » avec la part
réellement mesurée et la liste des composantes manquantes ; `DailyAdviceEngine`
ne rend aucun conseil du jour ; `TrainingLoadMonitor` n'émet plus son alerte
« Forme du jour basse ». Le score reste calculé et l'objet reste non-nul :
faire disparaître la carte aurait remplacé un chiffre faux par un silence
inexplicable.

Ce seuil est un **choix**, pas une mesure. Il a un coût visible : cinq gardes
du dépôt notaient un score sur la seule FC repos — 0,30 du panier — et ont dû
recevoir une seconde composante pour continuer d'observer ce qu'elles
vérifient. C'est précisément le signe que le changement mord.

`TrendPoint.sampleCount` et `ScoreComponent.sampleCount` portent donc la
profondeur de mesure jusqu'à l'écran (« 1 mesure », « 9 mesures »), dans les
deux applications — sur les **moyennes** seulement : sur un total (énergie),
le nombre d'échantillons ne dit rien de la fiabilité de la valeur. Le score n'est **pas** modifié : une composante assise sur
un seul échantillon pèse toujours autant qu'une assise sur neuf. Refuser de
noter en deçà d'un seuil reste une option ouverte, non tranchée — le seuil
serait arbitraire là où le compte affiché ne l'est pas. La mesure du
2026-09-04 ci-dessus donne cependant un cas limite concret : une composante à
0,10 de poids nominal portant 100 % du panier produit un verdict tranché à
partir de presque rien.

**Seuils du libellé final** (`HealthScoreEngine.swift:109-116`) :

| Score | Libellé |
|---|---|
| ≥ 85 | Excellente forme |
| 70 – 84 | Bonne forme |
| 50 – 69 | Forme correcte |
| < 50 | Récupération conseillée |

**Ce que ça ne fait pas.** Aucun de ces coefficients (600, 300, 120) n'est
une valeur clinique ou publiée dans une étude — ce sont des conventions
choisies pour produire des scores qui « se sentent » justes sur les données
d'un coureur amateur, au même titre que les scores propriétaires des montres
du commerce dont ce moteur s'inspire explicitement. Le moteur ne sait rien
d'un profil médical (âge, pathologie, médication) : un score bas signale un
écart à *votre propre* normale récente, pas un diagnostic. Il ne pondère pas
non plus par la confiance dans la baseline (5 points et 60 points comptent
pareil une fois le seuil minimum franchi).

---

## 5. Score de sommeil — `SleepScoreEngine`

**Question :** « comment était ma nuit ? » — un score par nuit, façon
Withings, qui juge la durée, la répartition par phase et la continuité.

**Entrées.** Des `SleepRecord` d'une nuit (même découpage « nuit = jour de
`startDate − 12 h` » que `SleepAggregator`, §3), en excluant seulement
`InBed` (`SleepScoreEngine.swift:26`) — contrairement à `SleepAggregator`,
les segments `Awake` sont conservés ici : ils ne comptent pas dans la durée
endormie, mais chaque segment `Awake` incrémente le compteur de réveils
utilisé pour le score de continuité.

**Calcul.** 100 points répartis en quatre volets :

```swift
targetHours = 8.0          // cible de durée
deepTargetShare = 0.15     // cible : sommeil profond ≥ 15 % du temps endormi
remTargetShare = 0.20      // cible : REM ≥ 20 % du temps endormi

durationRatio = min(asleep / 8.0, 1)
durationPoints   = durationRatio × 50
deepPoints       = min((deep / asleep) / 0.15, 1) × 20
remPoints        = min((rem  / asleep) / 0.20, 1) × 20
continuityPoints = max(0, 1 − réveils / 8) × 10
score = durée + profond + REM + continuité     // 50 + 20 + 20 + 10 = 100
```
(`SleepScoreEngine.swift:20-71`)

**Cas particulier — pas de données de phase.** Les nuits enregistrées sous
watchOS < 9 (avant l'introduction du suivi par phase) n'ont que la valeur
générique `Unspecified`, sans `Deep`/`REM` distincts. Le code le détecte
(`deep + rem == 0`) et note alors la nuit **sur la durée seule, rebasée sur
100** (`durationRatio × 100`) plutôt que sur 50 points — sinon ces nuits
plafonneraient injustement à 60 (le maximum atteignable sans les 40 points
de profond/REM), commentaire explicite du code
(`SleepScoreEngine.swift:16-19`).

**Seuils.** Les deux cibles de proportion (15 % profond, 20 % REM) et les
« 8 réveils = continuité nulle » sont des conventions de l'industrie du
sommeil grand public, pas des seuils cliniques validés individuellement pour
cette application.

**Ce que ça ne fait pas.** Ne distingue pas un réveil de 10 secondes d'un
réveil de 20 minutes — `awakeCount` compte des occurrences, pas des durées.
Ne croise pas la durée de sommeil avec l'heure de coucher ou l'heure de
réveil (régularité), une dimension absente du score.

---

## 6. Effort quotidien — `StrainEngine`

**Question :** « à quel point ma journée a-t-elle été physiquement
intense ? » — un score 0-100 dérivé du temps passé dans chaque zone de
fréquence cardiaque, sur toute la journée (pas seulement pendant une séance
de sport).

**Entrées.** Des échantillons de fréquence cardiaque continue de la journée,
et un `maxHeartRate` — **paramètre du moteur**, pas une valeur qu'il calcule
lui-même. Dans l'application telle qu'elle tourne aujourd'hui, cette FC max
est la valeur observée la plus haute sur les **2 dernières années**,
**bornée entre 140 et 210** bpm (`min(max(observedMax, 140), 210)`,
`ActivityViewModel.swift:35-40`) — une fourchette de plausibilité
physiologique, pas une formule d'âge (pas de « 220 − âge »). C'est une borne
de sécurité contre un artefact de capteur, pas une mesure clinique de FC
maximale.

**Calcul.** Chaque échantillon « couvre » l'intervalle jusqu'au suivant,
plafonné à 5 minutes (`maxSampleGapMinutes = 5.0`,
`StrainEngine.swift:21`) pour ne pas sur-compter un trou de mesure (capteur
retiré, batterie vide). Les zones et leurs poids :

```swift
zoneLowerBounds = [0.50, 0.60, 0.70, 0.80, 0.90]  // fraction de FC max
zoneWeights     = [1,    2,    4,    7,    10]    // Z1 … Z5
```
(`StrainEngine.swift:19-20`)

La charge pondérée de la journée est la somme, sur les cinq zones, de
`minutes × poids`. Le score est cette charge rapportée à `fullScoreLoad =
600.0`, la charge correspondant à un score de 100 :

```swift
score = min(chargePondérée / 600 × 100, 100)
```
(`StrainEngine.swift:23,46-47`) — le commentaire du fichier illustre :
≈ 60 min en Z4 (poids 7) donnent une charge de 420, soit un score de 70.

**Seuils du libellé** (`StrainEngine.swift:60-67`) :

| Score | Libellé |
|---|---|
| ≥ 70 | Effort intense |
| 40 – 69 | Effort soutenu |
| 15 – 39 | Effort modéré |
| < 15 | Journée légère |

**Ce que ça ne fait pas.** Les poids par zone (1/2/4/7/10) et le seuil de
600 sont calibrés pour « ressembler » aux scores d'effort des trackers du
commerce (Whoop, Bevel), pas dérivés d'un modèle physiologique publié. Le
score ne distingue pas l'origine de l'élévation de fréquence cardiaque —
effort sportif, stress, chaleur, fièvre comptent identiquement.

---

## 7. Composition corporelle — `BodyCompositionEngine`

**Question :** comment se répartit le poids entre masse grasse et masse
maigre, et comment cette masse maigre se décompose-t-elle (muscle, os) ?

**Entrées.** Des séries journalières de poids, part de graisse, masse maigre
et IMC — typiquement produites par `DailyAggregator.averages` (§2) à partir
de mesures HealthKit et/ou Withings (voir §1 pour la note sur la source
Withings, non classée dans la priorité mais ponctuelle donc sans effet
pratique).

**Calcul.**

```swift
fatMass = weight × fatShare     // fatShare en fraction, 0,25 = 25 %
```
(`BodyCompositionEngine.swift:14`) — **`fatMass` est dérivée, jamais
mesurée directement** : la balance Withings ne synchronise vers Apple Santé
que le poids, le % de graisse, la masse maigre et l'IMC ; la masse grasse en
kilogrammes est recalculée en la multipliant par le poids du jour
(`BodyCompositionEngine.swift:3-6`).

Les photographies journalières (`dailySnapshots`) sont jointes **sur les
jours où un poids existe** — sans poids, ni la masse grasse en kg ni l'IMC ne
sont interprétables (`BodyCompositionEngine.swift:18-19`). Un « delta il y a
N jours » (utilisé par exemple pour `weightDelta30d`, §8) prend la
photographie la plus récente à cette date ou avant, puisqu'on ne se pèse pas
tous les jours (`BodyCompositionEngine.swift:44-48`).

**Le diagramme de Sankey de répartition du poids** (`weightSankey`,
`BodyCompositionEngine.swift:55-84`) construit un arbre à deux niveaux :

```
Poids total → Masse maigre + Masse grasse
Masse maigre → Muscle + Os + Autres tissus   (si la balance fournit muscle et/ou os)
```

« Autres tissus » (organes, peau…) est le reste : `masse maigre − muscle −
os`, affiché seulement s'il dépasse 50 g (`rest > 0.05`,
`BodyCompositionEngine.swift:77`) — sinon négligeable ou révélateur d'une
incohérence (muscle + os > masse maigre, mesures peut-être de jours
différents). Le niveau 2 n'apparaît pas du tout si la balance ne fournit ni
muscle ni os ce jour-là.

**Ce que ça ne fait pas.** L'**eau corporelle, bien que remontée par
Withings, n'apparaît jamais dans l'arbre** : elle est transversale (contenue
dans le muscle et les organes) et ne s'additionne pas aux autres
compartiments sans double-compte — un choix de représentation explicite,
pas un oubli (`BodyCompositionEngine.swift:50-54`). La graisse viscérale
(indice Withings sans unité physique) n'a pas non plus de place dans cet
arbre en kilogrammes.

---

## 8. Observations en langage naturel — `InsightsEngine`

**Question :** quelles phrases générer automatiquement pour résumer ce qui
change dans les données récentes ?

**Entrées.** Une structure `InsightInputs` **déjà entièrement pré-agrégée** —
le moteur ne fait aucune requête ni aucun calcul de fenêtre lui-même, il ne
fait que du raisonnement sur des nombres qu'on lui donne
(`InsightsEngine.swift:12-13`). Les fenêtres réellement utilisées aujourd'hui
sont décidées par `DashboardViewModel.loadWellness()` :

| Entrée | Fenêtre / définition réelle | Source |
|---|---|---|
| `restingHRMean7` / `restingHRMean30` | moyenne des moyennes journalières sur 7 j / 30 j | `DashboardViewModel.swift:75-76` |
| `sleepHoursMean7` | moyenne sur 7 j, seulement si ≥ 3 nuits trackées | `DashboardViewModel.swift:80` |
| `stepsThisWeek` / `stepsLastWeek` | semaine glissante en cours vs même **portion écoulée** de la semaine précédente (mercredi 15 h se compare au mercredi 15 h passé, pas à la semaine complète) | `DashboardViewModel.swift:49-60` |
| `vo2Latest` / `vo2ThreeMonthsAgo` | dernier point vs premier point d'une fenêtre de 90 jours | `HealthCheckShared/Analysis/WellnessOrchestrator.swift:73-74` (partagé macOS/Companion, cf. `DashboardViewModel.swift:83`) |
| `weightDelta30d` | dernière moyenne journalière − première moyenne journalière sur 30 j | `DashboardViewModel.swift:85-88` |

**Calcul.** Six règles indépendantes, chacune produisant zéro ou une
observation :

| Règle | Seuil | Sentiment |
|---|---|---|
| FC repos 7 j vs 30 j | ≥ +3 % | avertissement (« FC repos élevée ») |
| | ≤ −3 % | positif (« FC repos en baisse ») |
| Sommeil moyen 7 j | < 7 h | avertissement (« dette de sommeil ») |
| | ≥ 7,5 h | positif (« sommeil solide ») |
| Pas, semaine vs semaine (portion égale) | ≥ +20 % | positif |
| | ≤ −20 % | neutre |
| VO₂ max, 3 derniers mois | delta ≥ +1 ml/kg/min | positif |
| Poids, 30 j | \|delta\| ≥ 1 kg | neutre |

(`InsightsEngine.swift:28-104`) Les observations sont triées : avertissements
d'abord, puis positives, puis neutres (`InsightsEngine.swift:106-107`) — il
n'y a pas de note explicite pour une baisse de VO₂ max, seule la progression
est signalée.

**Ce que ça ne fait pas.** Aucune détection de tendance statistique (pas de
régression, pas de test de significativité) — chaque règle compare deux
nombres à un seuil fixe. Une seule mauvaise nuit isolée peut suffire à faire
passer `sleepHoursMean7` sous 7 h si le reste de la semaine est déjà
limite ; le garde-fou des « ≥ 3 nuits trackées » protège contre l'absence de
données, pas contre un échantillon de 3 nuits statistiquement fragile.

---

## 9. Corrélations — `CorrelationEngine`

**Question :** « est-ce que mieux dormir améliore ma récupération le
lendemain ? » — mesurer si deux séries journalières varient ensemble, avec
un décalage temporel configurable.

**Entrées.** Deux séries `TrendPoint` (typiquement issues de
`DailyAggregator`, §2) et un décalage en jours (`lagDays`).

**Calcul.** L'alignement (`align`) apparie la valeur de `x` au jour D à la
valeur de `y` au jour D + `lagDays` — seuls les jours où les deux existent
produisent une paire (`CorrelationEngine.swift:42-50`). Le coefficient est le
r de Pearson standard :

```swift
r = covariance(x, y) / √(variance(x) × variance(y))
```
(`CorrelationEngine.swift:24-37`)

**Seuils.**

| Condition | Comportement |
|---|---|
| Moins de `minimumPairs = 10` paires | `nil` — aucun coefficient affiché |
| Variance nulle sur x ou y (série constante) | `nil` — la corrélation n'est pas définie |
| \|r\| ≥ 0,6 | qualifiée « forte » |
| 0,4 ≤ \|r\| < 0,6 | « modérée » |
| 0,2 ≤ \|r\| < 0,4 | « faible » |
| \|r\| < 0,2 | « négligeable » |

(`CorrelationEngine.swift:17-67`) Le seuil de 10 paires et les bandes de
qualification sont des conventions usuelles en physiologie de terrain, pas
un calcul de puissance statistique propre à cette application — avec 10
paires, un r de Pearson reste bruité, et l'app choisit délibérément de ne
rien afficher plutôt qu'une fausse certitude en dessous (commentaire
explicite, `CorrelationEngine.swift:18-19`).

**Ce que ça ne fait pas.** Un r de Pearson mesure une association linéaire,
pas une causalité — l'application l'affiche avec cet avertissement à
l'écran (voir `README.md`). Le moteur ne corrige pas non plus pour les
comparaisons multiples : tester plusieurs paires de métriques augmente la
chance de trouver un r élevé par hasard, et rien dans ce moteur n'en tient
compte.

---

## 10. Statistiques d'entraînement — `WorkoutStatsEngine`

**Question :** combien de temps par activité et par semaine, tous sports
confondus ?

**Entrées.** Les `Workout` bruts (pas de résolution de priorité de source ici
— les séances sont déjà des lignes uniques, sans chevauchement à
arbitrer, contrairement aux séries continues du §1).

**Calcul.** La durée est normalisée quelle que soit l'unité stockée dans
l'export :

```swift
"min"       → duration
"s" / "sec" → duration / 60
"hr" / "h"  → duration × 60
autre       → nil                 // jamais de nombre fabriqué
```
(`WorkoutStatsEngine.swift:74-81`) Une unité non reconnue rend `nil` — la
fonction ne convertit rien plutôt que de supposer silencieusement que
`duration` est déjà en minutes. Chaque appelant décide explicitement de ce
que « pas de durée exploitable » signifie pour lui : `weeklyVolumes` et le
total de la semaine affiché à l'écran font contribuer 0 minute à la séance
concernée (une omission visible plutôt qu'un chiffre inventé), et
`TrainingPlanner.distanceKm` (§11.1) fait de même pour le kilométrage plutôt
que d'estimer une distance à partir d'une durée qu'on n'a pas pu interpréter.

`weeklyVolumes` regroupe les séances par semaine et par type d'activité
traduit en français (une table de 20 libellés,
`WorkoutStatsEngine.swift:15-36`, repli sur l'identifiant HealthKit sans son
préfixe `HKWorkoutActivityType` pour un type non traduit). Les semaines sans
séance sont incluses (minutes à zéro) pour que le graphique ne saute pas de
colonne.

**Une seule définition de « semaine » dans tout le projet.** `weeklyVolumes`
découpe les semaines via `TrainingPlanner.monday`
(`WorkoutStatsEngine.swift:92-111`) — la même fonction, ancrée au lundi de
façon *indépendante* du
`firstWeekday` du `Calendar` reçu, qu'utilisent les moteurs d'entraînement
(§11-13, `TrainingPlanner.swift:130-136`). Ce n'a pas toujours été le cas :
`weeklyVolumes` découpait auparavant les semaines avec
`calendar.dateInterval(of: .weekOfYear, for:)`, qui suit le `firstWeekday` de
la locale de l'appareil. Sur un appareil réglé en français (semaine
commençant le lundi), les deux découpages coïncidaient et le bug restait
invisible ; sur un appareil réglé en anglais américain (semaine commençant
le dimanche), un dimanche couru aurait rejoint des semaines différentes selon
l'écran consulté — le graphique de volume hebdomadaire et l'onglet
Entraînement auraient pu afficher deux totaux « cette semaine » différents
pour le même historique.

---

## 11. Le plan d'entraînement — `TrainingPlanner`

C'est le moteur le plus dense du projet ; sa conception complète est
documentée dans `docs/superpowers/specs/2026-08-23-training-plans-design.md`
(notamment §5.2 et §5.2bis, qui font foi sur les intentions de conception —
les valeurs ci-dessous sont recopiées du code réellement exécuté).

**Question :** « combien courir cette semaine, et quelles séances, pour
arriver à ma course en forme sans me blesser ? » — un plan hebdomadaire
déterministe, recalculé à chaque affichage à partir de l'objectif et de
l'historique réel de course, jamais persisté (`TrainingPlanner.swift:79-81`)
— donc il ne peut jamais se désynchroniser de ce qui a réellement été couru.

### 11.1 Lecture de la charge et repli de distance

Deux définitions de charge, réutilisées telles quelles par
`TrainingLoadMonitor` (§12) — **une seule définition, partagée entre les deux
moteurs**, pour que le plan et le moniteur ne puissent jamais diverger sur ce
qu'ils appellent « charge » :

```swift
acuteKm         = somme des km courus sur les 7 derniers jours (aujourd'hui inclus)
chronicWeeklyKm = somme des km courus sur les 28 derniers jours / 4
```
(`TrainingPlanner.swift:109-126`)

**La distance d'une séance sans distance mesurée est une estimation, pas une
mesure — et seulement quand l'estimation est possible.** Certaines séances
importées (anciens imports Strava) n'ont pas de distance ; le repli est
`durationMinutes / 7.0`, une hypothèse d'allure confortable à 7:00 min/km
(`fallbackPaceMinutesPerKm = 7.0`, `TrainingPlanner.swift:89,103-107`). Si la
séance n'a ni distance mesurée **ni** durée exploitable — `durationMinutes`
rend `nil` pour une unité non reconnue (§10) — la séance contribue **0 km**
plutôt qu'un chiffre fabriqué à partir d'une unité qu'on ne comprend pas : un
0 rate silencieusement une séance dans le calcul de charge, mais une distance
inventée aurait faussé la base d'ancrage qui détermine tout l'arc du plan.
Ce même repli est utilisé partout où une distance de séance est lue — charge
aiguë, charge chronique, appariement des séances (§13) — pour qu'il n'existe
qu'une seule définition de « la distance d'une séance » dans tout le projet.

### 11.2 L'ancrage : ce qui est fixé une fois, ce qui suit la réalité

C'est la partie la plus subtile du moteur, et celle que le code documente le
plus abondamment (`TrainingPlanner.swift:146-182`, §5.2bis de la spec) parce
qu'une première implémentation s'était trompée trois fois de suite sur le
même problème : une quantité censée être fixée une fois était recalculée
depuis `today` à chaque reconstruction.

**Le lundi de la première semaine de construction** (`firstBuildMonday`) est
lu sur `goal.createdAt`, **jamais sur `today`** :

```swift
creationMonday = lundi de la semaine de création
takesTargets   = jours restants dans la semaine de création ≥ minimumDaysForTargets (3)
candidate      = takesTargets ? creationMonday : creationMonday + 7 jours
```
(`TrainingPlanner.swift:158-164`) — sauf un cas limite : si l'objectif est
créé le samedi ou le dimanche qui précède immédiatement sa propre course, ce
qui rendrait `candidate` postérieur au lundi de la course, le moteur revient
à `creationMonday` pour que la semaine de course existe quand même
(`TrainingPlanner.swift:165-170`).

Pourquoi ne jamais relire `today` : si la séquence de semaines dépendait de
la date du jour, l'horizon rétrécirait à mesure que la course approche,
jusqu'à tomber dans la branche « objectif de maintien » à deux semaines
(§11.4) même pour un plan initialement long, et l'affûtage disparaîtrait.
**Conséquence assumée : supprimer puis recréer un objectif redémarre tout
l'arc depuis la charge du moment** — un acte explicite de l'utilisateur, pas
un effet de bord silencieux.

Le tableau ci-dessous (repris du code, `TrainingPlanner.swift:146-320`)
résume ce qui est figé à la création contre ce qui se relit à chaque
affichage :

| Quantité | Ancrée sur | Se relit à chaque affichage ? |
|---|---|---|
| Séquence des lundis du plan | `goal.createdAt` | Non |
| Rôle de chaque semaine (construction / pic / affûtage / course) | position par rapport au lundi de la course | Non |
| Cible d'une semaine **passée ou en cours** | charge mesurée avant son lundi, plafonnée par la cible de la semaine précédente | Oui, mais seulement tant que la semaine n'est pas terminée |
| Cible d'une semaine **future** | cible de la semaine précédente × facteur, **aucune lecture de charge** | Non — projection pure |
| La base d'ancrage (`anchorBaseKm`) et le facteur de rampe (`rampFactor`) | charge mesurée avant la première semaine de construction | Non, calculés une seule fois |

### 11.3 La base d'ancrage et le facteur de progression

```swift
anchorBaseKm = max(measuredBaseKm(avant firstMonday), minimumStartVolumeKm)  // 10.0 km
rampFactor   = anchorBaseKm < goal.distanceKm ? 1.15 : 1.10
              // comebackRampFactor         steadyRampFactor
```
(`TrainingPlanner.swift:83-85,214-216`) où `measuredBaseKm` est
`max(chronicWeeklyKm, acuteKm)` mesurée strictement avant le lundi considéré
(`TrainingPlanner.swift:177-182`) — le plus favorable des deux lectures
crédite la semaine de reprise déjà en cours (`acuteKm`) sans réinitialiser un
coureur déjà entraîné à un volume débutant (`chronicWeeklyKm`).

**Le facteur choisi à l'ancrage ne change plus ensuite pour ce plan** : 1,15
si la base de départ est encore sous la distance de l'objectif (une reprise
qui reconstruit vers un niveau connu tolère une progression un peu plus
rapide), sinon 1,10. `TrainingPlan.rampFactor` et `.anchorBaseKm` sont
exposés sur le résultat précisément pour que l'écran explique le plan sans
recalculer cet ancrage (`TrainingPlanner.swift:47-53`).

Chaque semaine de montée applique ce facteur, plafonné pour que la **semaine
de pic** ne dépasse jamais `goal.distanceKm × 1,5` (`volumeCap`,
`peakVolumeMultiplier = 1.5`, `TrainingPlanner.swift:86,232,294`).

### 11.4 La règle de non-rattrapage — et son absence de plancher

Pour chaque semaine de montée (construction ou pic), la base à partir de
laquelle le facteur s'applique dépend de si la semaine est passée/en cours
ou future :

```swift
// semaine passée ou en cours (monday <= currentMonday)
base = min(measuredBaseKm(avant son lundi), previousTarget)

// semaine future
base = previousTarget          // aucune lecture de charge

target = min(base × rampFactor, volumeCap)
```
(`TrainingPlanner.swift:274-294`) C'est la règle de non-rattrapage : une
semaine courue en dessous de sa cible re-base les semaines suivantes vers le
bas (le `min` avec la charge mesurée) ; une semaine dépassée ne les remonte
jamais au-delà de la progression normale (le `min` avec `previousTarget`
plafonne aussi dans l'autre sens).

**Cette règle n'a aucun plancher — assumé, pas un oubli.** Sur le cas d'or
de la spec (§5.2bis) : un plan de 14,49 / 16,66 / 19,16 / 14,37 / 9,58 km
devient, si **une seule** semaine est manquée,
14,49 / 3,62 / 4,17 / 3,12 / 2,08 km — un **effondrement de 78 %** — parce
que la base d'ancrage venait de la charge aiguë (12,6 km) alors que la charge
chronique n'était que de 3,15 km, et qu'une semaine vide ramène l'aiguë à
zéro. Le choix documenté est de garder ce rebasage et de le **signaler**
(`TrainingLoadMonitor`, §12) plutôt que d'ajouter un plancher, qui
décrocherait le plan de la réalité — la propriété même que tout ce mécanisme
existe pour préserver.

### 11.5 Le pic, l'affûtage, et la branche de maintien

Le pic est toujours à *course − 2 semaines*
(`peakIndex = mondays.count - 3`, `TrainingPlanner.swift:268`). Après le
pic :

```swift
raceWeek = peakVolume × raceWeekFactor   // 0.5
taper     = peakVolume × taperFactor      // 0.75  (l'affûtage : réduire le
                                           //  volume avant la course pour
                                           //  arriver frais)
```
(`TrainingPlanner.swift:88,297-303`)

**Cas particulier : objectif créé à ≤ 2 semaines de la course.** Toutes les
semaines restantes sont des semaines d'affûtage — y compris ce qui serait la
semaine de course :

```swift
target = anchorBaseKm × taperFactor    // 0.75, pour TOUTES les semaines,
                                        // semaine de course comprise
```
(`TrainingPlanner.swift:244-265`) **Cette semaine de course-là n'utilise donc
pas `raceWeekFactor` (0,5) comme dans le déroulé normal — elle reste à
`× 0,75` comme le reste de la branche de maintien**, alors même qu'elle porte
le rôle `.raceWeek`. C'est délibéré et testé : il n'y a jamais eu de semaine de
pic dans cette branche, donc rien dont `raceWeekFactor` pourrait prendre la
moitié. Un commentaire à cet endroit du code le dit explicitement, pour que
la prochaine personne à lire cette ligne ne « corrige » pas ce qui ressemble
à une incohérence entre le rôle et le facteur. Le test
`test_plan_raceTooClose_isTaperOnlyAndNeverRamps`
(`TrainingPlannerTests.swift:161-177`) pin à la fois la borne large
(`targetKm <= startVolume × 0,75`, insuffisante à elle seule pour distinguer
0,75 de 0,5) et, depuis ce correctif, la valeur exacte de la semaine
`.raceWeek` — `anchorBaseKm × taperFactor` précisément, pas
`anchorBaseKm × raceWeekFactor` — pour que toute confusion future entre les
deux facteurs fasse échouer ce test plutôt que de passer inaperçue.
`isMaintenance = true` marque ce cas sur `TrainingPlan`, et l'écran affiche
un avertissement dédié.

### 11.6 Les séances de la semaine

Chaque semaine non-affûtage porte trois séances « cœur » plus une
optionnelle. Le partage du volume :

```swift
longRunShare  = 0.60   // sortie longue : jusqu'à 60 % du volume de la semaine
hillsShare    = 0.25   // côtes : 25 %
baseEndurance = reste (volume − longue − côtes), plancher minimumBaseKm = 3.0 km
```
(`TrainingPlanner.swift:324-327,374-422`)

**Sortie longue :**

```swift
longKm = min(
    targetKm × 0.60,
    previousLongKm + longRunWeeklyGrowthKm,   // 2.5 km/semaine max
    min(14.0, goal.distanceKm × 0.8)          // plafond absolu
)
if affûtage: longKm = min(longKm, goal.distanceKm × 0.4)
```
(`TrainingPlanner.swift:377-380`) où `previousLongKm` part de la plus longue
sortie des 14 jours précédant la première semaine de construction (repli
`defaultPreviousLongKm = 5.0` km si aucune, `TrainingPlanner.swift:341-350`)
et progresse ensuite semaine après semaine à partir de la sortie longue
*planifiée* de la semaine précédente — pas de la sortie réellement courue.

**Côtes :** cible de dénivelé qui grandit linéairement de
`firstWeekClimbM = 100` m (première semaine) jusqu'au pic
`peakClimb = min(maximumClimbM, elevationGainM × 0,75)`, plafonné à
`maximumClimbM = 300` m
(`TrainingPlanner.swift:304-311,329-330,240`) ; ×0,5 en affûtage ; nul en
semaine de course (remplacée par un « déverrouillage » de 15 minutes,
`legOpener`) et pendant la semaine de clôture (voir plus bas).

**Zones de fréquence cardiaque** (`TrainingPlanner.swift:332-334,382-384`) :

| Zone | Bornes (% de `hrMax`) |
|---|---|
| Facile | 60 – 75 % |
| Endurance | 70 – 80 % |
| Difficile (côtes) | 85 – 92 % |

`hrMax` est, ici aussi, un **paramètre** du moteur : dans l'application
telle qu'elle tourne, c'est le maximum observé sur les 180 derniers jours
(`hrMaxWindowDays = 180`, `TrainingViewModel.swift:34,90-92`), avec un repli
à 190 bpm si la requête ne renvoie rien (`defaultHRMax`,
`TrainingViewModel.swift:92`) — pas une formule d'âge, et pas la même fenêtre
que les 2 ans utilisés pour `StrainEngine` (§6) : les deux moteurs lisent la
FC max sur des horizons différents, choisis indépendamment par leurs
appelants respectifs.

**Séance optionnelle :** 30 minutes faciles, ajoutée sauf en semaine
d'affûtage, non comptée dans le volume cible de la semaine — une fois
réellement courue, elle compte comme n'importe quelle autre sortie dans la
charge exécutée (§12), mais pas dans la cible qu'elle est censée compléter.

**Note de cohérence interne.** La séance d'endurance fondamentale a un
plancher de 3 km même quand `targetKm − sortie longue − côtes` tombe
en dessous. Sur une petite semaine de reprise, ce plancher peut donc pousser
la somme réelle des trois séances cœur légèrement **au-dessus** du volume
cible affiché pour la semaine — le volume cible est un paramètre de calcul
des séances, pas une somme garantie exacte des séances qui en sortent.

### 11.7 Ce que ce moteur ne fait délibérément pas

- **Le dénivelé n'est jamais vérifié, seulement prescrit.** Vérifié dans le
  code au moment de la conception (§6.1 de la spec) : la table `workout`
  n'a aucune colonne d'altitude, les points de route échangés par le
  compagnon n'ont que latitude/longitude/horodatage, et les fichiers GPX
  écrits par le compagnon n'ont pas d'élément `<ele>`. **Aucune donnée
  d'élévation n'existe nulle part dans le pipeline.** La cible de dénivelé
  d'une séance de côtes est donc une instruction de coaching affichée à
  l'écran, jamais une valeur comparée à ce qui a été réellement couru — le
  critère « séance faite » (§13) se fonde uniquement sur la distance,
  identique à toute autre séance.
- **Aucune prescription d'allure** (min/km) — l'objectif v1 est le confort,
  pas un temps cible ; seules des zones de fréquence cardiaque sont
  prescrites.
- **Un seul objectif actif à la fois** : la course future la plus proche
  l'emporte, les autres sont ignorées tant qu'elle n'est pas passée
  (`RaceGoal.active`, `RaceGoal.swift:20-28`).
- Le kilométrage en côtes et en plat est traité identiquement dans le
  volume — la séance de côtes dédiée est le seul mécanisme d'équilibrage,
  il n'y a pas de métrique ajustée à la pente.

### 11.8 Alternance côtes / intervalles VO2max

Une semaine de montée en charge (`.build`/`.peak`) sur deux remplace sa
séance de côtes par une séance d'intervalles VO2max, dans une zone
cardiaque quasi-maximale (`hrRange(0.90, 0.97, hrMax:)`, au-dessus de la
zone `hard` 85–92 % des côtes). L'alternance est pilotée par
`weekIndexInRamp` — la position (base 0) de la semaine parmi toutes les
semaines `.build`/`.peak`, calculée par `TrainingPlanner.plan(...)`
(`TrainingPlanner.swift:316`) : index pair → côtes, index impair →
intervalles (`TrainingPlanner.swift:408-410`). La
première semaine de montée en charge (index 0) reste toujours en côtes.
`.taper`, `.raceWeek` et la semaine de clôture ne reçoivent jamais
d'intervalles.

`VO2MaxEngine` (`HealthCheckShared/Analysis/VO2MaxEngine.swift`) interprète
séparément la VO2max mesurée comme un signal de progression :

```swift
recentWindowDays = 30            // fenêtre récente, jusqu'à aujourd'hui inclus
priorWindowDays = 90             // fenêtre antérieure, immédiatement avant
meaningfulDeltaThreshold = 1.0   // mL/min·kg
```

`trend(records:today:calendar:)` retourne `nil` si l'une des deux fenêtres
n'a aucun échantillon — pas de seuil de volume minimal, les échantillons
VO2max étant déjà rares par nature (estimés par l'Apple Watch sur certaines
sorties GPS). `stagnationAlert(trend:chronicKm:)` retourne une alerte
(`.info` si stable, `.warning` si en baisse) seulement quand la charge
chronique atteint `TrainingLoadMonitor.meaningfulChronicKm` (8,0 km/semaine,
la même constante que le moniteur de charge, référencée et non dupliquée) —
en dessous, la stagnation n'est pas surprenante et ne mérite pas d'alerte.

---

## 12. Suivi de charge — `TrainingLoadMonitor`

**Question :** « est-ce que j'en fais trop, ou pas assez, par rapport à ce
qui est sûr ? » — deux régimes d'alerte selon qu'un objectif de course est
actif ou non.

**Entrées.** L'historique de course, le plan actif (optionnel), le score de
forme du jour (optionnel, §4), la date du jour et le calendrier.

**Calcul — sans plan actif : le ratio charge aiguë/chronique (ACWR).**
`ACWR` (*Acute:Chronic Workload Ratio*) est le rapport entre la charge des 7
derniers jours et la charge hebdomadaire moyenne des 28 derniers jours — les
mêmes `acuteKm`/`chronicWeeklyKm` que §11.1, une seule définition partagée
entre les deux moteurs :

```swift
acwr = acuteKm / chronicWeeklyKm
```

Ce ratio n'est calculé (non-`nil`) que si l'historique est jugé
« significatif » :

```swift
meaningful = weeksWithARun(28 derniers jours) >= 3  ||  chronicWeeklyKm >= 8.0
```
(`TrainingLoadMonitor.swift:44-49`, `minimumActiveWeeks = 3`,
`meaningfulChronicKm = 8.0`) où `weeksWithARun` compte les **semaines
distinctes** (lundi à lundi) contenant au moins une sortie sur les 28
derniers jours — un gros volume concentré sur une seule sortie ne suffit pas
à établir une base (`TrainingLoadMonitor.swift:131-139`). En dessous de ce
seuil, l'application affiche « Reprise en cours — l'indicateur de charge
s'activera après 3 semaines régulières » plutôt qu'un ratio trompeur : une
reprise affiche mécaniquement un ratio énorme (12,6 / 3,15 ≈ 4,0 pour le cas
d'or de la spec) qui est de l'arithmétique, pas un danger.

| Condition (sans plan) | Alerte |
|---|---|
| ACWR > 1,3 (`highRatio`) | avertissement : « Vous progressez trop vite — réduisez cette semaine » |
| ACWR < 0,8 (`lowRatio`) | info : « Vous pouvez en faire un peu plus » |

**Calcul — avec un plan actif : les alertes suivent le plan, pas l'ACWR
brut.** Le planificateur plafonne déjà la progression (§11.3) : une montée
conforme au plan est sûre par construction, et l'ACWR brut ne doit pas la
contredire — une reprise l'affiche mécaniquement énorme, ce qui serait
contradictoire avec une carte qui prescrit justement une reprise
progressive (`TrainingLoadMonitor.swift:16-21`). Les alertes comparent alors
le réalisé de la semaine à la **cible du plan** :

| Condition | Constante | Alerte |
|---|---|---|
| exécuté > 125 % de la cible | `overshootFactor = 1.25` | avertissement : « Vous dépassez le plan — tenez-vous-en aux séances prévues » |
| exécuté < 50 % de la cible **et** ≤ 2 jours restants dans la semaine | `behindFactor = 0.5`, `lateWeekDaysLeft = 2` | info : « Semaine en retard — elle ne sera pas rattrapée la semaine suivante » |
| forme du jour < 50 **et** une séance de côtes ou une sortie longue restent à faire | `lowReadinessScore = 50.0` | info : « Forme du jour basse — intervertissez avec une séance facile » |

(`TrainingLoadMonitor.swift:57-91`) L'ACWR reste **affiché** même quand un
plan est actif (à titre informatif), mais ne pilote plus l'alerte.

**Semaine de clôture : aucune alerte de charge ne se déclenche.** Ces trois
alertes (dépassement, retard, effondrement) sont explicitement sautées pour
la semaine `role == .currentWeekClosing` (§11.2) —
`TrainingLoadMonitor.swift:57-61` exclut ce rôle avant d'entrer dans la
branche « avec plan » — et comme un plan existe, la branche « sans plan »
(ACWR brut) ne s'applique pas non plus. Pendant la semaine de création d'un
objectif trop entamée pour recevoir des cibles, l'application ne surveille
donc littéralement aucune charge, ce qui est cohérent : cette semaine ne
porte aucune cible à laquelle comparer le réalisé.

**L'alerte d'effondrement de plan** (§11.4) est indépendante des précédentes
— une semaine peut être à la fois en retard et issue d'un arc effondré,
et les deux méritent d'être dites
(`TrainingLoadMonitor.swift:73-84`) :

```swift
collapseFactor = 0.6
hasCollapsed = current.role et previous.role sont tous deux des semaines
               de montée (.build ou .peak)  &&  current.targetKm < previous.targetKm × 0.6
```
(`TrainingLoadMonitor.swift:39,110-122`) Seules les semaines de montée sont
concernées : un relâchement d'affûtage (× 0,75) ou une semaine de course
(× 0,5) baissent *par construction*, ce n'est pas un effondrement
(`TrainingLoadMonitor.swift:105-109`). Le message d'alerte nomme les deux
cibles et indique la sortie : recréer l'objectif, qui réancre la semaine 0
sur `max(charge mesurée, minimumStartVolumeKm)` — 10 km au plancher, un
ordre de grandeur au-dessus d'un plan effondré.

**Ce que ça ne fait pas.** Le moniteur ne recalcule jamais le score de forme
lui-même — il le reçoit déjà calculé
(`TrainingLoadMonitor.swift:16,41`, même `ReadinessScore` que §4). Il ne
propose jamais de modifier le plan lui-même : la suggestion d'inverser une
séance dure avec une séance facile est **purement indicative**, le plan
affiché ne bouge pas tant que l'utilisateur n'agit pas.

---

## 13. Rapprochement séances prévues / réalisées — `SessionMatcher`

**Question :** parmi les séances courues cette semaine, lesquelles
correspondent à quelles séances prévues du plan ?

**Entrées.** La semaine planifiée (`PlannedWeek`, §11.6) et les séances de
course réellement exécutées (`Workout` filtrés sur
`HKWorkoutActivityTypeRunning`).

**Calcul.** Un appariement glouton, en deux passes (`SessionMatcher.swift`) :

1. Les séances **définies en distance** (sortie longue, côtes, endurance —
   `targetKm > 0`) sont triées par distance cible décroissante, les sorties
   exécutées par distance décroissante, et appariées dans cet ordre — la
   plus longue séance prévue avec la plus longue sortie courue, et ainsi de
   suite.
2. Les séances **définies en durée** (optionnelle, déverrouillage —
   `targetKm <= 0`) ne participent pas à ce tri par taille : elles se
   contentent d'une sortie restante dans le stock, s'il en reste une, et
   comptent « faites » dès qu'une sortie leur est attribuée, quelle que soit
   sa distance.

Une séance à distance cible est « faite » si la sortie appariée atteint au
moins 70 % de la cible :

```swift
doneThreshold = 0.70
isDone = distanceCourue >= cible × 0.70
```
(`SessionMatcher.swift:19,35`) — même règle pour les côtes que pour toute
autre séance : voir §11.7, aucune donnée de dénivelé n'existe pour vérifier
autrement.

Les sorties courues qui restent après appariement des séances prévues sont
étiquetées « hors plan » ; elles comptent dans `executedKm` (utilisé par
`TrainingLoadMonitor`, §12) mais ne remplissent aucune case du plan.

**Ce que ça ne fait pas.** Rien n'est persisté — l'appariement est recalculé
à chaque affichage, il ne peut donc jamais se désynchroniser de la réalité
(`SessionMatcher.swift:15-17`), mais cela veut aussi dire qu'il n'y a pas de
mémoire d'un appariement passé : si l'historique de séances change (import
corrigé, doublon supprimé), l'appariement d'une semaine peut changer
rétroactivement. L'algorithme apparie par **rang de taille**, pas par
proximité sémantique : la sortie la plus longue de la semaine est toujours
appariée à la séance cible la plus longue, quel que soit l'écart réel entre
les deux. Une semaine où une seule sortie de 8 km est courue, avec une
sortie longue cible à 8,1 km et des côtes cibles à 3,6 km, apparie ces 8 km
à la sortie longue (faite, 8 ≥ 8,1 × 0,70) — la séance de côtes reste
« à faire », sans aucune sortie qui lui soit associée, même si c'est
justement une côte que l'utilisateur a courue ce jour-là.

---

## 14. Conseil du jour — `DailyAdviceEngine`

**Question :** « qu'est-ce que je fais aujourd'hui, en tenant compte de tout
ce que l'app sait déjà ? » — un message unique sur l'Accueil, composé à
partir de verdicts déjà calculés par d'autres moteurs, sans introduire de
nouveau seuil.

**Entrées.** Le score de forme du jour (optionnel, §4), les alertes de
charge du jour (`TrainingLoadMonitor.assess(...).alerts`, §12, appelé
depuis l'Accueil avec `plan: nil` — voir « Ce que ça ne fait pas »
ci-dessous), et l'alerte de stagnation VO2max du jour
(`VO2MaxEngine.stagnationAlert(...)`, §11.8).

**Le palier est directement le label de `HealthScoreEngine.label(for:)`** —
aucune nouvelle échelle :

| `readiness.label` | Palier |
|---|---|
| Récupération conseillée | `.repos` |
| Forme correcte | `.prudence` |
| Bonne forme / Excellente forme | `.opportunite` |

Sans score de forme (`readiness == nil`), aucun conseil n'est produit —
`advise(...)` retourne `nil`, pas de texte de repli inventé
(`DailyAdviceEngine.swift`).

**Le texte.** Sous `.repos` ou `.prudence`, une alerte de sévérité
`.warning` (charge ou VO2max) remplace le texte générique du palier si
l'une existe — jamais sous `.opportunite`, où l'afficher contredirait
« Bonne forme »/« Excellente forme ». Ordre de scan fixe et déterministe :
les alertes de `TrainingLoadMonitor` d'abord (dans leur ordre de
production), puis celle de `VO2MaxEngine` — la première trouvée l'emporte.
Les alertes `.info` ne remontent jamais ici (déjà visibles sur
Entraînement).

**Ce que ça ne fait pas.** Le moteur ne recalcule rien : ni score de
forme, ni charge, ni tendance VO2max — il compose des verdicts déjà
produits et déjà documentés ailleurs dans ce fichier. Depuis l'Accueil,
l'appel à `TrainingLoadMonitor.assess(...)` passe systématiquement
`plan: nil` : le plan d'entraînement n'est pas encore calculé à ce point
du chargement (`DashboardViewModel.loadWellness()` s'exécute avant
`TrainingViewModel.load()`), et le recalculer dupliquerait le chargement
d'objectif et de `hrMax` déjà fait par `TrainingViewModel`. Les alertes
propres à un plan actif (dépassement, retard, effondrement) restent donc
invisibles depuis l'Accueil et ne s'affichent que sur Entraînement.

---

## 15. Suivi de poids — `WeightEngine`

**Question :** « est-ce que je perds/prends du poids, à quel rythme, et est-ce
que ce rythme est sûr et cohérent avec mon objectif ? »

**Entrées.** La série journalière de poids (`[TrendPoint]`), un objectif de
poids optionnel (`WeightGoal` : poids cible + date cible), et un booléen
indiquant si la charge d'entraînement du jour est déjà signalée comme
élevée ailleurs (`TrainingLoadMonitor.assess(...).alerts` contient un
`.warning` — jamais un second calcul de charge).

**Tendance.** Comme `VO2MaxEngine` (§11.8), une comparaison de deux fenêtres
glissantes plutôt qu'un delta premier/dernier point (fragile aux valeurs
isolées) :

```swift
recentWindowDays = 14   // fenêtre récente, jusqu'à aujourd'hui inclus
priorWindowDays = 14    // fenêtre antérieure, immédiatement avant
stableNoiseThresholdKg = 0.15
```

`trend(weights:today:calendar:)` retourne `nil` si l'une des deux fenêtres
n'a aucune pesée. Le rythme hebdomadaire est le delta entre les deux
moyennes divisé par 2 (les deux semaines qui séparent les centres des
fenêtres) ; la direction est `.stable` sous le seuil de bruit, `.gaining`/
`.losing` sinon.

**Trajectoire.** `nil` sans objectif actif, ou si la date cible est déjà
dépassée. Avec un objectif, le rythme requis est
`(poidsCible − moyenneRécente) / semainesRestantes`, comparé au rythme réel :

| Condition | Constante | Verdict |
|---|---|---|
| rythme réel dans ±20 % du rythme requis | `onTrackToleranceRatio = 0.20` | `.onTrack` |
| en dessous (y compris rythme de signe opposé) | | `.tooSlow` |
| au-dessus | | `.tooFast` |

**Alerte de sécurité.** Repère médical usuel, pas une constante validée
spécifiquement pour cette application (réserve du §16) :

```swift
safeInfoRatePercent = 0.5      // % du poids corporel / semaine
safeWarningRatePercent = 1.0
```

En dessous de 0,5 %/semaine, aucune alerte. Entre 0,5 % et 1 %, `.info`. Au
delà de 1 %, `.warning` — le message est durci (mention explicite de la
charge d'entraînement) quand `trainingLoadElevated` est vrai, sans jamais
recalculer cette charge : c'est une alerte déjà produite par
`TrainingLoadMonitor` qui est simplement transmise.

**Ce que ça ne fait pas.** Le moteur ne lit ni le store ni l'horloge, ne
recalcule jamais la charge d'entraînement, et n'ajuste le repère de rythme
sûr à la morphologie ou à l'état de santé de l'utilisateur — un même
pourcentage s'applique à tous.

---

## 16. Avertissement

**Rien dans ce document ni dans l'application ne constitue un avis
médical.** Les scores de forme, de sommeil et d'effort sont des heuristiques
construites sur des données d'appareils grand public (Apple Watch, iPhone,
balance Withings) — pas des dispositifs médicaux, pas calibrées ni validées
cliniquement pour cette application. Les seuils et coefficients documentés
ci-dessus (600, 300, 120, 0,15, 0,20, 1,3, 0,8, 0,6…) sont des conventions
choisies pour produire des chiffres qui semblent justes sur les données d'un
usage personnel, pas des constantes issues d'une étude publiée sur cette
application précise. Une décision sur l'entraînement, le repos ou la santé
appartient à la personne et, le cas échéant, à un professionnel de santé —
jamais à un score affiché par cette application.
