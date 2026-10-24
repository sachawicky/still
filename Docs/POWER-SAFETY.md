# Still — correction veille et Focus (24 octobre 2026)

Still 2.0.0 RC 2 (build 7) donne priorité à la veille explicite et à la batterie. Le projet est natif Swift 6, SwiftUI/AppKit, avec IOKit. Le lanceur de commandes a été corrigé pour éviter les erreurs de descripteur lors de la récupération des anciens réglages de veille. Les sessions actuelles utilisent des assertions natives, sans activer de réglage global.

## Architecture retenue et limites Apple

- Une session utilise uniquement `PreventUserIdleSystemSleep`, avec libération automatique par le noyau au bout de trois heures. Aucune assertion de veille système forcée ou de maintien de l'écran n'est créée.
- Still ne peut plus activer `SleepDisabled`. Une ancienne valeur dont Still possède le marqueur peut être restaurée à zéro. Une lecture inconnue ou une restauration échouée conserve ce marqueur et affiche une erreur ; une valeur externe est seulement signalée.
- Le menu Apple reste libre de demander une veille forcée. Still n'attend pas une notification tardive pour rendre cette demande possible : son assertion ne s'y oppose pas. La notification `NSWorkspace.willSleep` libère l'assertion et verrouille la reprise, pour les veilles forcées ou automatiques effectivement engagées.
- **Capot fermé sans écran externe : maintien éveillé non garanti, contournement désactivé.** Les API publiques ne permettent pas de garantir ce maintien tout en garantissant la priorité du menu Apple. `PreventSystemSleep` n'apporte pas cette garantie pour le capot ; les propriétés privées ou réservées aux services système n'ont pas été utilisées.
- **Écran externe : aucun maintien énergétique Still.** CoreGraphics énumère les écrans en ligne, y compris les écrans miroirs ou en veille. Les changements sont observés par callback. Une erreur d'énumération libère le maintien par précaution. macOS gère le mode clamshell et ses conditions matérielles habituelles.
- **Verrouillage :** libération à réception de `com.apple.screenIsLocked`, sans demander de veille. Cette notification distribuée existe sur macOS mais n'est pas un contrat public documenté. Les notifications publiques de désactivation de session et de veille d'écran constituent un repli conservateur. La détection immédiate de tout verrouillage ne peut donc pas être certifiée pour toutes les versions de macOS ; un essai réel reste requis. Une simple désactivation d'application n'est pas assimilée à un verrouillage.
- Sortie de veille, déverrouillage, événements d'agents et branchements d'écran ne lèvent pas le verrou de sécurité. Une nouvelle action manuelle est nécessaire. Un lancement après crash ne restaure pas l'ancienne session manuelle ; les préférences d'activation automatique demeurent celles de l'utilisateur.
- Batterie : seuil effectif au moins 15 %, seuil supérieur choisi respecté. Mesure inconnue sur batterie, pression thermique et mode économie d'énergie suspendent le maintien. Durées effectives au plus trois heures, sans écraser les valeurs enregistrées des préférences.
- Les assertions appartiennent au processus : macOS les détruit si Still meurt. Aucun gardien permanent, helper privilégié ou script de surveillance n'est installé. Les commandes résiduelles de diagnostic/récupération utilisent `posix_spawn`, des descripteurs explicites et une sortie temporaire privée ; les assertions natives ne dépendent plus de ces commandes.

