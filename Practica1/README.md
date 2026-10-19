# Práctica 1: Servidores, Proxies y Certificados

Claudia · 1º ASIR · IES Guadalpeña · Curso 2026/2027

## 1. Decisiones de diseño

**Dominios.** He elegido dos dominios, uno por cada marca:
- `brisa-docs.nimbus.test` es la marca pública. Le puse Brisa porque quería un nombre suave, para la documentación que puede leer cualquiera.
- `cumbre-interno.nimbus.test` es la marca interna. Le puse Cumbre porque suena a algo que está arriba y no es para todos.

Uso `.test` porque es una terminación que existe solo para pruebas y no choca con webs reales. Los dos dominios apuntan a `127.0.0.1` desde el fichero `/etc/hosts`.

**MPM.** He usado `event`. Lo comprobé con `apachectl -V | grep -i mpm`, que me dio `Server MPM: event`. Lo elegí porque Nginx va a mantener muchas conexiones abiertas con Apache, y `event` las gestiona mejor que `prefork`. `prefork` solo hace falta si usas `mod_php`, y aquí solo sirvo páginas estáticas.

**Puerto de Apache.** Apache escucha en `127.0.0.1:8087`. Así dejo libres el 80 y el 443 para Nginx, y como solo escucha en local, nadie de fuera puede saltarse el proxy.

**Fichero sensible.** Se llama `claves_internas.ini`. Es un fichero falso con una clave inventada y está en la marca interna.

## 2. Fase 1: Apache con dos Virtual Hosts

Hice tres ficheros en `sites-available`:
- `000-defecto.conf`: el Virtual Host por defecto.
- `brisa.conf`: la marca pública, en `/var/www/brisa`.
- `cumbre.conf`: la marca interna, en `/var/www/cumbre`.

Cada uno tiene su `DocumentRoot`, su `ErrorLog` y su `CustomLog`. Los activé con `a2ensite`, desactivé el sitio por defecto de Apache con `a2dissite 000-default.conf` y cambié el puerto en `ports.conf` a `Listen 127.0.0.1:8087`.

Con `apachectl -S` comprobé que los tres Virtual Hosts están cargados en el puerto 8087 y que el servidor por defecto es el mío:

```
default server defecto.invalid (/etc/apache2/sites-enabled/000-defecto.conf:1)
port 8087 namevhost defecto.invalid (/etc/apache2/sites-enabled/000-defecto.conf:1)
port 8087 namevhost brisa-docs.nimbus.test (/etc/apache2/sites-enabled/brisa.conf:1)
port 8087 namevhost cumbre-interno.nimbus.test (/etc/apache2/sites-enabled/cumbre.conf:1)
```

### Pruebas con curl

Cada dominio devuelve su contenido:
```
$ curl -H "Host: brisa-docs.nimbus.test" http://127.0.0.1:8087/
<h1>Brisa: documentacion publica</h1>

$ curl -H "Host: cumbre-interno.nimbus.test" http://127.0.0.1:8087/
<h1>Cumbre: zona interna</h1>
```

El fichero sensible está bloqueado (usé `Require all denied` dentro de `<Files>`):
```
$ curl -i -H "Host: cumbre-interno.nimbus.test" http://127.0.0.1:8087/claves_internas.ini
HTTP/1.1 403 Forbidden
```

El listado de directorios está desactivado (`Options -Indexes`). Como se hereda, vale también para las subcarpetas. Lo probé con `/privado/`, que no tiene `index.html`:
```
$ curl -i -H "Host: cumbre-interno.nimbus.test" http://127.0.0.1:8087/privado/
HTTP/1.1 403 Forbidden
```

Un dominio que no existe cae en mi Virtual Host por defecto:
```
$ curl -i -H "Host: otro.dominio.test" http://127.0.0.1:8087/
HTTP/1.1 403 Forbidden
```

### ¿Por qué un dominio desconocido cae en ese Virtual Host?

Apache mira la cabecera `Host` de la petición y busca un Virtual Host con ese `ServerName`. Si no encuentra ninguno, usa el primero que se cargó en ese puerto, y los ficheros de `sites-enabled` se cargan por orden alfabético. Por eso llamé `000-defecto.conf` al mío: empieza por `000`, carga el primero y así decido yo qué pasa en vez de que sea al azar. Ese Virtual Host apunta a una carpeta vacía y da 403, así que un dominio desconocido nunca llega a ver el contenido de una marca.

## 3. Fase 2: Nginx delante de Apache

