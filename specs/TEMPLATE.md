# Spec : <titre court du changement>

Date : AAAA-MM-DD — Statut : brouillon | validée | exécutée

## Contexte

(1-3 lignes : pourquoi ce changement existe, ce qui le motive.)

## Périmètre

- Ce que la spec couvre (section par section, numérotées).
- Ce qu'elle ne couvre PAS (listé explicitement — l'agent ne tranche pas
  hors périmètre).

## Maquettes (si la spec touche le frontend)

- Niveau : statique | fonctionnelle déployée — Statut : en attente | validées
- Chemin : specs/mockups/<date>-<slug>/

## §1 <Première propriété>

(Décrire le comportement voulu, précis et vérifiable — pas une description du
code. Chaque section doit pouvoir se tester.)

## §2 <Deuxième propriété>

## Tests

- Pour chaque section : la propriété testable correspondante.
- TDD : tests rouges avant implémentation.
- Pas de test tautologique : un test qui réécrit l'implémentation au lieu de
  vérifier la propriété est refusé.
- En fin de run : suite complète du projet relancée.

## Hors périmètre (noté, non tranché)

(les points repérés mais laissés de côté — pour ne pas les perdre.)
