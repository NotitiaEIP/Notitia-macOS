#!/bin/zsh
# Génère une réunion de test (voix de synthèse françaises de macOS) et la dépose dans le dossier temporaire
# du conteneur de Notitia, le seul que l'app sandboxée peut lire. Puis, en Debug :
#   apple/build/Build/Products/Debug/Notitia.app/Contents/MacOS/Notitia -NotitiaDemoMode YES -NotitiaDemoAudio notitia-reunion-test.m4a
# La note « Réunion de test — sprint 3 » apparaît dans Réunions (mode démo : base en mémoire, vraies données intactes).
set -e
cd "${0:A:h}"
work=$(mktemp -d)
i=0
while IFS=$'\t' read -r voice text; do
  i=$((i + 1))
  n=$(printf "%02d" $i)
  if [[ "$voice" == "SILENCE" ]]; then
    echo "$text" > "$work/$n.silence"
  else
    say -v "$voice" -o "$work/$n.aiff" "$text"
  fi
done < script.tsv
swiftc -swift-version 5 -o "$work/concat" concat.swift
out=~/Library/Containers/com.notitia.Notitia/Data/tmp/notitia-reunion-test.m4a
mkdir -p "${out:h}"
"$work/concat" "$work" "$out"
rm -rf "$work"
echo "Fichier prêt : $out"
