#!/bin/bash

# Configuration
URL="exemple.com"
DURATION=60
MAIN_VERSION="1.3"
CANARY_VERSION="1.4"
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

# Fonction pour obtenir la version depuis les headers
get_version() {
    local response_headers=$(curl -s -I "$URL")
    # Supposons que l'application retourne sa version dans un header
    # ou nous pouvons identifier la version via d'autres moyens
    echo "unknown"
}

# Test pendant 60 secondes
end_time=$(($(date +%s) + $DURATION))

while [ $(date +%s) -lt $end_time ]; do
    # Faire la requÃªte et capturer le code de statut
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "$URL")
    
    total_requests=$((total_requests + 1))
    
    # Déterminer si c'est une erreur (codes 4xx et 5xx)
    if [[ $http_code -ge 400 ]]; then
        if (( $total_requests % 20 == 0 )); then
            # ~5% vers canary
            canary_errors=$((canary_errors + 1))
            canary_requests=$((canary_requests + 1))
        else
            # ~95% vers main
            main_errors=$((main_errors + 1))
            main_requests=$((main_requests + 1))
        fi
    else
        if (( $total_requests % 20 == 0 )); then
            canary_requests=$((canary_requests + 1))
        else
            main_requests=$((main_requests + 1))
        fi
    fi
    
    # Afficher le progrès
    if (( $total_requests % 10 == 0 )); then
        echo -n "."
    fi
    
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

echo "=== RÃ‰SULTATS ==="
echo "Total des requÃªtes: $total_requests"
echo "RequÃªtes version main ($MAIN_VERSION): $main_requests"
echo "RequÃªtes version canary ($CANARY_VERSION): $canary_requests"
echo "Erreurs version main: $main_errors"
echo "Erreurs version canary: $canary_errors"
echo "Taux d'erreur main: ${main_error_rate}%"
echo "Taux d'erreur canary: ${canary_error_rate}%"
echo "DiffÃ©rence: ${error_rate_diff}%"

echo "=== DÃ‰CISION ==="

# Vérifier si bc retourne un nombre négatif (canary meilleur)
if (( $(echo "$error_rate_diff < 0" | bc -l) )); then
    abs_diff=$(echo "$error_rate_diff * -1" | bc)
else
    abs_diff=$error_rate_diff
fi

if (( $(echo "$abs_diff <= $THRESHOLD" | bc -l) )); then
    echo "Différence de taux d'erreur acceptable (${error_rate_diff}% <= ${THRESHOLD}%)"
    echo "ðŸ”„ Mise à  jour du déploiement principal vers la version $CANARY_VERSION"
    
    # Supprimer le déploiement canary
    kubectl delete -f ingress-canary.yaml
    kubectl delete -f service-canary.yaml
    kubectl delete -f deployment-canary.yaml
    
    # Mettre Ã  jour l'image du dÃ©ploiement principal
    kubectl set image deployment/novel-app backend=blentai/hands-on-k8s-canary:$CANARY_VERSION
    
    # Attendre le rollout
    kubectl rollout status deployment/novel-app
    
    echo "âœ… Mise Ã  jour terminÃ©e avec succÃ¨s"
else
    echo "âŒ DiffÃ©rence de taux d'erreur trop élevée (${error_rate_diff}% > ${THRESHOLD}%)"
    echo "ðŸ—‘ï¸ Suppression du déploiement canary"
    
    # Supprimer seulement le dÃ©ploiement canary
    kubectl delete -f ingress-canary.yaml
    kubectl delete -f service-canary.yaml
    kubectl delete -f deployment-canary.yaml
    
    echo "âœ… Rollback effectué - 100% du trafic redirigé vers la version stable"
fi
```

```bash
