#!/usr/bin/env bash
# Uso: ./prueba_limit.sh [cantidad] [pausa_en_segundos]
# Ejemplos: ./prueba_limit.sh        -> 30 peticiones seguidas
#           ./prueba_limit.sh 6      -> 6 peticiones seguidas (usuario normal)
#           ./prueba_limit.sh 20 0.2 -> 20 peticiones con 0,2 s de pausa

DOMINIO="brisa-docs.nimbus.test"
PUERTO="443"

cantidad="${1:-30}"
pausa="${2:-0}"


for ((i=1; i<=cantidad; i++)); do
   codigo=$(curl -k -sS -o /dev/null -w '%{http_code}' \
       --resolve ${DOMINIO}:${PUERTO}:127.0.0.1 \
       https://${DOMINIO}:${PUERTO}/)


   printf '%02d %s\n' "$i" "$codigo"


   if [[ "$pausa" != "0" && "$i" -lt "$cantidad" ]]; then
       sleep "$pausa"
   fi
done
