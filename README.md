# Enregistreur d'appels

Petite app macOS qui vit dans la barre de menus et **enregistre les appels passés avec l'app Téléphone ou FaceTime** du Mac, puis les **transcrit en local** en indiquant qui parle.

```
Appel du 29/10/2026 à 21h46 — 10 min 37 s

[00:00] Correspondant : Bonjour, c'est Julie de Véranda Conseil.
[00:04] Moi : Ah bonjour ! Oui, je vous écoute.
```

- 🎙️ **Ta voix** vient du micro, **celle de ton correspondant** du son du Mac : les deux sont enregistrées séparément puis mixées dans un `.m4a`.
- 📞 **Automatique** : l'enregistrement démarre quand un appel Téléphone / FaceTime utilise le micro et s'arrête quand tu raccroches. Bouton manuel disponible aussi.
- 📝 **Transcription « Moi / Correspondant »** avec [whisper.cpp](https://github.com/ggml-org/whisper.cpp), entièrement sur ton Mac : rien ne part sur internet.
- 🔇 Les phrases que le micro réentend par les haut-parleurs sont retirées, et les silences sont ignorés (détecteur de voix Silero).
- 📁 Tout est rangé dans `~/Documents/Appels enregistrés/`.

> ⚠️ **Préviens toujours ton correspondant.** Enregistrer une conversation privée sans le consentement de la personne est illégal dans de nombreux pays (en France : article 226-1 du Code pénal).

## Prérequis

- macOS 15 (Sequoia) ou plus récent, Mac Apple Silicon ou Intel
- Pour passer des appels depuis le Mac : un iPhone avec les « Appels sur d'autres appareils » activés (Continuité)
- Pour la transcription (facultatif) : [Homebrew](https://brew.sh)

## Installation

### Option 1 — Télécharger l'app

1. Télécharge `Enregistreur-d-appels.zip` dans les [Releases](../../releases), décompresse-le et glisse l'app dans **Applications**.
2. L'app n'est pas notarisée par Apple : au premier lancement, macOS la bloque. Ouvre **Réglages Système → Confidentialité et sécurité** et clique **« Ouvrir quand même »**. Ou, dans le Terminal :
   ```bash
   xattr -dr com.apple.quarantine "/Applications/Enregistreur d'appels.app"
   ```

### Option 2 — Compiler soi-même

Il faut les outils de développement d'Apple (`xcode-select --install`).

```bash
git clone https://github.com/lucalumpa/enregistreur-appels.git
cd enregistreur-appels
./build.sh            # compile et installe dans ~/Applications
```

`./build.sh --release` produit en plus `build/Enregistreur-d-appels.zip` (app universelle Apple Silicon + Intel).

### Activer la transcription

```bash
brew install whisper-cpp
mkdir -p ~/.whisper && cd ~/.whisper
curl -LO https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin      # ~1,6 Go
curl -LO https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin        # ~1 Mo
```

L'app détecte Whisper toute seule : l'option **« Transcrire chaque appel »** apparaît dans le menu. Compte environ 20 s de calcul par minute d'appel sur un Mac M1.

## Premier lancement

macOS demande deux autorisations : **Micro** et **Enregistrement audio système**. Accepte les deux, sinon l'enregistrement reste bloqué ou silencieux. Coche ensuite **« Lancer à l'ouverture de session »** dans le menu pour que l'app démarre toute seule.

## Si l'enregistrement automatique ne se déclenche pas

Pendant un appel, lance :

```bash
"/Applications/Enregistreur d'appels.app/Contents/MacOS/EnregistreurAppels" --processus
```

La liste montre les processus qui utilisent le micro ; ceux reconnus comme un appel sont marqués `APPEL`. Si ton appel n'y est pas, ajoute son identifiant à `callBundleIDs` dans [`Sources/App.swift`](Sources/App.swift) et ouvre une issue.

## Comment ça marche

| Fichier | Rôle |
|---|---|
| [`App.swift`](Sources/App.swift) | Menu de la barre de menus, détection des appels, démarrage/arrêt automatique |
| [`CallRecorder.swift`](Sources/CallRecorder.swift) | Capture du son système (*process tap* Core Audio) et du micro, puis mixage |
| [`Transcriber.swift`](Sources/Transcriber.swift) | Whisper voix par voix, fusion « Moi / Correspondant », filtres anti-écho et anti-boucles |
| [`CoreAudioUtils.swift`](Sources/CoreAudioUtils.swift) | Petites fonctions d'accès à Core Audio |

## Licence

[MIT](LICENSE)
