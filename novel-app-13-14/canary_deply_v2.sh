#!/bin/bash

# Configuration
URL="http://a6f6260cf16f34d18af65a9793fdfbbf-1952091971.eu-west-1.elb.amazonaws.com"
DURATION=60
MAIN_VERSION="1.3" # Version de base (à ajuster pour le test 1.5)
CANARY_VERSION="1.4" # Version canary (à ajuster pour le test 1.5)
THRESHOLD=25

# Compteurs
total_requests=0
main_errors=0
canary_errors=0
main_requests=0
canary_requests=0

echo "Démarrage des tests Canary pour $DURATION secondes..."
echo "URL: $URL"
echo "Seuil d'erreur: $THRESHOLD%"

# Fonction pour obtenir la version depuis le corps de la réponse
get_version_from_body() {
    # Lire le contenu du fichier temporaire où le corps de la réponse a été enregistré
    local response_body=$(cat "$1") # Prend le nom du fichier en paramètre
    
    # Regex adaptée pour extraire la version du format "Novel (vX.Y)"
    # Elle capture les chiffres et les points après "v" et avant la parenthèse fermante
    local version=$(echo "$response_body" | grep -oP '\(v\K[0-9.]+\)')
    
    if [ -z "$version" ]; then
        echo "unknown" # Fallback si la version n'est pas trouvée
    else
        echo "$version"
    fi
}

# Test pendant DURATION secondes
end_time=$(($(date +%s) + $DURATION))

while [ $(date +%s) -lt $end_time ]; do
    # Faire la requête, capturer le code de statut et enregistrer le corps de la réponse dans un fichier temporaire
    # Utilisation de "$$" pour créer un fichier temporaire unique pour chaque exécution du script
    http_code=$(curl -s -o "/tmp/response_body_$$.txt" -w "%{http_code}" "$URL")
    current_version=$(get_version_from_body "/tmp/response_body_$$.txt") # Passer le nom du fichier temporaire
    
    total_requests=$((total_requests + 1))
    
    is_error=0
    if [[ $http_code -ge 400 ]]; then
        is_error=1
    fi

    # Attribuer la requête à la version main ou canary en fonction de la version détectée dans la réponse
    if [[ "$current_version" == "$CANARY_VERSION" ]]; then
        canary_requests=$((canary_requests + 1))
        if [ $is_error -eq 1 ]; then
            canary_errors=$((canary_errors + 1))
        fi
    elif [[ "$current_version" == "$MAIN_VERSION" ]]; then
        main_requests=$((main_requests + 1))
        if [ $is_error -eq 1 ]; then
            main_errors=$((main_errors + 1))
        fi
    else
        # Gérer les cas où la version est inconnue ou inattendue
        echo "Avertissement: Version inattendue/non détectée: '$current_version' pour la requête $total_requests (HTTP $http_code)"
        # Pour le but de ce script, nous pourrions les attribuer au main par défaut si inconnue
        main_requests=$((main_requests + 1))
        if [ $is_error -eq 1 ]; then
            main_errors=$((main_errors + 1))
        fi
    fi
    
    # Afficher le progrès
    if (( $total_requests % 10 == 0 )); then
        echo -n "."
    fi
    
    # Petite pause pour ne pas surcharger le serveur
    sleep 0.1
done

echo ""
echo "Tests terminés. Analyse des résultats..."

# Calculer les taux d'erreur
if [ $main_requests -gt 0 ]; then
    main_error_rate=$(echo "scale=2; $main_errors * 100 / $main_requests" | bc)
else
    main_error_rate=0
fi

if [ $canary_requests -gt 0 ]; then
    canary_error_rate=$(echo "scale=2; $canary_errors * 100 / $canary_requests" | bc)
else
    canary_error_rate=0
fi

# Calculer la différence
error_rate_diff=$(echo "scale=2; $canary_error_rate - $main_error_rate" | bc)

echo "=== RÉSULTATS ==="
echo "Total des requêtes: $total_requests"
echo "Requêtes version main ($MAIN_VERSION): $main_requests"
echo "Requêtes version canary ($CANARY_VERSION): $canary_requests"
echo "Erreurs version main: $main_errors"
echo "Erreurs version canary: $canary_errors"
echo "Taux d'erreur main: ${main_error_rate}%"
echo "Taux d'erreur canary: ${canary_error_rate}%"
echo "Différence: ${error_rate_diff}%"

echo "=== DÉCISION ==="

# Vérifier si bc retourne un nombre négatif (canary meilleur)
if (( $(echo "$error_rate_diff < 0" | bc -l) )); then
    abs_diff=$(echo "$error_rate_diff * -1" | bc)
else
    abs_diff=$error_rate_diff
fi

if (( $(echo "$abs_diff <= $THRESHOLD" | bc -l) )); then
    echo "✅ Différence de taux d'erreur acceptable (${error_rate_diff}% <= ${THRESHOLD}%)"
    echo "🔄 Mise à jour du déploiement principal vers la version $CANARY_VERSION"
    
    # Supprimer le déploiement canary
    kubectl delete -f ingress-canary.yaml
    kubectl delete -f service-canary.yaml
    kubectl delete -f deployment-canary.yaml
    
    # Mettre à jour l'image du déploiement principal
    kubectl set image deployment/novel-app backend=blentai/hands-on-k8s-canary:$CANARY_VERSION
    
    # Attendre le rollout
    echo "Attente de la fin du rollout du déploiement principal..."
    kubectl rollout status deployment/novel-app --timeout=300s
    
    echo "✅ Mise à jour terminée avec succès"
else
    echo "❌ Différence de taux d'erreur trop élevée (${error_rate_diff}% > ${THRESHOLD}%)"
    echo "🗑️ Suppression du déploiement canary"
    
    # Supprimer seulement le déploiement canary
    kubectl delete -f ingress-canary.yaml
    kubectl delete -f service-canary.yaml
    kubectl delete -f deployment-canary.yaml
    
    echo "✅ Rollback effectué - 100% du trafic redirigé vers la version stable"
fi

# Nettoyage du fichier temporaire après la boucle
rm -f "/tmp/response_body_$$.txt"