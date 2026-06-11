<!-- Translated from EN docs — last sync: 2026-06-11 (réécriture Partie A pour le Pi 5) -->

# Guide pas à pas pour débutant — Fedora 44 (ARM64) sur Raspberry Pi 5, à partir de zéro

Ce guide vous emmène d'un Raspberry Pi 5 nu jusqu'à un hôte de lecture audiophile entièrement réglé, exécutant [DirettaRendererUPnP](https://github.com/cometdom/DirettaRendererUPnP) et/ou [slim2Diretta](https://github.com/cometdom/slim2Diretta). Aucune expérience Linux préalable n'est requise — chaque étape donne la commande exacte à taper.

**Temps nécessaire :** environ 2 à 3 heures au total. L'essentiel est la compilation du noyau + FFmpeg + DRUP, qui tourne sans surveillance.

**Ce que vous aurez à la fin :** un Raspberry Pi 5 sans écran dédié à la lecture audio, avec un noyau temps réel, des cœurs CPU isolés, de l'Ethernet jumbo vers votre DAC Diretta, et un renderer audio (UPnP et/ou LMS) qui apparaît simplement sur votre réseau pour être piloté par votre point de contrôle.

> **Un PC x86 plutôt qu'un Pi ?** Ce guide et cet assistant sont prévus pour le Raspberry Pi 5 sous Fedora 44 (ARM64). Sur un PC Intel/AMD, utilisez le projet jumeau x86_64 : [fedora-audiophile-setup](https://github.com/cometdom/fedora-audiophile-setup).

## Table des matières

- [Avant de commencer](#avant-de-commencer)
- **Partie A — à la machine (écran, clavier)**
  - [1. Choisir le bon matériel](#1-choisir-le-bon-matériel)
  - [2. Un mot sur le firmware du Pi (pas de BIOS)](#2-un-mot-sur-le-firmware-du-pi-pas-de-bios)
  - [3. Télécharger l'image Fedora](#3-télécharger-limage-fedora)
  - [4. Écrire Fedora sur la carte SD](#4-écrire-fedora-sur-la-carte-sd)
  - [5. Premier démarrage et configuration initiale](#5-premier-démarrage-et-configuration-initiale)
  - [6. Noter l'adresse IP](#6-noter-ladresse-ip)
- **Partie B — depuis votre canapé (SSH)**
  - [7. Se connecter en SSH](#7-se-connecter-en-ssh)
  - [8. Installer les prérequis](#8-installer-les-prérequis)
  - [9. Télécharger le SDK Diretta](#9-télécharger-le-sdk-diretta)
  - [10. Transférer le SDK](#10-transférer-le-sdk)
  - [11. Cloner l'assistant et le lancer](#11-cloner-lassistant-et-le-lancer)
  - [12. Parcourir le menu de l'assistant](#12-parcourir-le-menu-de-lassistant)
  - [13. Répondre aux questions des modules](#13-répondre-aux-questions-des-modules)
  - [14. Redémarrer](#14-redémarrer)
- **Partie C — après le redémarrage**
  - [15. Vérifier que tout tourne](#15-vérifier-que-tout-tourne)
  - [16. Premier test d'écoute](#16-premier-test-découte)
  - [17. Dépannage](#17-dépannage)
- [Référence rapide (TL;DR)](#référence-rapide-tldr)

---

## Avant de commencer

Il vous faut :

- Un **Raspberry Pi 5** (4 Go, 8 Go ou 16 Go). 8 Go est une cible confortable. Le Pi 4 n'est pas une cible de cet assistant.
- L'**alimentation officielle USB-C 27 W** (le Pi 5 est exigeant côté alimentation — une alim sous-dimensionnée provoque des instabilités aléatoires) et un **refroidisseur actif / ventilateur**. Le refroidissement n'est pas optionnel ici : l'assistant fixe le gouverneur CPU sur *performance*, donc le Pi chauffe et bridera sans refroidissement actif.
- Une **carte microSD** (classée A2, ≥ 16 Go) — ou, mieux, un **SSD NVMe sur un HAT M.2**. C'est là que vit Fedora ; pas votre musique (elle est en streaming depuis votre serveur LMS/Roon/Minimserver ou depuis Qobuz/Tidal).
- Un **second ordinateur** (votre portable/poste principal) pour écrire la carte SD puis vous connecter en SSH.
- Un **écran + clavier** (câble micro-HDMI pour le Pi 5) pour la configuration unique du premier démarrage. Vous pourrez les débrancher après le [§6](#6-noter-ladresse-ip).
- Un **câble Ethernet** vers votre réseau domestique — le Wi-Fi est déconseillé pour du streaming audio soutenu. Le Pi 5 a une carte réseau gigabit intégrée (votre côté LAN).
- (Optionnel mais recommandé pour le meilleur lien Diretta) **Une seconde carte réseau** pour le lien point à point Diretta — un **adaptateur USB-Ethernet à puce Realtek RTL8156** est le choix de référence et le seul moyen de pousser le MTU jusqu'à 16128 (le meilleur compromis sinon est le jumbo 9014, géré par la carte intégrée). Branchez-le sur un des ports **USB 3.0** du Pi 5 (les bleus).
- Une **cible Diretta / DAC** sur votre réseau audio (c'est vers elle que le Pi diffusera).
- L'adresse IP ou un accès admin à votre **box / routeur** (pour retrouver l'IP du Pi plus tard).
- **Environ 1 heure de patience** pendant l'étape de compilation FFmpeg + DRUP en [§13](#13-répondre-aux-questions-des-modules).

---

# Partie A — à la machine

Vous aurez besoin d'un écran et d'un clavier branchés sur le Pi pour cette partie (un câble micro-HDMI pour le port HDMI du Pi 5). Après le [§6](#6-noter-ladresse-ip), vous pourrez les débrancher et tout terminer à distance en SSH.

## 1. Choisir le bon matériel

Une configuration type :

- **Hôte audio** : un **Raspberry Pi 5**. Son Cortex-A76 4 cœurs suffit pour faire tourner un cœur système plus trois cœurs audio isolés (`isolcpus=1-3`). **4 Go de RAM suffisent** ; 8 Go offrent une marge supplémentaire pour la mise en cache du flux par le noyau. Utilisez l'**alimentation officielle USB-C 27 W** et un **refroidisseur actif** — l'assistant fixe le gouverneur sur *performance*, donc un refroidissement passif bridera.
- **Stockage** : une bonne **microSD A2** (≥ 16 Go) convient ; un **SSD NVMe sur HAT M.2** est plus rapide et plus fiable pour l'OS. Les fichiers musicaux ne résident pas ici — ils sont en streaming depuis votre serveur LMS/Minimserver/Roon ou depuis Qobuz/Tidal…
- **Deux cartes réseau (optionnel mais idéal)** : la **carte gigabit intégrée** du Pi 5 pour votre LAN (points de contrôle, internet), plus un **adaptateur USB-Ethernet** pour un lien point à point direct vers la cible Diretta. Pour ce lien, un adaptateur à puce **Realtek RTL8156** est le choix de référence — c'est la seule famille qui prend en charge le MTU **16128** (la carte intégrée plafonne au jumbo 9014, ce qui convient à la plupart des configurations). Branchez-le sur un des ports **USB 3.0** du Pi 5 (les bleus), pas USB 2.0.

Les configurations à une seule carte réseau fonctionnent aussi — l'assistant gère ce cas automatiquement.

## 2. Un mot sur le firmware du Pi (pas de BIOS)

Bonne nouvelle : le Raspberry Pi n'a **pas de BIOS** à configurer, ni de **Secure Boot** à désactiver — donc rien de tout le bricolage x86 habituel d'avant-installation ne s'applique. Sur un PC x86, vous désactiveriez les C-states, le SpeedStep et le Turbo Boost dans le BIOS ; sur le Pi, ces réglages n'existent pas, et il n'y a rien à faire ici. L'assistant fixe le CPU sur *performance* et désactive les états de veille profonds côté OS (module 06), ce qui suffit.

Un Pi 5 actuel est livré avec un firmware de démarrage assez récent pour exécuter Fedora ; si votre Pi a pris la poussière sur une étagère, vous pourrez mettre l'EEPROM à jour plus tard depuis Fedora (`sudo fwupdmgr update`) — pas nécessaire pour ce guide.

> **Pour aller plus loin (optionnel, après une première écoute).** Le module 06 permet de plafonner la fréquence max du CPU côté OS (`/etc/default/audiophile-cpu-states`, `CPU_MAX_PCT=…`) — pratique pour itérer, redémarrer le service, écouter. Une fréquence de pointe plus basse tire moins de courant et chauffe moins, ce que certains préfèrent à l'écoute. Le Pi 5 peut aussi être réglé (ou overclocké) via des paramètres firmware façon `/boot/config.txt`, mais c'est hors sujet ici et inutile pour obtenir un bon résultat.

## 3. Télécharger l'image Fedora

Sur votre **ordinateur principal** (pas le Pi). Contrairement à une installation x86, vous n'utilisez pas d'ISO/installeur — vous écrivez une **image disque** toute prête directement sur la carte SD.

1. Ouvrez https://fedoraproject.org/server/download dans votre navigateur.
2. Choisissez l'architecture **aarch64** et téléchargez l'**image brute** (*Raw Image*, un fichier `.raw.xz`), pas l'ISO. Le nom ressemble à `Fedora-Server-44-*.aarch64.raw.xz`.
3. Enregistrez-la sur votre ordinateur principal.

> **Server ou Minimal ?** Les deux éditions aarch64 de Fedora 44 conviennent — l'assistant vérifie seulement que vous êtes sur Fedora **44**. L'image brute Server est le choix recommandé et le mieux documenté ; l'image « Minimal » aarch64, plus légère, est celle qu'a utilisée avec succès notre premier testeur sur Pi 5.

## 4. Écrire Fedora sur la carte SD

Utilisez **Raspberry Pi Imager** (https://www.raspberrypi.com/software/) ou **balenaEtcher** (https://etcher.balena.io). Les deux écrivent le `.raw.xz` compressé directement — pas besoin de le décompresser d'abord.

Insérez la microSD (via un lecteur de cartes) dans votre ordinateur principal, puis :

**Avec Raspberry Pi Imager :**
1. Cliquez sur **Choose OS** → tout en bas → **Use custom**, et choisissez le `Fedora-Server-44-*.aarch64.raw.xz` téléchargé.
2. Cliquez sur **Choose Storage** → sélectionnez votre carte SD. **Vérifiez trois fois** — tout ce qui est pointé sera effacé.
3. Cliquez sur **Next**. Si une « personnalisation de l'OS » est proposée, choisissez **Non / ne rien régler** — cette fonction ne concerne que Raspberry Pi OS, pas Fedora ; on fait la configuration au premier démarrage.
4. Confirmez et attendez l'écriture et la vérification.

**Avec balenaEtcher :** **Flash from file** → le `.raw.xz` → **Select target** → votre carte SD → **Flash!**

![Écriture de l'image — Flash from file, Select target, Flash](../images/fr/01-balena-etcher.jpg)

Éjectez proprement la carte, puis insérez-la dans le Pi (le logement est sous la carte).

## 5. Premier démarrage et configuration initiale

Pas d'installeur à parcourir — l'image que vous avez écrite est déjà un système Fedora complet. Au premier démarrage, elle lance une **configuration texte** unique à l'écran.

1. Insérez la carte SD, branchez l'écran (micro-HDMI) et le clavier, branchez le **câble Ethernet** vers votre LAN, puis branchez l'alimentation. Le Pi démarre.
2. Au bout d'une minute, un menu texte apparaît, intitulé quelque chose comme **« Configuration initiale de Fedora »**, avec des entrées numérotées à compléter une à une — tapez le numéro, Entrée, remplissez, puis revenez au menu.

Complétez ces entrées :

- **Langue / clavier** — choisissez les vôtres.
- **Fuseau horaire** — réglez votre fuseau.
- **Mot de passe administrateur (root)** — choisissez-en un robuste. Vous ne l'utiliserez pas souvent, mais il sera utile en cas d'urgence.
- **Création d'utilisateur** — créez votre compte quotidien :
  - Nom d'utilisateur : court et en minuscules, p. ex. `dommusic`.
  - Définissez un mot de passe.
  - Choisissez **faire de cet utilisateur un administrateur** (cela le met dans le groupe `wheel`, donc il peut utiliser `sudo`).

Quand toutes les entrées sont marquées comme faites, choisissez **`c`** (continuer) / **Terminé**. Le Pi achève la configuration et affiche une **invite de connexion**. Connectez-vous avec le compte **utilisateur** que vous venez de créer (pas root).

Le réseau ne demande aucune configuration : la carte filaire obtient automatiquement une adresse de votre box.

### 5.5 Agrandir le système de fichiers racine

L'image est dimensionnée pour la plus petite carte, donc la partition racine ne remplit probablement pas encore votre SD/NVMe. Vérifiez d'abord :

```bash
df -h /
```

Si `/` affiche déjà l'essentiel de la capacité de votre carte, passez à la suite. Sinon, agrandissez-la — la carte SD est `/dev/mmcblk0` et la racine est sa 3ᵉ partition (`mmcblk0p3`) ; sur un disque NVMe c'est `/dev/nvme0n1` et `nvme0n1p3` :

```bash
sudo parted /dev/mmcblk0
# à l'invite (parted) :
unit GB
print                 # repérez que la partition 3 est la racine Linux
resizepart 3 100%     # répondez Oui s'il avertit que la partition est utilisée
quit

sudo resize2fs /dev/mmcblk0p3
df -h /                # vérifiez que / occupe maintenant toute la taille
```

## 6. Noter l'adresse IP

Dans le terminal :

```bash
ip addr show
```

Cherchez une ligne du type `inet 192.168.1.104/24` sous votre interface filaire (sur le Pi 5, la carte intégrée s'appelle généralement `end0`). Notez cette adresse — vous vous y connecterez en SSH ensuite. (Vous pouvez aussi la retrouver dans la liste des clients DHCP de votre box.)

Fedora Server a déjà SSH activé, donc vous pouvez sans doute vous connecter tout de suite. Pour en être sûr — pendant que vous avez encore la session locale — lancez :

```bash
sudo systemctl enable --now sshd
```

Vous pouvez maintenant débrancher l'écran et le clavier du Pi. Passez à votre ordinateur principal.

---

# Partie B — depuis votre canapé

Tout ce qui suit se fait en SSH depuis votre ordinateur principal.

## 7. Se connecter en SSH

Depuis votre **ordinateur principal** (Terminal sur Mac/Linux, PowerShell sur Windows 10+) :

```bash
ssh dommusic@192.168.1.104
```

Remplacez `dommusic` par le nom d'utilisateur créé en [§5.6](#56-compte-utilisateur) et `192.168.1.104` par l'IP du [§6](#6-noter-ladresse-ip). La première fois, tapez `yes` pour accepter la clé d'hôte, puis saisissez le mot de passe.

Vous devriez voir une invite du type `[dommusic@audio-pc ~]$`. Vous êtes connecté.

## 8. Installer les prérequis

Une installation Fedora minimale ne contient presque rien. Mettez le système à jour et installez les quelques outils dont l'assistant dépend :

```bash
sudo dnf -y update
sudo dnf -y install git curl grubby dnf-plugins-core tar
```

- `git` est nécessaire pour cloner le dépôt de l'assistant (et DRUP, slim2Diretta).
- Les autres sont utilisés par l'assistant lui-même ; si vous en oubliez, `00-preflight` les installera comme filet de sécurité.
- (Pas de `mokutil` ici, contrairement au guide x86 — le Pi n'a pas de Secure Boot.)

## 9. Télécharger le SDK Diretta

Le SDK Diretta Host est requis pour compiler DRUP et slim2Diretta. **Il doit être téléchargé à la main** car sa licence n'autorise qu'un usage personnel.

Sur votre **ordinateur principal** (pas le PC audio) :

1. Ouvrez https://www.diretta.link/hostsdk.html dans votre navigateur.
2. Téléchargez la dernière archive **DirettaHostSDK**. Le nom de fichier ressemble à `DirettaHostSDK_149_8.tar.zst`.

Conservez le fichier dans un dossier facile à retrouver — vous le copierez sur le PC audio ensuite.

## 10. Transférer le SDK

Depuis votre **ordinateur principal** (ouvrez une nouvelle fenêtre Terminal/PowerShell — gardez votre session SSH ouverte dans l'autre) :

```bash
scp ~/Downloads/DirettaHostSDK_149_8.tar.zst dommusic@192.168.1.104:~/
```

Adaptez le chemin, le nom d'utilisateur et l'IP à votre système. Le fichier est copié dans le dossier personnel de l'utilisateur sur le PC audio.

Puis, de retour dans la **session SSH** sur le PC audio :

```bash
cd ~
tar --zstd -xf DirettaHostSDK_149_8.tar.zst
ls -d DirettaHostSDK_*
```

Vous devriez voir un dossier nommé `DirettaHostSDK_149` (ou similaire) dans votre dossier personnel. L'assistant le détecte automatiquement à partir de là.

## 11. Cloner l'assistant et le lancer

Toujours dans la session SSH :

```bash
cd ~
git clone https://github.com/cometdom/fedora-rpi-audiophile-setup.git
cd fedora-rpi-audiophile-setup
sudo ./setup.sh
```

Au premier lancement, un menu numéroté apparaît.

## 12. Parcourir le menu de l'assistant

```
What do you want to do?

   1) Full install              all modules in order (recommended)
   2) 00 preflight            — verify hard pre-conditions...
   3) 01 kernel-rt            — install the PREEMPT_RT kernel...
   ...
  14) 99 finalize             — sanity-check + offer reboot
  15) Exit

Choose [1]:
```

Appuyez simplement sur **Entrée** (ou tapez `1`). L'assistant exécute tous les modules dans l'ordre. Des questions vous seront posées en chemin — la section suivante explique chacune d'elles.

> **Lire le menu.** Chaque ligne de module affiche deux numéros : le **`2)`, `3)`, …** en tête est le choix de menu (ce que vous tapez), et les deux chiffres juste après — **`00`, `01`, …, `99`** — sont le numéro du module, qui correspond à `modules/NN-name.sh` et aux références utilisées dans le §13 ci-dessous et ailleurs dans la doc. Les deux diffèrent parce que le menu contient des entrées supplémentaires (Full install, Exit) qui ne sont pas des modules. Quand le guide parle de « module 06 », cherchez le `06` sur la ligne, pas le choix `6`.

> Si vous devez relancer un seul module (p. ex. vous avez sauté DRUP la première fois), vous pouvez soit choisir son numéro dans ce menu, soit utiliser le raccourci : `sudo ./setup.sh --only kernel-rt`.

## 13. Répondre aux questions des modules

Pour chaque question, la **valeur par défaut** (entre crochets, du type `[Y/n]` ou `[y/N]`) est ce qui se produit si vous appuyez juste sur Entrée. La lettre en majuscule est le défaut.

| Module | Question | Réponse recommandée |
|---|---|---|
| 02 system-tuning | `Use the -nosmt tuner variant?` | **N** (Entrée) — le Cortex-A76 du Pi 5 n'a de toute façon pas de SMT/Hyper-Threading, donc `-nosmt` n'ajoute qu'un drapeau sans effet ; le tuner normal isole les cœurs audio de la même façon. |
| 03 network-stack | `Set up stable names by MAC?` | **Y** (Entrée) — renomme vos cartes réseau en `eth-lan` et `eth-diretta` à partir de leur adresse MAC. Met l'hôte à l'abri de tout changement matériel qui décalerait l'énumération PCI (remplacement de carte, ajout d'une carte PCIe, insertion/retrait d'une carte graphique sur un host sans GPU intégré). Si vous refusez, le wizard garde les noms `enpXsY` assignés par le noyau et tout changement matériel ultérieur peut nécessiter des édits manuels. Effectif au prochain démarrage. |
| 03 network-stack | `Use these roles?` (LAN/Diretta auto-détectés) | **Y** (Entrée) si le mapping affiché est correct. Le wizard pré-sélectionne LAN = carte avec route par défaut, Diretta = l'autre (quand vous avez exactement deux cartes Ethernet). Répondez **N** pour choisir les rôles manuellement dans un menu. |
| 03 network-stack | `K) Keep NetworkManager / S) Switch to systemd-networkd / N) Skip` | **K** (Entrée) — garder NetworkManager est plus sûr pour une première installation. |
| 04 tmpfs-disk | `Mount /var/log and /var/tmp as tmpfs?` | **Y** (Entrée) — zéro écriture disque pendant la lecture. |
| 05 services-cleanup | `Disable firewalld?` | **Y** (Entrée) — hôte audio dédié sur un LAN de confiance. |
| 05 services-cleanup | `Disable SELinux?` | **Y** (Entrée) — aucun surcoût. |
| 06 cpu-states | `Cap the CPU max frequency? (opt-in)` | **N** (Entrée) pour la première installation. Si vous voulez tester le réglage audiophile (fréquence max abaissée → moins de bruit électrique perçu sur la sortie analogique du DAC, subjectif), répondez **Y** et un pourcentage (50 est un bon point de départ ; essayez 75/100 ensuite). Vous pouvez ré-ajuster sans relancer le wizard : éditez `/etc/default/audiophile-cpu-states` puis `sudo systemctl restart audiophile-cpu-states.service`. |
| 10 install-drup | `Install DirettaRendererUPnP?` | **Y** si vous voulez UPnP / Audirvana / Roon / mConnect. Sinon **n**. |
| 10 install-drup | Choix de la carte réseau | Choisissez la carte reliée à votre cible Diretta. L'autre (celle qui a une IP) est votre côté LAN. |
| 10 install-drup | `Build DRUP with Clang + LTO?` | **Y** (Entrée) — meilleure qualité audio, compilation un peu plus longue. |
| 10 install-drup | Menu **version de FFmpeg** de l'`install.sh` de DRUP | **2 = FFmpeg 7.1** sur le Pi 5. La valeur par défaut (`3 = 8.0.1`) échouerait à la compilation sur le Pi ; la 7.1 compile et fonctionne. (L'assistant affiche ce rappel juste avant de lancer l'installeur.) |
| 10 install-drup | Question `Configure firewall?` propre à DRUP | **N** — vous avez désactivé firewalld à l'étape 05. Répondre Y ici interromprait le script. |
| 10 / 11 | `MTU for the Diretta NIC` (demandé par le wizard) | **2 = 9014** (jumbo, défaut) sur la plupart des cartes ; **3 = 16128** seulement avec une carte Realtek RTL8156 ET une cible qui le gère ; **1 = 1500** sinon. |
| 10 install-drup | Question MTU propre à `install.sh` de DRUP (plus tard) | Donnez la **même** réponse que ci-dessus. C'est un doublon sans danger (basé sur nmcli) ; c'est le drop-in `.link` du wizard qui s'applique de façon fiable, y compris sous systemd-networkd. |
| 11 install-slim2diretta | `Install slim2Diretta?` | **Y** si vous diffusez depuis LMS / Lyrion Music Server. Sinon **n**. |
| 11 install-slim2diretta | `LMS server IP?` | Laissez vide pour l'auto-découverte, ou tapez l'IP du serveur LMS. |
| 99 finalize | `Reboot now?` | **N** (Entrée) au premier passage — vérifions ce qui est installé avant de redémarrer. |

L'étape de loin la plus longue est **10 install-drup** : elle compile FFmpeg depuis les sources. Comptez ~30 minutes pendant lesquelles l'écran défile avec beaucoup de coches vertes. C'est normal.

## 14. Redémarrer

Une fois l'assistant terminé et après avoir parcouru le récapitulatif `[OK] / [--]` qu'affiche le module finalize, redémarrez :

```bash
sudo reboot
```

Attendez 1 à 2 minutes, puis reconnectez-vous en SSH (même commande qu'au [§7](#7-se-connecter-en-ssh)).

---

# Partie C — après le redémarrage

## 15. Vérifier que tout tourne

```bash
uname -r
```

La sortie doit contenir `rt`, par exemple `6.x.x-rt`. Cela confirme que le noyau temps réel est bien utilisé.

```bash
cat /proc/cmdline
```

Cherchez des mots comme `isolcpus`, `nohz_full`, `rcu_nocbs` — ce sont les options d'isolation CPU ajoutées à GRUB par le tuner DRUP.

```bash
systemctl status diretta-renderer
```

(ignorez ceci si vous n'avez pas installé DRUP) — vous devriez voir `Active: active (running)`. Idem pour `systemctl status slim2diretta` si vous l'avez installé.

```bash
ip link show
```

Repérez votre carte Diretta (celle choisie à l'étape 10) et confirmez que son MTU est `9014` (ou la valeur choisie).

En cas de problème, voir le [§17 Dépannage](#17-dépannage) ci-dessous.

## 16. Premier test d'écoute

### Si vous avez installé DirettaRendererUPnP

Sur votre téléphone, tablette ou ordinateur (même réseau), utilisez un point de contrôle UPnP :

- **Audirvana** (Mac / Windows / Linux)
- **JPlay** (iOS)
- **mConnect** (iOS / Android)
- **BubbleUPnP** (Android)
- **Tune Server** (Mac / Windows / Linux)

Cherchez un appareil nommé **Diretta Renderer** (ou ce que vous avez défini comme `NAME` dans `/etc/default/diretta-renderer`). Choisissez un morceau et lancez la lecture.

### Si vous avez installé slim2Diretta

Dans la page d'administration de votre serveur LMS / Lyrion Music Server, le PC audio apparaît comme un nouveau lecteur nommé `slim2diretta` (ou le nom choisi). Choisissez-le comme cible de lecture.
slim2Diretta fonctionne aussi avec Roon, en activant le mode Squeezebox dans Roon.

Le premier son devrait atteindre votre cible Diretta / DAC en moins d'une seconde.

## 17. Dépannage

### « Impossible de se connecter en SSH après le redémarrage »

- Attendez 2 à 3 minutes — le premier démarrage sur le nouveau noyau est plus lent que d'habitude.
- Essayez de pinguer le nom d'hôte : `ping audio-pc.local` (ou le nom d'hôte que vous avez défini).
- Si vous avez plusieurs cartes réseau, l'IP côté LAN a pu changer ; vérifiez la page d'admin de votre box.

### « Le service DRUP ne tourne pas »

```bash
sudo systemctl status diretta-renderer
sudo journalctl -u diretta-renderer -n 50
```

Les causes les plus fréquentes :
- **`INTERFACE` incorrect dans `/etc/default/diretta-renderer`** — ce doit être la carte côté LAN (côté points de contrôle), pas la carte Diretta.
- **Aucune cible Diretta trouvée** — vérifiez que la cible est allumée et sur le même réseau que votre carte Diretta.

Modifiez la configuration :

```bash
sudo nano /etc/default/diretta-renderer
sudo systemctl restart diretta-renderer
```

### « L'adaptateur USB-Ethernet n'est pas détecté »

```bash
lsusb
dmesg | tail -30
ip link
```

Si l'adaptateur est dans `lsusb` mais pas dans `ip link`, il vous faut peut-être un pilote — voir le script `usb-ethernet_driver_install.sh` dans le dépôt DRUP, sous `~/DirettaRendererUPnP/`.

### « Le MTU n'a pas tenu »

Le wizard fixe le MTU Diretta via un drop-in `.link` systemd-udevd, qui fonctionne **aussi bien** sous NetworkManager que sous systemd-networkd. Vérifiez-le ainsi que la valeur effective :

```bash
cat /etc/systemd/network/50-audiophile-diretta-*.link   # doit montrer MTUBytes=
ip link show <votre-iface>                               # mtu <valeur> après un redémarrage
```

Si le fichier manque ou est incorrect, relancez le module d'installation (il proposera de reconfigurer) :

```bash
sudo ./setup.sh --only install-drup        # ou : --only install-slim2diretta
```

Pour forcer à la main, éditez `MTUBytes=` dans ce fichier `.link` et redémarrez (la valeur est appliquée par udevd au coldplug). Sous NetworkManager, vous pouvez aussi la fixer à chaud pour la session courante :

```bash
sudo nmcli connection modify "diretta-<votre-iface>" 802-3-ethernet.mtu 9014
sudo nmcli connection up "diretta-<votre-iface>"
```

### « L'assistant s'est interrompu en cours de route »

Relancez-le. Chaque module est idempotent — les changements déjà appliqués sont détectés et sautés. Pour ne relancer qu'un seul module :

```bash
sudo ./setup.sh --only <nom-du-module>
```

Par exemple : `sudo ./setup.sh --only install-drup`.

---

# Référence rapide (TL;DR)

Pour quand vous voudrez tout refaire de mémoire :

```bash
# === Partie A : à la machine ===
# Écrire Fedora 44 aarch64 (.raw.xz Server) sur la carte SD, démarrer le Pi,
# faire la config texte du premier démarrage, puis agrandir la racine — §3 à §5 :
#   df -h /
#   sudo parted /dev/mmcblk0      # puis : resizepart 3 100%
#   sudo resize2fs /dev/mmcblk0p3

# === Partie B : SSH depuis votre ordinateur principal ===

# Fedora Server a sshd activé par défaut ; noter l'IP du Pi (carte intégrée ~ end0) :
sudo systemctl enable --now sshd
ip addr show

# Depuis votre ordinateur principal :
ssh dommusic@<ip-du-pi>

# Dans la session SSH :
sudo dnf -y update
sudo dnf -y install git curl grubby dnf-plugins-core tar

# Télécharger le SDK Diretta depuis https://www.diretta.link/hostsdk.html
# Le transférer depuis votre ordinateur principal :
#   scp DirettaHostSDK_*.tar.zst dommusic@<ip-du-pi>:~/

# De retour dans la session SSH :
cd ~
tar --zstd -xf DirettaHostSDK_*.tar.zst
git clone https://github.com/cometdom/fedora-rpi-audiophile-setup.git
cd fedora-rpi-audiophile-setup
sudo ./setup.sh
# Choisir l'option 1 (Full install). Répondre aux questions comme au §13.

# === Partie C : après le redémarrage ===
sudo reboot
# Attendre, se reconnecter en SSH, puis vérifier :
uname -r                          # doit contenir 'rt'
cat /proc/cmdline                 # doit contenir isolcpus / nohz_full
systemctl status diretta-renderer # si DRUP installé
systemctl status slim2diretta     # si slim2Diretta installé
```

Bonne écoute.