Nginx es lo único que se ve desde fuera. Recibe todo el tráfico, se encarga del HTTPS y se lo pasa a Apache por el puerto 8087. Toda la configuración está en `/etc/nginx/conf.d/nimbus.conf` (hay una copia en la carpeta `nginx/` del repositorio).

### 3.1 Certificado de laboratorio

Generé una clave con curva ECDSA (`prime256v1`) y un certificado autofirmado a nombre de la marca pública:

```
openssl ecparam -genkey -name prime256v1 -out /etc/nginx/certs/nimbus.key
openssl req -new -x509 -key /etc/nginx/certs/nimbus.key -out /etc/nginx/certs/nimbus.crt -days 365 -subj "/CN=brisa-docs.nimbus.test"
```

La clave privada (`nimbus.key`) no la he subido al repositorio.

### 3.2 TLS

Dejé solo TLS 1.2 y TLS 1.3 con `ssl_protocols TLSv1.2 TLSv1.3;`. Las versiones anteriores tienen fallos conocidos.

Para los cifrados puse solo tres, todos `ECDHE-ECDSA`:
```
ECDHE-ECDSA-AES256-GCM-SHA384
ECDHE-ECDSA-AES128-GCM-SHA256
ECDHE-ECDSA-CHACHA20-POLY1305
```
Los elegí así por dos motivos. El primero es que mi certificado es ECDSA, así que solo sirven las suites ECDSA. El segundo es que todas usan ECDHE, que da *forward secrecy*: aunque alguien robara la clave dentro de un año, no podría descifrar el tráfico guardado de antes.

### 3.3 Redirección de HTTP a HTTPS

El puerto 80 redirige todo al 443 con `return 301 https://$host$request_uri;`.

```
$ curl -i -H "Host: brisa-docs.nimbus.test" http://127.0.0.1/
HTTP/1.1 301 Moved Permanently
Location: https://brisa-docs.nimbus.test/
```

Usé el código **301** porque el cambio a HTTPS es permanente y no algo temporal. Con un 301 el navegador se acuerda y la próxima vez va directo a HTTPS. Un 302 diría que es temporal y haría la ida y vuelta cada vez. (El 308 también es permanente, pero además obliga a mantener el método, y para una web de lectura no hace falta.)

### 3.4 La cabecera Host

**Primero sin la línea `proxy_set_header Host $host;`.** Nginx le manda a Apache el Host `127.0.0.1:8087`, que no coincide con ningún Virtual Host, y Apache me manda al Virtual Host por defecto:

```
$ curl -k -i --resolve brisa-docs.nimbus.test:443:127.0.0.1 https://brisa-docs.nimbus.test/
HTTP/1.1 403 Forbidden
```

**Después de añadir `proxy_set_header Host $host;`**, Apache recibe el nombre original y reparte bien cada marca:

```
$ curl -k --resolve brisa-docs.nimbus.test:443:127.0.0.1 https://brisa-docs.nimbus.test/
<h1>Brisa: documentacion publica</h1>

$ curl -k --resolve cumbre-interno.nimbus.test:443:127.0.0.1 https://cumbre-interno.nimbus.test/
<h1>Cumbre: zona interna</h1>
```

### 3.5 Protocolo y cifrado negociados

```
$ openssl s_client -connect 127.0.0.1:443 -servername brisa-docs.nimbus.test
Protocol  : TLSv1.3
Cipher    : TLS_AES_256_GCM_SHA384
```

Se negoció TLS 1.3, que es lo más moderno que ofrece el servidor.

## 4. Fase 2: Seguridad y límite de peticiones

### 4.1 Cabeceras de seguridad

Añadí tres cabeceras con `add_header ... always;`:
- `Strict-Transport-Security`: le dice al navegador que durante un año use siempre HTTPS con esta web.
- `X-Content-Type-Options: nosniff`: evita que el navegador "adivine" el tipo de un fichero y ejecute algo que no debe.
- `X-Frame-Options: DENY`: la elegí yo. Impide que otra web meta la mía dentro de un `<iframe>` para engañar al usuario (clickjacking). Me pareció importante porque una de las marcas es interna.

```
$ curl -k -I --resolve brisa-docs.nimbus.test:443:127.0.0.1 https://brisa-docs.nimbus.test/
HTTP/1.1 200 OK
Strict-Transport-Security: max-age=31536000; includeSubDomains
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
```

### 4.2 Rate limiting: cómo calculé los valores