Références Apple : [contrat IOKit](https://github.com/apple-oss-distributions/IOKitUser/blob/main/pwr_mgt.subproj/IOPMLib.h), [veille forcée et notifications QA1340](https://developer.apple.com/library/archive/qa/qa1340/_index.html), [notification de veille d'écran](https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification).

## Focus et notifications

Les fenêtres restent au niveau `floating`, sous la barre de menus, sans mode plein écran exclusif. Elles participent aux Spaces et peuvent accompagner un plein écran. Still ne modifie ni les modes de concentration macOS, ni le volume système, ni les autorisations des autres applications.

Les bannières natives de Still ne sont plus limitées à l'extérieur de Focus. Le délégué autorise leur présentation en premier plan. Les sons d'attention passent une fois par `NSSound`, selon le son/volume déjà choisi ; le son n'est pas doublé par la bannière. Les sons des autres applications restent gérés par macOS. Une bannière visible ou un son audible reste soumis aux préférences système.

Échap est observé uniquement dans les événements locaux à Still. Le premier clic gauche sur le fond Focus ferme toutes ses fenêtres immédiatement, y compris si Still était inactive ; le clic n'est pas transmis à l'application derrière. Les actions interactives existantes restent dans le menu Still. Les vues de contenu sont détachées immédiatement, sans fenêtre transparente différée. Quitter Focus ne termine aucun processus d'agent ; la session éveillée distincte reste contrôlable dans le menu Still et bornée par sa durée.

## Validation automatisée

Voir le [bilan du build 7](RELEASE-CANDIDATE.md) pour les commandes et leur portée : 36 tests Swift, 146 vérifications StillCheck, 4 tests de configuration des hooks, sonde de crash d'un processus jetable, cycle de fenêtres Focus et audit du paquet. Le test de cycle vérifie aussi que le périphérique de sortie et les commandes audio accessibles de volume/sourdine restent inchangés.

Les notifications système et transitions simulées ne constituent pas une validation physique. Une bannière réellement reçue, un son audible, une veille ou un verrouillage physique ne sont pas attestés par ces seuls tests. Aucun réglage d'une autre application n'est modifié.

## Validation manuelle courte

1. Activer volontairement les notifications natives dans Still et accorder la demande macOS. Vérifier Réglages Système → Notifications → Still → alertes et sons, ainsi que les exceptions souhaitées dans le mode de concentration utilisé. Pour une application tierce, effectuer sa propre demande de notification et vérifier ses réglages séparément.
2. Démarrer Focus. Déclencher une vraie demande d'un agent ou recevoir une notification d'une autre application. Vérifier séparément la bannière et le son. Ouvrir le Centre de notifications. Quitter avec Échap, recommencer puis cliquer : le bureau doit répondre immédiatement.
3. Sans travail à interrompre, démarrer une session Still puis choisir menu Apple → Mettre en veille. Après réveil, `pmset -g` doit indiquer `SleepDisabled 0` et `pmset -g assertions` ne doit montrer aucune assertion Still. Still doit attendre une reprise manuelle.
4. Démarrer une nouvelle session puis verrouiller avec Control-Command-Q. Après déverrouillage, vérifier les mêmes deux commandes et l'absence de reprise automatique. Le verrouillage seul ne doit pas déclencher une demande de veille de Still.
5. Brancher/débrancher un écran externe pendant une session : dès connexion, aucune assertion Still ; Focus peut rester visible. Pour le capot fermé avec écran, vérifier le comportement natif macOS avec les conditions d'alimentation/périphériques prévues. Sans écran, la veille normale à la fermeture est attendue, et le maintien éveillé n'est pas promis.
6. Lors d'un redémarrage choisi par l'utilisateur, vérifier `SleepDisabled 0` avant/après et aucune ancienne session manuelle restaurée. Les préférences de détection restent inchangées. Ne jamais fermer le capot pour un essai en laissant des travaux non sauvegardés.

Diagnostic de notifications en lecture seule : `dist/Still.app/Contents/MacOS/Still --notification-diagnostics`. Il indique l'autorisation macOS, les alertes et les sons, sans les modifier.

## Activation et désactivation des notifications

L'option de l'interface ou la commande explicite `/Applications/Still.app/Contents/MacOS/Still --enable-native-agent-notifications` active seulement la préférence de notifications natives et demande l'autorisation `[.alert, .sound]` à macOS. Les autres préférences, y compris celles d'une version future, sont conservées ; une valeur corrompue n'est pas écrasée. Quitter Still avant la commande puis le relancer pour recharger les préférences. La commande ne peut pas imposer une autorisation refusée, un style de bannière ou un son audible.

Pour annuler, désactiver « Native agent notifications » dans Still. Les autorisations système peuvent être modifiées dans les réglages macOS propres à Still. Ne pas importer tout un ancien domaine de préférences pour annuler un seul réglage.

## Retour arrière

L'installateur local conserve le paquet précédent dans son répertoire de sauvegarde ignoré par Git. Quitter Still proprement avant de restaurer un ancien paquet. Une ancienne version peut contenir le mécanisme global de veille : laisser sa session désactivée pour éviter de le réintroduire. Les préférences utilisateur ne sont pas supprimées par l'installation. Les sauvegardes, préférences, journaux et correctifs locaux ne font pas partie de la publication des sources.