Datos del enunciado:
- Un usuario normal hace como máximo 3 peticiones por segundo de forma continua.
- En un pico (varias pestañas a la vez) llega a 6 por segundo.
- El script de scraping hacía más de 20 por segundo.

Mis valores: `rate=4r/s` y `burst=6`.
- **rate=4r/s**: está un poco por encima de las 3 del usuario normal, así que nunca le molesta, pero es mucho menos que las 20 del scraper.
- **burst=6**: es una reserva de 6 peticiones extra, justo el pico legítimo. Con ella, un usuario que recarga varias pestañas no recibe errores.
- **nodelay**: las peticiones de la reserva se atienden al momento y no se retrasan.
- **Código 429**: devuelve "demasiadas peticiones", que es más claro que el 503 por defecto.

Lo imagino como un cubo con 6 litros de reserva que se rellena a 4 litros por segundo. Un usuario normal casi no lo vacía. El scraper lo vacía de golpe y se queda sin agua.

Configuración:
```
limit_req_zone $binary_remote_addr zone=zona_nimbus:10m rate=4r/s;
...
limit_req zone=zona_nimbus burst=6 nodelay;
limit_req_status 429;
```

### 4.3 Prueba con ráfaga

Simulé al scraper con 30 peticiones seguidas:
```
for i in $(seq 1 30); do curl -k -s -o /dev/null -w "%{http_code}\n" --resolve brisa-docs.nimbus.test:443:127.0.0.1 https://brisa-docs.nimbus.test/; done
```
Resultado: las primeras 7 u 8 dieron `200` (la petición normal más la reserva de 6) y el resto dio `429`. El límite bloquea el patrón del scraper.

Para el usuario legítimo hice 6 peticiones seguidas y todas dieron `200`, así que un pico normal no se penaliza.

## 5. Fase 3: Diagnóstico provocado

Provoqué un fallo en Apache y otro en Nginx, de conceptos distintos. Después de cada uno dejé la configuración otra vez bien.

### 5.1 Fallo en Apache: el `.htaccess` no hace nada

Quité el bloque `<Files>` de `cumbre.conf` y puse la misma regla en un fichero `.htaccess` dentro de `/var/www/cumbre`. Después de recargar Apache, el fichero sensible seguía saliendo.

| Síntoma observado | Hipótesis inicial | Comando de diagnóstico usado | Causa real y solución |
|---|---|---|---|
| `curl` a `claves_internas.ini` devuelve su contenido (200) aunque el `.htaccess` dice `Require all denied` | Que el `.htaccess` tuviera un error de sintaxis | `apachectl configtest`, `cat .htaccess` y `grep -ri AllowOverride /etc/apache2/` | `AllowOverride None` es el valor por defecto en Apache, y con él Apache ignora todos los `.htaccess`. Solución: poner la regla dentro del `<Directory>` del Virtual Host (que es lo que hice al final) o activar `AllowOverride` |

Lo que aprendí: la regla estaba bien escrita, pero Apache ni la leía. Lo vi con `grep`, que me enseñó el `AllowOverride None`.

### 5.2 Fallo en Nginx: la zona del rate limiting no se aplica

Comenté la línea `limit_req` del `location`, pero dejé `limit_req_zone` definida. `nginx -t` dijo que todo estaba correcto y el bucle de 30 peticiones dio siempre `200`.

| Síntoma observado | Hipótesis inicial | Comando de diagnóstico usado | Causa real y solución |
|---|---|---|---|
| El bucle de 30 peticiones nunca da 429, todas dan 200 | Que el `rate` fuera demasiado alto | `nginx -T \| grep -n limit_req` | `limit_req_zone` solo **define** la zona (como reservar un cubo), pero no limita nada hasta que `limit_req` la usa dentro del `location`. Solución: volver a poner `limit_req zone=zona_nimbus burst=6 nodelay;` |

Lo que aprendí: que una configuración "sin errores" no significa que haga lo que yo quiero. Con `nginx -T` vi que la zona existía pero ningún sitio la usaba.

## 6. Preparación de la defensa

Practiqué los dos cambios que pueden pedirme:
- **Tercer dominio:** añadí `tercero.nimbus.test` a `/etc/hosts` y probé con curl. Cae en `000-defecto` y da 403, porque ningún Virtual Host se llama así.
- **Cambiar el rate:** cambié `rate=4r/s` por `rate=1r/s`, hice `nginx -t`, recargué y repetí el bucle: ahora se bloquea antes.
